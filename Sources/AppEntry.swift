import SwiftUI
import AppKit
import CoreGraphics

@main
struct SystemWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - 共享状态

enum WidgetTheme: String, CaseIterable {
    case dark
    case light

    var displayName: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .dark: return Color(red: 0.11, green: 0.11, blue: 0.13)   // #1C1C1E
        case .light: return Color(red: 0.95, green: 0.95, blue: 0.97)  // #F2F2F7
        }
    }

    var primaryText: Color {
        self == .dark ? .white : .black
    }

    var secondaryText: Color {
        self == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.55)
    }

    var borderColor: Color {
        self == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.10)
    }
}

final class AppState: ObservableObject {
    @Published var editMode = false
    @Published var alwaysOnTop = false
    @Published var theme: WidgetTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "SystemWidgetTheme")
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "SystemWidgetTheme") ?? ""
        // 兼容旧的 纯黑/纯白 设置
        if saved == "white" {
            theme = .light
        } else {
            theme = WidgetTheme(rawValue: saved) ?? .dark
        }
    }
}

// MARK: - 数据模型（每秒刷新）

final class SystemStatsModel: ObservableObject {
    @Published var stats = SystemStats()
    @Published var cpuHistory: [Double] = []
    private var timer: Timer?

    init() {
        stats = SystemStatsSampler.sample()
        cpuHistory.append(stats.cpuPercent)
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats = SystemStatsSampler.sample()
            self.cpuHistory.append(self.stats.cpuPercent)
            if self.cpuHistory.count > 46 {
                self.cpuHistory.removeFirst(self.cpuHistory.count - 46)
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }
}

// MARK: - 应用代理：菜单栏 + 桌面面板

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private let model = SystemStatsModel()
    private let state = AppState()
    private let frameKey = "SystemWidgetPanelFrame"

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.systemwidget.plist")
    }

    private var mainScreen: NSScreen? { NSScreen.screens.first }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        // 调试/测试用：启动即置顶，便于确认渲染
        if CommandLine.arguments.contains("--always-on-top") {
            state.alwaysOnTop = true
        }
        setupStatusItem()
        setupPanel()
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                                   accessibilityDescription: "系统状态小组件")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let editItem = NSMenuItem(title: "移动位置（编辑模式）",
                                  action: #selector(toggleEditMode(_:)),
                                  keyEquivalent: "")
        editItem.target = self
        editItem.state = state.editMode ? .on : .off

        let topItem = NSMenuItem(title: "始终置顶",
                                 action: #selector(toggleAlwaysOnTop(_:)),
                                 keyEquivalent: "")
        topItem.target = self
        topItem.state = state.alwaysOnTop ? .on : .off

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self

        let themeItem = NSMenuItem(title: "外观预设", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for theme in WidgetTheme.allCases {
            let themeChoice = NSMenuItem(title: theme.displayName,
                                         action: #selector(selectTheme(_:)),
                                         keyEquivalent: "")
            themeChoice.target = self
            themeChoice.representedObject = theme.rawValue
            themeChoice.state = state.theme == theme ? .on : .off
            themeMenu.addItem(themeChoice)
        }
        themeItem.submenu = themeMenu

        let launchItem = NSMenuItem(title: "开机自启",
                                    action: #selector(toggleLaunchAtLogin(_:)),
                                    keyEquivalent: "")
        launchItem.target = self
        launchItem.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off

        menu.addItem(editItem)
        menu.addItem(topItem)
        menu.addItem(.separator())
        menu.addItem(themeItem)
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    // MARK: 桌面面板

    private func setupPanel() {
        let contentSize = NSSize(width: 300, height: 286)

        let hosting = NSHostingView(rootView: ContentView(model: model, state: state))
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: contentSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.contentView = hosting
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.appearance = NSAppearance(named: .aqua)
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.delegate = self
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

        panel = p

        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            let savedRect = NSRectFromString(saved)
            if !savedRect.isNull, let screen = mainScreen {
                let vf = screen.visibleFrame
                var frame = p.frame
                frame.origin = savedRect.origin
                // 卡片尺寸变化后，保证整个卡片仍然落在屏幕内
                if frame.minY < vf.minY { frame.origin.y = vf.minY }
                if frame.maxY > vf.maxY { frame.origin.y = vf.maxY - frame.height }
                if frame.minX < vf.minX { frame.origin.x = vf.minX }
                if frame.maxX > vf.maxX { frame.origin.x = vf.maxX - frame.width }
                if vf.intersects(frame) {
                    p.setFrame(frame, display: true)
                } else {
                    placeAtDefault(p)
                }
            } else {
                placeAtDefault(p)
            }
        } else {
            placeAtDefault(p)
        }

        applyPanelMode()
        p.orderFrontRegardless()
    }

    private func placeAtDefault(_ p: NSPanel) {
        guard let screen = mainScreen else { return }
        let vf = screen.visibleFrame
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 20,
                                 y: vf.maxY - size.height - 20))
    }

    /// 锁定状态：桌面层级 + 点击穿透；编辑/置顶：浮动层级
    private func applyPanelMode() {
        guard let p = panel else { return }
        let desktopIconLevel = CGWindowLevelForKey(.desktopIconWindow)
        // 比桌面图标高一档：文件夹不会盖住小组件，但普通窗口仍然在它上面
        let aboveIconsLevel = NSWindow.Level(rawValue: Int(desktopIconLevel) + 1)
        p.level = (state.editMode || state.alwaysOnTop) ? .floating : aboveIconsLevel
        p.ignoresMouseEvents = !state.editMode
        if state.editMode || state.alwaysOnTop {
            p.orderFrontRegardless()
        }
    }

    // MARK: 菜单动作

    @objc private func toggleEditMode(_ sender: NSMenuItem) {
        state.editMode.toggle()
        sender.state = state.editMode ? .on : .off
        applyPanelMode()
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        state.alwaysOnTop.toggle()
        sender.state = state.alwaysOnTop ? .on : .off
        applyPanelMode()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = WidgetTheme(rawValue: raw)
        else { return }
        state.theme = theme
        if let submenu = statusItem?.menu?.item(withTitle: "外观预设")?.submenu {
            for item in submenu.items {
                item.state = (item.representedObject as? String) == raw ? .on : .off
            }
        }
    }

    // MARK: 开机自启

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            removeLaunchAgent()
        } else {
            installLaunchAgent()
        }
        sender.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
    }

    private func installLaunchAgent() {
        do {
            let fm = FileManager.default
            let directory = launchAgentURL.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)

            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": "local.systemwidget",
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml,
                                                          options: 0)
            try data.write(to: launchAgentURL, options: .atomic)

            let uid = getuid()
            // 先移除旧注册，再注册新的，保证路径是最新应用的位置
            runLaunchctl(["bootout", "gui/\(uid)", launchAgentURL.path])
            runLaunchctl(["bootstrap", "gui/\(uid)", launchAgentURL.path])
        } catch {
            NSLog("开机自启安装失败: \(error)")
        }
    }

    private func removeLaunchAgent() {
        let uid = getuid()
        runLaunchctl(["bootout", "gui/\(uid)", launchAgentURL.path])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let p = panel else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: frameKey)
    }
}

