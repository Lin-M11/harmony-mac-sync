# harmony-mac-sync

把鸿蒙手机的短信同步到 Mac：新短信即时弹系统通知，并落库留档。

## 原理

Mac 作为蓝牙客户端，直连手机暴露的标准蓝牙服务，手机端零安装、不依赖任何鸿蒙权限：

| 通道 | 协议 | 用途 | 版本 |
|---|---|---|---|
| 短信 | MAP | 读取短信、订阅新消息事件 | V1 |
| 通讯录 | PBAP | 拉取通讯录与通话记录，反查来电姓名 | 规划中 |
| 来电 | HFP | 读取来电号码（CLIP） | 规划中 |

## 当前状态

V1 可用：连上手机 → 建立基线（已有短信不通知）→ 轮询收件箱 → 只对新增短信弹通知并落库。

- 新短信延迟 2–4 秒（`--interval 2`）
- 通知以 App 身份弹出：显示「鸿蒙短信同步」与图标，留在通知中心里
- 已见 handle 持久化，重启不重复通知
- 手机端 SDP 记录、OBEX 全链路、列表解析、事件订阅的实测记录见技术方案 §7

## 目录

| 路径 | 说明 |
|---|---|
| `harmony-mac-sync/鸿蒙7-Mac消息同步-技术方案.md` | 完整技术方案与验证记录 |
| `harmony-mac-sync/harmony_sync.swift` | 客户端：增量同步 + 系统通知 + 落库 |
| `harmony-mac-sync/make_icon.swift` | 图标生成（CoreGraphics → icns） |
| `harmony-mac-sync/build.sh` | 编译客户端并组装成 `HarmonySync.app` |
| `harmony-mac-sync/run_sync.command` | 双击启动：增量同步 |
| `harmony-mac-sync/run_fast_sync.command` | 双击启动：秒级轮询 |
| `harmony-mac-sync/run_notify_check.command` | 双击运行：通知自检 |

验证阶段的探针（SDP 查询与发布、OBEX 报文、列表解析、手机能力）已从工作树移除，取证结果收在技术方案 §7.1–§7.4；源码在 git 历史里，需要时 `git checkout <提交> -- <路径>` 取回。

## 构建

```bash
cd harmony-mac-sync
./build.sh
```

每个目标先编成 `xxx.bin`，再各自组装成 `xxx.app`（带蓝牙用途说明、图标与 ad-hoc 签名）。

## 运行

双击 `harmony-mac-sync/HarmonySync.app` 即以后台形态常驻，不占 Dock 图标。想看日志就双击 `run_sync.command`（增量同步）或 `run_fast_sync.command`（秒级轮询，跑 4 分钟），日志同时落在 `/tmp/harmony_sync_result.txt`。也可以直接跑：

```bash
./HarmonySync.app/Contents/MacOS/HarmonySync                     # 持续同步
./HarmonySync.app/Contents/MacOS/HarmonySync --interval 2        # 秒级轮询
./HarmonySync.app/Contents/MacOS/HarmonySync --test-notify       # 通知自检
```

双击 App 启动的是后台进程，退出在「活动监视器」里结束 `HarmonySync`。

首次运行需要在系统询问里允许蓝牙与通知。若错过那次询问，到「系统设置 → 通知」里把「鸿蒙短信同步」的开关打开即可。

本地数据：`~/Library/Application Support/HarmonySync/messages.db`（`message` / `seen_handle` / `sync_state` 三张表）

## 能力边界

**可同步**：短信

**不可同步**：App 推送通知

后者源于平台限制：鸿蒙把通知监听划为系统签名级权限、把短信读取划为 ACL 受限权限，第三方应用无法获取；官方的跨设备通知同步运行在华为分布式软总线内，Mac 不在该生态中。

## 环境

- 手机：HarmonyOS 7（实测 华为 Pura 80 Pro）
- Mac：macOS 12+
- 工具链：Swift / IOBluetooth / SQLite3

## 授权说明

macOS 的蓝牙权限按「负责进程」归因。从终端或 IDE 的 shell 启动的进程可能因宿主未声明蓝牙用途而被系统拒绝，此时请从 Terminal.app 直接运行，或双击 app bundle。
