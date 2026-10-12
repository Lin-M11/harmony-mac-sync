import Foundation
import IOBluetooth

// 命令行入口：跑同步、看日志、做各种本地自检。
//
// 与 GUI 共用 HarmonyCore.swift 里的引擎；两边用同一个数据库、同一套通知身份，
// 不会互相打架（同一时刻只跑一个）。

@main
struct HarmonyCLI {
    static func main() {
        // MARK: - 入口

        var args = Array(CommandLine.arguments.dropFirst())

        // 本地自检：弹一条测试通知，看通知的样子。不碰蓝牙
        if args.contains("--test-notify") {
            emit("=== 通知自检 ===")
            emit("通知身份：\(Bundle.main.bundleIdentifier ?? "（不是 App 包）")")
            Notifier.shared.prepare(activate: true)
            // 系统询问要用户点一下，给足时间；已授权时这一步立刻返回
            Notifier.shared.waitForAuthorization(seconds: 45)
            Notifier.shared.reportSettings()
            notify(title: "张三", body: "这是一条测试短信，用来确认通知的样子。", subtitle: "138 0000 0000")
            RunLoop.current.run(until: Date().addingTimeInterval(4.0))
            emit("已发出测试通知")
            exit(0)
        }

        // 本地自检：不连蓝牙，直接拿一份保存下来的列表验解析
        if let i = args.firstIndex(of: "--parse"), i + 1 < args.count {
            let path = args[i + 1]
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("读不到 \(path)")
                exit(1)
            }
            let tags = text.components(separatedBy: "<msg ").count - 1
            let msgs = parseListing(text)
            print("msg 元素 \(tags) 个，解析出 \(msgs.count) 条")
            print("正文含引号的条数：\(msgs.filter { $0.subject.contains("\"") }.count)")
            print("最新 3 条：")
            for m in msgs.prefix(3) {
                print("  [\(prettyTime(m.datetime))] \(m.peerNumber) — \(m.subject)")
            }
            if let q = msgs.first(where: { $0.subject.contains("\"") }) {
                print("含引号的样例：")
                print("  [\(prettyTime(q.datetime))] \(q.peerNumber) — \(q.subject)")
            }
            exit(0)
        }

        // 本地自检：拿一份事件报告正文验解析，不碰蓝牙
        if let i = args.firstIndex(of: "--event"), i + 1 < args.count {
            let path = args[i + 1]
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("读不到 \(path)")
                exit(1)
            }
            print("正文 \(text.count) 字")
            print("解析结果：\(parseEventReport(text))")
            exit(0)
        }

        // 本地自检：打印五种订阅写法的报文，不碰蓝牙
        if args.contains("--dump-notif") {
            let learned: [UInt8] = [0x00, 0x00, 0x00, 0x07]
            for (i, label) in NOTIF_VARIANTS.enumerated() {
                let p = notifRequest(variant: i, learnedConnID: learned)
                print("\(i) \(label)（\(p.count) 字节）")
                print("   \(hex(p))")
            }
            exit(0)
        }

        // 本地自检：用合成报文走一遍 MNS 入站处理，不碰蓝牙
        if args.contains("--mns-selftest") {
            var connID: [UInt8] = [0x00, 0x00, 0x00, 0x01]

            // 手机连上 MNS 时发的 Connect（带 Target = MNS UUID）
            var c1: [UInt8] = [0x10, 0x00, 0xFF, 0xFF]
            c1 += lenHeader(HDR_TARGET, MNS_UUID_128)
            let connect = frame(opcode: 0x80, body: c1)

            // 手机推来的事件报告
            let report = """
            <?xml version="1.0" encoding="UTF-8"?>
            <MAP-event-report version="1.0">
            <event type="NewMessage" handle="0000000000000042" folder="telecom/msg/inbox" msg_type="SMS_GSM"/>
            </MAP-event-report>
            """
            var c2: [UInt8] = []
            c2 += lenHeader(HDR_TYPE, Array(EVENT_REPORT_TYPE.utf8))
            c2 += lenHeader(HDR_APPPARAMS, [0x0F, 0x01, 0x01])
            c2 += lenHeader(HDR_END_OF_BODY, Array(report.utf8))
            let eventPut = frame(opcode: OBEX_PUT_FINAL, body: c2)

            // 手机断开
            let disconnect = frame(opcode: 0x81, body: [])

            for (label, packet) in [("Connect", connect), ("事件报告", eventPut), ("断开", disconnect)] {
                let d = mnsDecide(packet, connID: &connID)
                print("== \(label)（\(packet.count) 字节）")
                print("   应答 \(String(format: "0x%02X", d.code))   会话号 \(hex(connID))\(d.close ? "   关闭通道" : "")")
                for l in d.lines { print("   \(l)") }
                if let e = d.event { print("   → 触发同步：\(e)") }
            }
            exit(0)
        }

        // 本地自检：把几种候选字典按 plist 打出来，不碰蓝牙
        if args.contains("--dump-sdp") {
            let candidates: [(NumStyle, PdlStyle, Bool)] = [
                (.dictSize, .nestedDict, true),
                (.typed, .nestedDict, true),
                (.number, .nestedDict, true),
                (.dictPlain, .nestedDict, true),
                (.dictSize, .nestedDict, false),
            ]
            for (i, c) in candidates.enumerated() {
                print("===== 候选 \(i + 1)：\(c.0.rawValue) + \(c.1.rawValue)\(c.2 ? " + Profile" : "") =====")
                let dict = mnsServiceDict(channel: MNS_RFCOMM_CHANNEL, num: c.0, style: c.1, includeProfile: c.2)
                if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                } else {
                    print("（打不出来）")
                }
            }
            exit(0)
        }

        // 只跑 MNS 服务端：发布 SDP 记录并守着，看手机能不能主动连过来。不碰 MAP 会话。
        if let i = args.firstIndex(of: "--mns-hold") {
            let secs = i + 1 < args.count ? (Double(args[i + 1]) ?? 150) : 150
            print("只跑 MNS 服务端，保持 \(Int(secs)) 秒")
            print("")

            let mns = MnsServer()
            mns.start { detail in
                print("  [MNS] 事件：\(detail)")
            }
            print("")

            var left = secs
            let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                left -= 15
                print("  · 还剩 \(Int(max(left, 0))) 秒，入站连接 \(mns.incomingCount) 次")
            }
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.run(until: Date().addingTimeInterval(secs))
            print("")
            print("结束：入站连接共 \(mns.incomingCount) 次")
            exit(0)
        }

        let once = args.contains("--once")
        let reset = args.contains("--reset")
        if args.contains("--no-mns") { mnsEnabled = false }
        if let i = args.firstIndex(of: "--interval"), i + 1 < args.count,
           let v = Double(args[i + 1]), v >= 1 {
            pollInterval = v
            args.removeSubrange(i...(i + 1))
        }
        if let i = args.firstIndex(of: "--limit"), i + 1 < args.count,
           let v = UInt16(args[i + 1]), v >= 1 {
            listingLimit = v
            args.removeSubrange(i...(i + 1))
        }
        args.removeAll { $0.hasPrefix("--") }

        emit("========================================")
        emit(" 鸿蒙短信 → Mac 同步")
        emit("========================================")

        // 通知身份：先问一次授权，之后新短信就能以 App 的名义弹出来
        Notifier.shared.prepare()

        guard let store = Store(path: DB_PATH) else { exit(1) }

        if reset {
            store.exec("DELETE FROM seen_handle; DELETE FROM message; DELETE FROM sync_state;")
            emit("已清空本地记录")
        }

        let target = args.count > 0 ? args[0] : DEVICE_DEFAULT
        var channelID: BluetoothRFCOMMChannelID = CHANNEL_DEFAULT
        if args.count > 1, let v = UInt8(args[1]) { channelID = v }

        guard let device = IOBluetoothDevice(addressString: target) else {
            emit("✗ 设备对象构造失败：\(target)")
            exit(1)
        }

        let bootstrapped = store.state("bootstrap_at") != nil
        emit("设备     : \(device.name ?? "?")")
        emit("通道     : \(channelID)")
        emit("数据库   : \(DB_PATH)")
        emit("轮询间隔 : \(Int(pollInterval)) 秒")
        emit("每轮条数 : \(listingLimit) 条")
        emit("模式     : \(once ? "只跑一轮" : "持续轮询")")
        emit("事件订阅 : \(mnsEnabled ? "开启（Mac 作 MNS 服务端）" : "关闭")")
        emit("基线     : \(bootstrapped ? "已建立，只处理新短信" : "未建立，本轮只记录不通知")")
        emit("")

        let sync = Sync(store: store, device: device, channelID: channelID, once: once)
        sync.baseline = !bootstrapped

        if mnsEnabled {
            emit("启动 MNS 服务端：发布 SDP 记录并监听")
            let mns = MnsServer()
            mns.ignoreChannelID = channelID
            mns.start { detail in
                sync.pollNow(detail)
            }
            emit("")
        }

        sync.start()

        // 心跳：每 10 秒报一次状态，卡住的时候也能从日志里看出来
        if !once {
            let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                sync.heartbeat()
            }
            RunLoop.current.add(timer, forMode: .default)
        }

        CFRunLoopRun()

        emit("")
        emit("=== 结束 ===")
        emit("已见 handle \(store.count("seen_handle")) 条，本地短信 \(store.count("message")) 条")
    }
}
