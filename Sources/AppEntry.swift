import SwiftUI
import AppKit

@main
struct SystemWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
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

struct WidgetPalette {
    let isDark: Bool

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
}

@MainActor
final class AppState: ObservableObject {
    @Published var editMode = false
    var alwaysOnTop = false
    @Published var theme: WidgetTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "SystemWidgetTheme")
            onThemeChange?(theme)
        }
    }

    private static let transparencyKey = "SystemWidgetGlassTransparency"
    static let defaultTransparency = 0.40

    private(set) var transparency: Double

    var onThemeChange: ((WidgetTheme) -> Void)?
    var onTransparencyChange: ((Double) -> Void)?

    func setTransparency(_ value: Double) {
        guard value.isFinite else { return }
        transparency = min(1, max(0, value))
        UserDefaults.standard.set(transparency, forKey: Self.transparencyKey)
        onTransparencyChange?(transparency)
    }

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "SystemWidgetTheme") ?? ""
        switch saved {
        case "white":
            // 兼容更早版本的 纯白 设置
            theme = .light
        case "dark", "light":
            theme = WidgetTheme(rawValue: saved) ?? .auto
        default:
            theme = .auto
        }

        let savedTransparency = (defaults.object(forKey: Self.transparencyKey)
            ?? defaults.object(forKey: "SystemWidgetGlassTransparencyV2")) as? Double
        if let savedTransparency, savedTransparency.isFinite {
            transparency = min(1, max(0, savedTransparency))
        } else {
            transparency = Self.defaultTransparency
        }
    }
}

// MARK: - 数据模型

@MainActor
final class SystemStatsModel: ObservableObject {
    struct Snapshot {
        var stats = SystemStats()
        var cpuHistory: [Double] = []
    }

    @Published private(set) var snapshot = Snapshot()
    private var samplingTask: Task<Void, Never>?

    init() {
        samplingTask = Task { [weak self] in
            let sampler = SystemStatsSampler()
            while !Task.isCancelled {
                let stats = await sampler.sample()
                guard !Task.isCancelled, self != nil else { return }
                self?.publish(stats)
                // 采样与 UI 分离，菜单跟踪和窗口拖动时也不会阻塞主线程。
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func publish(_ stats: SystemStats) {
        var history = snapshot.cpuHistory
        history.append(stats.cpuPercent)
        if history.count > 46 { history.removeFirst() }
        snapshot = Snapshot(stats: stats, cpuHistory: history)
    }

    deinit {
        samplingTask?.cancel()
    }
}

// MARK: - 应用代理：菜单栏 + 桌面面板

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var statusItemRetryCount = 0
    private var panel: WidgetPanel?
    private let model = SystemStatsModel()
    private let state = AppState()

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.systemwidget.plist")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = state.theme.appearance
        // 调试/测试用：启动即置顶，便于确认渲染
        if CommandLine.arguments.contains("--always-on-top") {
            state.alwaysOnTop = true
        }
        state.onThemeChange = { [weak self] theme in
            // 面板与菜单一起跟随，避免卡片变深色而状态栏菜单仍是浅色
            NSApp.appearance = theme.appearance
            self?.panel?.appearance = theme.appearance
        }
        state.onTransparencyChange = { [weak self] value in
            self?.panel?.setTransparency(value)
        }
        setupStatusItem()
        setupPanel()

        // 调试用：启动后自动展开菜单，便于截图检查滑块布局
        if CommandLine.arguments.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let item = self?.statusItem,
                      let menu = item.menu,
                      let button = item.button else { return }
                let anchor = NSPoint(x: 0, y: -2)
                menu.popUp(positioning: nil, at: anchor, in: button)
            }
        }
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

        // 透明度滑块：菜单里放一个自定义视图，拖动时实时改玻璃染色
        let opacityView = TransparencySliderView(transparency: state.transparency) { [weak self] value in
            self?.state.setTransparency(value)
        }
        opacityView.frame = NSRect(origin: .zero, size: TransparencySliderView.preferredSize)
        let opacityItem = NSMenuItem()
        opacityItem.view = opacityView

        menu.addItem(editItem)
        menu.addItem(topItem)
        menu.addItem(.separator())
        menu.addItem(themeItem)
        menu.addItem(opacityItem)
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        item.menu = menu
        // 菜单按最长标题自适应宽度，这里给个下限，保证滑块不会被压得太窄
        menu.minimumWidth = 216
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
        let widget = WidgetPanel(content: ContentView(model: model, state: state),
                                 transparency: state.transparency)
        widget.appearance = state.theme.appearance
        widget.delegate = self
        panel = widget

        widget.restorePosition()
        applyPanelMode()
        widget.orderFrontRegardless()
    }

    private func applyPanelMode() {
        panel?.setMode(isEditing: state.editMode, alwaysOnTop: state.alwaysOnTop)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        panel?.keepCardOnScreen()
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
        guard let panel, notification.object as? WidgetPanel === panel else { return }
        panel.rememberDraggedPosition()
    }
}

// MARK: - 菜单里的透明度滑块

/// 菜单项自定义视图：一行标题 + 实时百分比 + 滑块。
/// 拖动时连续回调，卡片立刻换染色强度，不用关菜单就能看到效果。
/// 子视图用 Auto Layout 约束，菜单按内容缩放宽度时不会把滑块挤出去。
final class TransparencySliderView: NSView {
    static let preferredSize = NSSize(width: 200, height: 48)

    private let titleLabel = NSTextField(labelWithString: "玻璃透明度")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let onChange: (Double) -> Void

    init(transparency: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        build(transparency: transparency)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(transparency: Double) {
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = min(100, max(0, transparency * 100))
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                                constant: 8),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            slider.heightAnchor.constraint(equalToConstant: 16),
        ])

        updateValueLabel()
    }

    private func updateValueLabel() {
        valueLabel.stringValue = "\(Int(slider.doubleValue.rounded()))%"
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        updateValueLabel()
        onChange(sender.doubleValue / 100)
    }
}

// MARK: - 界面

struct ContentView: View {
    @ObservedObject var model: SystemStatsModel
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var stats: SystemStats { model.snapshot.stats }
    private var palette: WidgetPalette {
        state.theme.palette(for: colorScheme)
    }

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
        .overlay {
            if state.editMode {
                RoundedRectangle(cornerRadius: WidgetMetrics.cardRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .top) {
            if state.editMode { editHint }
        }
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
            let history = model.snapshot.cpuHistory
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
        let load = stats.loadAverage
        return HStack(spacing: 8) {
            Text(String(format: "负载 %.1f · %.1f · %.1f", load.0, load.1, load.2))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryText)
                .help("过去 1、5、15 分钟的系统负载均值")
            Spacer(minLength: 4)
            Text(stats.uptimeText)
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
