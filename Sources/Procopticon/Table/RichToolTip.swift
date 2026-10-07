import AppKit
import SwiftUI

/// Shows SwiftUI content as a tooltip in a floating panel, timed like standard tooltips: it appears
/// once the pointer has rested over an area, moves straight to the next area while one is showing,
/// and goes away when the pointer leaves or the user clicks, types or scrolls.
///
/// The owning view reports the area under the pointer (any hashable value, e.g. a table cell) with
/// `pointerMoved(over:content:)`. Content is built only when the tooltip is about to appear.
@MainActor
final class RichToolTipController {
    private var panel: RichToolTipPanel?
    private var pending: DispatchWorkItem?
    private var area: AnyHashable?
    /// The area the user clicked in; it doesn't show a tooltip again until the pointer leaves it.
    private var suppressedArea: AnyHashable?
    private var isShowing: Bool { panel?.isVisible == true }
    private var resignObserver: NSObjectProtocol?

    init() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    /// Delay before the first tooltip appears, honoring the system-wide `NSInitialToolTipDelay`
    /// (milliseconds) when set.
    private var initialDelay: TimeInterval {
        let ms = UserDefaults.standard.double(forKey: "NSInitialToolTipDelay")
        return ms > 0 ? ms / 1000 : 1.0
    }

    func pointerMoved(over newArea: AnyHashable?, content: @escaping () -> AnyView?) {
        guard newArea != area else { return }
        area = newArea
        pending?.cancel()
        pending = nil
        if suppressedArea != nil, suppressedArea != newArea {
            suppressedArea = nil
        }
        guard newArea != nil, suppressedArea == nil else {
            hide()
            return
        }
        if isShowing {
            show(content())
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.area == newArea else { return }
            self.show(content())
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay, execute: work)
    }

    /// Hides the tooltip. With `keepingArea`, the area under the pointer stays quiet until the
    /// pointer leaves it, as after a click; otherwise the next movement starts over.
    func dismiss(keepingArea: Bool = false) {
        pending?.cancel()
        pending = nil
        suppressedArea = keepingArea ? area : nil
        if !keepingArea {
            area = nil
        }
        hide()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func show(_ content: AnyView?) {
        guard let content, NSApp.isActive else {
            hide()
            return
        }
        let panel = panel ?? RichToolTipPanel()
        self.panel = panel
        panel.show(content, near: NSEvent.mouseLocation)
    }
}

/// Borderless, click-through panel in the tooltip material.
private final class RichToolTipPanel: NSPanel {
    private static let cornerRadius: CGFloat = 8
    private static let maxWidth: CGFloat = 600
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = NSWindow.Level(Int(CGWindowLevelForKey(.helpWindow)))
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]

        let effect = NSVisualEffectView()
        effect.material = .toolTip
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ content: AnyView, near pointer: NSPoint) {
        hosting.rootView = AnyView(
            WidthLimit(maxWidth: Self.maxWidth) { content }
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                })
        let size = hosting.fittingSize
        setFrame(Self.frame(for: size, near: pointer), display: true)
        hosting.frame = contentView?.bounds ?? .zero
        orderFront(nil)
        invalidateShadow()
    }

    /// Below and to the right of the pointer like a standard tooltip, kept on the pointer's screen.
    private static func frame(for size: NSSize, near pointer: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let cursor = NSCursor.current
        // The hot spot is measured from the top of the cursor image.
        let belowCursor = max(16, cursor.image.size.height - cursor.hotSpot.y) + 2
        var origin = NSPoint(x: pointer.x, y: pointer.y - belowCursor - size.height)
        if origin.y < visible.minY {
            origin.y = pointer.y + 6
        }
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Lays its content out at most `maxWidth` wide, even when asked for its ideal size (as
/// `fittingSize` does), so long text wraps instead of making the tooltip as wide as a single line.
private struct WidthLimit: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
