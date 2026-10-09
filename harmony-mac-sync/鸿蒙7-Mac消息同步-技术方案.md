# 鸿蒙 7 → Mac 消息与通话同步 · 技术方案

| 项 | 内容 |
|---|---|
| 版本 | v1.0 |
| 日期 | 2026-10-09 |
| 目标平台 | 手机 HarmonyOS 7（纯血鸿蒙，API 26+） / Mac macOS 14+ |
| 状态 | 已验证：蓝牙服务确认通过 |

---

## 摘要

一句话结论：**短信、通讯录、来电能同步到 Mac；App 推送通知不能。**

方案是 **Mac 侧蓝牙直连**——用标准蓝牙 MAP / PBAP / HFP 协议直接跟手机通信。手机端零安装、不碰鸿蒙权限。手机已确认暴露这三类服务，通道成立。

App 推送通知的缺口来自硬约束：鸿蒙把「通知监听」划为系统签名级权限、把「短信读取」划为 ACL 受限权限，第三方应用拿不到；官方跨设备通知同步只跑在华为分布式软总线（超级终端）内部，Mac 不在这个生态内。

---

## 1. 需求与目标

### 1.1 目标

在 Mac 上实时收到手机的三类信息，并以 macOS 原生通知形式提醒：

| 类别 | 具体内容 |
|---|---|
| 短信 | 短信 / 彩信的接收提醒，可查看正文与发送方 |
| 通话 | 来电提醒（号码 + 通讯录姓名）、未接来电记录 |
| 通知 | 手机各 App 的推送通知 |

### 1.2 非目标（本期不做）

- 在 Mac 上回复短信、拨打电话
- 微信 / QQ 等 App 内部消息的完整会话同步（受平台限制，见 §3）
- 手机端安装任何常驻应用

---

## 2. 可行性结论

先给判断，理由见 §3。

| 类别 | 可行性 | 说明 |
|---|---|---|
| 短信 | 可行 | 走蓝牙 MAP 协议（Message Access Profile） |
| 来电 | 可行 | 走蓝牙 HFP 协议（Hands-Free Profile）的 CLIP 来电显示 |
| 通讯录 | 可行 | 走蓝牙 PBAP 协议，用于把号码解析成姓名 |
| App 通知 | **不可行** | 无任何可用通道，详见 §3.3 |

---

## 3. 鸿蒙侧权限与技术约束

这一节是整个方案的地基。先把「为什么不能做手机端 App」讲清楚，后面的路线选择才有依据。

### 3.1 通知监听：系统签名级权限，第三方拿不到

鸿蒙的通知订阅能力（`NotificationSubscriber`）需要声明：

```
ohos.permission.NOTIFICATION_CONTROLLER
```

华为官方资料明确说明该权限为 **系统签名级别（system signature）**，普通第三方应用无法获取，仅面向系统应用或与系统签名的应用开放。且该能力**必须由用户手动授权**，属于敏感权限。

虽然 HarmonyOS 6 起引入了更细粒度的监听权限（可按 `bundleNames` 指定只监听特定应用），但底层授权级别并未对普通开发者放开。

**结论：通知监听这条路，个人 / 普通企业开发者走不通。**

### 3.2 短信读取：ACL 受限权限，审批严格

| 权限 | 级别 | 说明 |
|---|---|---|
| `ohos.permission.READ_MESSAGES` | 受限（ACL） | 读取短信内容 |
| `ohos.permission.RECEIVE_SMS` | 受限（ACL） | 接收短信广播 |

受限权限需要走 **ACL 白名单申请**（在 `module.json5` 里配置 `acls`，并提交华为侧审核）。企业签名场景下有一线通过可能，但审核周期长、不保证通过，且**通知监听的级别比它更高，同样拿不到**。

### 3.3 官方跨设备通知同步：Mac 不在生态内

HarmonyOS 6/7 确实有跨设备通知同步能力，但它的实现依赖：

- **分布式软总线**——负责设备发现、认证、P2P 通道
- **分布式数据管理**（`@ohos.data.distributedData` 的 KVStore，`autoSync=true`）
- 数据在「**超级终端**」内广播，目标设备限定为 PC / 平板 / 智慧屏等 **HarmonyOS 生态设备**

所需权限为 `DISTRIBUTED_DATASYNC`、`GET_DISTRIBUTED_DEVICE_INFO`。这套体系的设备发现与认证由华为账号 + 设备证书完成，**macOS 设备无法作为节点接入**。

