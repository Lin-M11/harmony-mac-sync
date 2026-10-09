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

方案是 **Mac 侧蓝牙直连**——用标准蓝牙 MAP / PBAP / HFP 协议直接跟手机通信。手机端零安装、不碰鸿蒙权限。手机已确认暴露这三类服务；MAP 通道已实测打通，可读取短信列表（见 §7.2）。

短信按**增量同步**做：绑定后拉一次列表建立基线，之后只对新增的短信取正文、弹通知、落库，不搬运历史短信。手机侧有新消息时通过 MAP 的 MNS 事件主动通知 Mac，另有定时拉列表兜底（见 §5.2.1）。

App 推送通知的缺口来自硬约束：鸿蒙把「通知监听」划为系统签名级权限、把「短信读取」划为 ACL 受限权限，第三方应用拿不到；官方跨设备通知同步只跑在华为分布式软总线（超级终端）内部，Mac 不在这个生态内。

---

## 1. 需求与目标

### 1.1 目标

在 Mac 上实时收到手机的三类信息，并以 macOS 原生通知形式提醒：

| 类别 | 具体内容 |
|---|---|
| 短信 | 新短信到达时同步到 Mac，弹系统通知，可查看正文与发送方 |
| 通话 | 来电提醒（号码 + 通讯录姓名）、未接来电记录 |
| 通知 | 手机各 App 的推送通知 |

### 1.2 非目标（本期不做）

- 在 Mac 上回复短信、拨打电话
- 拉取手机里的历史短信全量：只同步绑定之后新到达的短信，已有短信仅用于建立基线
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
- 服务 UUID：MAS `0x1132`（消息存取，在手机上），MNS `0x1133`（消息事件通知，在 Mac 上）
- 传输：OBEX over RFCOMM

**关键流程（新短信到达即同步）**

角色分工：Mac 是 **MCE**，手机是 **MSE**。MNS 这一侧反过来——**Mac 是 MNS 服务端**，手机在有事时主动连上来。

1. SDP 查询拿到 MSE 的 RFCOMM 通道号
2. 连 MSE，`SETPATH` 到 `telecom/msg/inbox`
3. 向 MSE 订阅事件：`PUT`，Type `x-bt/MAP-NotificationRegistration`，AppParams `0x0B` = `0x01`
4. Mac 侧同时发布 MNS 的 SDP 记录（UUID `0x1133`）并监听，等手机连进来
5. 有新短信时，手机主动连上 Mac 的 MNS 通道，`PUT` Type `x-bt/MAP-Event-Report`
6. Mac 收到事件 → 拉一次收件箱列表 → 与已见 handle 比对 → 对新增的那条弹通知并落库

| 操作 | OBEX 请求 | 目标路径 / 头 |
|---|---|---|
| 进入收件箱 | `SETPATH` | `telecom/msg/inbox` |
| 订阅新消息事件 | `PUT` | Type: `x-bt/MAP-NotificationRegistration` |
| 收事件 | `PUT`（手机发起） | Type: `x-bt/MAP-Event-Report` |
| 列消息 | `GET` | Type: `x-bt/MAP-msg-listing`，AppParams `0x01` 限条数 |
| 读正文（可选） | `GET` | Type: `x-bt/message`，Name: `<handle>` |
| 回上级目录 | `SETPATH` | 空字符串（backup 语义） |

短信文本本身就在列表的 `subject` 属性里（见 §7.2.3），所以新短信的正文不必再单独取一次；`x-bt/message` 留着应付长短信被 `subject` 截断的情况。

7. 消息体为 **bMessage** 格式（类 MIME 的分段结构），需自行解析

**两条路径，同一套落库逻辑**

```
MNS 事件（秒级）  ──┐
                    ├──→ 比对 handle ──→ 取正文 ──→ 弹通知 ──→ 落库
定时拉列表（兜底） ──┘
```

定时那条是为了兜住事件丢失的情况，间隔 30 秒即可。两条路径都走同一个去重入口，重复触发不会重复通知。

