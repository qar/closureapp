# Closure for iOS (prototype)

This folder holds the iOS app. The playback engine lives in `../core`. It is
C++17 on Apple's AudioToolbox, with no JUCE and no third-party code.

## Build

```bash
# Core tests (runs on macOS, no device needed)
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build -j
./core/build/closure_core_tests            # add --bench for decode speed

# Listen through the Mac's output
./core/build/closure-play a.flac b.flac
```

## 开发命令

需要完整安装的 Xcode、XcodeGen、CMake 和 fastlane。下面的命令从 `ios/` 运行。
在仓库根目录可用 `make -C ios <命令>`。运行 `make` 可查看全部命令。

| 命令 | 用途 |
|---|---|
| `make test` | 在模拟器运行 iOS 单元测试 |
| `make core-test` | 在 Mac 上编译并测试 C++ 播放内核 |
| `make check` | 合并前检查：工程与 `project.yml` 一致，iOS 和内核测试通过 |
| `make build` | 编译真机 Release 包 |
| `make device` | 编译 Release 包并安装到 iPhone |
| `make launch` | 在 iPhone 上启动已安装的 App |
| `make project` | 修改 `project.yml` 后重新生成工程，并提交生成结果 |
| `make xcode` | 在 Xcode 中打开工程 |
| `make archive`、`make upload` | 归档，然后签名并上传到 App Store Connect |
| `make metadata-push`、`make metadata-fetch` | 上传或下载商店文案 |
| `make release VERSION=0.1.0` | 从 `develop` 创建 `release/0.1.0`，更新版本并在本地提交 |

`make test` 和 `make build` 会显示关键结果，并把完整日志保存在 `build/test.log`
和 `build/device.log`。命令失败时会返回非零退出码。

设备名称、模拟器名称和代理等本机设置放在 `ios/local.mk`。Git 会忽略此文件。
也可以直接指定，例如 `make device DEVICE="My iPhone"`。

```make
DEVICE := My iPhone
SIMULATOR := iPhone 17
```

归档、上传和下载文案的命令需要 App Store Connect API 密钥。将密钥 ID 和 issuer ID
放在 `ios/fastlane/.env`，将 `.p8` 文件放在 `~/.appstoreconnect/private_keys/`。
上传文案也可以使用 fastlane 的 Apple ID 登录。版本号统一读取 `project.yml`。

分支按 git flow 管理。功能分支从 `develop` 创建，完成后合并回 `develop`。
`make release` 要求当前分支为 `develop`，且工作区干净。该命令创建发布分支，
更新版本号，将构建号重置为 `1`，重新生成工程并提交。
完成发布时，将发布分支合并到 `main`，打 `v<版本号>` 标签，再合并回 `develop`。
合并到 `main`、打标签和推送前需要确认。
Xcode Cloud 会通过 `ci_scripts/ci_pre_xcodebuild.sh` 将构建号设为 `CI_BUILD_NUMBER`。

## Getting music in

- Tap **+** to import files or folders from the Files app. The app copies them.
- In Finder, select the iPhone, open **Files › Closure**, and drop files or folders
  there. The app moves them into its library the next time it becomes active.
- "Open in Closure" from the share sheet.

The library lives in `Library/Application Support/Music` and is excluded from the
device's iCloud backup. The index (`library.json`) stores paths relative to that
folder, because the app container path can change after an update.

## Debug launch arguments

`-ClosureAutoplay` plays the first album; add `-ClosureShowNowPlaying` to open the
now playing sheet. Both exist only in Debug builds.

## What the prototype does not do yet

Product requirements, with the status on each platform, live in
[`docs/features.yml`](../docs/features.yml).

- Ogg Vorbis and files with more than two channels.
- Sample-rate switching inside a queue. The rate is chosen when a queue starts.
- Artwork, editing, playlists, search, sync.
