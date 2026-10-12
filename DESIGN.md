---
name: 鸿蒙短信同步
description: 原生 macOS 菜单栏应用，把鸿蒙手机的短信同步到 Mac
colors:
  canvas: "#FAF9F7"
  canvas-dark: "#17181A"
  surface: "#FFFFFF"
  surface-dark: "#1E2022"
  chrome: "#F3F1ED"
  chrome-dark: "#212325"
  hover: "#EFEDE8"
  hover-dark: "#2A2C2E"
  line: "#E4E1DA"
  line-dark: "#33363A"
  line-strong: "#CFCCC4"
  line-strong-dark: "#45484C"
  ink: "#1B1D1C"
  ink-dark: "#F0F1EF"
  ink-secondary: "#4A4F4C"
  ink-secondary-dark: "#C3C6C3"
  ink-tertiary: "#636865"
  ink-tertiary-dark: "#8E938F"
  accent: "#1D6B54"
  accent-dark: "#4FBF9A"
  accent-soft: "#E3F0EB"
  accent-soft-dark: "#1C3A32"
  wait: "#8A6A1F"
  wait-dark: "#D8AC53"
  danger: "#A93B36"
  danger-dark: "#E0776F"
  on-accent: "#FFFFFF"
  on-accent-dark: "#10120F"
typography:
  window-title:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"PingFang SC\", sans-serif"
    fontSize: "18px"
    fontWeight: 500
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  section-title:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"PingFang SC\", sans-serif"
    fontSize: "16px"
    fontWeight: 500
    lineHeight: 1.35
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"PingFang SC\", sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.6
  body-strong:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"PingFang SC\", sans-serif"
    fontSize: "14px"
    fontWeight: 500
    lineHeight: 1.6
  caption:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"PingFang SC\", sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.5
  mono:
    fontFamily: "ui-monospace, \"SF Mono\", Menlo, monospace"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.5
rounded:
  control: "6px"
  row: "10px"
  panel: "14px"
  pill: "999px"
spacing:
  s1: "4px"
  s2: "8px"
  s3: "12px"
  s4: "16px"
  s5: "24px"
  s6: "32px"
components:
  panel:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.panel}"
  panel-head:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    padding: "12px 16px"
  row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    padding: "8px 16px"
  row-hover:
    backgroundColor: "{colors.hover}"
    textColor: "{colors.ink}"
    padding: "8px 16px"
  row-selected:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.ink}"
    padding: "8px 16px"
  button:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "4px 12px"
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.surface}"
    rounded: "{rounded.control}"
    padding: "4px 12px"
  field:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "4px 8px"
  chip:
    backgroundColor: "{colors.chrome}"
    textColor: "{colors.ink-secondary}"
    rounded: "{rounded.control}"
    padding: "2px 10px"
  chip-active:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.accent}"
    rounded: "{rounded.control}"
    padding: "2px 10px"
  code-chip:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.accent}"
    rounded: "{rounded.control}"
    padding: "1px 6px"
---

## Overview

鸿蒙短信同步是一个原生 macOS 菜单栏应用：把鸿蒙手机的短信同步到 Mac，弹系统通知，落库，并提供一个翻看历史短信的窗口。用户是开发者本人，坐在 Mac 前写代码，要的是不拿起手机就知道手机来了什么短信。

**视觉世界：仪表。** 不做聊天应用的热闹，不做品牌工具的彩色。这是一台监视链路状态的仪表——读得快是因为有序，不是因为响。界面的价值在于让「现在通不通」和「刚来了什么」这两件事各占一个位置，其余全部让路。

**模式：Operate。** 用户在完成任务，不在被说服。扫描性、一致性、原生预期高于表达欲；品牌感落在精确的细节里，不落在装饰上。

参考实现在 `design/设计规范.html`，那是这套系统的实物样本。

## Colors

**克制用色。** 主色只出现在三处：连接状态、主操作、当前选中。除此之外界面是中性色的。

**中性色一律带暖调**，`#FAF9F7` 不是纯白，`#1B1D1C` 不是纯黑。纯灰在两种模式下都会显脏。

**分层**：`canvas` 是最底的面（窗口底、搜索框内底），`surface` 是内容面（面板、列表），`chrome` 是次级面（工具栏、面板头）。三层的明度差很小，靠 1px 描边而不是靠阴影区分。

**文字三级**：`ink` 用于标题、发件人、开关标签；`ink-secondary` 用于短信正文与说明；`ink-tertiary` 用于时间、状态、占位符。

对比度实测（WCAG AA 下限：正文 4.5:1，大字 3:1）：

| 令牌 | 浅色 | 深色 | 对本底色的对比度 |
|---|---|---|---|
| `ink` | #1B1D1C | #F0F1EF | 15.6:1 / 15.9:1 |
| `ink-secondary` | #4A4F4C | #C3C6C3 | 7.9:1 / 10.3:1 |
| `ink-tertiary` | #636865 | #8E938F | 5.4:1 / 5.7:1 |
| `accent` | #1D6B54 | #4FBF9A | 6.1:1 / 7.8:1 |
| `wait` | #8A6A1F | #D8AC53 | 4.8:1 / 8.4:1 |
| `danger` | #A93B36 | #E0776F | 5.9:1 / 6.0:1 |