**首次绑定**：先拉一次 inbox 列表，把已有 handle 全部记为「已见」但不通知，只建立基线。否则第一次启动会把收件箱里所有短信一次性弹出来。

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
| 存储 | SQLite（系统 `libsqlite3`） | 存消息与通话记录，支持检索；不引第三方依赖，`import SQLite3` 即可 |
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
├── MapClient              MAP：订阅事件、listing 解析、bMessage 解码
├── MnsServer              MAP MNS：发布 SDP 记录、监听手机推来的事件
├── PbapClient             PBAP：vCard 拉取与解析
└── HfpClient              HFP：AT 命令通道、CLIP 解析

Core
├── SyncEngine             比对 handle，决定哪些是新消息
├── MessageBus             统一事件流（短信 / 来电 / 通话记录）
├── Store                  SQLite 持久化，幂等去重（按 handle）
└── ContactResolver        号码 → 姓名

UI
├── MenuBarExtra           状态图标 + 快捷面板
├── MessageListView        短信列表与详情
├── CallHistoryView        通话记录
└── SettingsView           设备绑定、通知规则、开机自启
```

**实现顺序**：先跑通「定时拉列表 → 比对 → 取正文 → 通知 → 落库」这条闭环，它只依赖已经验证过的链路，能立刻用起来；再把 `MnsServer` 接上，把新短信的延迟从「最长一个轮询周期」压到秒级。两者共用 `SyncEngine` 的去重入口。

### 6.3 数据流

```
手机事件
  ├─ MAP MNS 事件 ──┐
  │                 ├─→ SyncEngine 比对 handle ─→ MapClient 取正文 ─┐
  ├─ MAP 定时拉列表 ─┘                                              │
  ├─ HFP CLIP ────────────────────────────────────────────────────┼─→ MessageBus
  └─ PBAP 定时同步 ───────────────────────────────────────────────┘      │
                                                                        ├─→ Store 持久化
                                                                        ├─→ UserNotifications 弹通知
                                                                        └─→ UI 实时刷新
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
  is_read      INTEGER DEFAULT 0,
  notified_at  INTEGER                    -- 弹过通知的时间，NULL 表示还没弹
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

