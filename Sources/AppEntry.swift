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

// MARK: - 尺寸

enum WidgetMetrics {
    /// 卡片可见尺寸。内容与升级前保持一致（300 × 286）。
    static let cardSize = CGSize(width: 300, height: 286)
    /// 卡片外留白，用来容纳投影，避免被窗口边缘裁切
    static let shadowInset: CGFloat = 18
    /// 窗口整体尺寸 = 卡片 + 四周留白
    static var windowSize: CGSize {
        CGSize(width: cardSize.width + shadowInset * 2,
               height: cardSize.height + shadowInset * 2)
    }
    /// 圆角半径，对齐 macOS 27 收紧后的窗口圆角
    static let cardRadius: CGFloat = 24
}

// MARK: - 外观

enum WidgetTheme: String, CaseIterable {
    case auto
    case dark
    case light

    var displayName: String {
        switch self {
        case .auto: return "跟随系统"
        case .dark: return "深色玻璃"
        case .light: return "浅色玻璃"
        }
    }

    /// 自动档交给系统决定深浅；其余两档锁定窗口外观，玻璃与文字同步切换
    var appearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }

    func palette(for scheme: ColorScheme) -> WidgetPalette {
        let isDark: Bool
        switch self {
        case .auto: isDark = (scheme == .dark)
        case .dark: isDark = true
        case .light: isDark = false
        }
        return WidgetPalette(isDark: isDark)
    }
}

/// 液态玻璃用色。玻璃本身负责折射，这里只补充「染色 + 文字 + 边缘」三组颜色，
/// 保证任何壁纸上都读得清。
struct WidgetPalette {
    let isDark: Bool

    /// 玻璃染色。macOS 27 的液态玻璃可从未着色到完全染色，
    /// 桌面小组件需要一定染色才能在复杂壁纸前保持可读性。
    var glassTint: Color {
        isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.46)
    }

    var primaryText: Color {
        isDark ? Color.white.opacity(0.97) : Color.black.opacity(0.90)
    }

    var secondaryText: Color {
        isDark ? Color.white.opacity(0.66) : Color.black.opacity(0.56)
    }

    /// 进度条底槽
    var track: Color {
        isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }

    /// 边缘：顶部高光
    var rimHighlight: Color {
        isDark ? Color.white.opacity(0.55) : Color.white.opacity(0.90)
    }

    /// 边缘：底部暗边，用来和背景分离
    var rimShadow: Color {
        isDark ? Color.black.opacity(0.34) : Color.black.opacity(0.14)
    }

    /// 顶部的柔和内反光，模拟玻璃表面的镜面感
    var topSheen: Color {
        isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.26)
    }

    var shadow: Color {
        isDark ? Color.black.opacity(0.45) : Color.black.opacity(0.20)
    }
}

