# Closure

跨端音乐播放器（JUCE）。v1 仅 macOS：本地文件播放 + 标准浅色 UI。

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

- 清爽单页布局：当前播放封面、播放列表和底部常驻播放控制
- 默认播放列表：可一次添加多个本地音频或目录，拖入文件和目录会追加到列表
- 播放列表会保存到本地配置，重新打开应用时自动恢复仍存在的文件
- 重复模式：关闭、单曲循环、列表循环，可点击列表中的曲目立即切换
- 后台 read-ahead + 音频线程内 block 级换曲，曲目边界支持 gapless 播放
- 可在播放控制区打开或关闭 gapless 播放模式
- 后台读取标题、艺术家、专辑、时长和 macOS 嵌入封面；缺失标签时回退到文件名
- 本地音频格式（mp3 / flac / wav / aiff / m4a / ogg …）
- 播放 / 暂停 / 停止、上一首 / 下一首、进度条、音量
- 标准 macOS 原生窗口 + 简洁毛玻璃控件界面

## 音频测试

```bash
cmake -B build -DCLOSURE_BUILD_TESTS=ON
cmake --build build --target ClosureAudioTests -j
ctest --test-dir build -R ClosureAudioTests --output-on-failure
```

## 路线图（摘要）

见 [docs/VISION.md](docs/VISION.md)。云同步、跨端、曲库均在本地播放稳定之后。
