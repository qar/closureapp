# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Electron（v10.1.2）+ React 16 桌面音乐播放器。渲染进程用 webpack 打包，音频播放基于 SoundManager2，数据持久化用 NeDB（嵌入式文档数据库，无需服务）。

## 常用命令

```bash
yarn start          # webpack --watch 开发构建（输出到 bundle/bundle.js），需保持运行
yarn run electron   # 启动 Electron（依赖 bundle/ 已生成，需与 yarn start 配合，开两个终端）
yarn pack           # 生产构建（buildconfig/prod.config.js）
yarn dist           # 生产构建 + electron-builder 打包分发
```

注意：
- package.json 里的 `test` / `eject` 脚本引用 react-scripts，但它不在依赖中——**没有可用的测试设施**，这两个脚本是残留，不要使用。
- README 中提到的 electron-packager / `yarn run package` 已过时，实际打包用 electron-builder（`yarn dist`）。
- 根目录可放 `.MODE` 文件（内容如 `production`）控制运行模式；缺省为 `development`（会在 View 菜单中加入 devtools 入口）。

## 架构

### 进程模型与全局状态共享（关键）

本项目**不用常规 IPC 传数据**，而是依赖 Electron 10 的旧特性：主进程把对象挂到 `global`，渲染进程通过 `remote.getGlobal()` 直接取用（`main.js` 开启了 `nodeIntegration: true` 和 `enableRemoteModule: true`）：

- `global.soundsDb` / `global.settingsDb` — NeDB 实例，**渲染进程直接读写数据库**
- `global.events` — 共享的 EventEmitter（`src/events.js`），跨进程事件总线
- `global.MEDIA_DIR` / `global.COVERS_DIR` / `global.MODE` — 路径与模式常量

跨进程事件流示例：主进程注册系统媒体键（MediaPlayPause 等）→ `events.emit('play:toggle')` → 渲染进程 `components/app.js` 中 `events.on('play:toggle', ...)` 响应。改动任何一侧的事件名时要在两侧同步（事件名：`play:toggle` / `play:next` / `play:previous` / `goto:settings`）。

唯一的传统 IPC 通道：渲染进程菜单点击 `ipcRenderer.send('addFileToLibrary')` → 主进程弹文件对话框、拷贝文件、解析 ID3 标签、写入 NeDB → `win.webContents.send('addNewItem', item)` 回传给渲染进程追加到队列。

### 数据与文件布局

- 曲库文件：拷贝到 `~/my_music_repo/`，文件名为 `<md5 哈希><扩展名>`，md5 哈希同时作为 NeDB 中的 `_id`
- 封面图：`~/my_music_repo/covers/`，文件名 `<artist>-<album>.<ext>`
- NeDB 数据文件：`<userData>/app_data/sounds.db` 与 `settings.db`
- ID3 标签解析用 jsmediatags；封面提取逻辑在主进程（导入时）和 `utils/getCoverFromMP3File.js`（渲染进程补齐缺失封面）各有一份

### 渲染进程

- 入口 `src/index.js`：初始化 SoundManager2、构建应用菜单（菜单在渲染进程通过 `remote.Menu` 设置，不在主进程）、挂载 React
- `components/app.js` 是**唯一的状态容器**：播放队列、当前曲目、播放/暂停、音量、循环模式全部在此，通过 props 下发到 `components/Player/*` 和 `components/App/*` 的展示组件；播放控制直接调用 SoundManager2 的 sound 对象
- 窗口是无边框窗口（`frame: false`）；macOS 上关闭窗口只隐藏不退出（`before-quit` 标志位控制）

### 构建

- webpack 配置在 `buildconfig/`（prod 仅在 dev 基础上覆盖 mode/devtool），target 为 `electron-renderer`
- 路径别名：`components` / `styles` / `assets` / `utils` 指向仓库根下同名目录（import 时不写相对路径）
- `.scss` 启用了 **CSS Modules**（`import styles from 'xxx.scss'` 后用 `styles.class_name`），`.css` 则是普通全局样式
- Babel 用的是老版 preset（es2015 + react），不支持 class properties 等新语法，组件里都是 constructor + bind 的写法，新代码保持一致