CREATE TABLE sync_state (
  key   TEXT PRIMARY KEY,
  value TEXT
);
```

`handle` 取 MAP 的消息句柄或 PBAP 记录的 UID，配合唯一索引天然实现幂等，重复触发不会重复通知。

`sync_state` 存同步游标，几个键：

| 键 | 含义 |
|---|---|
| `bootstrap_at` | 建立基线的时间，早于它的短信只入库不通知 |
| `last_poll_at` | 上次轮询时间 |
| `last_seen_handle` | 上次见到的最大 handle，用于快速判断有没有新消息 |

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

### 7.2 OBEX 全链路（2026-10-09 实测通过）

在 Mac 上用 Swift + IOBluetooth 直接收发 OBEX 报文（不经 `IOBluetoothOBEXSession`，以便逐字节对照），实测链路：

| 步骤 | 请求 | 结果 |
|---|---|---|
| 1 | 打开 RFCOMM 通道 26 | 成功 |
| 2 | `OBEX Connect`，Target = MAS UUID | `0xA0` |
| 3 | `SETPATH` → `telecom` / `msg` / `inbox` | 三次 `0xA0` |
| 4 | `GET x-bt/MAP-msg-listing` | 收全 450 452 字节，558 条记录 |
| 5 | `GET x-bt/message`（正文） | 见 §7.3 |

测试机型：华为 Pura 80 Pro（HarmonyOS 7）。

#### 7.2.1 实测得到的三条报文规则

这台手机的 MSE 实现与 OBEX 通用规范有几处出入，直接影响握手能否成功：

**① 请求 opcode 的 final 位必须置位**

OBEX 请求 opcode 的最高位表示"本请求到此为止"。`Connect` = `0x80`、`SETPATH` = `0x85` 天然带这一位，`GET` 则有两种写法：

| 写法 | opcode | 服务端表现 |
|---|---|---|
| 非 final | `0x03` | 持续回 `0x90`（继续），572 次后超时 |
| final | `0x83` | 一次请求即开始下发数据 |

取列表与取正文都须用 `0x83`。这是整条链路里最关键的一处。

**② Connection ID 在 SETPATH 与 GET 上的要求相反**

Connection ID 是 `Connect` 之后服务端下发的会话标识，本机实测为 `00 00 00 01`，随 `SETPATH msg` 的响应一起到达。通用规范要求后续所有请求都带上它，而这台手机是：

```
Connect : 0x80 | len | 10 00 FF FF | Target 头
SETPATH : 0x85 | len | Flags | Constants | Name 头     ← 带 Connection ID 会被拒（0xC0）
GET     : 0x83 | len | Connection ID | Type | Name     ← 不带 Connection ID 会被拒
GET 续传: 0x83 | len | Connection ID                   ← 只带 Connection ID 即可
```

这两条各自用独立会话逐项试出：SETPATH 在不带 Connection ID 时返回 `0xA0`，带上时返回 `0xC0`；GET 相反。

**③ Target 头只需出现在 Connect**

`Connect` 以 MAS UUID 的大端字节序作为 Target 头，服务端会校验——换成别的 UUID 立即回 `0xC6`。后续请求不必再带。

#### 7.2.2 目录结构

`GET x-obex/folder-listing` 返回：

```xml
<folder-listing version="1.0"><folder name="telecom"/></folder-listing>
```

路径为 `telecom/msg/inbox`，逐级 `SETPATH` 进入。

#### 7.2.3 列表数据

`GET x-bt/MAP-msg-listing` 返回一份完整 XML（本机实测 450 452 字节，UTF-8）：

```xml
<?xml version='1.0' encoding='utf-8' standalone='yes'?>
<MAP-msg-listing version="1.0">
  <msg handle="400000000000839" subject="…" datetime="20261009T104036"
       sender_name="" sender_addressing="106876251015490"
       recipient_addressing="+8613171726112" type="SMS_GSM" size="1"
       text="yes" reception_status="complete" attachment_size="0"
       priority="no" read="no" sent="no" protected="no"/>
  …
