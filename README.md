# TransAudio

> 把 Android 手机的系统声音实时送到 Mac 播放 —— 走 ADB（Wi‑Fi 或 USB），不依赖蓝牙。
> 单窗口 GUI，一个按钮开关，可在界面上调音频缓冲 / 码率 / 编码。

[界面截图]
<img width="796" height="508" alt="screenshot" src="https://github.com/user-attachments/assets/d471c413-d906-4b73-9a6d-db115b61941d" />


---

## 为什么不用蓝牙？

macOS 的蓝牙栈**不提供 A2DP Sink（接收端）**角色：系统设置里只有"输出"，没有"输入"，Mac 无法作为蓝牙音箱被手机连接。GitHub 上唯一的 macOS 方案
`airander/A2DP-SINK` 早在 2014 年就归档且只接收 RTP 包、不做解码。

所以在 macOS 上接收 Android 音频，可行路径是 **ADB + scrcpy 的音频采集能力**：手机端用 Android 的
`AudioPlaybackCapture`（Android 11+）抓取系统混音，编码后经 adb 传到 Mac 播放。

## 特性

- **Native CoreAudio 播放（默认）**：保留 scrcpy 的 ADB、demux 和 decoder，由 App 通过有界 PCM ring 与 `AVAudioEngine` 统一播放，不再叠加官方 SDL/regulator 缓冲
- **Legacy 显式回退**：仍可手动选择官方 scrcpy 5.0.1 播放链；单次会话不会静默切换引擎
- **单窗口 App**：状态、输出设备、实测网络延迟、音频参数集中在一个界面里
- **一键开关**：START / STOP、启动失败、client 异常、断网和关窗均走同一清理入口
- **参数可调**：Auto 或 50/100/200/350/500 ms 缓冲、96K–320K 码率、opus/aac/flac/raw，以及 Native/Legacy 引擎
- **真实 PCM 统计**：Native 的 `Data Received` 显示实际收到的解码后 PCM 字节数，不是网络编码流量或时间估算
- **真实延迟测量**：定时 `ping` 手机，显示 Wi-Fi 往返 RTT（颜色分档）
- **自动恢复手机声音**：启动/停止/关窗都会清理手机端残留的 `scrcpy-server` 进程，避免“电脑关了手机反而没声音”
- **自动找设备**：优先 USB，其次用记住的 IP 走无线；失效会自动重启 adb 服务重试
- **应用播放采集**：默认使用 `--audio-source=playback`（Android `AudioPlaybackCapture`），修复部分 HyperOS 设备用 `output` 采集抖音直播时只有静音的问题
- **不改变系统默认输出**：Native 只读取并绑定 Start 时的当前输出设备，不切换 macOS 默认输出设备

## 推荐设置

> 日常使用可先从 **Native + Auto + 128K + opus** 开始。Auto 会根据启动时的网络测量选择缓冲；Wi-Fi 下限为 100ms，连续欠载时逐步增加，最高 500ms。
>
> 若希望排除有损编码因素，可选择 `raw`（约 1.5 Mbps）或 `flac`；它们不接收 Bitrate 参数。网络不稳定时，增大 Buffer 或改用 USB 比单纯提高码率更有效。

其他环境：

| 环境 | Buffer | Bitrate | Codec |
|---|---|---|---|
| Wi-Fi 一般 / 有卡顿 | 500 ms | 128K | opus |
| 2.4GHz / 弱信号 | 500 ms | 96K | opus |
| 最稳（任何网络） | 200 ms | 192K | aac + **USB 直连** |

### Bitrate 与音质的对应关系

> 先澄清一个概念：**Bitrate（码率）≠ 采样率/位深**。采集编码源的采样率和位深固定为
> **48 kHz / 16-bit 立体声**，所以不存在“16-bit 96 kHz”这种档位；Bitrate 只决定有损编码器每秒用多少数据逼近源音频。
> Native 在解码后统一转换为 48kHz / Float32 / stereo，再交给 CoreAudio；这不改变源音频本身的无损或有损属性。
> 想要避免额外的有损编码伪影，可选 `flac` 或 `raw`。

| Bitrate | opus 听感 | aac 听感 | 建议 |
|---|---|---|---|
| 96K | 广播级，复杂音乐偶有轻微伪影 | 勉强可用 | 弱网保底 |
| 128K | 多数人听不出与原声的区别（"透明"） | 接近透明 | 默认 |
| 192K | 完全透明 | 透明 | 日常推荐 |
| 256K | 已超出人耳感知，收益递减 | 同上 | 高要求场景 |
| 320K | 接近 opus 编码器上限 | aac 上限 | 天花板，再高无意义 |
| —（flac / raw） | 避免额外的有损编码 | — | 用于排除编码伪影，不保证消除网络或播放欠载 |

## 工作原理

### Native（默认）

