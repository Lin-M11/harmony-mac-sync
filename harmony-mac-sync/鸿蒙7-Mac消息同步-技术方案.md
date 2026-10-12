# 鸿蒙 7 → Mac 消息与通话同步 · 技术方案

| 项 | 内容 |
|---|---|
| 版本 | v1.0 |
| 日期 | 2026-10-09 |
| 目标平台 | 手机 HarmonyOS 7（纯血鸿蒙，API 26+） / Mac macOS 14+ |
| 状态 | 已验证：蓝牙服务确认通过 |

---

## 摘要

一句话结论：**短信能同步到 Mac —— V1 就做这一件事**；通讯录、来电同样可行，排在后续版本；App 推送通知不能。

方案是 **Mac 侧蓝牙直连**——用标准蓝牙 MAP / PBAP / HFP 协议直接跟手机通信。手机端零安装、不碰鸿蒙权限。手机已确认暴露这三类服务；MAP 通道已实测打通，可读取短信列表（见 §7.2）。

短信按**增量同步**做：绑定后拉一次列表建立基线，之后只对新增的短信取正文、弹通知、落库，不搬运历史短信。手机侧有新消息时通过 MAP 的 MNS 事件主动通知 Mac，另有定时拉列表兜底（见 §5.2.1）。

App 推送通知的缺口来自硬约束：鸿蒙把「通知监听」划为系统签名级权限、把「短信读取」划为 ACL 受限权限，第三方应用拿不到；官方跨设备通知同步只跑在华为分布式软总线（超级终端）内部，Mac 不在这个生态内。

---

## 1. 需求与目标

### 1.1 目标

**V1 只做短信**：新短信到达手机时同步到 Mac，以 macOS 系统通知提醒，并落库可查。

| 类别 | 具体内容 | 版本 |
|---|---|---|
| 短信 | 新短信到达时同步到 Mac，弹系统通知，落库可查 | **V1** |
| 通话 | 来电提醒（号码 + 通讯录姓名）、未接来电记录 | 后续，见 §9.2 |
| 通讯录 | 号码 → 姓名解析 | 后续，见 §9.2 |
| App 通知 | 手机各 App 的推送通知 | 不做，见 §3.3 |

### 1.2 非目标

- 在 Mac 上回复短信、拨打电话
- 拉取手机里的历史短信全量：只同步绑定之后新到达的短信，已有短信仅用于建立基线
- V1 不涉及通话、通讯录、App 通知（见 §9.2）
- 微信 / QQ 等 App 内部消息的完整会话同步（受平台限制，见 §3）
- 手机端安装任何常驻应用

---

## 2. 可行性结论

先给判断，理由见 §3。

| 类别 | 可行性 | 版本 | 说明 |
|---|---|---|---|
| 短信 | 可行，已实测跑通 | **V1** | 走蓝牙 MAP 协议（Message Access Profile） |
| 通讯录 | 可行 | 后续 B4 | 走蓝牙 PBAP 协议，用于把号码解析成姓名 |
| 来电 | 可行 | 后续 B2 | 走蓝牙 HFP 协议（Hands-Free Profile）的 CLIP 来电显示 |
| App 通知 | **不可行** | 不做 | 无任何可用通道，详见 §3.3 |

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

若未来拿到 ACL 权限，可作为增强方案叠加（见 §9.3）。

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
│  │ MSE  消息服务 (0x1132)│◄─┼──── MAP: OBEX GET ─────────┼──┤  MAP 客户端  ← V1      │  │
│  │ MNS  消息通知 (0x1133)│◄─┼──── MAP: 事件订阅 ─────────┼──┤  (MCE)        B1      │  │
│  ├───────────────────────┤  │                            │  ├────────────────────────┤  │
│  │ PSE  通讯录服务(0x112F)│◄─┼──── PBAP: OBEX GET ────────┼──┤  PBAP 客户端  B4      │  │
│  ├───────────────────────┤  │                            │  ├────────────────────────┤  │
│  │ AG   音频网关 (0x111F)│◄─┼──── HFP: AT 命令 / CLIP ───┼──┤  HFP 免提端   B2      │  │
│  └───────────────────────┘  │                            │  └────────────────────────┘  │
└─────────────────────────────┘                            │              │               │
                                                           │              ▼               │
                                                           │   ┌──────────────────────┐   │
                                                           │   │  增量比对 + 去重      │   │
                                                           │   └──────────────────────┘   │
                                                           │        │          │          │
                                                           │        ▼          ▼          │
                                                           │   本地数据库   系统通知       │
                                                           │   (SQLite)                 │
                                                           └──────────────────────────────┘
```

标注 V1 的是本期范围，B1 / B2 / B4 见 §9.2。

### 5.2 蓝牙通道的分工（V1 只用 MAP）

#### 5.2.1 MAP —— 负责短信 / 彩信（V1）

- 角色：Mac 作为 **MCE**（Message Client Equipment），手机是 **MSE**（Message Server Equipment）
- 服务 UUID：MAS `0x1132`（消息存取，在手机上），MNS `0x1133`（消息事件通知，在 Mac 上）
- 传输：OBEX over RFCOMM

**关键流程（新短信到达即同步）**

两条路径汇聚到同一个去重入口：**定时拉列表**（V1 的主路径，`--interval 2` 时延迟就是一个轮询周期）+ **MNS 事件**（手机推，秒级；Mac 侧发布 MNS 记录的实测状态见 §7.4）。

角色分工：Mac 是 **MCE**，手机是 **MSE**。MNS 这一侧反过来——**Mac 是 MNS 服务端**，手机在有事时主动连上来。

1. SDP 查询拿到 MSE 的 RFCOMM 通道号
2. 连 MSE，`SETPATH` 到 `telecom/msg/inbox`
3. 向 MSE 订阅事件：`PUT`，Type `x-bt/MAP-NotificationRegistration`，AppParams 通知状态（`0x0E`）= `0x01`，正文带填充字节 `0x30`
4. Mac 侧同时发布 MNS 的 SDP 记录（UUID `0x1133`）并监听，等手机连进来
5. 有新短信时，手机主动连上 Mac 的 MNS 通道，`PUT` Type `x-bt/MAP-event-report`
6. Mac 收到事件 → 立刻拉一次收件箱列表 → 与已见 handle 比对 → 对新增的那条弹通知并落库

| 操作 | OBEX 请求 | 目标路径 / 头 |
|---|---|---|
| 进入收件箱 | `SETPATH` | `telecom/msg/inbox` |
| 订阅新消息事件 | `PUT` | Type: `x-bt/MAP-NotificationRegistration` |
| 收事件 | `PUT`（手机发起） | Type: `x-bt/MAP-event-report` |
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

定时那条是为了兜住事件丢失的情况，5 秒一轮——带上 MaxListCount 之后每轮只有几 KB，跑得起。两条路径都走同一个去重入口，重复触发不会重复通知。

**首次绑定**：先拉一次 inbox 列表，把已有 handle 全部记为「已见」但不通知，只建立基线。否则第一次启动会把收件箱里所有短信一次性弹出来。

**标准文件夹路径**：`telecom/msg/inbox`、`sent`、`outbox`、`draft`、`deleted`

#### 5.2.2 PBAP —— 负责通讯录与通话记录（后续版本 B3 / B4）

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

#### 5.2.3 HFP —— 负责来电提醒（后续版本 B2）

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

> ⚠ 注意：macOS 系统本身可能把手机识别为音频设备并占用 HFP 通道。**应避免启用 SCO 音频链路**，只处理信令，否则会与系统音频抢占。

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
| UI | 命令行窗口（V1） | 日志即界面；菜单栏形态是 B5 |
| 蓝牙 | **IOBluetooth** 框架 | `IOBluetoothOBEXSession` 提供 OBEX 原语 |
| 通知 | **UserNotifications**（`UNUserNotificationCenter`） | 通知以 App 身份弹出：显示 App 名字与图标、留在通知中心；需要 `.app` 包承载身份，见 §7.6 |
| 存储 | SQLite（系统 `libsqlite3`） | 存短信，支持检索；不引第三方依赖，`import SQLite3` 即可 |
| 并发 | Swift Concurrency（Actor） | 蓝牙回调在 RunLoop 线程，需桥接到 actor |

**关于 IOBluetooth**：这是 Apple 的公开框架，提供用户态蓝牙访问。关键类：

- `IOBluetoothDeviceInquiry` —— 设备发现
- `IOBluetoothDevice` —— 设备对象，`pair()` / `isPaired()`
- `IOBluetoothSDPServiceRecord` —— SDP 查询，拿 RFCOMM 通道号
- `IOBluetoothRFCOMMChannel` —— RFCOMM 通道，`writeSync` / `rfcommChannelData` 收发字节流
- `IOBluetoothHandsFreeDevice` —— HFP 免提端封装，带 `handsFreeDevice:incomingCallWithNumber:` 等 delegate 回调（B2 用）

**注意**：`IOBluetoothOBEXSession` 是 Apple 提供的 OBEX 封装，但它对 MAP 的自定义 Header 支持有限。实测走的是**直接在 RFCOMM 字节流上收发 OBEX 报文**（`IOBluetoothRFCOMMChannel`），好处是能逐字节对照，报文规则见 §7.2.1。这部分是本项目的主要工作量。

### 6.2 模块划分

```
BluetoothLink
├── DeviceDiscovery        扫描 / 配对 / 记住设备
├── SDPResolver            查询 MAP 服务与通道号
├── OBEXClient             OBEX 原语封装 + 重连
└── MapClient              MAP：listing 解析、增量比对

