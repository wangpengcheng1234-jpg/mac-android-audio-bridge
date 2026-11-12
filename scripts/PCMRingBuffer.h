#ifndef PCM_RING_BUFFER_H
#define PCM_RING_BUFFER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PCMRingBuffer PCMRingBuffer;

typedef enum {
    PCMRingStatePriming = 0,
    PCMRingStatePlaying = 1,
    PCMRingStateRebuffering = 2,
    PCMRingStateStopping = 3,
    PCMRingStateStopped = 4,
} PCMRingState;

typedef struct {
    uint64_t receivedPCMBytes;
    uint64_t renderedFrames;
    uint64_t underflowEvents;
    uint64_t underflowFrames;
    uint64_t overflowEvents;
    uint64_t overflowFrames;
    uint64_t rebufferEvents;
    size_t availableFrames;
    size_t targetFrames;
    uint32_t state;
    int32_t consumptionRatePPM;
} PCMRingSnapshot;

PCMRingBuffer *pcm_ring_create(size_t capacityFrames);
void pcm_ring_destroy(PCMRingBuffer *ring);
void pcm_ring_reset(PCMRingBuffer *ring);

void pcm_ring_set_target_frames(PCMRingBuffer *ring, size_t targetFrames);
void pcm_ring_set_consumption_rate_ppm(PCMRingBuffer *ring, int32_t ratePPM);
void pcm_ring_request_stop(PCMRingBuffer *ring);

void pcm_ring_note_received_bytes(PCMRingBuffer *ring, size_t byteCount);
void pcm_ring_note_overflow(PCMRingBuffer *ring, size_t frameCount);
size_t pcm_ring_write_interleaved(PCMRingBuffer *ring, const float *samples,
                                  size_t frameCount);

// Fills two non-interleaved output channels. Missing frames are zero-filled.
// This function is allocation-free and lock-free for the single audio consumer.
uint32_t pcm_ring_render(PCMRingBuffer *ring, float *left, float *right,
                         size_t frameCount);

size_t pcm_ring_available_frames(const PCMRingBuffer *ring);
PCMRingSnapshot pcm_ring_snapshot(const PCMRingBuffer *ring);

#ifdef __cplusplus
}
#endif

#endif