**结论：即使自研鸿蒙 App，也无法把通知送到 Mac。**

### 3.4 相对可行的部分：电话状态

```typescript
import { observer } from '@ohos.telephony.observer';
import { call } from '@ohos.telephony.call';

// 监听通话状态变化
observer.on('callStateChange', (data) => { /* ... */ });
// 监听来电号码
observer.on('callDetailsChange', (data) => { /* ... */ });
```

对应权限 `ohos.permission.GET_TELEPHONY_STATE`，授权级别明显低于前两者，自研鸿蒙 App 场景下可以申请到。

但这只能覆盖「来电」一类，短信和通知依然拿不到——**做手机端 App 的性价比因此很低**。

### 3.5 约束汇总

```
短信      ──✕── READ_MESSAGES / RECEIVE_SMS  → ACL 受限，难批
通知      ──✕── NOTIFICATION_CONTROLLER      → 系统签名级，无解
分布式同步 ──✕── 仅超级终端内部，Mac 无法接入
来电      ──✓── GET_TELEPHONY_STATE          → 可申请
```

---

## 4. 路线评估

### 路线 1：手机装转发 App（兼容安卓）

**已排除。** 该路线依赖安装 APK，鸿蒙 7 不再兼容安卓应用。

### 路线 2：自研鸿蒙 App 采集 + 局域网转发

**不推荐。** 按 §3 的分析，这条路最多只能拿到电话状态，短信和通知全部拿不到——投入产出比极低。除非后续拿到企业 ACL 授权，否则不值得启动。

若未来拿到 ACL 权限，可作为增强方案叠加（见 §9.2）。

### 路线 3：Mac 蓝牙直连（推荐）

Mac 作为蓝牙客户端，直接连接手机暴露的标准蓝牙服务。

| 维度 | 评估 |
|---|---|
| 手机端改动 | 无，不需要装任何东西 |
| 依赖的鸿蒙权限 | 无，走标准蓝牙协议栈 |
| 能拿到 | 短信、彩信、通讯录、来电、通话记录 |
| 拿不到 | App 推送通知 |
| 系统升级影响 | 小，协议是蓝牙 SIG 标准，不随鸿蒙版本变化 |
| 主要风险 | 华为手机 MAP / PBAP 服务是否默认对外暴露，需实测（§7） |
| 工作量 | 中等偏上，OBEX 层需自行实现 |

**结论：选路线 3。** 下面展开设计。

---

## 5. 推荐方案：蓝牙直连

### 5.1 总体架构

```
┌─────────────────────────────┐        蓝牙 BR/EDR          ┌──────────────────────────────┐
│      鸿蒙 7 手机             │                            │           Mac                │
│                             │                            │                              │
│  ┌───────────────────────┐  │                            │  ┌────────────────────────┐  │
│  │ MSE  消息服务 (0x1132)│◄─┼──── MAP: OBEX GET ─────────┼──┤  MAP 客户端            │  │
│  │ MNS  消息通知 (0x1133)│◄─┼──── MAP: 事件订阅 ─────────┼──┤  (MCE)                 │  │
│  ├───────────────────────┤  │                            │  ├────────────────────────┤  │
│  │ PSE  通讯录服务(0x112F)│◄─┼──── PBAP: OBEX GET ────────┼──┤  PBAP 客户端 (PCE)     │  │
│  ├───────────────────────┤  │                            │  ├────────────────────────┤  │
│  │ AG   音频网关 (0x111F)│◄─┼──── HFP: AT 命令 / CLIP ───┼──┤  HFP 免提端 (HF)       │  │
│  └───────────────────────┘  │                            │  └────────────────────────┘  │
└─────────────────────────────┘                            │              │               │
                                                           │              ▼               │
                                                           │   ┌──────────────────────┐   │
                                                           │   │ 统一消息总线 (Actor) │   │
                                                           │   └──────────────────────┘   │
                                                           │        │          │          │
                                                           │        ▼          ▼          │
                                                           │   本地数据库   通知中心       │
                                                           │   (SQLite)   (UserNotif.)    │
                                                           │        │                     │
                                                           │        ▼                     │
                                                           │   菜单栏 UI (MenuBarExtra)   │
                                                           └──────────────────────────────┘
```

### 5.2 三条蓝牙通道的分工

#### 5.2.1 MAP —— 负责短信 / 彩信

- 角色：Mac 作为 **MCE**（Message Client Equipment），手机是 **MSE**（Message Server Equipment）
- 服务 UUID：MSE `0x1132`，MNS `0x1133`（MNS 专门用于接收新消息事件）
- 传输：OBEX over RFCOMM