Core
├── SyncEngine             比对 handle，决定哪些是新消息
├── Store                  SQLite 持久化，幂等去重（按 handle）
└── Notifier               弹 macOS 系统通知

UI
└── 命令行窗口（V1）        日志即界面
```

后续版本再加（见 §9.2）：

```
BluetoothLink
├── MnsServer              MAP MNS：发布 SDP 记录、监听手机推来的事件      B1
├── PbapClient             PBAP：vCard 拉取与解析                        B4
└── HfpClient              HFP：AT 命令通道、CLIP 解析                   B2

Core
├── ContactResolver        号码 → 姓名                                  B4
└── MessageBus             统一事件流（短信 / 来电 / 通话记录）             B2

UI
├── MenuBarExtra           状态图标 + 快捷面板                            B5
├── MessageListView        短信列表与详情                                 B8
├── CallHistoryView        通话记录                                      B3
└── SettingsView           设备绑定、通知规则、开机自启                      B6
```

**V1 的实现顺序**：定时拉列表 → 比对 handle → 弹通知 → 落库。只依赖已验证过的链路，交付即能用。

### 6.3 数据流

V1：

```
手机收件箱
    │
    └─ 定时拉列表 ──→ SyncEngine 比对 handle ──→ 新短信
                                                    ├─→ Store 落库
                                                    ├─→ Notifier 弹系统通知
                                                    └─→ 日志输出
```

后续版本在这条链上挂新的入口，去重入口不变（见 §9.2）：MNS 事件（B1）、HFP 来电（B2）、PBAP 通讯录（B4）。

### 6.4 数据模型

```sql
-- 已见 handle：去重的依据
CREATE TABLE IF NOT EXISTS seen_handle (
  handle      TEXT PRIMARY KEY,
  stamp       TEXT NOT NULL,              -- 列表里自带的日期串，用于按时间清理
  first_seen  INTEGER NOT NULL
);

-- 新到达的短信：只有新增的才写进来
CREATE TABLE IF NOT EXISTS message (
  id           INTEGER PRIMARY KEY,
  handle       TEXT NOT NULL UNIQUE,
  peer_number  TEXT,
  peer_name    TEXT,
  body         TEXT,
  stamp        TEXT,                      -- 列表里的日期串
  received_at  INTEGER NOT NULL,          -- 本机收到的时刻
  notified_at  INTEGER                    -- 弹过通知的时刻
);

CREATE TABLE IF NOT EXISTS sync_state (
  key   TEXT PRIMARY KEY,
  value TEXT
);