`accent-soft` 是主色的浅底，用于选中行与验证码，不用于文字。`on-accent` 是主色底上的文字色，随主题取值：浅色模式取白，深色模式取近黑，与各自主题下主色的明度匹配。

## Typography

**单一字族：系统字体。** 原生应用用系统字体不是妥协，是正解——它跟着系统版本更新、跟着用户的辅助功能设置走、与窗口控件同源。产品界面也不需要展示字体与正文配对的把戏。

**固定字阶，四档**，比例 1.125–1.17：

| 层级 | 字号 / 字重 | 用途 |
|---|---|---|
| 窗口标题 | 18px / 500 | 「消息记录」窗口标题 |
| 区块标题 | 16px / 500 | 面板分区、日期分组 |
| 正文 | 14px / 400 | 短信正文、说明文字 |
| 强调正文 | 14px / 500 | 发件人、开关标签 |
| 辅助 | 12px / 400 | 时间、状态、占位符 |
| 等宽 | 12px / 400 | 验证码、令牌名、代码片段 |

**数字一律等宽**（`font-variant-numeric: tabular-nums`），让时间戳与金额竖着对齐。短信正文是唯一允许长行的内容，上限 68ch；列表行不设上限。

## Layout

间距取 4 的倍数：`4 / 8 / 12 / 16 / 24 / 32`。

**分组内紧、组间松。** 面板里的三个分区（连接状态、监听开关、最近收到）之间用 1px 分隔线，不用卡片。列表行之间也是 1px 分隔线。

**留白方向**：标题上方的留白多于下方。

固定宽度：菜单栏面板 300px，消息记录窗口 560px（最小 420px，最大 720px）。消息列表的日期分组标题在滚动时吸顶。

## Elevation & Depth

**只有两处有阴影**：菜单栏面板、消息记录窗口。它们是浮在桌面上的表面，需要与背后的窗口分开。

其余一律不用阴影。列表行、按钮、开关的层次靠描边和底色差表达。阴影必须带偏移和柔化：`0 1px 2px rgba(27,29,28,.06), 0 6px 16px -4px rgba(27,29,28,.10)`。零偏移的彩色光晕是装饰，不是深度。

## Shapes

三档圆角：控件 `6px`、列表行 `10px`、面板 `14px`；胶囊（日期筛选、令牌名）用 `999px`。

**母题：一条链路把两边连起来。** 左边是手机（窄、实心、内容源），右边是带底座的显示器（宽、描边、接收端），中间一条横条落在两者的共同中线上。这个标记承担三处：App 图标、菜单栏图标、界面里的连接状态指示。

链路通：实线 + 主色。链路断：虚线 + `ink-tertiary`，两端形状转为描边。菜单栏图标是单色模板图，18pt，随系统明暗自动反相，通与断各一张。

图标一律自绘 SVG 或 SF Symbols，线条粗细统一，不用 emoji 或 Unicode 字符充当图标。

## Components

每个可交互控件都要有完整状态：默认、悬停、聚焦、按下、禁用、加载、出错。

**面板（`panel`）** 菜单栏点开后弹出的主体。三段式：头部是设备名与链路状态，中部是两个监听开关，下部是最近收到的短信。底部一条主操作。

**列表行（`row`）** 消息记录的基本单元。左边发件人固定 108px 宽（超出省略），中间正文占满，右边时间等宽数字。悬停变 `hover` 底，选中变 `accent-soft` 底并加 2px 主色内阴影。

**开关（switch）** 32×20，滑块 16px，位移 180ms 指数缓出。打开时底色为 `accent`。禁用时整体降到 50% 不透明度。

**状态指示（state）** 7px 圆点 + 12px 文字。三态：`accent`（已连接）、`wait`（连接中）、`ink-tertiary`（未连接）。连接中不加闪烁或脉冲，只换颜色。

**验证码（code-chip）** 正文里被认出的验证码，`accent-soft` 底、主色字、等宽数字，右侧一个「复制」按钮。复制后按钮文字在 1.2 秒内变成「已复制」再变回。

**空状态（empty）** 放链路标记的断开形态（用 `line-strong` 色），一句标题，一段说明它教会用户下一步做什么，一个主操作按钮。

**加载** 用骨架屏（`chrome` 底的圆角条），不用转圈。

## Do's and Don'ts

**要**

- 让「通不通」和「来了什么」各占一个固定位置，用户不用找。
- 主色只用于连接状态、主操作、当前选中。
- 中性色带暖调；文字只用 `ink` / `ink-secondary` / `ink-tertiary` 三级。
- 时间与金额用等宽数字。
- 动效只传达状态变化，150–250ms，指数缓出。
- 跟随系统深浅色与「减弱动态效果」设置。
- 空状态教会用户下一步。

**不要**

- 在标题上方加小号标签（kicker / eyebrow）。标题自己扛得住。
- 用卡片堆页面结构，更不要卡片套卡片。
- 用彩色左边框标记卡片或列表项。
- 用渐变文字；强调靠字重和字号。
- 用玻璃与模糊做装饰。
- 用 emoji 或 Unicode 字符充当图标。
- 用纯灰或纯黑。
- 给不需要打断的任务套模态框。
- 用自定义滚动条或非标准控件来「有特色」。
- 在非激活状态上使用高饱和色。
