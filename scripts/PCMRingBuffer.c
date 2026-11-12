#include "PCMRingBuffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define PCM_RING_FADE_FRAMES 240 // 5 ms at 48 kHz
#define PCM_RING_Q32_ONE UINT64_C(0x100000000)

struct PCMRingBuffer {
    size_t capacity;
    float *left;
    float *right;

    _Atomic size_t targetFrames;
    _Atomic uint64_t readPosition; // Q32 frame index, written by consumer only
    _Atomic uint64_t writePosition; // whole frames, written by producer only
    _Atomic uint64_t readStep; // Q32 frames per output frame
    _Atomic uint32_t state;
    _Atomic float gain;
    _Atomic uint32_t fadeRemaining;

    _Atomic uint64_t receivedPCMBytes;
    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t underflowEvents;
    _Atomic uint64_t underflowFrames;
    _Atomic uint64_t overflowEvents;
    _Atomic uint64_t overflowFrames;
    _Atomic uint64_t rebufferEvents;
};

static uint32_t pcm_ring_load_state(const PCMRingBuffer *ring) {
    return atomic_load_explicit((_Atomic uint32_t *)&ring->state,
                                memory_order_acquire);
}

PCMRingBuffer *pcm_ring_create(size_t capacityFrames) {
    if (capacityFrames < 2) {
        return NULL;
    }
    PCMRingBuffer *ring = calloc(1, sizeof(*ring));
    if (!ring) {
        return NULL;
    }
    ring->capacity = capacityFrames;
    ring->left = calloc(capacityFrames, sizeof(float));
    ring->right = calloc(capacityFrames, sizeof(float));
    if (!ring->left || !ring->right) {
        pcm_ring_destroy(ring);
        return NULL;
    }
    atomic_init(&ring->targetFrames, 0);
    atomic_init(&ring->readPosition, 0);
    atomic_init(&ring->writePosition, 0);
    atomic_init(&ring->readStep, PCM_RING_Q32_ONE);
    atomic_init(&ring->state, PCMRingStatePriming);
    atomic_init(&ring->gain, 0.0f);
    atomic_init(&ring->fadeRemaining, 0);
    return ring;
}

void pcm_ring_destroy(PCMRingBuffer *ring) {
    if (!ring) {
        return;
    }
    free(ring->left);
    free(ring->right);
    free(ring);
}

void pcm_ring_reset(PCMRingBuffer *ring) {
    if (!ring) {
        return;
    }
    atomic_store_explicit(&ring->readPosition, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->writePosition, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->readStep, PCM_RING_Q32_ONE,
                          memory_order_relaxed);
    atomic_store_explicit(&ring->state, PCMRingStatePriming,
                          memory_order_release);
    atomic_store_explicit(&ring->gain, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&ring->fadeRemaining, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->receivedPCMBytes, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->renderedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->underflowEvents, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->underflowFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->overflowEvents, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->overflowFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->rebufferEvents, 0, memory_order_relaxed);
}

void pcm_ring_set_target_frames(PCMRingBuffer *ring, size_t targetFrames) {
    if (!ring) {
        return;
    }
    if (targetFrames > ring->capacity / 2) {
        targetFrames = ring->capacity / 2;
    }
    atomic_store_explicit(&ring->targetFrames, targetFrames,
                          memory_order_release);
}

void pcm_ring_set_consumption_rate_ppm(PCMRingBuffer *ring, int32_t ratePPM) {
    if (!ring) {
        return;
    }
    if (ratePPM < 995000) {
        ratePPM = 995000;
    } else if (ratePPM > 1005000) {
        ratePPM = 1005000;
    }
    uint64_t step = (PCM_RING_Q32_ONE * (uint64_t) ratePPM) / UINT64_C(1000000);
    atomic_store_explicit(&ring->readStep, step, memory_order_release);
}

void pcm_ring_request_stop(PCMRingBuffer *ring) {
    if (!ring) {
        return;
    }
    uint32_t state = pcm_ring_load_state(ring);
    if (state == PCMRingStateStopped) {
        return;
    }
    if (state != PCMRingStatePlaying || atomic_load_explicit(&ring->gain,
                                                             memory_order_relaxed) <= 0.0f) {
        atomic_store_explicit(&ring->state, PCMRingStateStopped,
                              memory_order_release);
        return;
    }
    atomic_store_explicit(&ring->fadeRemaining, PCM_RING_FADE_FRAMES,
                          memory_order_relaxed);
    atomic_store_explicit(&ring->state, PCMRingStateStopping,
                          memory_order_release);
}

