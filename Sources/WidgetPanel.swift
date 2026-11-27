import AppKit
import CoreGraphics
import SwiftUI

enum WidgetMetrics {
    static let cardSize = CGSize(width: 300, height: 286)
    static let cardRadius: CGFloat = 24
    // 保留 v2 窗口的边距，现有位置无需再次迁移。
    static let shadowInset: CGFloat = 18
    static let windowSize = CGSize(width: cardSize.width + 2 * shadowInset,
                                   height: cardSize.height + 2 * shadowInset)
}

enum WidgetGlassMaterial: String, CaseIterable {
    case translucent
    case standard

    var displayName: String {
        switch self {
        case .translucent: return "通透玻璃"
        case .standard: return "标准玻璃"
        }
    }
}

final class WidgetPanel: NSPanel {
    private static let frameKey = "SystemWidgetPanelFrameV2"
    private static let legacyFrameKey = "SystemWidgetPanelFrame"
    private let surface: WidgetSurface
    private var hasStartedDrag = false

    init(content: ContentView, material: WidgetGlassMaterial, transparency: Double) {
        surface = WidgetSurface(content: content, glassMaterial: material, transparency: transparency)
        super.init(contentRect: NSRect(origin: .zero, size: WidgetMetrics.windowSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = surface
    }

    func setMode(isEditing: Bool, alwaysOnTop: Bool) {
        if !isEditing { hasStartedDrag = false }
        surface.isEditing = isEditing
        let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        level = (isEditing || alwaysOnTop) ? .floating : desktop
        ignoresMouseEvents = !isEditing
        if isEditing || alwaysOnTop {
            orderFrontRegardless()
        }
    }

    func setGlassMaterial(_ material: WidgetGlassMaterial) {
        surface.glassMaterial = material
    }

    func setTransparency(_ value: Double) {
        surface.transparency = value
    }

    func restorePosition() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.frameKey),
           let saved = Self.savedFrame(stored) {
            setFrameOrigin(saved.origin)
        } else if let stored = defaults.string(forKey: Self.legacyFrameKey),
                  let saved = Self.savedFrame(stored) {
            let inset = WidgetMetrics.shadowInset
            setFrameOrigin(NSPoint(x: saved.minX - inset, y: saved.minY - inset))
        } else if let visible = NSScreen.screens.first?.visibleFrame {
            let card = WidgetMetrics.cardSize
            let inset = WidgetMetrics.shadowInset
            setFrameOrigin(NSPoint(x: visible.maxX - card.width - 20 - inset,
                                   y: visible.maxY - card.height - 20 - inset))
        }
        keepCardOnScreen()
    }

    private static func savedFrame(_ value: String) -> NSRect? {
        let rect = NSRectFromString(value)
        guard !rect.isEmpty, rect.minX.isFinite, rect.minY.isFinite else { return nil }
        return rect
    }

    func keepCardOnScreen() {
        let card = frame.insetBy(dx: WidgetMetrics.shadowInset, dy: WidgetMetrics.shadowInset)
        let displays = NSScreen.screens.map(\.visibleFrame)
        guard let origin = Self.visibleCardOrigin(for: card, on: displays),
              origin != card.origin else { return }
        hasStartedDrag = false
        let inset = WidgetMetrics.shadowInset
        setFrameOrigin(NSPoint(x: origin.x - inset, y: origin.y - inset))
    }

    static func visibleCardOrigin(for card: NSRect, on displays: [NSRect]) -> NSPoint? {
        func overlap(with display: NSRect) -> CGFloat {
            let overlap = card.intersection(display)
            return overlap.width * overlap.height
        }

        guard let primary = displays.first else { return nil }
        let best = displays.max { overlap(with: $0) < overlap(with: $1) } ?? primary
        let visible = overlap(with: best) > 0 ? best : primary
        return NSPoint(x: min(max(card.minX, visible.minX), max(visible.minX, visible.maxX - card.width)),
                       y: min(max(card.minY, visible.minY), max(visible.minY, visible.maxY - card.height)))
    }

    fileprivate func beginDrag(with event: NSEvent) {
        // AppKit 将原始按下事件交给 WindowServer，保留系统跨屏拖动。
        hasStartedDrag = true
        performDrag(with: event)
    }

    func rememberDraggedPosition() {
        guard surface.isEditing, hasStartedDrag else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }
}

private final class WidgetDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        (window as? WidgetPanel)?.beginDrag(with: event)
    }
}

private final class WidgetSurface: NSView {
    private let material: NSView
    private let hosting: NSHostingView<ContentView>
    private let fallbackTint: NSView?
    private let dragView = WidgetDragView()

    var isEditing: Bool {
        get { !dragView.isHidden }
        set { dragView.isHidden = !newValue }
    }

    var glassMaterial: WidgetGlassMaterial {
        didSet { updateMaterial() }
    }

    var transparency: Double {
        didSet { updateMaterial() }
    }

    init(content: ContentView, glassMaterial: WidgetGlassMaterial, transparency: Double) {
        self.glassMaterial = glassMaterial
        self.transparency = transparency
        let size = WidgetMetrics.cardSize
        hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: hosting.frame)
            // 实测 regular 在这种大面积跨窗口背景上保留了更多折射细节。
            glass.style = .regular
            glass.cornerRadius = WidgetMetrics.cardRadius
            material = glass
            fallbackTint = nil
        } else {
            let frost = NSVisualEffectView(frame: hosting.frame)
            frost.blendingMode = .behindWindow
            frost.material = .hudWindow
            frost.state = .active
            frost.wantsLayer = true
            frost.layer?.cornerRadius = WidgetMetrics.cardRadius
            frost.layer?.masksToBounds = true

            let tint = NSView(frame: hosting.frame)
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            frost.addSubview(tint)
            frost.addSubview(hosting)
            material = frost
            fallbackTint = tint
        }

        super.init(frame: NSRect(origin: .zero, size: WidgetMetrics.windowSize))
        let inset = WidgetMetrics.shadowInset
        let card = NSRect(x: inset, y: inset, width: size.width, height: size.height)
        material.frame = card
        addSubview(material)
        dragView.frame = card
        dragView.isHidden = true
        addSubview(dragView)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        updateMaterial()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterial()
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        updateMaterial()
    }

    private func updateMaterial() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base = dark ? NSColor.black : .white
        // 默认档轻染色，滑块两端覆盖低透光至无染色。
        let strength = pow(1 - transparency, 3.3)
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            let blendsWithBackdrop = glassMaterial == .translucent
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

            if blendsWithBackdrop {
                if hosting.superview !== self {
                    glass.contentView = NSView(frame: glass.bounds)
                    hosting.frame = glass.frame
                    addSubview(hosting, positioned: .above, relativeTo: glass)
                }
                // 混合的是玻璃层，前景数据保持原来的不透明度。
                glass.alphaValue = 1 - 0.55 * transparency
            } else {
                if glass.contentView !== hosting {
                    hosting.removeFromSuperview()
                    hosting.frame = glass.bounds
                    glass.contentView = hosting
                }
                glass.alphaValue = 1
            }
            glass.tintColor = strength > 0 ? base.withAlphaComponent(strength) : nil
        } else {
            fallbackTint?.layer?.backgroundColor = base.withAlphaComponent(strength).cgColor
        }
    }
}
