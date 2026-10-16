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

首次配置会下载固定版本的 Sparkle，供 macOS 自动更新使用。离线构建可加
`-DCLOSURE_ENABLE_UPDATES=OFF`，此时应用不会检查更新。

## 安装与更新

从 [GitHub Releases](https://github.com/qar/closureapp/releases) 下载最新的
`Closure-<版本>-mac.dmg`，打开后将 `Closure.app` 拖入“应用程序”。发布包同时支持
Intel 和 Apple Silicon，最低系统版本为 macOS 11。

应用启动后会自动检查 GitHub Releases 中的新版本，也可从应用菜单选择
“Check for Updates...”。更新由 Sparkle 下载并校验签名后安装。此应用免费提供；
免费分发并不免除 Apple 代码签名、公证或 JUCE 许可要求。

当前仓库已配置 Sparkle 更新签名密钥。打 `v<版本>` 标签会触发
`.github/workflows/release-macos.yml`，自动发布 DMG 安装包、ZIP 更新包和
`appcast.xml`。标签版本必须与 `CMakeLists.txt` 中的 `project(... VERSION ...)` 一致。
首次发布前应先增加版本号，再推送对应标签。

CI 可选配置 Apple Developer ID 签名和公证，以免用户遇到 Gatekeeper 拦截：

| GitHub Actions Secret | 内容 |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Developer ID Application 证书的 P12 文件，base64 编码 |
| `APPLE_CERTIFICATE_PASSWORD` | P12 密码 |
| `APPLE_SIGNING_IDENTITY` | Developer ID Application 证书名称或 SHA-1 |
| `APPLE_NOTARY_APPLE_ID` | 公证使用的 Apple ID |
| `APPLE_NOTARY_PASSWORD` | App 专用密码 |
| `APPLE_NOTARY_TEAM_ID` | Apple Developer Team ID |

没有这些可选 Secret 时仍会发布经过 Sparkle 签名的免费安装包，但 macOS
Gatekeeper 可能要求用户在“隐私与安全性”中手动允许首次打开。更新私钥存于
`SPARKLE_EDDSA_PRIVATE_KEY` Secret；备份留在本机钥匙串的 `com.qar.closure`
账户中，勿将私钥提交到仓库。

本地也可以运行 `bash scripts/package-macos.sh <Closure.app 路径> dist` 生成
DMG 和 ZIP。`swift scripts/generate-icon.swift assets/ClosureIcon.png` 可重新生成图标。

## v1 功能

- 清爽单页布局：当前播放封面、播放列表和底部常驻播放控制
- 当前播放封面区域可切换为实时音频频谱显示
- 默认播放列表：可一次添加多个本地音频或目录，拖入文件和目录会追加到列表
- 播放列表会保存到本地配置，重新打开应用时自动恢复仍存在的文件
- 重复模式：关闭、单曲循环、列表循环，可点击列表中的曲目立即切换
- 后台 read-ahead + 音频线程内 block 级换曲，曲目边界支持 gapless 播放
- 可在播放控制区打开或关闭 gapless 播放模式
- 后台读取标题、艺术家、专辑、时长和 macOS 嵌入封面；缺失标签时回退到文件名
- 左侧当前播放区域支持内嵌歌词；无内嵌歌词时回退到同名 `.lrc` 文件
- 本地歌词缺失时按歌曲 metadata 自动查询 LRCLIB，并缓存查询结果
- 专辑详情支持手动匹配 MusicBrainz，并补全发行信息和 Cover Art Archive 封面
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