// MARK: - 界面

struct ContentView: View {
    @ObservedObject var model: SystemStatsModel
    @ObservedObject var state: AppState

    private var stats: SystemStats { model.stats }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 4)
            row(title: "CPU", symbol: "cpu", percent: stats.cpuPercent,
                caption: String(format: "%.0f%%", stats.cpuPercent * 100),
                color: .orange)
            Spacer(minLength: 4)
            cpuSparkline
            Spacer(minLength: 4)
            row(title: "内存", symbol: "memorychip", percent: stats.memoryPercent,
                caption: String(format: "%.1f / %.1f GB", stats.memoryUsedGB, stats.memoryTotalGB),
                color: .blue)
            Spacer(minLength: 4)
            row(title: "存储", symbol: "internaldrive", percent: stats.diskPercent,
                caption: String(format: "%.1f / %.1f GB", stats.diskUsedGB, stats.diskTotalGB),
                color: .green)
            Spacer(minLength: 4)
            batterySection
            Spacer(minLength: 4)
            networkSection
            Spacer(minLength: 4)
            footer
        }
        .padding(14)
        .frame(width: 300, height: 286)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(state.theme.backgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(state.editMode ? Color.accentColor : state.theme.borderColor,
                              lineWidth: state.editMode ? 1.5 : 0.8)
        }
        .overlay(alignment: .top) {
            if state.editMode {
                Text("编辑模式：按住拖动，菜单栏锁定")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .padding(.top, 8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            Text("系统状态")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.theme.primaryText)
            Spacer(minLength: 4)
            Text("\(stats.cpuBrand) · \(stats.coreCount)核")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(state.theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var batterySection: some View {
        Group {
            if stats.hasBattery, let level = stats.batteryPercent {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: batterySymbol(level: level, charging: stats.batteryCharging))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.green)
                            .frame(width: 18)
                        Text("电池")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(state.theme.secondaryText)
                        Spacer(minLength: 8)
                        ProgressView(value: level)
                            .progressViewStyle(.linear)
                            .tint(.green)
                            .frame(width: 56)
                        Text(String(format: "%.0f%%", level * 100))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(state.theme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(width: 100, alignment: .trailing)
                    }
                    if stats.batteryCharging || stats.batteryPlugged || stats.batteryMinutesRemaining != nil {
                        HStack(spacing: 4) {
                            Image(systemName: batteryStatusSymbol)
                                .font(.system(size: 9, weight: .semibold))
                            Text(batteryStatusText)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.green.opacity(0.9))
                        .padding(.leading, 26)
                    }
                }
            } else if stats.hasBattery {
                row(title: "电池", symbol: "battery.0percent", percent: 0,
                    caption: "—", color: .green)
            } else {
                row(title: "电池", symbol: "powerplug", percent: 0,
                    caption: "无电池", color: .secondary)
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: networkSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 18)
                Text("网络")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state.theme.secondaryText)
                Spacer(minLength: 8)
                Text("↓ \(formatSpeed(stats.networkDownBps))   ↑ \(formatSpeed(stats.networkUpBps))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(state.theme.primaryText)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(networkStatusText)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(state.theme.secondaryText)
            .padding(.leading, 26)
        }
    }

    private var networkSymbol: String {
        stats.ipAddress.isEmpty ? "wifi.slash" : "wifi"
    }

    private var networkStatusText: String {
        if !stats.networkName.isEmpty {
            return "\(stats.networkName) · \(stats.ipAddress)"
        }
        if !stats.ipAddress.isEmpty {
            return "IP \(stats.ipAddress)"
        }
        return "未连接网络"
    }

    private func formatSpeed(_ bps: UInt64) -> String {
        let value = Double(bps)
        if value >= 1_048_576 {
            return String(format: "%.1f MB/s", value / 1_048_576)
        }
        if value >= 1024 {
            return String(format: "%.0f KB/s", value / 1024)
        }
        return "\(bps) B/s"
    }

    private var cpuSparkline: some View {
        Canvas { context, size in
            let history = model.cpuHistory
            guard history.count > 1, size.width > 0, size.height > 0 else { return }
            let slots = 46
            let step = size.width / CGFloat(slots - 1)
            let points: [CGPoint] = history.enumerated().map { index, value in
                let x = step * CGFloat(index)
                let y = size.height - CGFloat(min(1, max(0, value))) * (size.height - 6) - 3
                return CGPoint(x: x, y: y)
            }
            guard let first = points.first, let last = points.last else { return }

            var area = Path()
            area.move(to: CGPoint(x: first.x, y: size.height))
            for p in points { area.addLine(to: p) }
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [Color.orange.opacity(0.38), Color.orange.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            var line = Path()
            line.move(to: first)
            for p in points.dropFirst() { line.addLine(to: p) }
            context.stroke(line, with: .color(Color.orange.opacity(0.9)), lineWidth: 1.5)
        }
        .frame(height: 36)
    }

    private var footer: some View {
        let load = SystemStatsSampler.loadAverage()
        return HStack(spacing: 8) {
            Text(String(format: "负载 %.1f · %.1f · %.1f", load.0, load.1, load.2))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(state.theme.secondaryText)
                .help("过去 1、5、15 分钟的系统负载均值")
            Spacer(minLength: 4)
            Text(SystemStatsSampler.uptimeText())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(state.theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var batteryStatusSymbol: String {
        if stats.batteryCharging { return "bolt.fill" }
        if stats.batteryPlugged { return "powerplug.fill" }
        return "timer"
    }

    private var batteryStatusText: String {
        if stats.batteryCharging { return "正在充电" }
        if stats.batteryPlugged { return "电源供电" }
        if let m = stats.batteryMinutesRemaining {
            if m >= 60 { return "剩余约 \(m / 60)小时\(m % 60)分" }
            return "剩余约 \(m)分钟"
        }
        return "电池供电"
    }

    private func row(title: String, symbol: String, percent: Double,
                     caption: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(state.theme.secondaryText)
            Spacer(minLength: 8)
            ProgressView(value: percent)
                .progressViewStyle(.linear)
                .tint(color)
                .frame(width: 56)
            Text(caption)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(state.theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 100, alignment: .trailing)
        }
    }

    private func batterySymbol(level: Double, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 0..<0.25: return "battery.25percent"
        case 0.25..<0.5: return "battery.50percent"
        case 0.5..<0.75: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

}
