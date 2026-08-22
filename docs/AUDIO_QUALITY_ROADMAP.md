# Audio Quality Roadmap

当前版本：`0.2.3`

本文记录 Closure 后续音频质量工作的范围。本轮只确定版本和路线，不实现以下音频输出改造。

## 当前基线

- 音频文件由 JUCE 解码为 PCM，支持 FLAC、ALAC、WAV、AIFF、OGG、MP3 等格式。
- 输出链路使用 JUCE `AudioDeviceManager`、`AudioSourcePlayer` 和 `AudioTransportSource`。
- 当源采样率和设备采样率不一致时，当前使用 JUCE `ResamplingAudioSource`。
- 当前没有 ReplayGain、响度标准化、均衡器或其他音频 DSP。
- 当前音量接口是 `float`，因此不能宣称端到端 64-bit 音频路径。
- macOS CoreAudio 共享模式下，当前不能宣称真正的独占或硬件级 bit-perfect。

## 后续任务

### 1. 设备采样率匹配

- 查询当前设备支持的采样率。
- 在播放会话开始前，尽量将设备采样率匹配到当前播放上下文的源采样率。
- 读取并验证设备实际采样率，不能只相信请求值。
- 采样率切换失败时安全回退，并明确提示或记录状态。
- 以专辑或播放上下文为切换单位，避免每首歌切换 CoreAudio 设备。

### 2. 直通 / Bit-perfect 最佳努力模式

- 提供可选模式，关闭软件增益、ReplayGain、Limiter、SRC 和声道混合。
- 只有源格式、声道布局和设备采样率满足条件时才允许进入直通状态。
- macOS 上将 CoreAudio Hog mode 作为可选的最佳努力方案，不宣称所有设备都支持真正独占。
- 记录设备不支持、系统混音或蓝牙/AirPlay/HDMI 转换等无法保证的边界。
- 直通条件不满足时 fail-closed 或明确回退到普通高质量模式，不能静默声称 bit-perfect。

### 3. 双精度音量与 DSP 参数链

- 用 `double` 计算用户音量、前级增益和 ReplayGain 线性增益。
- 在音频线程内使用无锁或原子化参数，并对增益变化做平滑，避免 click。
- 保持 `AudioTransportSource` 和设备输出增益为 unity，避免重复增益。
- 明确 JUCE 当前 `AudioSource` 和 CoreAudio callback 仍以 `float` 为主，不能将其描述成端到端 double sample path。

### 4. ReplayGain

- 读取 `REPLAYGAIN_TRACK_GAIN`、`REPLAYGAIN_TRACK_PEAK`、`REPLAYGAIN_ALBUM_GAIN` 和 `REPLAYGAIN_ALBUM_PEAK`。
- 支持 Track 模式和 Album 模式，并提供 preamp 与 clipping prevention 策略。
- 标签缺失时保持 unity gain，不阻塞播放。
- 曲目切换时使用平滑增益过渡。
- 对重采样后的 intersample peak 保持清晰边界，必要时单独设计 true-peak limiter。

### 5. 高质量可配置重采样

- 先保留当前 JUCE 重采样作为低开销默认策略。
- 评估 JUCE `WindowedSincInterpolator`、Apple `AudioConverter`/`AVAudioConverter` 和专用外部 SRC 的实现成本与延迟。
- 高质量模式必须包含合理的抗混叠低通、EOF、seek、延迟补偿和跨 block 边界处理。
- 对 44.1kHz、48kHz、88.2kHz、96kHz 之间的升采样和降采样做 sweep、impulse 与 Nyquist 附近信号测试。
- 明确高质量模式的 CPU、延迟和内存代价，不默认牺牲实时稳定性。

## 验收原则

- 不以主观听感作为唯一结论。
- 设备采样率、实际输出格式和是否发生 SRC 必须可观测。
- 使用固定测试信号验证频响、alias、延迟、增益误差和曲目边界。
- 对 bit-perfect 只能验证应用层 PCM 路径；DAC 之前的系统、驱动和硬件处理必须单独说明。