-- 后续版本 B3
CREATE TABLE IF NOT EXISTS call_record (
  id           INTEGER PRIMARY KEY,
  handle       TEXT NOT NULL UNIQUE,
  peer_number  TEXT,
  peer_name    TEXT,
  type         TEXT NOT NULL,             -- incoming / outgoing / missed
  started_at   INTEGER NOT NULL,
  duration     INTEGER DEFAULT 0
);
```

`handle` 取 MAP 列表里的消息句柄，配合 `UNIQUE` 天然实现幂等，重复触发不会重复通知。

**`seen_handle` 与 `message` 分开**：建立基线时只往 `seen_handle` 记 handle，不落正文——首次绑定会把收件箱里已有的几十条一次记成已见，这些不需要搬运。`seen_handle` 按 `stamp` 保留 120 天，超期由 `prune` 清掉。

`sync_state` 目前只用一个键：

| 键 | 含义 |
|---|---|
| `bootstrap_at` | 建立基线的时间。库里没有它，说明是首次运行 |

### 6.5 工程配置

**Info.plist**（由 `build.sh` 生成）

```xml
<key>CFBundleIdentifier</key><string>com.linlu.harmonysync</string>
<key>CFBundleDisplayName</key><string>鸿蒙短信同步</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>用于连接手机并读取短信与通知</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>用于连接手机并读取短信与通知</string>
```

图标放 `Contents/Resources/AppIcon.icns`；打包后 `lsregister -f` 向 LaunchServices 登记，通知中心才会按 App 显示名字与图标。运行时用 `NSApplication.setActivationPolicy(.accessory)` 常驻后台，不占 Dock 图标。

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

复现方式：`sdp_probe.swift` 列出全部服务记录与各自的 UUID；`phone_cap_probe.swift` 在此基础上把 MAS 记录的每个属性都展开。两者都用 `IOBluetoothSDPServiceRecord.matchesUUID16` 判断服务类型——`ServiceClassIDList`（`0x0001`）外层是数据元素序列（类型 6），UUID 在它的子元素里，靠外层类型判断会全部落空。

**结论：MAP / PBAP / HFP 三类服务均在，方案成立。**

#### 7.1.1 MAS 记录明细（2026-10-10 实测）

展开手机那条 `SMS/MMS` 记录（`phone_cap_probe.swift`）：

| 属性 | 值 | 说明 |
|---|---|---|
| `0x0001` ServiceClassIDList | `0x1132` | MAP Message Access Server |
| `0x0004` ProtocolDescriptorList | L2CAP → RFCOMM(通道 **26**) → OBEX | 与客户端现有实现一致 |
| `0x0005` BrowseGroupList | `0x1002` | Public Browse Root |
| `0x0009` BluetoothProfileDescriptorList | `0x1134` + `0x0104` | MAP profile，版本 1.4 |
| `0x0100` ServiceName | `SMS/MMS` | |
| `0x0200` GoepL2capPsm | `0x1029` | 手机同时提供 L2CAP 上的 GOEP 通道 |
| `0x0315` MASInstanceID | `0` | |
| `0x0316` SupportedMessageTypes | `0x0E` | 置位：1、2、3 |
| `0x0317` SupportedFeatures | `0x000603FF` | 置位：0–9、17、18 |

`SupportedFeatures` 的关键位：

| 位 | 含义 | 实测 |
|---|---|---|
| 0 | 通知注册 Notification Registration | **支持** |
| 1 | 通知 Notification | **支持** |
| 2 | 浏览 Browsing | 支持 |
| 3 | 数据库标识 Database Identifier | 支持 |
| 4 | 文件夹版本计数 | 支持 |

**结论：手机 MAS 声明支持「通知注册」，MNS 事件订阅这条路成立。** 手机侧不发布 MNS 记录——它是 MSE，符合预期。

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

**只取最新若干条**：列表请求带 AppParams `0x01`（MaxListCount，2 字节大端）即可只拿最新的 N 条，实测这台手机直接接受（`4C 00 07 01 02 00 14` 表示只取 20 条）。轮询因此从 450 KB 降到几 KB，是这条路径能高频跑的前提。

### 7.3 后续版本 B7：短信正文

正文在列表的 `subject` 属性里已经拿到了（见 §7.2.3），所以这一步不影响新短信的同步闭环，只关系到一个问题：**长短信会不会在 `subject` 里被截断**。实测 1024 条里最长 127 字、且只有 1 条正好 127 字，看不出硬截断的迹象，但样本里没有超长短信，还不能下定论。

为了拿到确定完整的正文，仍在收敛 `GET x-bt/message` 的请求写法。当前服务端返回 `0xC0`；Connection ID 与 AppParams 的四种组合已逐一试过，不是原因。现用一份 15 用例的探测程序收敛 handle 在 Name 头里的写法——十六进制串 / 十进制串 / 8 字节大端原始值，UTF-8 与 UTF-16BE 两种编码，带不带结尾 `0x0000`。每个用例单开一条 OBEX 会话，避免会话状态互相污染。

### 7.4 B1：MNS 事件订阅（订阅成立；Mac 侧 SDP 记录发布未成）

方向是反的——**Mac 是 MNS 服务端，手机主动连过来**。要做三件事：

**一、Mac 侧发布 MNS 的 SDP 记录并监听**

```swift
IOBluetoothSDPServiceRecord.publishedServiceRecord(with: mnsServiceDict(...))
IOBluetoothRFCOMMChannel.register(forChannelOpenNotifications: self,
                                  selector: #selector(incoming(_:channel:)),
                                  withChannelID: channelID,
                                  direction: kIOBluetoothUserNotificationChannelDirectionIncoming)