**关键流程（实时收新短信）**

1. 通过 SDP 查询拿到 MSE 和 MNS 的 RFCOMM 通道号
2. 连接 **MNS** 并保持长连接，等待 OBEX 事件报告
3. 收到 `NewMessage` 事件后，连 **MSE** 拉取内容：

| 操作 | OBEX 请求 | 目标路径 / 头 |
|---|---|---|
| 进入收件箱 | `SETPATH` | `telecom/msg/inbox` |
| 列消息 | `GET` | Type: `x-bt/MAP-msg-listing` |
| 读正文 | `GET` | Name: `<handle>.bm`，Type: `x-bt/message` |
| 回上级目录 | `SETPATH` | 空字符串（backup 语义） |

4. 消息体为 **bMessage** 格式（类 MIME 的分段结构），需自行解析

**标准文件夹路径**：`telecom/msg/inbox`、`sent`、`outbox`、`draft`、`deleted`

#### 5.2.2 PBAP —— 负责通讯录与通话记录

- 角色：Mac 作为 **PCE**（Phonebook Client Equipment），手机是 **PSE**
- 服务 UUID：PSE `0x112F`
- 传输：OBEX over RFCOMM，返回 vCard 3.0 数据

| 路径 | 内容 |
|---|---|
| `telecom/pb.vcf` | 主通讯录 |
| `telecom/ich.vcf` | 来电记录 |
| `telecom/och.vcf` | 去电记录 |
| `telecom/mch.vcf` | 未接来电 |
| `telecom/cch.vcf` | 合并通话记录 |

支持 `Filter` 头做字段裁剪（只取 `FN` / `TEL`），能显著降低传输量。**通讯录的作用是把来电号码解析成姓名。**

#### 5.2.3 HFP —— 负责来电提醒

- 角色：Mac 作为 **HF**（免提端），手机是 **AG**（音频网关）
- 服务 UUID：HF `0x111E`，AG `0x111F`
- 关注的是 **AT 命令通道**，不启用音频通道

```
来电时手机 → Mac 推送：
  RING
  +CLIP: "13800138000",129,,,,0        ← 来电号码
  +CLCC: 1,1,4,0,0,"13800138000",129   ← 通话状态

Mac → 手机（本期可选实现）：
  ATA      ← 接听
  AT+CHUP  ← 挂断
```

> ⚠️ 注意：macOS 系统本身可能把手机识别为音频设备并占用 HFP 通道。**应避免启用 SCO 音频链路**，只处理信令，否则会与系统音频抢占。

### 5.3 为什么不用其它协议

| 备选 | 排除原因 |
|---|---|
| BLE（CoreBluetooth） | MAP / PBAP / HFP 都是经典蓝牙 BR/EDR 协议，BLE 承载不了 |
| 局域网 + 手机端 App | 需鸿蒙侧权限，见 §3 |
| 华为云空间 API | 无公开 API 可读短信 |
| HiCar / 多屏协同 | 只支持 Windows 与华为生态设备，Mac 无官方支持 |

---

## 6. Mac 端应用设计

### 6.1 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 语言 | Swift 5.9+ | 需要直接调 Objective-C 的 IOBluetooth |
| UI | SwiftUI + `MenuBarExtra` | 菜单栏常驻应用，`LSUIElement = true` 隐藏 Dock 图标 |
| 蓝牙 | **IOBluetooth** 框架 | `IOBluetoothOBEXSession` 提供 OBEX 原语 |
| 通知 | `UserNotifications` | 走 macOS 通知中心，与系统通知风格一致 |
| 存储 | SQLite（GRDB） | 存消息与通话记录，支持检索 |
| 并发 | Swift Concurrency（Actor） | 蓝牙回调在 RunLoop 线程，需桥接到 actor |

**关于 IOBluetooth**：这是 Apple 的公开框架，提供用户态蓝牙访问。关键类：

- `IOBluetoothDeviceInquiry` —— 设备发现
- `IOBluetoothDevice` —— 设备对象，`pair()` / `isPaired()`
- `IOBluetoothSDPServiceRecord` —— SDP 查询，拿 RFCOMM 通道号
- `IOBluetoothOBEXSession` —— OBEX 会话，提供 `sendConnectCommand` / `sendGetCommand` / `sendSetPathCommand` / `sendPutCommand`
- `IOBluetoothHandsFreeDevice` —— HFP 免提端封装，带 `handsFreeDevice:incomingCallWithNumber:` 等 delegate 回调

