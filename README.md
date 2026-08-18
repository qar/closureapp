# Closure

跨端音乐播放器（JUCE）。v1 仅 macOS：本地文件播放 + 毛玻璃 UI。

旧 Electron 代码冻结在标签 `archive/rebirth-latest`。

## 要求

- macOS 11+
- Xcode + CMake 3.22+
- 本仓库 submodule：`external/JUCE`（8.0.x）

```bash
git submodule update --init --recursive
```

## 构建与运行

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --target ClosureApp -j
open build/ClosureApp_artefacts/Debug/Closure.app
```

## v1 功能

- 默认播放列表：一次添加多个本地音频，拖入文件会追加到列表
- 列表循环播放，可点击列表中的曲目立即切换
- 后台 read-ahead + 音频线程内 block 级换曲，曲目边界支持 gapless 播放
- 本地音频格式（mp3 / flac / wav / aiff / m4a / ogg …）
- 播放 / 暂停 / 停止、进度条、音量
- 窗口级毛玻璃（`NSVisualEffectView`）+ 玻璃卡片 LookAndFeel

## 音频测试

```bash
cmake -B build -DCLOSURE_BUILD_TESTS=ON
cmake --build build --target ClosureAudioTests -j
ctest --test-dir build -R ClosureAudioTests --output-on-failure
```

## 路线图（摘要）

见 [docs/VISION.md](docs/VISION.md)。云同步、跨端、曲库均在本地播放稳定之后。