```

SDP 记录的属性：

| 属性 | 值 |
|---|---|
| ServiceClassIDList | `0x1133` |
| ProtocolDescriptorList | L2CAP(PSM `0x0003`) → RFCOMM(通道号) → OBEX(`0x0008`) |
| BluetoothProfileDescriptorList | MAP(`0x1134`) v1.2 |
| ServiceName | `MAP MNS` |
| SupportedFeatures | `0x00000003`（Notification Registration + Notification） |

**判据（2026-10-10 更新）**

发布侧读回来的对象不能当判据：同一台机器连着发布五次，换服务名、换协议栈写法，读回来的属性 ID 列表**完全一样**（`0000,0001,0002,0005,0006,0008,0100`），`0x0004` 从来不出现，RFCOMM 通道号永远读不到。

对本机地址做 SDP 查询也不能当判据：发布前和发布后各查一次，读数都是 0 条，它区分不出记录在不在。同一次运行里对**手机**做 SDP 查询能正常返回记录，说明查询代码本身没问题，是本机查询这条路取不到本机 SDP 数据库。

`remove()` 的返回值同样不能当判据：实测连删两次**都返回成功**（`0`），记录在不在它都这么答。删不到时它另有一个返回值（按句柄删是 `kIOReturnNoDevice`），但对同一条记录连删两次的读数是一样的，配不成对。

所以判据换成**蓝牙守护进程的日志**加**手机的行为**：

| 观察点 | 说明 |
|---|---|
| `addServiceDataToLocalSDP: SRH …` | 记录有没有真的进本机 SDP 库，以及分到的句柄 |
| `addServiceDataToLocalSDP: Number of attributes: n` | 属性有没有被解析进去 |
| `Failed to register psm with result …` | 协议栈那一层有没有挂上 |
| 订阅返回码 | MAS 通道上的 `PUT` 是否回 `0xA0` |
| 手机是否回连 | 入站通道上有没有出现连接 |
| 事件是否到达 | 回连后 `x-bt/map-event-report` 的正文 |

日志抓取写在脚本里（`run_pub_diag.command` 第四段）。框架的内部报错记在**调用方进程名**下，不只记在 `bluetoothd` 名下，两个进程名都要带。

**角色方向（2026-10-10 核对）**

MNS 由 MCE 一侧注册。Android 的 `MapClientService`（MCE 角色）启动时就建一个 `MnsService`，它先开 OBEX 服务端套接字拿到 RFCOMM 通道号，再调 `SdpManager.createMapMnsRecord("MAP Message Notification Service", 通道号, -1, MNS_VERSION, MAP_SUPPORTED_FEATURES)` 把记录挂出去。手机作为 MSE，订阅生效后按这条记录回连。方案里的分工与它一致。

发布侧配一层候选轮换，只放本机 SDP 服务器接受得了的表达方式：

1. **数字元素**：完整字典（`DataElementType` + `DataElementSize` + `DataElementValue` 三项齐全）、简写字典（只有类型和值，长度即宽度）。
2. **协议栈的表达方式**：嵌套数组；`0x0009` Profile 描述可带可不带。

候选共四份：两种数字写法各配「带 Profile」与「不带 Profile」。逐个发布、读回，取第一份能读回通道号的；都读不到就留第一份当保底，入站监听另外叠一层「所有入站通道」。

**数字元素的两种可用表达**（`sdp_ground_probe.swift` 里另有两个用例专门摸边界）：完整字典与简写字典能被本机 SDP 服务器接受；显式构造（`withType:sizeDescriptor:size:value:`）与裸 `NSNumber` 会让发布整体返回空，且本机 SDP 服务器随后会连着拒收后续记录——`0x1133`、从未用过的 128 位 UUID 一律照拒，重启蓝牙守护进程才恢复。

**用 `Data` 表达数字时必须显式写 `DataElementType`。** 框架会把裸 `Data` 推断成 UUID 类型，1 字节的 `Data`（比如 RFCOMM 通道号）不是合法的 UUID 宽度，框架会打印 `size for type 3 (UUID) invalid: 1 bytes`，整条记录发布返回空。

**心跳（2026-10-10 实测）**：客户端每 10 秒打一行状态。轮询本身是静默的，日志里分不出是在等还是已经不动了——那次跑动里四种候选写法发布全部返回空之后，90 秒里一行输出都没有。

**发布侧的状态记录（2026-10-10 09:40 与 10:17 两次实测）**

09:40 那轮：四种数字写法加守候里的三份，发布**全部返回空**。关键是其中「简写字典」那份与 09:22 拿到对象的那次**字节相同**——同一份字典、新起的进程、不同的结果，说明变的是本机 SDP 服务器的状态，不是字典内容。时间线上 09:22:45 之前各用例都能拿到对象，09:22:49 起全部返回空；这中间只跑过用 `withElementValue` 装 `Data` 的那个用例，框架当场报了 `size for type 3 (UUID) invalid: 1 bytes`。

10:17 重启蓝牙守护进程后再跑一轮（`run_sdp_reset_check.command`），读数：

| 用例 | 发布 | 读回 |
|---|---|---|
| `state` | — | 控制器电源开，已配对 9 台，当前连接 0 台 |
| `minimal` | ✓ 句柄 `0x4F491133` | 属性 `[0000,0001,0002,0005,0006,0008,0100]`，`0004` 没有 |
| `control-128` | ✓ 句柄 `0x4F49C0B0` | 同上 |
| `attr-dict-size` | ✓ | 同上，本机 SDP 查询 0 条 |
| `attr-typed` | ✗ 返回空 | — |
| `hold` | 完整字典 ✓（通道读不到）／显式构造 ✗／裸 `NSNumber` ✗ | 本机查询 0 条，守候 120 秒入站 0 次 |

**重启把「发布返回空」解开了**：`minimal`、`control-128`、`attr-dict-size` 重新拿得到对象，而且换一个从未用过的 128 位类 UUID 也照收——说明服务器不是按类 UUID 拒收。剩下两件事没变：读回的属性 ID 列表恒定、`0x0004` 恒定缺席、RFCOMM 通道号恒定读不到；本机 SDP 查询恒定 0 条。这两件事都归到「读数不可用」这一条上，见前面的判据段。

那 120 秒的守候是在手机**没连上**的前提下跑的——重启蓝牙之后手机变成 `Not Connected`、当前连接 0 台。要验回连，得先让手机连上，或者让手机重新做一遍服务发现。

探针为此补的用例：

| 用例 | 回答什么 |
|---|---|
| `state` | 控制器电源、本机地址、当前连接的设备——先排除「控制器没开」这类外部因素 |
| `minimal` | 只放类 UUID + 服务名，不带协议栈。它成了就说明服务器本身收，问题在协议栈那一层的表达 |
| `control-128` | 换一个从未用过的 128 位类 UUID，同样不带协议栈。它成了就说明服务器按类 UUID 拒收 |
| `phone` | 对照组：对手机做 SDP 查询。这条路径已知能返回记录，用它证明查询代码本身没问题 |
| `truth` | 一个进程里串起「查本机 → 两种写法各发一份 → 各自用 `remove()` 配对 → 最后查手机」，每步读数可比 |

配套脚本两个：`run_sdp_reset_check.command`（重启蓝牙守护进程 → `state` / `minimal` / `control-128` / `attr-dict-size` / `attr-typed` → 守候 120 秒）、`run_mns_live.command`（重启蓝牙守护进程 → `state` / `truth` → 客户端跑 200 秒 → `phone` 收尾）。

**订阅侧实测（2026-10-10 10:54）**

MAS 通道上的订阅这次回 `0xA0`：

```
[10:54:49] → Connect（26 字节）
[10:54:50]   ✓ 已连接手机
[10:54:50] → 订阅新消息事件［ConnID + Type + 通知状态 + 填充字节］（54 字节）
[10:54:50]   Connection ID = 00 00 00 01
[10:54:50]   ✓ 事件订阅成功［ConnID + Type + 通知状态 + 填充字节］
```

所以「向 MSE 订阅」这一半成立：`0x0E` 标签、长度 1、填充字节 `0x30` 这套组合被手机接受。

同一轮里 Mac 侧四份候选 SDP 记录**全部发布返回空**，没有记录挂出去，手机自然没有回连（日志里没有入站连接）。这一轮没有重启蓝牙守护进程，服务器还停在上一轮留下的状态里——正好印证前面那条：坏状态要重启才清。

**秒级轮询暴露的两个问题（2026-10-10 10:54 实测）**

`--interval 2 --limit 1` 跑起来之后：

1. **窗口打满时回退到「取整份列表」，整份要过一百多个分片。** 日志里 10:55:08 发起整份请求，10:57:42 才收完，中间 154 秒全在续传，轮询停摆。`--limit 1` 让这个回退几乎每轮都触发——窗口只有 1 条，只要有 1 条新的就「整窗全新」。
2. **整份列表把历史短信当成新短信。** 本地基线当时只有几条，整份 1024 条里 999 条判为全新，一次弹了 999 条通知、入库 999 条。

延迟数据这一轮作废：10:55:46 那条短信直到 10:57:42 才被处理，这段时间都花在整份列表的分片上。

三处调整：

| 调整 | 说明 |
|---|---|
| 窗口打满只放宽一轮 | 放宽到 `min(窗口 × 8, 200)` 再取一次，下一轮回到正常窗口。不再取整份列表 |
| 首次接触整窗记成基线 | 整窗全新、且本地记下的 handle 还没窗口多时，把这一窗记入已见、不通知——窗口外多半还压着一大堆更早的短信，逐条弹通知就是刷屏 |
| 秒级脚本改用默认窗口 20 | 请求固定 46 字节，条数只占其中 2 字节，小窗口省不下请求；窗口 1 条反而让回退一直触发 |

**秒级轮询实测（2026-10-10 11:07）**

间隔 2 秒、每轮最新 20 条，本地库清空后重跑。开机先静默建基线（20 条记入已见、不通知），随后每 2 秒一轮；期间连发四条短信：

| 短信时间（手机侧） | 客户端处理 | 延迟 |
|---|---|---|
| 11:08:01 | 11:08:03 | 2 秒 |
| 11:08:06 | 11:08:09 | 3 秒 |
| 11:08:11 | 11:08:14 | 3 秒 |
| 11:08:14 | 11:08:17 | 3 秒 |

一条通知对应一条短信，没有多弹也没有漏；最后两条只隔 3 秒，照样各自通知一次。启动那一下不再刷屏。

同一轮里 MNS 的四份候选记录仍然全部发布返回空，手机没有回连。这一轮新观察到一点：刚重启完蓝牙守护进程时，对手机的 SDP 查询只返回 1 条、随后 4 条（平时 18 条）且服务名全空——协议栈还在恢复。探针原来「查到非空就返回」，读到的是半截结果；已改成等条数稳定。另外把对手机的查询挪到发布之后——远端查询会占住协议栈，发布排在它后面容易拿不到对象。

**定时轮询继续保留**：事件丢失时它是兜底，订阅不可用时它是唯一路径。`--no-mns` 可以关掉订阅做对照。

把延迟压到秒级不一定要等事件订阅落地——轮询周期本身就可以压：`--interval 2` 是每 2 秒要一次最新的 20 条，请求 46 字节，延迟就是一个周期。配套脚本 `run_fast_sync.command` 用这套参数跑 4 分钟。两种方式可以并存：订阅生效时轮询当兜底，订阅没落地时轮询就是主路径。

**发布侧的状态记录（2026-10-10 11:20）**

重启蓝牙守护进程后立刻跑，发布排在对手机的查询之前，两种数字写法仍然返回空；客户端四份候选同样全部返回空。

同一轮的其余读数都正常：

| 项 | 读数 |
|---|---|
| 事件订阅 | 回 `0xA0` |
| 轮询 | 71 次无停摆，日志 14 KB |
| 入站连接 | 无——没有记录挂出去，手机不会连过来 |
| 新短信 | 2 条，各弹一次通知并入库 |

那两条短信的延迟：

| 短信时间（手机侧） | 客户端处理 | 延迟 |
|---|---|---|
| 11:21:01 | 11:21:04 | 3 秒 |
| 11:21:03 | 11:21:07 | 4 秒 |

一条通知对应一条短信，没有多弹也没有漏。

**字典格式已按头文件核对（2026-10-10 11:26，不连蓝牙）**

系统头文件对发布字典的约定：

| 约定 | 内容 |
|---|---|
| 键名 | 以十六进制属性 ID 开头，其后可跟一个空格与任意后缀 |
| 数字元素 | 完整字典（`DataElementType` + `DataElementSize` + `DataElementValue`）与简写字典（`DataElementType` + `DataElementValue`，宽度取数据长度）都合法 |
| 本地属性 | 可选。`LocalAttributes` 里可写 `Persistent` 与 `TargetApplication`；不写时记录随进程退出而撤下 |

核对结果：现有字典的键名与数字写法都在约定之内，键名带不带后缀都能被接受。

**`withServiceDictionary` 不做解析（2026-10-10 11:28，不连蓝牙）**

`IOBluetoothSDPServiceRecord.withServiceDictionary(_:device:)` 返回的记录，`attributes` 就是传进去的那份字典原文——键还是原来的字符串键，值是原样的数组与字典。它不校验、不转换。所以「解析成功」说明不了字典是否可用，真正的转换发生在发布那一步。要判定字典是否可用，得看发布的结果。

**发布判定探针（sdp_pub_diag.swift）**

只在本机跑，不需要手机：

| 用例 | 做什么 |
|---|---|
| `bundle` | 进程身份：Bundle ID、用途说明、C 层符号是否齐全 |
| `parse` | 三份字典各过一遍 `withServiceDictionary`，打印属性原文 |
| `mns-ours` | MAP MNS，当前生产写法 |
| `spp-num` | 对照组：串口服务（`0x1101`），键名带后缀、数字用数值 |
| `spp-data` | 对照组：串口服务，键名不带后缀、数字用数据 |
| `spp-obex` | 串口服务，协议列表多一层 OBEX |
| `mns-nobex` | MAP MNS，协议列表不带 OBEX |
| `mns-min` | MAP MNS，只留 `0001` 与 `0004` |
| `mns-l2cap` | MAP MNS，`0004` 只留 L2CAP |
| `mns-persist` | MAP MNS，带 `LocalAttributes` 的 `Persistent` |
| `mns-psm1001` | MAP MNS，协议列表里的 L2CAP 换成动态 PSM `0x1001` |
| `mns-nol2cap` | MAP MNS，协议列表去掉 L2CAP，只留 RFCOMM 与 OBEX |
| `repeat-spp` | 同一份串口字典在同一进程里连发 4 次 |
| `repeat-mns` | 同一份 MAP MNS 字典在同一进程里连发 4 次 |
| `capi-spp` | C 层 `IOBluetoothAddServiceDict` 发串口服务 |
| `capi-mns` | C 层 `IOBluetoothAddServiceDict` 发 MAP MNS |

`spp-*` 与 `mns-*` 构成一组对照：串口服务是系统文档里就有示例的标准服务，它若也发不出去，说明瓶颈在发布这条路上，与 MNS 的字典内容无关。`spp-obex` 与 `mns-nobex` 把「类 UUID」和「协议列表里带不带 OBEX」这两个变量分开。

`repeat-*` 看的是同一份字典连发时的变化，用来判断前一次发布会不会影响后一次。

`capi-*` 走 C 层 `IOBluetoothAddServiceDict`（`dlsym` 取符号），与 Objective-C 层的结果对照——两层读数一致时，可以排除某一层特有的问题。

脚本 `run_pub_diag.command` 分四段：重启蓝牙守护进程（等 12 秒）→ 进程身份与字典原文 → **逐项判定**（每个用例前各重启一次并等 12 秒，让每个用例都成为「守护进程就绪后的第一个服务」）→ **连续发布**（同一份字典在同一进程里连发四次）→ 抓蓝牙守护进程与探针自身的日志。

等待时间给 12 秒是有原因的：给 3 秒时四个用例全部失败，连已知能成的串口服务也一样；给到 10 秒以上才稳定。守护进程起来之后要再过几秒才收得住发布请求。

**发布判定实测（2026-10-10 14:00）**

重启蓝牙守护进程后逐项跑，结果分成两半：

| 用例 | 服务 | 结果 |
|---|---|---|
| `spp-num` | 串口 `0x1101`，数字用数值 | **发布 ✓** 句柄 `0x4F491101`，RFCOMM 通道 1 |
| `spp-data` | 串口 `0x1101`，数字用数据 | **发布 ✓** 句柄 `0x4F491101`，RFCOMM 通道 1 |
| `capi-spp` | C 层发串口 | **返回 0（成功）** 句柄 `0x700050` |
| `mns-ours` | MAP MNS `0x1133`，当前写法 | ✗ 返回空 |
| `mns-min` | MAP MNS，只留 `0001` + `0004` | ✗ 返回空 |
| `mns-l2cap` | MAP MNS，`0004` 只留 L2CAP | ✗ 返回空 |
| `mns-persist` | MAP MNS，带 `Persistent` | ✗ 返回空 |
| `capi-mns` | C 层发 MAP MNS | ✗ 返回 `0xE00002BC` |

**发布这条路是通的**——串口服务在 Objective-C 层与 C 层都能发出去，而且读回的属性是真实的数据元素（`uuid32(00 00 11 01)`、`{ uuid32(00 00 00 03), uint32(3) }`），RFCOMM 通道号也读得到。**MAP MNS 这一份两份写法都发不出去**，C 层也一样。所以瓶颈落在 MNS 这份记录本身，与发布通道无关。

同一轮的蓝牙守护进程日志给出了具体停在哪一步：

```
addServiceDataToLocalSDP: SRH 0x4F491133
addServiceDataToLocalSDP: Number of attributes: 5
addServiceDataToLocalSDP: publishing PSM 3
trying to publish psm:3 inMTU:1024 inMPS:1024 ... for session "…classic-…-63"
Registering L2CAP Channel with PSM 0x0003 for session "…classic-…-63"
Failed to register L2CAP Channel with PSM 0x0003 ... with result 402
Failed to register psm with result 0x709
```

三点读数：

1. **记录本身建起来了**——`SRH 0x4F491133`，5 条属性全部解析进去（与字典里的五个键对上）。
2. **停在后一步**：按协议列表里的 L2CAP 项去注册 PSM 3（RFCOMM 的公共 PSM），这一步失败。
3. 句柄的构成是 `0x4F49` 加上类 UUID：串口拿到 `0x4F491101`、MNS 拿到 `0x4F491133`。同一个类 UUID 反复发布，拿回的是同一个句柄。

据此把下一轮要问的问题收敛成一个：**MNS 作为「重启后的第一个服务」发布时，能不能成**。能成，说明是 PSM 被前一个服务占住；不能成，说明是这份记录的内容被拒。

**发布判定实测（2026-10-10 14:57）**

这一轮加了一组对照：同一份串口字典与同一份 MNS 字典，在**同一个进程里各连发四次**。

| 用例 | 第 1 次 | 第 2 次 | 第 3 次 | 第 4 次 |
|---|---|---|---|---|
| `repeat-spp` 串口 `0x1101` | ✓ 句柄 `0x4F491101` 通道 1 | ✓ 同上 | ✓ 同上 | ✓ 同上 |
| `repeat-mns` MAP MNS `0x1133` | ✗ 返回空 | ✗ 返回空 | ✗ 返回空 | ✗ 返回空 |

同一进程、同一时刻、同一套写法，**串口四次全成、MNS 四次全空**。四次的服务器日志逐字一致：

```
addServiceDataToLocalSDP: Number of attributes: 5, 0x5
addServiceDataToLocalSDP: SRH 0x4F491133
addServiceDataToLocalSDP: publishing PSM 3
Registering L2CAP Channel with PSM 0x0003 for session "…classic-27415-53"
Failed to register L2CAP Channel with PSM 0x0003 … with result 402
Classic Channel published callback PSM : 3 result : 1801
Failed to register psm with result 0x709
```

**「重启后等 3 秒」不够。** 这一轮第二段把「每个用例前各重启一次」的等待设成了 3 秒，四个用例**全部失败**——包括已知能成的串口服务。同一轮第三段不再重启、距上次重启已过 10 秒，串口四次全成。也就是说守护进程起来之后要再过几秒才收得住发布请求，等待时间不够时读数会被污染。脚本已把等待改成 12 秒。

**框架那句 `Added service with handle 4F491133` 不是成功标志。** 四次失败里每次都照打这一行——它只表示框架把请求发出去了，服务器那一侧的注册结果要看 `Failed to register psm with result …`。

据此这一轮把变量继续收窄，新增两个用例：

| 用例 | 变的是什么 | 要回答的问题 |
|---|---|---|
| `mns-psm1001` | 协议列表里的 L2CAP 换成动态 PSM `0x1001` | PSM 3 被占住是不是唯一原因 |
| `mns-nol2cap` | 协议列表去掉 L2CAP，只留 RFCOMM 与 OBEX | 不碰 PSM 时这份记录能不能进库 |

`mns-psm1001` 若能成，说明卡点确实是 PSM 3 那一格；`mns-nol2cap` 若能成，说明记录本身可以被接受。两个都仍返回空，就说明是类 UUID `0x1133` 这一层被拒。

发布是异步的：发出后先跑一两秒 RunLoop 再读回。

入站监听注册两层：一层按读回的通道号、一层不限通道（`register(forChannelOpenNotifications:selector:)`）。两层会对同一条通道各回调一次，按通道号去重，并排除自己连手机 MAS 的那条通道（`ignoreChannelID`）。

**二、向 MSE 订阅**

MAS 通道上发 `PUT`（`0x82`），头部三样：

| 头部 | 值 |
|---|---|
| Connection ID | 会话号（`00 00 00 01`） |
| Type | `x-bt/MAP-NotificationRegistration` |
| AppParams | 通知状态：标签 `0x0E`、长度 1、值 `0x01` |

**正文必须带一个填充字节 `0x30`**——OBEX 里正文为空的 `PUT` 等同删除，规范专门要求填 `'0'` 来规避。整包：opcode 3 + ConnID 5 + Type 头 36 + AppParams 头 6 + EndOfBody 头 4 = 54 字节。

备用写法四种依次回退：不带 Connection ID、用已学到的 Connection ID、加 `Name` 头、末尾改用 `Body` 头。

**三、收到事件后立即同步**

手机连上 MNS 通道后推 `PUT`，Type `x-bt/MAP-event-report`，AppParams 带 MAS 实例号（标签 `0x0F`），正文是 XML：

```xml
<MAP-event-report version="1.0">
  <event type="NewMessage" handle="…" folder="telecom/msg/inbox" msg_type="SMS_GSM"/>