**注意**：`IOBluetoothOBEXSession` 只给 OBEX 原语，**MAP / PBAP 的报文构造与解析需要自己写**（这部分是主要工作量）。同时它基于 RunLoop，与 Swift Concurrency 混用时要包一层适配。

### 6.2 模块划分

```
BluetoothLink
├── DeviceDiscovery        扫描 / 配对 / 记住设备
├── SDPResolver            查询 MAP / PBAP / HFP 服务与通道号
├── OBEXClient             OBEX 原语封装 + 重连
├── MapClient              MAP：listing 解析、bMessage 解码、MNS 事件订阅
├── PbapClient             PBAP：vCard 拉取与解析
└── HfpClient              HFP：AT 命令通道、CLIP 解析

Core
├── MessageBus             统一事件流（短信 / 来电 / 通话记录）
├── Store                  SQLite 持久化，幂等去重（按 handle + 时间戳）
└── ContactResolver        号码 → 姓名

UI
├── MenuBarExtra           状态图标 + 快捷面板
├── MessageListView        短信列表与详情
├── CallHistoryView        通话记录
└── SettingsView           设备绑定、通知规则、开机自启
```

### 6.3 数据流

```
手机事件
  ├─ MAP MNS 事件 ──→ MapClient 拉取 ──┐
  ├─ HFP CLIP     ──→ HfpClient 解析 ──┼──→ MessageBus ──┬──→ Store 持久化
  └─ PBAP 定时同步 ─→ PbapClient      ─┘                │
                                                        ├──→ UserNotifications 弹通知
                                                        └──→ UI 实时刷新
```

### 6.4 数据模型

```sql
CREATE TABLE message (
  id           INTEGER PRIMARY KEY,
  handle       TEXT    NOT NULL,          -- 消息唯一标识，用于去重
  folder       TEXT    NOT NULL,          -- inbox / sent / ...
  direction    TEXT    NOT NULL,          -- in / out
  peer_number  TEXT,
  peer_name    TEXT,
  body         TEXT,
  timestamp    INTEGER NOT NULL,
  is_read      INTEGER DEFAULT 0
);
CREATE UNIQUE INDEX idx_message_handle ON message(handle);

CREATE TABLE call_record (
  id           INTEGER PRIMARY KEY,
  handle       TEXT    NOT NULL,
  peer_number  TEXT,
  peer_name    TEXT,
  type         TEXT    NOT NULL,          -- incoming / outgoing / missed
  started_at   INTEGER NOT NULL,
  duration     INTEGER DEFAULT 0
);
CREATE UNIQUE INDEX idx_call_handle ON call_record(handle);
```

`handle` 取 MAP 的消息句柄或 PBAP 记录的 UID，配合唯一索引天然实现幂等，避免重复通知。

### 6.5 工程配置

**Info.plist**

```xml
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>用于连接手机并同步短信、通话记录与来电提醒</string>
```

**entitlements**（沙盒开启时）

```xml
<key>com.apple.security.device.bluetooth</key><true/>
```

> 若走非沙盒分发（开发者签名自用），可直接关闭沙盒，省去部分限制，但需自行处理权限申请流程。

---

## 7. 验证结果

### 7.1 蓝牙服务确认（2026-10-09 完成）

在 Mac 上对手机（华为 Pura 80 Pro）执行 SDP 查询，返回 18 条服务记录，其中：

| SDP 服务名 | 对应能力 |
|---|---|
| `SMS/MMS` | MAP 短信服务（MSE） |
| `OBEX Phonebook Access Server` | PBAP 通讯录（PSE） |
| `Handsfree Gateway` | HFP 来电（AG） |
| `Advanced Audio Source` | A2DP 音频 |
| `OBEX Object Push` | 文件传输 |

原始输出见 [`sdp_probe_result.txt`](sdp_probe_result.txt)。

**结论：MAP / PBAP / HFP 三类服务均在，方案成立。**

### 7.2 待验证：OBEX 握手

在写 Swift App 之前，用 Python + PyObjC 快速验证，成本最低：

```
Python 3.13 + pyobjc-framework-IOBluetooth
```

验证内容：

1. SDP 查询拿到 MSE 的 RFCOMM 通道号
2. `IOBluetoothOBEXSession` 发 `OBEX Connect`，确认返回成功
3. `SETPATH` 进 `telecom/msg/inbox`
4. `GET` 拉 `x-bt/MAP-msg-listing`，打印原始报文

