import SwiftUI
import AppKit

/// 消息记录窗口的开合。
///
/// 菜单栏应用登录时不弹窗：窗口按需创建，之后复用同一个。
final class MessageWindowController {
    static let shared = MessageWindowController()

    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: MessageWindowView().environmentObject(AppModel.shared))
        let w = NSWindow(contentViewController: host)
        w.title = "消息记录"
        w.setContentSize(NSSize(width: 560, height: 520))
        w.minSize = NSSize(width: 420, height: 360)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("HSMessageWindow")
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 面板是系统托管的浮层，开完新窗口把它收掉，免得压在新窗口上面。
/// 只对浮层动手，认不出就什么也不做。
func dismissMenuBarPanel() {
    guard let w = NSApp.keyWindow, w is NSPanel else { return }
    w.orderOut(nil)
}

/// 消息记录窗口：只读浏览 + 关键字搜索 + 时间范围筛选 + 验证码一键复制。
struct MessageWindowView: View {
    @EnvironmentObject private var model: AppModel

    @State private var keyword = ""
    @State private var span: Span = .all
    @State private var items: [StoredMessage] = []

    /// 时间范围筛选
    enum Span: String, CaseIterable, Identifiable {
        case all = "全部"
        case today = "今天"
        case week = "近 7 天"

        var id: String { rawValue }

        var since: Date? {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            switch self {
            case .all: return nil
            case .today: return today
            case .week: return cal.date(byAdding: .day, value: -6, to: today)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HairLine()
            if items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 420, idealWidth: 560, maxWidth: 720,
               minHeight: 360, idealHeight: 520)
        .background(Color.hsCanvas)
        .task(id: reloadKey) { reload() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: HS.s3) {
            HStack(spacing: HS.s2) {
                Text("消息记录")
                    .font(.hsWindowTitle)
                    .foregroundStyle(Color.hsInk)
                Spacer(minLength: HS.s2)
                Text("共 \(items.count) 条")
                    .font(.hsCaption)
                    .monospacedDigit()
                    .foregroundStyle(Color.hsInk3)
            }

            HStack(spacing: HS.s3) {
                searchField
                HStack(spacing: HS.s1) {
                    ForEach(Span.allCases) { s in
                        spanChip(s)
                    }
                }
            }
        }
        .padding(.horizontal, HS.s4)
        .padding(.top, HS.s5)
        .padding(.bottom, HS.s3)
        .background(Color.hsChrome)
    }

    private var searchField: some View {
        HStack(spacing: HS.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.hsInk3)
            TextField("搜索发件人或内容", text: $keyword)
                .textFieldStyle(.plain)
                .font(.hsBody)
                .foregroundStyle(Color.hsInk)
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hsInk3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HS.s3)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: HS.rControl).fill(Color.hsCanvas))
        .overlay(
            RoundedRectangle(cornerRadius: HS.rControl)
                .strokeBorder(Color.hsLine, lineWidth: 1)
        )
        .frame(maxWidth: 280)
    }

    private func spanChip(_ s: Span) -> some View {
        let active = span == s
        return Button {
            span = s
        } label: {
            Text(s.rawValue)
                .font(.hsCaption)
                .foregroundStyle(active ? Color.hsAccent : Color.hsInk2)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: HS.rControl)
                        .fill(active ? Color.hsAccentSoft : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HS.rControl)
                        .strokeBorder(active ? Color.clear : Color.hsLine, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 列表

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.day) { g in
                    Section {
                        ForEach(g.items) { m in
                            MessageRow(message: m)
                            HairLine()
                        }
                    } header: {
                        dayHeader(g.day)
                    }
                }
            }
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        HStack(spacing: HS.s2) {
            Text(MessageWindowView.dayLabel(day))
                .font(.hsSectionTitle)
                .foregroundStyle(Color.hsInk)
            Spacer(minLength: HS.s2)
        }
        .padding(.horizontal, HS.s4)
        .padding(.vertical, HS.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hsChrome)
        .overlay(alignment: .bottom) { HairLine() }
    }

    private var emptyState: some View {
        VStack(spacing: HS.s3) {
            LinkMark(linked: false, color: .hsLineStrong, width: 112)
            Text(keyword.isEmpty ? "还没有短信" : "没有匹配的短信")
                .font(.hsSectionTitle)
                .foregroundStyle(Color.hsInk)
            Text(keyword.isEmpty
                 ? "在菜单栏面板里打开「短信监听」，手机收到短信就会同步到这里。"
                 : "换个关键字，或者把时间范围放宽一些。")
                .font(.hsBody)
                .foregroundStyle(Color.hsInk3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(HS.s6)
    }

    // MARK: 数据

    /// 关键字、范围、库里总数，任一项变了就重新查
    private var reloadKey: String {
        "\(keyword)\u{1}\(span.rawValue)\u{1}\(model.totalCount)"
    }

    private func reload() {
        items = model.store.searchMessages(keyword: keyword, since: span.since)
    }

    private var groups: [(day: Date, items: [StoredMessage])] {
        let cal = Calendar.current
        var out: [(day: Date, items: [StoredMessage])] = []
        for m in items {
            let d = cal.startOfDay(for: m.sentAt)
            if let last = out.last, last.day == d {
                out[out.count - 1].items.append(m)
            } else {
                out.append((d, [m]))
            }
        }
        return out
    }

    static func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 EEEE" : "yyyy年M月d日"
        return f.string(from: d)
    }
}

// MARK: - 行

/// 列表行：左边发件人固定 108px，中间正文，右边时间。
struct MessageRow: View {
    let message: StoredMessage

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: HS.s3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(message.displayName)
                    .font(.hsBodyStrong)
                    .foregroundStyle(Color.hsInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !message.peerName.isEmpty, !message.peerNumber.isEmpty {
                    Text(message.peerNumber)
                        .font(.hsCaption)
                        .monospacedDigit()
                        .foregroundStyle(Color.hsInk3)
                        .lineLimit(1)
                }
            }
            .frame(width: 108, alignment: .leading)

            VStack(alignment: .leading, spacing: HS.s2) {
                Text(message.body)
                    .font(.hsBody)
                    .foregroundStyle(Color.hsInk2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = message.verificationCode {
                    CopyChip(code: code)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(MessageRow.clock(message.sentAt))
                .font(.hsCaption)
                .monospacedDigit()
                .foregroundStyle(Color.hsInk3)
        }
        .padding(.horizontal, HS.s4)
        .padding(.vertical, HS.s3)
        .background(hovered ? Color.hsHover : Color.clear)
        .onHover { hovered = $0 }
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// 验证码：等宽数字 + 复制按钮，复制后 1.2 秒内报「已复制」。
struct CopyChip: View {
    let code: String

    @State private var copied = false
    @State private var reset: DispatchWorkItem?

    var body: some View {
        HStack(spacing: HS.s2) {
            Text(code)
                .font(.hsMono)
                .foregroundStyle(Color.hsAccent)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(code, forType: .string)
                copied = true
                reset?.cancel()
                let w = DispatchWorkItem { copied = false }
                reset = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
            } label: {
                Text(copied ? "已复制" : "复制")
                    .font(.hsCaption)
                    .foregroundStyle(Color.hsAccent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: HS.rControl).fill(Color.hsAccentSoft))
    }
}