</MAP-event-report>
```

事件类型在正文的 `type` 属性里。解析按属性名扫描，属性名前锚一个空格——否则 `msg_type` 会被当成 `type`、`old_folder` 会被当成 `folder`。收到后应答 `0xA0` 并立刻拉一次收件箱列表，不等下一个轮询周期。

入站侧对报文只做三件事：Connect 记下手机给的会话号（没给就用 `00 00 00 01`）并应答 `0xA0`；事件报告取正文 XML 与 AppParams 的 MAS 实例号，应答后触发同步；断开则关通道。这段判定抽成了纯函数，可以用 `--mns-selftest` 脱开蓝牙自检。

事件若在上一轮请求还在路上时到达，会记下来、等这一轮结束立刻补一次拉取（0.5 秒后），而不是丢掉。

**本地自检（2026-10-10，不连蓝牙）**

订阅报文、事件解析、以及 MNS 入站处理都在客户端里留了可离线运行的入口，先在本机把编码与判定固定下来：

```
$ HarmonySync --dump-notif
0 ConnID + Type + 通知状态 + 填充字节（54 字节）
   82 00 36 CB 00 00 00 01 42 00 24 <Type 33 字节> 4C 00 06 0E 01 01 49 00 04 30

$ HarmonySync --event ev2.xml
正文 226 字
解析结果：type=MessageDeleted handle=0000000000000005 folder=telecom/msg/inbox msg_type=SMS_CDMA

