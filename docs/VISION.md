# Closure — Vision (v2)

跨端本地优先音乐播放器。JUCE 实现，音质与简洁 UI 优先。

## 产品原则

1. **音质第一**：尽量 bit-perfect / 高品质重采样；设备路由清晰可控。
2. **UI 克制**：少控件、大留白；使用标准 macOS 窗口和轻量毛玻璃内容区。
3. **本地优先**：v1 只做本机文件；云同步（Google Drive 等）后置。
4. **跨端同一内核**：音频与曲库逻辑与平台 UI 壳分离；v1 只交付 macOS。

## v1 范围（macOS）

| 做 | 不做 |
|----|------|
| 打开 / 拖入本地音频并播放 | 歌单库 / 扫描整个 Music 目录 |
| 播放 / 暂停 / 停止 / 进度 / 音量 | 均衡器、DSP 插件宿主 |
| 标准 macOS 窗口 + 简洁毛玻璃 UI | Windows / Linux / iOS / Android |
| 常见格式（系统解码 + JUCE 基础格式） | Google Drive / 流媒体 |
| | 歌词、封面抓取、在线元数据 |

## 架构草图

```
┌─────────────────────────────────────┐
│  UI (JUCE components + glass LF)    │  native macOS + visual effect
├─────────────────────────────────────┤
│  AudioEngine                        │  device · transport · formats
├─────────────────────────────────────┤
│  (later) Library / Cloud adapters   │
└─────────────────────────────────────┘
```

- `AudioEngine`：深模块——打开文件、播控、状态回调；UI 不碰设备细节。
- `PlayerPanel` / `GlassLookAndFeel`：可换肤的布局与控件层。
- 曲库、云盘：作为后续 adapter，不进 v1 主路径。

## 音质方向（后续迭代）

- CoreAudio 直通 / Hog mode 最佳努力选项
- 匹配源采样率，避免无谓重采样
- FLAC / ALAC 无损优先路径
- 可选线性相位重采样（非默认）

## UI 方向

- 低透明度浅色背景、适度圆角卡片、细描边
- 浓墨色主操作色，其他控件保持低对比度
- 控件少：Add、播放控制图标、进度、音量
- 中英混排时用系统字体栈，避免花哨装饰字体