</MAP-msg-listing>
```

实测 1024 条记录，`handle`、`subject`、`datetime`、`sender_addressing`、`read`、`type` 均解析正常，中文不乱码。

**`subject` 就是短信正文**：短信文本原样放在这个属性里（实测最长 127 字），发送方在 `sender_addressing`。新短信的正文不必再单独取一次——除非后续发现长短信在这里被截断。

**属性顺序固定**：`handle` → `subject` → `datetime` → `sender_name` → `sender_addressing` → `recipient_name` → `recipient_addressing` → `type` → `size` → `text` → `reception_status` → `attachment_size` → `priority` → `read` → `sent` → `protected`。

> **解析陷阱**：手机生成的 XML **不转义正文里的英文引号**。实测 1024 条里有 1 条的正文带引号，形如 `subject="…有意可回复"Y"办理。…"`，`XMLParser` 在这一处直接中断，只解析出前 558 条、后面 466 条全部丢失。因此列表不能用 XML 解析器读，要按属性名扫描：每个属性的值延伸到**下一个属性名**为止，这样值里的引号不会截断它。

> **分片处理**：服务端按约 64 KB 分片下发，每片以 `0x90` 提示还有后续。客户端收到 `0x90` 后继续发 `0x83` 取下一片，且**不能清空已累积的缓冲**——否则只会拿到最后一片。

### 7.3 进行中：短信正文

正文在列表的 `subject` 属性里已经拿到了（见 §7.2.3），所以这一步不影响新短信的同步闭环，只关系到一个问题：**长短信会不会在 `subject` 里被截断**。实测 1024 条里最长 127 字、且只有 1 条正好 127 字，看不出硬截断的迹象，但样本里没有超长短信，还不能下定论。

为了拿到确定完整的正文，仍在收敛 `GET x-bt/message` 的请求写法。当前服务端返回 `0xC0`；Connection ID 与 AppParams 的四种组合已逐一试过，不是原因。现用一份 15 用例的探测程序收敛 handle 在 Name 头里的写法——十六进制串 / 十进制串 / 8 字节大端原始值，UTF-8 与 UTF-16BE 两种编码，带不带结尾 `0x0000`。每个用例单开一条 OBEX 会话，避免会话状态互相污染。

### 7.4 待验证：MNS 事件订阅

Mac 发布 UUID `0x1133` 的 SDP 记录并监听，看手机是否会在有新短信时主动连上来推 `x-bt/MAP-Event-Report`。要确认的点：

1. 手机 SDP 里 MNS 记录用的是 RFCOMM 还是 L2CAP PSM（MAP 1.2 起允许 L2CAP）
2. 手机是否真的发起这条回连——MNS 是 MSE 主动连 MCE，方向与我们平时的连接相反
3. `x-bt/MAP-NotificationRegistration` 订阅返回码

这一步不阻塞上线：定时拉列表那条路径已经能拿到新短信，MNS 只是把延迟压到秒级。

### 7.5 待验证：HFP 信令

用 `IOBluetoothHandsFreeDevice` 连接手机 AG，打一个电话进来，观察是否能收到 `incomingCallWithNumber` 回调，同时确认**系统音频通道未被抢占**。

### 7.6 验证清单

- [x] 手机蓝牙配对成功，SDP 记录中出现 MAP / PBAP / HFP 服务
- [x] OBEX Connect + SETPATH + GET listing 全链路通
- [x] 列表解析正确，1024 条记录，中文不乱码
- [ ] 正文请求写法确定，`x-bt/message` 能取回短信内容
- [ ] 定时拉列表 → 比对 handle → 只对新增的取正文，闭环可用
- [ ] 新短信能弹出 macOS 系统通知
- [ ] 短信落库，重启后不重复通知
- [ ] MNS 事件订阅能收到手机推来的新消息事件
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

请求 opcode 的最高位为 final 位，单包请求须置位。

| 操作 | 码值 | 用途 |
|---|---|---|
| Connect | `0x80` | 建立会话 |
| Disconnect | `0x81` | 断开 |
| Put | `0x02` / `0x82` | 发送 |
| Get | `0x03` / `0x83` | 拉取（本机须用 `0x83`） |
| SetPath | `0x85` | 切换目录 |
| Abort | `0xFF` | 中止 |

### OBEX Header

长度编码由 ID 高两位决定：`00` 取 2 字节、`01` 取 3 字节 + 变长值、`10` 取 3 字节、`11` 取 5 字节。

| Header | ID | 用途 |
|---|---|---|
| Name | `0x01` | 文件名 / 目录名 / 消息 handle |
| Type | `0x42` | 操作类型 |
| Target | `0x46` | 目标服务 UUID |
| Body | `0x48` | 数据段 |
| EndOfBody | `0x49` | 数据段结束 |
| AppParams | `0x4C` | 应用参数 |
| Connection ID | `0xCB` | 会话标识 |

### MAP 关键 Header

| Header | 值 | 用途 |
|---|---|---|
| Type | `x-bt/MAP-msg-listing` | 请求消息列表 |
| Type | `x-bt/message` | 请求消息正文 |
| Type | `x-obex/folder-listing` | 请求目录结构 |
| Type | `x-bt/MAP-Event-Report` | 订阅事件（MNS） |
| AppParams `0x14` | Charset，1 字节 | 正文字符集 |
| AppParams `0x01` | Attachment，1 字节 | 是否含附件 |

### 响应码

| 码值 | 含义 |
|---|---|
| `0xA0` | 成功 |
| `0x90` | 继续（还有后续分片） |
| `0xC0` | 请求无效 |
| `0xC6` | 内容类型不接受 |

判定成功看 `op & 0xF0 == 0xA0`。

---

## 附录 B：参考

- Apple Developer · IOBluetooth Framework
  https://developer.apple.com/documentation/iobluetooth
- 华为开发者文档 · 通知订阅能力与权限管理
- Bluetooth SIG · Message Access Profile (MAP) Specification
- Bluetooth SIG · Phone Book Access Profile (PBAP) Specification
- Bluetooth SIG · Hands-Free Profile (HFP) Specification