final class AppState: ObservableObject {
    @Published var editMode = false
    @Published var alwaysOnTop = false
    @Published var theme: WidgetTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "SystemWidgetTheme")
            onThemeChange?(theme)
        }
    }

    /// 主题变化时同步窗口外观（玻璃材质跟着系统深浅色走）
    var onThemeChange: ((WidgetTheme) -> Void)?

    init() {
        let saved = UserDefaults.standard.string(forKey: "SystemWidgetTheme") ?? ""
        switch saved {
        case "white":
            // 兼容更早版本的 纯白 设置
            theme = .light
        case "dark", "light":
            theme = WidgetTheme(rawValue: saved) ?? .auto
        default:
            theme = .auto
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
    private var statusItemRetryCount = 0
    private var panel: NSPanel?
    private let model = SystemStatsModel()
    private let state = AppState()
    private let frameKey = "SystemWidgetPanelFrameV2"
    private let legacyFrameKey = "SystemWidgetPanelFrame"

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.systemwidget.plist")
    }

    private var mainScreen: NSScreen? { NSScreen.screens.first }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = state.theme.appearance
        // 调试/测试用：启动即置顶，便于确认渲染
        if CommandLine.arguments.contains("--always-on-top") {
            state.alwaysOnTop = true
        }
        state.onThemeChange = { [weak self] theme in
            self?.panel?.appearance = theme.appearance
        }
        setupStatusItem()
        setupPanel()
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        // 重试场景：先移除可能残留的旧状态项
        if let old = statusItem {
            NSStatusBar.system.removeStatusItem(old)
            statusItem = nil
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "SystemWidgetStatusItem"
        item.isVisible = true

        if let button = item.button {
            button.image = Self.makeStatusBarIcon()
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "SystemWidget"
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

        // 开机自启等场景下，启动瞬间系统菜单栏可能尚未就绪，按钮可能为 nil。
        // 稍后重试，确保仪表盘图标一定出现、菜单可用。
        if item.button == nil, statusItemRetryCount < 10 {
            statusItemRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.setupStatusItem()
            }
        }
    }

    /// 生成菜单栏图标；SF Symbol 不可用时回退到系统内置符号，最后用绘制兜底，
    /// 保证任何系统环境下都有可见图标。
    private static func makeStatusBarIcon() -> NSImage {
        if let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                                accessibilityDescription: "SystemWidget") {
            return symbol
        }
        if let symbol = NSImage(systemSymbolName: "gauge",
                                accessibilityDescription: "SystemWidget") {
            return symbol
        }
        return Self.drawFallbackIcon()
    }

    private static func drawFallbackIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let circleRect = NSRect(x: 1.5, y: 1.5, width: 15, height: 15)
        let circle = NSBezierPath(ovalIn: circleRect)
        circle.lineWidth = 2
        NSColor.black.setStroke()
        circle.stroke()

        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: 9, y: 9))
        needle.line(to: NSPoint(x: 14, y: 4.5))
        needle.lineWidth = 2
        needle.lineCapStyle = .round
        needle.stroke()

        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 7.5, y: 7.5, width: 3, height: 3)).fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: 桌面面板

    private func setupPanel() {
        let windowSize = WidgetMetrics.windowSize

        let hosting = NSHostingView(rootView: ContentView(model: model, state: state))
        hosting.frame = NSRect(origin: .zero, size: windowSize)
        hosting.autoresizingMask = [.width, .height]

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: windowSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.contentView = hosting
        p.isOpaque = false
        p.backgroundColor = .clear
        // 投影由卡片自己绘制（更贴合玻璃的柔和光晕），窗口层不再叠一层系统阴影
        p.hasShadow = false
        p.appearance = state.theme.appearance
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.delegate = self
        // stationary：不受 Mission Control /「点击墙纸显示桌面」影响，点击桌面空白处时
        // 其他窗口被收起，小组件仍留在桌面，方便随时查看系统信息。
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        panel = p

        restoreFrame(for: p)
        applyPanelMode()
        p.orderFrontRegardless()
    }

    /// 恢复上次位置。卡片现在带了一圈投影留白，旧版本保存的是「卡片本身」的窗口位置，
    /// 这里做一次换算，让升级后卡片在屏幕上原地不动。
    private func restoreFrame(for p: NSPanel) {
        let defaults = UserDefaults.standard
        var cardOrigin: NSPoint?

        if let saved = defaults.string(forKey: frameKey) {
            let rect = NSRectFromString(saved)
            if !rect.isNull { cardOrigin = NSPoint(x: rect.minX + WidgetMetrics.shadowInset,
                                                  y: rect.minY + WidgetMetrics.shadowInset) }
        } else if let legacy = defaults.string(forKey: legacyFrameKey) {
            let rect = NSRectFromString(legacy)
            if !rect.isNull { cardOrigin = rect.origin }
        }

        guard let origin = cardOrigin, let screen = mainScreen else {
            placeAtDefault(p)
            return
        }

        let visible = screen.visibleFrame
        var frame = p.frame
        frame.origin = NSPoint(x: origin.x - WidgetMetrics.shadowInset,
                               y: origin.y - WidgetMetrics.shadowInset)

        // 卡片尺寸或屏幕变化后，保证整张卡片仍然落在屏幕内
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }

        if visible.intersects(frame) {
            p.setFrame(frame, display: true)
        } else {
            placeAtDefault(p)
        }
    }

    private func placeAtDefault(_ p: NSPanel) {
        guard let screen = mainScreen else { return }
        let visible = screen.visibleFrame
        let card = WidgetMetrics.cardSize
        let inset = WidgetMetrics.shadowInset
        p.setFrameOrigin(NSPoint(x: visible.maxX - card.width - 20 - inset,
                                 y: visible.maxY - card.height - 20 - inset))
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
    @Environment(\.colorScheme) private var colorScheme

    private var stats: SystemStats { model.stats }
    private var palette: WidgetPalette { state.theme.palette(for: colorScheme) }

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
        .frame(width: WidgetMetrics.cardSize.width, height: WidgetMetrics.cardSize.height)
        .background {
            WidgetCardBackground(palette: palette, isEditing: state.editMode)
        }
        .overlay(alignment: .top) {
            if state.editMode {
                editHint
            }
        }
        .padding(WidgetMetrics.shadowInset)
        .frame(width: WidgetMetrics.windowSize.width, height: WidgetMetrics.windowSize.height)
    }

    private var editHint: some View {
        Text("编辑模式：按住拖动，菜单栏锁定")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.92), in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 4, y: 1)
            .padding(.top, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("系统状态")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Spacer(minLength: 4)
            Text("\(stats.cpuBrand) · \(stats.coreCount)核")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.secondaryText)
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
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.green)
                            .frame(width: 18)
                        Text("电池")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                        Spacer(minLength: 8)
                        MeterBar(value: level, tint: .green, track: palette.track)
                        Text(String(format: "%.0f%%", level * 100))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(width: 100, alignment: .trailing)
                    }
                    if stats.batteryCharging || stats.batteryPlugged
                        || stats.batteryMinutesRemaining != nil || stats.batteryPowerWatts != nil {
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
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)
                    .frame(width: 18)
                Text("网络")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 8)
                Text("↓ \(formatSpeed(stats.networkDownBps))   ↑ \(formatSpeed(stats.networkUpBps))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(networkStatusText)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(palette.secondaryText)
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
                    Gradient(colors: [Color.orange.opacity(0.40), Color.orange.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            var line = Path()
            line.move(to: first)
            for p in points.dropFirst() { line.addLine(to: p) }
            context.stroke(
                line,
                with: .linearGradient(
                    Gradient(colors: [Color.orange, Color.orange.opacity(0.75)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(height: 36)
        .padding(.horizontal, 3)
    }

    private var footer: some View {
        let load = SystemStatsSampler.loadAverage()
        return HStack(spacing: 8) {
            Text(String(format: "负载 %.1f · %.1f · %.1f", load.0, load.1, load.2))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryText)
                .help("过去 1、5、15 分钟的系统负载均值")
            Spacer(minLength: 4)
            Text(SystemStatsSampler.uptimeText())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
        }
    }

    private var batteryStatusSymbol: String {
        if stats.batteryCharging { return "bolt.fill" }
        if stats.batteryPlugged { return "powerplug.fill" }
        return "timer"
    }

    private var batteryStatusText: String {
        if stats.batteryCharging {
            if let w = stats.batteryPowerWatts, w != 0 {
                return "正在充电 · \(formatPower(w))"
            }
            return "正在充电"
        }
        if stats.batteryPlugged { return "电源供电" }
        if let m = stats.batteryMinutesRemaining {
            let remaining = m >= 60 ? "剩余约 \(m / 60)小时\(m % 60)分" : "剩余约 \(m)分钟"
            if let w = stats.batteryPowerWatts, w != 0 {
                return "\(remaining) · 放电 \(formatPower(w))"
            }
            return remaining
        }
        if let w = stats.batteryPowerWatts, w != 0 {
            return "电池供电 · 放电 \(formatPower(w))"
        }
        return "电池供电"
    }

    private func formatPower(_ watts: Double) -> String {
        let value = abs(watts)
        if value >= 100 {
            return String(format: "%.0f W", value)
        }
        return String(format: "%.1f W", value)
    }

    private func row(title: String, symbol: String, percent: Double,
                     caption: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            Spacer(minLength: 8)
            MeterBar(value: percent, tint: color, track: palette.track)
            Text(caption)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.primaryText)
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

// MARK: - 玻璃组件

/// 卡片底板：液态玻璃 + macOS 27 的边缘处理（更亮的镜面高光 + 更暗的描边），
/// 再补一层柔和投影把卡片从壁纸上托起来。
struct WidgetCardBackground: View {
    let palette: WidgetPalette
    let isEditing: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WidgetMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        glass
            .overlay { rim }
            .overlay {
                if isEditing {
                    shape.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                }
            }
            .shadow(color: palette.shadow, radius: 12, x: 0, y: 5)
    }

    @ViewBuilder
    private var glass: some View {
        if #available(macOS 26.0, *) {
            // 真正的液态玻璃：由系统负责背景折射、染色与无障碍适配
            Color.clear
                .glassEffect(.regular.tint(palette.glassTint), in: shape)
        } else {
            // macOS 26 以下：退回毛玻璃材质，视觉尽量接近
            shape
                .fill(.ultraThinMaterial)
                .overlay { shape.fill(palette.glassTint) }
        }
    }

    private var rim: some View {
        ZStack {
            // 单一描边：左上偏亮（镜面高光）、右下偏暗（macOS 27 的暗边），
            // 用角度渐变一次画完，避免出现「双线」轮廓
            shape.strokeBorder(
                LinearGradient(stops: [
                    .init(color: palette.rimHighlight, location: 0.0),
                    .init(color: Color.white.opacity(palette.isDark ? 0.14 : 0.38), location: 0.30),
                    .init(color: Color.white.opacity(0.02), location: 0.58),
                    .init(color: palette.rimShadow, location: 1.0),
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
            // 顶部内侧柔光，让玻璃有厚度
            shape
                .fill(
                    LinearGradient(colors: [palette.topSheen, .clear],
                                   startPoint: .top, endPoint: .center)
                )
                .blur(radius: 6)
                .clipShape(shape)
                .allowsHitTesting(false)
        }
    }
}

/// 胶囊进度条：玻璃风格下的细长仪表，数值变化时平滑过渡
struct MeterBar: View {
    let value: Double
    let tint: Color
    let track: Color

    private var clamped: Double { min(1, max(0, value)) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(track)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(colors: [tint.opacity(0.78), tint],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: max(4, width * CGFloat(clamped)))
                    .animation(.smooth(duration: 0.45), value: clamped)
            }
        }
        .frame(width: 56, height: 5)
    }
}