**这四步跑通，方案即成立。**

### 7.3 待验证：HFP 信令

用 `IOBluetoothHandsFreeDevice` 连接手机 AG，打一个电话进来，观察是否能收到 `incomingCallWithNumber` 回调，同时确认**系统音频通道未被抢占**。

### 7.4 验证清单

- [x] 手机蓝牙配对成功，SDP 记录中出现 MAP / PBAP / HFP 服务
- [ ] OBEX Connect + SETPATH + GET listing 全链路通
- [ ] bMessage 正文解析正确，中文不乱码
- [ ] MNS 事件订阅能收到新短信推送
- [ ] HFP 能拿到来电号码，且不抢占系统音频
- [ ] 手机重启 / 走出蓝牙范围后能自动重连

---

## 8. 风险清单

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| R1 | 华为手机不对外暴露 MAP / PBAP 服务 | **致命，方案不成立** | §7.1 先验证；若不暴露则只能转 §9.2 |
| R2 | 系统升级后收紧蓝牙服务 | 高 | 协议是蓝牙 SIG 标准，通常稳定；做好版本监控 |
| R3 | OBEX 报文手写工作量大、易出错 | 中 | 先用 Python 原型跑通，再移植 Swift |
| R4 | HFP 与 macOS 系统音频抢占 | 中 | 只走信令通道，不建立 SCO 音频链路 |
| R5 | 消息量大时 PBAP 全量同步慢 | 中 | 用 `Filter` 裁剪字段，改增量同步 |
| R6 | 手机锁屏后服务挂起 | 中 | 已配对设备的 MAP 服务通常常驻；实测确认 |
| R7 | 无 App 通知能力 | 高（体验缺失） | 明确产品定位为「短信 + 通话」；见 §9 |
| R8 | macOS 蓝牙权限与沙盒限制 | 中 | 非沙盒分发，或配好 bluetooth entitlement |

---

## 9. 备选与增强方案

### 9.1 本期范围

只做**短信 + 来电 + 通话记录**。App 通知明确不承诺。

### 9.2 增强：如果拿到企业 ACL 权限

若后续以企业开发者身份拿到 `READ_MESSAGES` / `RECEIVE_SMS` 的 ACL 白名单，可以叠加一个手机端鸿蒙 App 做局域网推送，作为蓝牙之外的冗余通道（例如手机不在蓝牙范围内时仍能收到短信）。

但注意：**通知监听权限（`NOTIFICATION_CONTROLLER`）级别更高，仍无解**，App 通知这项在任何路线下都拿不到。

### 9.3 增强：Mac 侧体验补足

- 短信验证码自动识别并高亮，支持一键复制
- 来电时 Mac 全屏弹窗 + 响铃
- 通讯录反查，陌生号码标注归属地
- 与 macOS 聚焦（Spotlight）集成，可搜索历史短信

---

## 附录 A：协议速查

### 服务 UUID

| 服务 | UUID |
|---|---|
| MAP MSE | `00001132-0000-1000-8000-00805F9B34FB` |
| MAP MNS | `00001133-0000-1000-8000-00805F9B34FB` |
| PBAP PSE | `0000112F-0000-1000-8000-00805F9B34FB` |
| HFP HF | `0000111E-0000-1000-8000-00805F9B34FB` |
| HFP AG | `0000111F-0000-1000-8000-00805F9B34FB` |

### OBEX 操作码

| 操作 | 码值 | 用途 |
|---|---|---|
| Connect | `0x80` | 建立会话 |
| Disconnect | `0x81` | 断开 |
| Put | `0x02` | 发送 |
| Get | `0x03` | 拉取 |
| SetPath | `0x85` | 切换目录 |
| Abort | `0xFF` | 中止 |

### MAP 关键 Header

| Header | 值 | 用途 |
|---|---|---|
| Type | `x-bt/MAP-msg-listing` | 请求消息列表 |
| Type | `x-bt/message` | 请求消息正文 |
| Type | `x-bt/MAP-Event-Report` | 订阅事件（MNS） |

---

## 附录 B：参考

- Apple Developer · IOBluetooth Framework
  https://developer.apple.com/documentation/iobluetooth
- 华为开发者文档 · 通知订阅能力与权限管理
- Bluetooth SIG · Message Access Profile (MAP) Specification
- Bluetooth SIG · Phone Book Access Profile (PBAP) Specification
- Bluetooth SIG · Hands-Free Profile (HFP) Specification