$ HarmonySync --mns-selftest
== Connect（26 字节）    应答 0xA0   会话号 00 00 00 01
== 事件报告（226 字节）  应答 0xA0
   ★ 事件报告：type=NewMessage handle=0000000000000042 folder=telecom/msg/inbox msg_type=SMS_GSM  MAS实例=1
   → 触发同步：…
== 断开（3 字节）        应答 0xA0   关闭通道
```

事件解析那个用例把属性顺序打乱并塞入 `old_folder` / `msg_type` 干扰项，结果仍然正确；MNS 自检覆盖手机回连后的完整三步。

**排障要点**

订阅返回 `0xC0`，且响应体只有一条 `EndOfBody` 头（`49 00 03`）时，按顺序核对三处：通知状态参数是否用 `0x0E` 标签、长度为 1；正文是否带了填充字节 `0x30`；Connection ID 是否与当前会话一致。MAS 侧读不到通知状态参数即判为坏请求，这是 `0xC0` 的直接来源。

**要观察的点**

1. 订阅返回码是否变成 `0xA0`
2. 手机是否真的发起这条回连——方向与平时的连接相反
3. 事件延迟：订阅生效后事件会立刻触发一次拉取，不等下一个周期
4. 本机 SDP 记录是否真的挂上去了——用 `remove()` 的返回值配对判断，见前面的判据段

**只跑 MNS 的入口**

`--mns-hold <秒>` 发布 SDP 记录并守着，不建立 MAP 会话。用来单独验证「手机能不能主动连过来」，把变量从 MAP 那边摘干净。

#### 7.4.1 地面真相探针（sdp_ground_probe.swift）

专门回答「本机 SDP 服务器实际存了什么、手机能查到什么」。用例各自独立进程，避免互相干扰：

| 用例 | 做什么 |
|---|---|
| `state` | 控制器电源、本机地址、当前连接的设备 |
| `audit` | 只查不发。对本机地址做 SDP 查询，列出全部记录 |
| `phone` | 对照组：对手机做 SDP 查询。证明查询代码本身没问题 |
| `truth` | 一个进程里串起「查本机 → 两种写法各发一份 → 各自用 `remove()` 配对 → 最后查手机」，每步读数可比 |
| `minimal` | 最简记录：只有类 UUID + 服务名，不带协议栈 |
| `control-128` | 对照：换一个从未用过的 128 位类 UUID，同样不带协议栈 |
| `attr-dict-size` | 数字元素用完整字典（含 `DataElementSize`） |
| `attr-typed` | 数字元素用 `withType:sizeDescriptor:size:value:` 显式构造 |
| `attr-number` | 数字元素用裸 `NSNumber` |
| `attr-dict-plain` | 数字元素用简写字典（对照） |
| `hold [秒]` | 三种写法各发一条记录、各占一个通道，一起挂着等手机回连；同时注册入站监听，有连接进来就打印通道号 |

`minimal` 与 `control-128` 是一对：前者排除「服务器整体不收」，后者排除「服务器按类 UUID 拒收」。

`phone` 与 `audit` 是一对：前者证明查询代码能返回记录，后者的 0 条才有意义——它说明本机查询这条路取不到本机 SDP 数据库，而不是查询坏了。

查询等的是「条数连续 2 秒不变」，不是「非空就返回」。刚重启完蓝牙守护进程时协议栈还在恢复，第一批结果只有一两条且服务名全空。

`hold` 里三条记录用不同通道号，手机连过来时打出的通道号能反推出它选了哪一份记录。

配套脚本四个：`run_ground_check.command`（审计 → 四种读数写法 → 守候 150 秒）、`run_sdp_reset_check.command`（重启蓝牙守护进程 → 状态 / 最简 / 对照 / 完整 → 守候 120 秒）、`run_mns_live.command`（重启蓝牙守护进程 → `state` / `truth` → 客户端跑 200 秒 → `phone` 收尾）、`run_pub_diag.command`（发布判定探针 `sdp_pub_diag.swift`，见 §7.4）。

### 7.5 后续版本 B2：HFP 信令

用 `IOBluetoothHandsFreeDevice` 连接手机 AG，打一个电话进来，观察是否能收到 `incomingCallWithNumber` 回调，同时确认**系统音频通道未被抢占**。

### 7.6 验证清单

**增量同步实测（2026-10-09 11:16–11:20）**：客户端连上手机后建立基线（20 条 handle 记入已见，不通知），随后每 20 秒轮询一次。期间收到一条测试短信，客户端在下一轮就抓到并弹出通知、写入数据库：

```
[11:16:41] → GET 收件箱列表（最新 20 条）（46 字节）
[11:16:42]   ✓ 已建立基线：20 条记入已见，不通知
[11:17:04]   无新短信（列表 20 条）
…
[11:20:23]   ★ 新短信 1 条
[11:20:23]     [2026-10-09 11:20:01] 8618828851954
[11:20:23]       测试1
[11:20:24]   ✓ 已通知并入库，本地共 1 条
```

短信 11:20:01 到手机，11:20:23 弹通知——**延迟等于一个轮询周期**。整条 RFCOMM 会话保持 4 分钟未断，`MaxListCount` 参数手机直接接受，没有走整份列表的回退。

**通知以 App 身份弹出（2026-10-10）**：客户端包成 `HarmonySync.app`（显示名「鸿蒙短信同步」，带图标），通知走 `UNUserNotificationCenter`，与通知中心里其它 App 是同一种形式：

- 通知上显示 App 自己的名字与图标
- 程序在前台时也照常放横幅（`willPresent` 返回 `[.banner, .list, .sound]`）
- 同一个发件人的通知用 `threadIdentifier` 归到一组，像聊天 App 那样叠起来
- 通知留在通知中心里，点右上角日期时间能翻到

自检：双击 `run_notify_check.command`，或直接跑 `HarmonySync.app/Contents/MacOS/HarmonySync --test-notify`。自检会打印通知身份与授权状态：

```
[15:13:08] === 通知自检 ===
[15:13:08] 通知身份：com.linlu.harmonysync
[15:13:08]   ✓ 通知已授权
[15:13:08]   通知授权状态：已允许
[15:13:12] 已发出测试通知
```

首次运行需要一次授权：系统弹一次询问，点「允许」即可；若错过那次询问，到「系统设置 → 通知 → 鸿蒙短信同步」把开关打开，效果相同。

- [x] 手机蓝牙配对成功，SDP 记录中出现 MAP / PBAP / HFP 服务
- [x] OBEX Connect + SETPATH + GET listing 全链路通
- [x] 列表解析正确，1024 条记录，中文不乱码
- [x] 定时拉列表 → 比对 handle → 只对新增的弹通知并落库，闭环可用
- [x] 新短信弹出 macOS 系统通知，正文取自列表的 `subject`
- [x] 通知以 App 身份弹出：显示 App 名字与图标，留在通知中心，见上
- [x] 短信落库，已见 handle 持久化，重启不重复通知
- [x] 手机 MAS 记录读通，`SupportedFeatures` 声明支持「通知注册」（§7.1.1）
- [ ] B7：正文请求写法确定，`x-bt/message` 能取回短信内容
- [x] 新短信延迟压到秒级：`--interval 2`，两轮实测 2–4 秒，见 §7.4
- [ ] B1：MNS 事件订阅能收到手机推来的新消息事件（订阅已被手机接受；Mac 侧发布 MNS 的 SDP 记录未成，见 §7.4。秒级延迟由高频轮询兜住，`--interval 2`）
- [ ] B2：HFP 能拿到来电号码，且不抢占系统音频
- [ ] B6：手机重启 / 走出蓝牙范围后能自动重连

---

### 7.7 交付物与使用

| 文件 | 作用 |
|---|---|
| `harmony_sync.swift` | 客户端：增量同步 → 系统通知 → 落库 |
| `make_icon.swift` | 图标生成：CoreGraphics 画十种尺寸，合成 `AppIcon.icns` |
| `build.sh` | 编译客户端并组装成 `HarmonySync.app`（蓝牙用途说明 + 图标 + ad-hoc 签名） |
| `run_sync.command` | 双击启动：增量同步，日志同步落盘 |
| `run_fast_sync.command` | 双击启动：间隔 2 秒的秒级轮询，跑 4 分钟 |
| `run_notify_check.command` | 双击运行：通知自检 |
| `鸿蒙7-Mac消息同步-技术方案.md` | 本文档 |

**验证阶段的探针**（SDP 查询与发布、OBEX 报文、列表解析、手机能力，共 12 个 `.swift` 与 8 个 `.command`）用于逐项取证，取证结果已收进 §7.1–§7.4。它们不在当前工作树里，源码保留在 git 历史中：

```bash
git log --oneline -- harmony-mac-sync/sdp_pub_diag.swift    # 找到引入它的提交
git checkout <提交> -- harmony-mac-sync/sdp_pub_diag.swift  # 取回单个文件
```

**构建**：`./build.sh` 编译客户端并组装成 `HarmonySync.app`（带蓝牙用途说明 + 图标 + ad-hoc 签名），末尾向 LaunchServices 登记。图标由 `make_icon.swift` 生成，`build.sh` 会自动调用。

**启动方式**：双击 `HarmonySync.app` 即以后台形态常驻，不占 Dock 图标；想看日志就双击 `run_sync.command`（增量同步）或 `run_fast_sync.command`（秒级轮询，跑 4 分钟），日志同时落在 `/tmp/harmony_sync_result.txt`。通知自检双击 `run_notify_check.command`。蓝牙权限记在启动进程上：双击 `.command` 时归到 Terminal，双击 `HarmonySync.app` 时归到 App 自己（`Info.plist` 里已声明用途说明），两种方式都能正常弹窗授权。

`harmony_sync.swift` 支持几个参数：

| 参数 | 作用 |
|---|---|
| 无 | 持续轮询 + 订阅手机的新消息事件，新短信即通知 |
| `--interval <秒>` | 改轮询间隔，默认 5 秒；压到 2 秒即秒级延迟 |
| `--limit <条>` | 每轮只取最新的 N 条，默认 20。请求固定 46 字节，条数只占其中 2 字节；窗口压到 1 条会让「整窗全新」几乎每轮都成立，不建议 |
| `--no-mns` | 只轮询，不订阅事件 |
| `--once` | 只跑一轮就退出 |
| `--reset` | 清空本地记录，下次运行重新建立基线 |
| `--parse <文件>` | 不连蓝牙，直接拿一份保存的列表验解析 |
| `--event <文件>` | 不连蓝牙，拿一份事件报告正文验解析 |
| `--dump-notif` | 不连蓝牙，打印五种订阅写法的报文字节 |
| `--dump-sdp` | 不连蓝牙，把五种候选 SDP 字典按 plist 打出来 |
| `--mns-selftest` | 不连蓝牙，用合成报文走一遍 MNS 入站处理（连接 / 事件报告 / 断开） |
| `--mns-hold <秒>` | 只跑 MNS 服务端：发布 SDP 记录并守着，不建立 MAP 会话 |
| `--test-notify` | 不连蓝牙，弹一条测试通知，打印通知身份与授权状态 |

**本地数据**：`~/Library/Application Support/HarmonySync/messages.db`

| 表 | 内容 |
|---|---|
| `message` | 新到达的短信正文与发送方 |
| `seen_handle` | 已见过的 handle，用于去重，保留 120 天 |
| `sync_state` | `bootstrap_at` 等游标 |

---

## 8. 风险清单

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| R1 | 华为手机不对外暴露 MAP 服务 | ~~致命~~ 已解除 | §7.1 实测确认 MAP / PBAP / HFP 服务均在 |
| R2 | 系统升级后收紧蓝牙服务 | 高 | 协议是蓝牙 SIG 标准，通常稳定；做好版本监控 |
| R3 | OBEX 报文手写工作量大、易出错 | ~~中~~ 已解除 | Swift 原型已跑通，报文规则固化在 §7.2.1 |
| R4 | 手机锁屏后 MAP 服务挂起 | 中 | 实测持续 4 分钟会话未断；长跑观察 |
| R5 | 轮询耗电与流量 | 中 | 每轮只取最新 20 条，请求 46 字节；后续用 MNS 取代高频轮询（B1） |
| R6 | macOS 蓝牙权限归因到启动进程 | 中 | 权限记在启动进程上，用 `.command` 双击启动即正常授权 |
| R7 | 通知的 App 身份 | ~~高~~ 已解除 | 客户端包成 `.app`，通知走 `UNUserNotificationCenter`，显示 App 名字与图标；见 §7.6 |
| R8 | 通话 / 通讯录依赖 HFP、PBAP | 中 | 排在后续版本（B2 / B4），各自独立验证 |

---

## 9. 版本范围

### 9.1 V1：只做短信

**新短信到达时同步到 Mac，弹系统通知，落库可查。** 就这一件事。

不碰通话、不碰通讯录、不碰 App 通知。理由：短信这条链路已经实测跑通（§7.2、§7.6），能独立交付；其余几项各自都有未验证的部分，混在一起会拖慢 V1。

### 9.2 后续版本（Backlog）

按价值排序，各自独立可做：

| # | 事项 | 依据 | 前置 |
|---|---|---|---|
| B1 | MNS 事件订阅，新短信延迟从轮询周期压到秒级 | §7.4 | 已实现，待实测 |
| B2 | 来电提醒（HFP 信令，CLIP 取号码） | §5.2.3 | 需验证不抢占系统音频 |
| B3 | 未接来电记录 | §5.2.2 | 需先做 B4 |
| B4 | 通讯录同步，号码 → 姓名 | §5.2.2 | 无 |
| B5 | 菜单栏应用形态（SwiftUI `MenuBarExtra`），替换现在的命令行窗口 | §6.1 | 无 |
| B6 | 开机自启、断连自动重连 | §7.6 末项 | 无 |
| B7 | 短信正文按需取回，应对超长短信被 `subject` 截断 | §7.3 | 需先定下 `x-bt/message` 的请求写法 |
| B8 | 消息列表 UI、搜索、验证码识别与一键复制 | V1 之后的体验补足 | 需先做 B5 |

**明确不做**：App 推送通知。见 §3.3，任何路线都拿不到。

### 9.3 增强：如果拿到企业 ACL 权限

若后续以企业开发者身份拿到 `READ_MESSAGES` / `RECEIVE_SMS` 的 ACL 白名单，可以叠加一个手机端鸿蒙 App 做局域网推送，作为蓝牙之外的冗余通道（例如手机不在蓝牙范围内时仍能收到短信）。

但注意：**通知监听权限（`NOTIFICATION_CONTROLLER`）级别更高，仍无解**，App 通知这项在任何路线下都拿不到。

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
| Type | `x-bt/MAP-NotificationRegistration` | 订阅 / 退订新消息事件 |
| Type | `x-bt/MAP-event-report` | 手机推来的事件报告（MNS） |

Type 字符串各家用的大小写不一致，比对时统一转小写。

### MAP 应用参数标签

| 标签 | 含义 | 长度 |
|---|---|---|
| `0x01` | MaxListCount | 2 字节 |
| `0x02` | ListStartOffset | 2 字节 |
| `0x0A` | Attachment | 1 字节 |
| `0x0D` | NewMessage | 1 字节 |
| `0x0E` | NotificationStatus | 1 字节（`0x01` 开、`0x00` 关） |
| `0x0F` | MASInstanceID | 1 字节 |
| `0x14` | Charset | 1 字节 |

订阅新消息事件时用的通知状态标签是 `0x0E`（长度 1，`0x01` 开、`0x00` 关）；正文放一个填充字节 `0x30`，让这个 `PUT` 不被当成删除。

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
