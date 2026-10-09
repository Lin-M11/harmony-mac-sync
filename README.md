# harmony-mac-sync

把鸿蒙手机的短信、通讯录和来电同步到 Mac。

## 原理

Mac 作为蓝牙客户端，直连手机暴露的标准蓝牙服务：

| 通道 | 协议 | 用途 |
|---|---|---|
| 短信 | MAP | 读取短信与彩信，订阅新消息事件 |
| 通讯录 | PBAP | 拉取通讯录与通话记录，反查来电姓名 |
| 来电 | HFP | 读取来电号码（CLIP） |

手机端零安装，不依赖任何鸿蒙权限。

## 当前状态

蓝牙服务确认已完成：手机（华为 Pura 80 Pro / HarmonyOS 7）暴露 `SMS/MMS`、`OBEX Phonebook Access Server`、`Handsfree Gateway` 三类服务，通道成立。

下一步：验证 OBEX 握手与 HFP 信令。

## 目录

| 路径 | 说明 |
|---|---|
| `harmony-mac-sync/鸿蒙7-Mac消息同步-技术方案.md` | 完整技术方案 |
| `harmony-mac-sync/sdp_probe.swift` | SDP 服务探查工具 |
| `harmony-mac-sync/sdp_probe_result.txt` | 探查原始输出 |

## 能力边界

**可同步**：短信、通讯录、通话记录、来电提醒

**不可同步**：App 推送通知

后者源于平台限制：鸿蒙把通知监听划为系统签名级权限、把短信读取划为 ACL 受限权限，第三方应用无法获取；官方的跨设备通知同步运行在华为分布式软总线内，Mac 不在该生态中。

## 环境

- 手机：HarmonyOS 7
- Mac：macOS 14+
- 工具链：Swift 6 / IOBluetooth

## 构建

```bash
cd harmony-mac-sync
swiftc -O -framework IOBluetooth -o SDPProbe.app/Contents/MacOS/SDPProbe sdp_probe.swift
codesign --force --deep --sign - SDPProbe.app
```

运行（首次需授予蓝牙权限）：

```bash
./SDPProbe.app/Contents/MacOS/SDPProbe <设备蓝牙地址>
```

## 授权说明

macOS 的蓝牙权限按「负责进程」归因。从终端或 IDE 的 shell 启动的进程可能因宿主未声明蓝牙用途而被系统拒绝，此时请从 Terminal.app 直接运行，或双击 app bundle。
