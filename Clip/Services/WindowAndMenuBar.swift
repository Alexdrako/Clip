import AppKit
import SwiftUI

// MARK: - WindowCloseInterceptor (critical pattern #7)

/// Close button hides the window instead of destroying it.
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.miniaturize(nil)
        // Hide after a beat so the miniaturize animation isn't jarring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sender.orderOut(nil)
            sender.deminiaturize(nil) // restore into hidden state, not Dock-minimized
        }
        return false
    }
}

// MARK: - TranslucentWindowBackground

/// Tahoe-style translucent window: tags/looks up "ClipMainWindow" and sets
/// near-opaque alpha in dark mode. Resolves dynamic colors in the current
/// drawing appearance so light/dark both look right.
struct TranslucentWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("ClipMainWindow")
            window.isOpaque = false
            window.backgroundColor = .clear
            let material = NSVisualEffectView.Material.underWindowBackground
            let effect = NSVisualEffectView(frame: window.contentLayoutRect)
            effect.material = material
            effect.blendingMode = .behindWindow
            effect.state = .active

            func resolvedAlpha() -> CGFloat {
                let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
                return appearance == .darkAqua ? 0.95 : 0.88
            }

            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(resolvedAlpha()).cgColor
            container.frame = effect.bounds
            container.autoresizingMask = [.width, .height]
            effect.addSubview(container, positioned: .below, relativeTo: nil)
            window.contentView?.addSubview(effect, positioned: .below, relativeTo: nil)
            effect.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                effect.topAnchor.constraint(equalTo: (window.contentView ?? view!).topAnchor),
                effect.bottomAnchor.constraint(equalTo: (window.contentView ?? view!).bottomAnchor),
                effect.leadingAnchor.constraint(equalTo: (window.contentView ?? view!).leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: (window.contentView ?? view!).trailingAnchor),
            ])
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - MenuBarController + Popover flow

final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var progressArcHost: ProgressArcHost?

    private let onOpenWindow: () -> Void
    private let onPasteAndAnalyze: () -> Void

    init(onOpenWindow: @escaping () -> Void,
         onPasteAndAnalyze: @escaping () -> Void) {
        self.onOpenWindow = onOpenWindow
        self.onPasteAndAnalyze = onPasteAndAnalyze
        super.init()
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                            accessibilityDescription: "Clip")
        statusItem?.button?.action = #selector(togglePopover(_:))
        statusItem?.button?.target = self

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.contentViewController = NSHostingController(rootView: MenuBarView(
            openMainWindow: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenWindow()
            },
            pasteAndAnalyze: { [weak self] in
                self?.popover.performClose(nil)
                self?.onPasteAndAnalyze()
            }
        ))
        progressArcHost = ProgressArcHost(button: statusItem?.button)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Progress arc drawn over the menu bar icon.
    func updateProgress(_ fraction: Double?) {
        progressArcHost?.fraction = fraction
    }
}

// MARK: - Status bar progress arc overlay

final class ProgressArcHost {
    weak var button: NSStatusBarButton?
    var fraction: Double? {
        didSet { redraw() }
    }

    private var timer: Timer?

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    private func redraw() {
        guard let button else { return }
        let base = NSImage(systemSymbolName: "arrow.down.circle.fill",
                           accessibilityDescription: "Clip") ?? NSImage()
        guard let fraction else {
            button.image = base
            return
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: size.width / 2, y: size.height / 2),
                           radius: 7,
                           startAngle: 90,
                           endAngle: 90 - 360 * fraction,
                           clockwise: true)
            path.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        button.image = image
    }
}