void pcm_ring_note_received_bytes(PCMRingBuffer *ring, size_t byteCount) {
    if (ring) {
        atomic_fetch_add_explicit(&ring->receivedPCMBytes, byteCount,
                                  memory_order_relaxed);
    }
}

void pcm_ring_note_overflow(PCMRingBuffer *ring, size_t frameCount) {
    if (!ring || frameCount == 0) {
        return;
    }
    atomic_fetch_add_explicit(&ring->overflowEvents, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&ring->overflowFrames, frameCount,
                              memory_order_relaxed);
}

size_t pcm_ring_write_interleaved(PCMRingBuffer *ring, const float *samples,
                                  size_t frameCount) {
    if (!ring || !samples || frameCount == 0 ||
        pcm_ring_load_state(ring) >= PCMRingStateStopping) {
        return 0;
    }
    uint64_t readPosition = atomic_load_explicit(&ring->readPosition,
                                                 memory_order_acquire);
    uint64_t readIndex = readPosition >> 32;
    uint64_t writeIndex = atomic_load_explicit(&ring->writePosition,
                                               memory_order_relaxed);
    uint64_t used = writeIndex - readIndex;
    if (used >= ring->capacity) {
        return 0;
    }
    size_t available = ring->capacity - (size_t) used;
    size_t count = frameCount < available ? frameCount : available;
    for (size_t i = 0; i < count; ++i) {
        size_t index = (size_t) ((writeIndex + i) % ring->capacity);
        ring->left[index] = samples[i * 2];
        ring->right[index] = samples[i * 2 + 1];
    }
    atomic_store_explicit(&ring->writePosition, writeIndex + count,
                          memory_order_release);
    return count;
}

static void pcm_ring_start_playing(PCMRingBuffer *ring) {
    atomic_store_explicit(&ring->gain, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&ring->fadeRemaining, PCM_RING_FADE_FRAMES,
                          memory_order_relaxed);
    atomic_store_explicit(&ring->state, PCMRingStatePlaying,
                          memory_order_release);
}