```text
手机 (Android 11+)
  → AudioPlaybackCapture → opus/aac/flac/raw
  → ADB（USB 或 TCP/IP 5555）
  → 定制 scrcpy-coreaudio：官方 demux / decoder 输出 AVFrame
  → swresample：48kHz、Float32 LE、stereo、interleaved
  → 本机 Unix domain socket
  → App 自有 1 秒有界 SPSC PCM ring
  → AVAudioSourceNode → AVAudioEngine → Start 时的当前输出设备
```

Native 保留官方 Android server、ADB、传输和解码，只替换 Mac 端 SDL/regulator 播放。App 统一管理缓冲、播放、统计和生命周期；收到首个有效解码 PCM 后才显示 `STREAMING · NATIVE`。环形缓冲负责欠载零填、重缓冲、5ms 淡入淡出和最高 ±0.5% 的平滑消费率校正。

### Legacy（手动回退）

官方 `scrcpy` client 使用原 SDL/regulator 播放链。界面明确显示 `STREAMING · LEGACY`，不会在一次会话中自动从 Native 切换过去。

两种模式都不会修改 macOS 默认输出设备。Stop 会停止播放器、client、日志及手机端相关 server，并清理本机 socket。

## 环境要求

| 项目 | 要求 |
|---|---|
| Mac | macOS 13 及以上（本项目按 `arm64-apple-macos13.0` 编译，Intel 机器改一下自己的 `-target` 即可） |
| 手机 | Android 11+，已开启「开发者选项 → USB 调试」（无线还需「无线调试」） |
| scrcpy | 5.0.1（Native 补丁和官方 server 均固定此版本；[官方发布页](https://github.com/Genymobile/scrcpy/releases)） |
| adb | Android platform-tools 里的 `adb`（scrcpy 自带一份也可用） |

## 安装

### 方式一：自己构建（推荐）

需要 macOS arm64、Xcode Command Line Tools（`clang` / `swiftc`）和 Python 3，不需要 Homebrew 或管理员权限。

```bash
git clone https://github.com/wangpengcheng1234-jpg/mac-android-audio-bridge.git
cd mac-android-audio-bridge

# 1. 下载官方 scrcpy 5.0.1 macOS arm64，保证同时存在：
#    scrcpy/scrcpy-macos-aarch64-v5.0.1/scrcpy
#    scrcpy/scrcpy-macos-aarch64-v5.0.1/scrcpy-server

# 2. 构建 Native client；固定版本与 SHA256，源码/工具/缓存均在 .build
bash scripts/build-scrcpy-coreaudio.sh

# 3. 编译 App，打包官方 client、Native client 和官方 server，并从内到外签名
bash scripts/build.sh

# 4. 产物：dist/TransAudio.app，拖进 /Applications 即可
```

Native 构建脚本会在项目 `.build` 的 Python venv 中安装固定版本 Meson、Ninja、CMake 和 pkgconf，并静态构建 SDL 3.4.18、FFmpeg 9.0.2 与 scrcpy 5.0.1。每阶段检查 `.build` 占用，超过 4GB 会停止。输出 client 会检查 arm64 架构及动态依赖，不允许引用 `/opt/homebrew` 或 `/usr/local` 动态库。

App 会按以下顺序查找 scrcpy：`UserDefaults 里的 scrcpyDir` → `App/Contents/Resources/scrcpy` →
`~/scrcpy/scrcpy-macos-aarch64-v5.0.1` → `~/Downloads/scrcpy-macos-aarch64-v5.0.1`。若只保留官方 client，可在界面明确选择 Legacy；Native 不会伪装成已构建成功。

### 方式二：直接用已构建的 App

把 App 放进 `/Applications`，首次启动允许「查找本地网络中的设备」。

## 使用

1. 手机上开启「开发者选项」和「USB 调试」。
2. **先用 USB 连一次**（这一步最省事）：`adb devices` 能看到设备后，打开 App 点 `START BRIDGE` 就能出声。
3. 想走无线：

```bash
adb tcpip 5555                     # 切到 TCP/IP 模式
adb connect <手机IP>:5555          # 例如 192.168.1.20:5555
```

之后拔掉 USB，App 里点 `START BRIDGE` 即可（首次会弹窗让你填手机 IP，成功后会记住）。

> 手机与 Mac 需要在同一个 Wi‑Fi；建议 5GHz、靠近路由器、手机别息屏/别开省电模式。

## 界面与参数

| 区域 | 内容 |
|---|---|
| System Info | 目标设备、Native/Legacy 状态、传输方式（USB / Wi‑Fi）、编码、运行时长、已接收量 |
| Performance & Levels | Mac 音量、当前输出设备（疑似蓝牙音箱时会提示）、实测网络延迟 RTT |
| 参数行 | `Buffer` / `Bitrate` / `Codec` / `Engine`，传输中锁定，改动在下次 START 生效 |

**Data Received 的口径随引擎明确区分**：Native 显示真实接收的解码后 PCM 字节数；它不包含协议头，也不是网络编码流量，静音 PCM 同样计入。Legacy 没有 PCM 回传，仍显示 `≈` 开头的时间估算值。Native 在首个有效 PCM 到达前显示 `WAITING PCM…`，不会仅因进程启动就宣称正在播放。`Network Latency` 是 `ping -c 2` 得到的平均往返时间。

### 卡顿 / 电流声怎么调

| 症状 | 建议 |
|---|---|
| 卡顿、断续 | `Buffer` 调到 350–500 ms；仍卡就改用 **USB**（最稳） |
| 滋滋/电流声 | `Codec` 换 `raw`（无损 PCM，彻底无编码伪影）；带宽不够再退回 `aac` + 192K |
| 延迟忽高忽低 | 看 `Network Latency`；换 5GHz、靠近路由器、关闭手机省电 |

## 常见问题

**点 START 提示"未找到手机"**
手机不在线或无线调试没开；App 会自动重启 adb 服务重试一次，仍失败就用 USB 连一次或重新
`adb connect`。

**显示已连接、Data Received 在增长，但抖音直播无声**
Native 的字节数只证明收到了 PCM，不证明 PCM 非静音；Legacy 的数值更是时间估算，两者都不能单独判断是否有可听声音。部分 HyperOS 设备使用 scrcpy 默认 `--audio-source=output` 时，会把抖音直播采成全 0 PCM；本项目已改用 `--audio-source=playback`，直接捕获应用媒体播放。若某个 App 明确禁止音频采集、内容受 DRM 保护，或手机媒体音量为 0，仍可能无声。

**关闭程序后手机没声音**
旧版 scrcpy 被强杀时机端的 `scrcpy-server` 会残留并继续占用音频路由。本项目已处理：启动、停止、
关窗都会清理残留；若遇到，可手动执行：

```bash
adb shell ps -A -o PID,ARGS | grep scrcpy
adb shell kill -9 <PID>
```

**手机音量条上还是"手机喇叭"图标**
这是方案固有限制，不是 bug：Mac 不是手机的音频输出设备，Android 仍按本机扬声器路由，抓的是系统混音。
功能不受影响（声音照样会到 Mac）。

**需要 macOS 权限吗？**
只需要首次启动时的「本地网络」授权（用于连手机）。不需要录屏、麦克风或辅助功能权限。

## 隐私

- 不采集、不上报任何数据；没有遥测/联网回传。
- 唯一的网络行为是**本机 adb 连接你的手机**，以及 `ping` 手机 IP 测延迟。
- 手机 IP、音量、编码参数只保存在本机 `UserDefaults`（`local.macaudio.phone`）。

## 代码来源与致谢

AppKit 界面、PCM ring 和 CoreAudio 播放器为本项目代码；`packaging/scrcpy-5.0.1-coreaudio.patch` 包含对官方 scrcpy `audio_player.c` / `audio_player.h` 的最小修改。Native 构建脚本会下载固定版本第三方源码到本地 `.build`，源码包不计入项目 Git 仓库。

| 来源 | 作用 | 许可 |
|---|---|---|
| [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) 5.0.1 | Android server、ADB、demux、decode；Native PCM sink 补丁及 Legacy client | Apache License 2.0 |
| [FFmpeg](https://ffmpeg.org/) 9.0.2 | 官方 decoder、`AVFrame` 与 `swresample` 格式转换；静态链接 | 当前未启用 GPL/nonfree 组件的构建采用 LGPL 2.1 或更高版本条款 |
| [SDL](https://www.libsdl.org/) 3.4.18 | 保留 scrcpy 官方构建依赖及非音频功能；Native 不使用 SDL 音频播放 | zlib License |
| [Android platform-tools (adb)](https://developer.android.com/tools/releases/platform-tools) | 设备连接、TCP/IP、音频音量与进程管理 | Android SDK 相关许可（Apache 2.0 等） |
| [spyalekos/spyblue](https://github.com/spyalekos/spyblue) | **仅参考**其终端仪表盘的配色与布局风格 | 原仓库未声明许可证，因此本项目未使用其任何代码 |
| 图标 | 本项目自绘（深色圆角 + 手机轮廓 + 声波） | 随本项目 MIT |

分发包含静态第三方库的 App 时，还需同时遵守各组件的许可证及对应源代码提供、修改说明等义务；本项目 MIT 许可证不替代这些条款。

## 许可证

[MIT](LICENSE) © 2026 iTrae

## 免责声明

仅供个人学习与自用。使用 scrcpy 的音频采集依赖 Android 的 `AudioPlaybackCapture`，
部分 App（带 DRM 或明确禁止采集）可能无声；请遵守当地法律与各 App 的服务条款。
