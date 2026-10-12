# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

delegated: 原生 SwiftUI（macOS 菜单栏应用）。开发机没有 Xcode，只有 CommandLineTools，所以构建走 `swiftc` 直接编译、脚本打包成 `.app`，不用 Xcode 工程。视觉系统由 impeccable 出规范，另做一张 HTML 设计规范页用来跑它的检测器。

## Users

小林本人，青岛的开发者。使用场景：坐在 Mac 前写代码，手机（华为 Pura 80 Pro，HarmonyOS 7）放在桌上或口袋里。他要的是**不拿起手机就知道手机来了什么短信**——验证码、银行动账、快递这类，扫一眼就够。

单用户产品。不考虑多用户、团队协作、也不考虑分发给别人安装。

## Product Purpose

把鸿蒙手机的短信同步到 Mac，弹 macOS 系统通知并落库；在界面上翻看历史短信、控制监听开关、管理手机连接。

成功的样子：手机来了短信，不用碰手机，Mac 上已经能看到发件人和正文。

## Positioning

手机端零安装、不碰鸿蒙权限——Mac 直连手机暴露的标准蓝牙服务（MAP 读短信、PBAP 读通讯录、HFP 管通话）。

这一条是别的方案做不到的：任何依赖手机端 App 或华为云 API 的路线，都要过鸿蒙的权限审批（通知监听是系统签名级、短信读取是 ACL 受限），而蓝牙 MAP 通道已经实测打通。

## Operating Context

- 手机与 Mac 走蓝牙经典配对。首次手动连接，之后自动连接
- 运行形态是菜单栏应用，不占 Dock
- 数据落在 `~/Library/Application Support/HarmonySync/messages.db`
- 开发环境没有 Xcode，只有 CommandLineTools；构建走 `swiftc` + 打包脚本
- 设计与视觉规范的依据是 impeccable，规范页是 HTML

## Capabilities and Constraints

已确认的功能：

- 短信增量同步：新短信到达 2–4 秒内同步到 Mac，弹系统通知，落库去重，重启不重复通知
- 消息记录窗口：按时间倒序浏览，每条显示发件人、正文、时间；支持按发件人或关键词搜索、按日期筛选；识别短信里的验证码并可一键复制
- 两个监听开关：短信监听、通话监听
- 「短信监听」关掉即断开蓝牙连接
- 首次手动连接手机，之后自动连接，断连自动重连
- 开机自启
- 菜单栏常驻，不占 Dock

约束与未定：

- 目标平台是 macOS 菜单栏应用（SwiftUI）。`## Platform` 记 `ios`，是因为 impeccable 的原生取值只有 ios / android / adaptive；macOS 与 iOS 同属 Apple 原生 SwiftUI 体系，取 ios 才能载入最贴近的原生审计清单
- **通话监听（HFP）后端待接**：HFP 探针尚未实测，界面先放开关与状态位，打开它不产生实际监听行为
- 超长短信正文取回未做（列表接口会截断正文）
- 记录窗口只读：不提供删除单条或清空
- App 推送通知（微信 / QQ 等）在任何路线下都拿不到，不做
- 手机端不安装任何常驻应用

## Brand Commitments

- 名字：`HarmonySync`（App 名），显示名「鸿蒙短信同步」。已确认采用
- 图标：本轮重绘，同时保留菜单栏用的单色模板图

## Evidence on Hand

- 实机通知截图：`assets/notification.png`（手机收到短信后 Mac 上弹出的系统通知）
- 完整技术方案与全部实测记录：`鸿蒙7-Mac消息同步-技术方案.md`
- 已跑通的链路：MAP OBEX 全链路、增量同步、以 App 身份弹出的系统通知
- **没有的东西**：真实用户评价、下载量、性能基准、定价、竞品对比数据。后续任何设计都不得编造这些

## Product Principles

1. **手机放一边。** 信息要主动来到 Mac 上，而不是让用户去手机里翻。
2. **看一眼就够。** 短信的价值在头几秒，发件人、正文、时间要压到最短路径上。
3. **做系统里的一员。** 通知、菜单栏、开机自启、深浅色模式都按 macOS 的惯例来，不发明自己的规矩。
4. **手机上不装东西。** 所有能力都从 Mac 这一侧取得。
5. **连接状态要看得见。** 蓝牙是会断的，界面上必须随时能看出「现在通不通」。

## Accessibility & Inclusion

- 跟随系统深浅色模式
- 尊重「减弱动态效果」设置
- 文字与背景对比度满足 WCAG AA（正文 4.5:1，大字 3:1）
- 键盘可达：开关可 Tab 聚焦，列表可键盘浏览