uint32_t pcm_ring_render(PCMRingBuffer *ring, float *left, float *right,
                         size_t frameCount) {
    if (!ring || !left || !right) {
        return PCMRingStateStopped;
    }
    memset(left, 0, frameCount * sizeof(float));
    memset(right, 0, frameCount * sizeof(float));

    uint32_t state = pcm_ring_load_state(ring);
    if (state == PCMRingStateStopped) {
        return state;
    }

    uint64_t writeIndex = atomic_load_explicit(&ring->writePosition,
                                               memory_order_acquire);
    uint64_t readPosition = atomic_load_explicit(&ring->readPosition,
                                                 memory_order_relaxed);
    uint64_t readIndex = readPosition >> 32;
    size_t available = writeIndex > readIndex
                     ? (size_t) (writeIndex - readIndex) : 0;

    if (state == PCMRingStatePriming || state == PCMRingStateRebuffering) {
        size_t target = atomic_load_explicit(&ring->targetFrames,
                                             memory_order_acquire);
        if (available < target || available == 0) {
            return state;
        }
        pcm_ring_start_playing(ring);
        state = PCMRingStatePlaying;
    }

    float gain = atomic_load_explicit(&ring->gain, memory_order_relaxed);
    uint32_t fadeRemaining = atomic_load_explicit(&ring->fadeRemaining,
                                                  memory_order_relaxed);
    uint64_t step = atomic_load_explicit(&ring->readStep,
                                         memory_order_acquire);
    size_t produced = 0;

    for (; produced < frameCount; ++produced) {
        readIndex = readPosition >> 32;
        if (readIndex >= writeIndex) {
            if (state == PCMRingStateStopping) {
                gain = 0.0f;
                fadeRemaining = 0;
                state = PCMRingStateStopped;
                atomic_store_explicit(&ring->state, state, memory_order_release);
            }
            break;
        }
        uint64_t nextIndex = readIndex + 1 < writeIndex ? readIndex + 1
                                                       : readIndex;
        size_t index = (size_t) (readIndex % ring->capacity);
        size_t next = (size_t) (nextIndex % ring->capacity);
        float fraction = (float) ((readPosition & UINT64_C(0xffffffff)) /
                                  (double) PCM_RING_Q32_ONE);
        float l = ring->left[index]
                + (ring->left[next] - ring->left[index]) * fraction;
        float r = ring->right[index]
                + (ring->right[next] - ring->right[index]) * fraction;

        if (state == PCMRingStateStopping) {
            if (fadeRemaining > 0) {
                gain -= 1.0f / (float) PCM_RING_FADE_FRAMES;
                --fadeRemaining;
            }
            if (gain <= 0.0f || fadeRemaining == 0) {
                gain = 0.0f;
                state = PCMRingStateStopped;
                atomic_store_explicit(&ring->state, state,
                                      memory_order_release);
                break;
            }
        } else if (fadeRemaining > 0) {
            gain += 1.0f / (float) PCM_RING_FADE_FRAMES;
            if (gain > 1.0f) {
                gain = 1.0f;
            }
            --fadeRemaining;
        }

        left[produced] = l * gain;
        right[produced] = r * gain;
        readPosition += step;
    }

    atomic_store_explicit(&ring->readPosition, readPosition,
                          memory_order_release);
    atomic_store_explicit(&ring->gain, gain, memory_order_relaxed);
    atomic_store_explicit(&ring->fadeRemaining, fadeRemaining,
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&ring->renderedFrames, produced,
                              memory_order_relaxed);

    if (state == PCMRingStatePlaying && produced < frameCount) {
        size_t missing = frameCount - produced;
        atomic_fetch_add_explicit(&ring->underflowEvents, 1,
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->underflowFrames, missing,
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->rebufferEvents, 1,
                                  memory_order_relaxed);
        atomic_store_explicit(&ring->readPosition, writeIndex << 32,
                              memory_order_release);
        atomic_store_explicit(&ring->gain, 0.0f, memory_order_relaxed);
        atomic_store_explicit(&ring->fadeRemaining, 0, memory_order_relaxed);
        state = PCMRingStateRebuffering;
        atomic_store_explicit(&ring->state, state, memory_order_release);
    }
    return state;
}

size_t pcm_ring_available_frames(const PCMRingBuffer *ring) {
    if (!ring) {
        return 0;
    }
    uint64_t writeIndex = atomic_load_explicit(&ring->writePosition,
                                               memory_order_acquire);
    uint64_t readPosition = atomic_load_explicit(&ring->readPosition,
                                                 memory_order_acquire);
    uint64_t readIndex = readPosition >> 32;
    return writeIndex > readIndex ? (size_t) (writeIndex - readIndex) : 0;
}

PCMRingSnapshot pcm_ring_snapshot(const PCMRingBuffer *ring) {
    PCMRingSnapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
    if (!ring) {
        return snapshot;
    }
    snapshot.receivedPCMBytes = atomic_load_explicit(&ring->receivedPCMBytes,
                                                     memory_order_relaxed);
    snapshot.renderedFrames = atomic_load_explicit(&ring->renderedFrames,
                                                   memory_order_relaxed);
    snapshot.underflowEvents = atomic_load_explicit(&ring->underflowEvents,
                                                    memory_order_relaxed);
    snapshot.underflowFrames = atomic_load_explicit(&ring->underflowFrames,
                                                    memory_order_relaxed);
    snapshot.overflowEvents = atomic_load_explicit(&ring->overflowEvents,
                                                   memory_order_relaxed);
    snapshot.overflowFrames = atomic_load_explicit(&ring->overflowFrames,
                                                   memory_order_relaxed);
    snapshot.rebufferEvents = atomic_load_explicit(&ring->rebufferEvents,
                                                   memory_order_relaxed);
    snapshot.availableFrames = pcm_ring_available_frames(ring);
    snapshot.targetFrames = atomic_load_explicit(&ring->targetFrames,
                                                 memory_order_acquire);
    snapshot.state = pcm_ring_load_state(ring);
    uint64_t step = atomic_load_explicit(&ring->readStep, memory_order_acquire);
    snapshot.consumptionRatePPM = (int32_t) ((step * UINT64_C(1000000)) /
                                             PCM_RING_Q32_ONE);
    return snapshot;
}
