# DESIGN.md — UI 设计规范

本规范从现有界面归纳而来，新增 UI 应遵循此文档，保持风格一致。

## 整体气质

明亮、极简、内容驱动。白底 + 细分隔线构成骨架，唯一的视觉重心是播放区的封面/头图；文字用细字重，控件小而克制。没有卡片、没有投影堆叠，层次全部由 1px 边框和背景图承担。

## 布局

### 页面骨架（自上而下三段）

| 区域 | 高度 | 说明 |
|---|---|---|
| `header_zone` | 80px | 无边框窗口的标题栏，整条可拖拽（`-webkit-app-region: drag`） |
| `play_zone` | 180px | 头图背景区，底部叠 46px 半透明控制条（`rgba(255,255,255,.5)`） |
| `library_zone` | `calc(100vh - 260px)` | `position: fixed; top: 260px`，内容滚动区 |

窗口默认 1300×800，`body { overflow: hidden }`——只有 library 区内部滚动，页面本身不滚。

### 三栏网格

横向布局统一使用同一条 Grid 公式，保证各段左右栏对齐：

```scss
display: inline-grid;
grid-template-columns: 250px 1fr 250px;   // 左侧栏 | 主内容 | 右侧栏
```

左右 250px 栏与中栏之间用 `1px solid #EEE` 边框分隔（左栏 `border-right`，右栏 `border-left`）。

### 间距节奏

- 区块内边距：**30px**（滚动区 padding、进度条左右 padding、分区 margin 均取 30）
- 组件内小间距：**10–20px**
- 列表行高：曲目行 **80px**（含 60×60 封面缩略图），菜单行 **40px**
- Grid/flex 优先，不用 float 布局（进度条内部的 `float: left` 是历史遗留，不再新增）

## 色彩

### 明区（白底部分）

| 用途 | 值 |
|---|---|
| 页面/区块背景 | `white` |
| 分隔线、列表行底边 | `#EEE`（1px solid） |
| 选中/激活项背景 | `#EEE` |
| 次要文字（品牌名等） | `#5C5C5C` |
| 滚动条 thumb | `#DEDEDE` |

### 暗区（叠在图片背景上的部分）

play_zone 内的所有文字与控件一律 **白色**，用透明度表达状态，不换色：

| 状态 | 值 |
|---|---|
| 默认 | `rgba(255, 255, 255, 0.7)` |
| hover | `rgba(255, 255, 255, 1)` + `text-shadow: 0 0 2px white`（微发光） |
| active（按下） | `rgba(255, 255, 255, 0.5)` |

### 强调色

全应用唯一的彩色：进度条填充 **`rgba(100, 200, 255, 1)`**（浅蓝）。新增需要强调的元素优先复用这个蓝，不引入第二种彩色。

## 字体

- 正文：系统字体栈（`-apple-system, BlinkMacSystemFont, "Segoe UI", "Roboto", ...`）
- 数字/时间：`"Roboto Thin"`（`styles/global.scss` 中 @font-face 引入，仅 Thin 一档）
- **细字重是核心气质**：标题、品牌名用 `font-weight: 200`；不要用 bold 做强调，用字号和留白

字号阶梯：

| 层级 | 大小 |
|---|---|
| 主标题（当前曲名） | 40px |
| 正文 / 次要信息（歌手名） | 16px |
| 辅助数字（时间） | 14px |
| 图标 | 20px |
| 栏目标题（如 "GENRES"） | 全大写 + 底部 1px `#EEE` 分隔线 |

## 图标

使用自制 icon font（`assets/fonts/icon.ttf`，字体名 `"Music Player Icon"`，码位 `\f100`–`\f10f`），已有 16 个图标：equalizer、fast_forward、favorite、headphones、menu、musical_note、mute、next、pause、play_button、previous、repeat、rewind、shuffle、stop、volume。

用法固定为两个类组合（CSS Modules）：

```jsx
import iconStyles from 'styles/icon.scss';
<span className={ `${iconStyles.icon} ${iconStyles.icon_play_button}` }></span>
```

不引入图片图标或第三方图标库；新图标应扩充 icon.ttf 并在 `styles/icon.scss` 补一行 `.icon_xxx:before`。

## 质感与深度

- **不用投影表达层级**。仅有的两处 shadow 都是"发光"而非"投影"：进度条圆点 `box-shadow: 0 0 8px white`、按钮 hover 的 `text-shadow: 0 0 2px white`
- 图片上叠文字时，用**毛玻璃背景**保证可读性：背景图 `filter: blur(2px); transform: scale(1.1)`（scale 用于裁掉模糊后的白边），z-index 压到文字之下
- 叠加在图片上的容器用半透明白（`rgba(255,255,255,.5)`），不用纯色块
- 进度条极细（高度 1px），末端 5×5 白色发光圆点作为把手；`border-radius` 只用于圆点（50%）和进度条（4px），其余元素直角

## 动效

| 场景 | 参数 |
|---|---|
| 按钮/控件状态切换 | `transition: all .2s ease-out` |
| 进度条宽度 | `transition: width 300ms ease` |

只做 transition，不做 keyframes 动画；时长不超过 300ms。

## 交互模式

- 可点元素 hover 时 `cursor: pointer`
- 进度条/音量条：点击条上任意位置按 `offsetX / offsetWidth` 比例 seek，无拖拽
- 播放队列：**双击**行播放（单击保留给未来的选中）
- 当前播放/选中项：背景 `#EEE`
- 长文本一律 `white-space: nowrap; overflow: hidden; text-overflow: ellipsis`
- 滚动条统一细样式：宽 5px，thumb `#DEDEDE`（`styles/scrollbar.scss` 全局生效）

## CSS 工程约定

- 每个组件配同名 `.scss`，通过 CSS Modules 引入：`import styles from './Xxx.scss'`
- **类名用 snake_case**（`control_btn`、`media_info`），与现有代码保持一致
- 复用样式按就近原则分层：跨 Player 子组件的公共样式放 `components/Player/Player.scss`，页面区块骨架放 `components/region.scss`，真正全局的（字体、滚动条、图标）放 `styles/`
- 多个 module 类组合用模板字符串：`` className={ `${styles.a} ${otherStyles.b}` } ``
- 内联 style 仅用于运行时计算值（进度宽度、动态背景图 URL），静态样式一律进 SCSS
