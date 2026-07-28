// PopoverController.swift
// MenuBarKit
//
// Owns the NSPanel + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific
// behaviour is injected via closures at configuration time.
//
// SIZING MODEL:
//   NSHostingController.sizingOptions = .preferredContentSize
//   SwiftUI reports its ideal size via preferredContentSize.
//   KVO fires applyContentSize on every layout pass that produces a new size.
//   applyContentSize calls panel.setFrame() — free resize, re-anchoring to
//   the left edge of the status button (anchorX).
//
// POSITIONING MODEL:
//   On open: panel left edge aligns with the left edge of the status button,
//   clamped so the panel never overflows the screen's visible frame.
//   On resize: the same anchorX (button.minX in screen coords) + anchorY are
//   re-used so the panel stays left-aligned under the button.
//
// VIEW HIERARCHY:
//   panel.contentView → NSGlassEffectView  (cornerRadius set here)
//                           .contentView → hostingController.view
//
//   NSGlassEffectView is the direct panel.contentView. Its cornerRadius clips
//   the glass natively inside the private glass compositor — no offscreen
//   compositing pass, survives addChildWindow() without reverting to rect corners.
//
//   clipWindowFrameBacking() rounds the AppKit frame-backing layer that lives
//   *outside* contentView, suppressing faint square pixel artefacts at the
//   window border without touching the glass compositor.
//
// WHAT BREAKS CORNERS (do not re-introduce):
//   • masksToBounds = true on any ancestor of NSGlassEffectView
//     Forces an offscreen compositing pass → glass severs live backdrop.
//   • NSVisualEffectView wrapper as panel.contentView
//     Adding a VEV ancestor caused glass-goes-square-on-sheet regression.
//   • CAShapeLayer mask on any layer
//   • Any async re-assertion of cornerRadius after addChildWindow()
//
// HOSTING CONTROLLER VIEW TRANSPARENCY:
//   NSHostingController creates its NSView with an opaque CALayer background.
//   SwiftUI's .background(.clear) does NOT reach this layer.
//   wantsLayer = true forces immediate layer creation, so layer is non-nil before
//   the view is attached to any superview. layer?.backgroundColor can therefore be
//   zeroed immediately after wantsLayer = true — ordering relative to contentView
//   assignment does not matter. (An earlier version of this header incorrectly stated
//   that zeroing before attachment was a silent no-op — that was wrong.)
//
// ROUNDED CORNERS — HISTORY:
//   Approaches tried and rejected (ALL regress to rect corners on sheet open):
//   1. NSVisualEffectView.cornerRadius / masksToBounds  → reset by addChildWindow()
//   2. CAShapeLayer mask                                → clips pixels, not blur compositor
//   3. NSGlassEffectView.cornerRadius (with VEV ancestor as contentView)
//                                                        → reset by addChildWindow()
//   4. NSGlassEffectView.clipsToBounds (same VEV-ancestor setup)
//                                                        → reset by addChildWindow()
//   5. NSPanel subclass overriding addChildWindow()     → AppKit resets again async after super
//   6. DispatchQueue.main.async re-assertion            → still a race, still regresses
//   7. plain NSView wrapper + masksToBounds = true      → WORKS for corners BUT forces offscreen
//                                                          compositing pass → glass goes flat
//                                                          dark rectangle when sheet opens
//   8–11. Various NSVisualEffectView clipView material/blending/maskImage approaches
//          → all removed; clipView no longer exists in the codebase. See PR #29.
//
//  CURRENT (working): NSGlassEffectView as direct panel.contentView
//    glassView.cornerRadius clips natively inside glass compositor — no offscreen pass,
//    survives addChildWindow. clipWindowFrameBacking() rounds the AppKit frame-backing
//    layer (contentView.superview) to suppress residual square border pixels.
//
// CORNER RADIUS VALUE:
//   20pt matches system status-bar panels (Weather, etc.) on macOS 26.
//
// SIZE CLAMPING:
//   applyContentSize clamps preferredContentSize to [minWidth, maxWidth] x maxHeight.
//
// SHEETS / OVERLAY GATE:
//   MBKAnchoredSheet renders as an overlay inside the same NSHostingController.
//   MBKOverlayGate blocks panel close while an overlay is active.
//
// STATUS BUTTON HIGHLIGHT:
//   button.highlight(true/false) is the correct API for keeping the status
//   item visually selected while the panel is open. isHighlighted drops when
//   the panel takes key status; highlight() does not.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let initialSize: NSSize
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hostingController: NSHostingController<AnyView>!

    private var sizeObservation: NSKeyValueObservation?
    private var isSetUp = false
    // nonisolated(unsafe) is safe here: both callbacks dispatch back to @MainActor
    // via Task { @MainActor in … } before touching any shared state.
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    /// Left edge of the status button in screen coordinates, captured at open time.
    private var anchorX: CGFloat = 0
    /// Bottom edge of the status button in screen coordinates, captured at open time.
    private var anchorY: CGFloat = 0

    private let cornerRadius: CGFloat = 20

    // NSGlassEffectView private KVC keys — all three set to 1 to produce dark glass.
    //
    // Each key controls a distinct stage of the same compositor pipeline:
    //   _subduedState = 1  Locks the glass to its own dark intrinsic tone instead of
    //                      sampling desktop colours. ("Subdued" in Apple's naming means
    //                      muted-toward-desktop; = 1 disables that sampling.)
    //   _variant      = 1  Selects the dark-glass rendering variant of the compositor.
    //   _scrimState   = 1  Enables the scrim layer that reinforces the dark tone.
    //
    // All three must be set together. Setting fewer than all three leaves the
    // pipeline misaligned — partial combinations produce light or inconsistent glass.
    // All three at 1 aligns the entire pipeline so they reinforce each other.
    //
    // These KVC values only affect tint/intensity, not the compositing path, so
    // they do not interact with the masksToBounds / offscreen-pass issue.
    private enum GlassConfig {
        static let variant: Int = 1
        static let subduedState: Int = 1
        static let scrimState: Int = 1
    }

    /// Root view captured at init; consumed once by setupPanel.
    private let pendingRootView: AnyView

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        contentSize: NSSize = NSSize(width: 320, height: 300),
        minWidth: CGFloat = 200,
        maxWidth: CGFloat = 600,
        maxHeight: CGFloat = 600
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.initialSize = contentSize
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.pendingRootView = AnyView(rootView)
    }

    // MARK: - Setup

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            mbkLog("PopoverController", "togglePanel — closing")
            closePanel()
        } else {
            mbkLog("PopoverController", "togglePanel — opening")
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button,
              let screen = button.window?.screen ?? NSScreen.main else {
            mbkLog("PopoverController", "openPanel — aborted: no button or screen")
            return
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = button.window?.convertToScreen(buttonRectInWindow)
            ?? NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY, width: 0, height: 0)

        anchorX = buttonRectOnScreen.minX
        anchorY = buttonRectOnScreen.minY
        mbkLog("PopoverController", "openPanel — anchor=(\(anchorX),\(anchorY))")

        let size = panel.frame.size
        let clampedX = min(anchorX, screen.visibleFrame.maxX - size.width)
        let origin = NSPoint(
            x: max(clampedX, screen.visibleFrame.minX),
            y: anchorY - size.height
        )
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setButtonHighlight(true)
        mbkLog("PopoverController", "openPanel — frame=(\(panel.frame)) isKeyWindow=(\(panel.isKeyWindow))")
        // Zero drawsBackground on every NSScrollView SwiftUI creates.
        // Deferred one run-loop tick: makeKeyAndOrderFront triggers SwiftUI's first
        // layout pass asynchronously, so scroll views don't exist until this fires.
        // (A synchronous call here would be a no-op — no scroll views exist yet.)
        DispatchQueue.main.async { [weak self] in
            self?.panel.contentView?.descendantScrollViews().forEach { $0.drawsBackground = false }
        }
        startEventMonitor()
    }

    private func closePanel() {
        guard !overlayGate.hasActiveOverlay else {
            mbkLog("PopoverController", "closePanel — blocked: overlay active")
            return
        }
        panel.orderOut(nil)
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "closePanel — closed")
    }

    /// Drives the status-button's pressed appearance while the panel is open.
    /// Uses `highlight(_:)` rather than `isHighlighted`: `isHighlighted` resets
    /// to false the moment the panel takes key status; `highlight(_:)` persists.
    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.highlight(on)
    }

    // MARK: - Panel setup

    private func setupPanel() {
        hostingController = NSHostingController(rootView: pendingRootView)
        hostingController.sizingOptions = .preferredContentSize
        mbkLog("PopoverController", "setupPanel — sizingOptions=.preferredContentSize")

        sizeObservation = hostingController.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let self, let newSize = change.newValue else { return }
            mbkLog("PopoverController", "KVO preferredContentSize → (\(newSize.width),\(newSize.height))")
            Task { @MainActor [weak self] in
                self?.applyContentSize(newSize)
            }
        }

        // .nonactivatingPanel is intentional — do not remove.
        // (a) MBKFilePicker uses styleMask.contains(.nonactivatingPanel) as a window
        //     discriminator to identify this panel among all NSApp.windows.
        // (b) Prevents the panel from stealing key focus from the frontmost app when clicked.
        // makeKeyAndOrderFront() + NSApp.activate() override the non-activation at open time
        // so the panel still receives keyboard input when it needs to.
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu   // matches system status-bar panels (Weather, Control Centre);
                                   // floats above .floating windows; survives space switches
        panel.isOpaque = false          // required — opaque window suppresses the glass compositor
        panel.backgroundColor = .clear  // required — non-clear bg paints over the glass layer
        panel.hasShadow = true          // WindowServer renders shadow independently of the glass compositor — safe

        // Glass view as direct panel.contentView — cornerRadius clips natively, no offscreen pass.
        //    CRITICAL: NSGlassEffectView must BE the direct panel.contentView.
        //    Any intervening layer-backed ancestor (NSVisualEffectView, a plain wantsLayer=true
        //    view) routes the glass through an offscreen compositing pass — corners then revert
        //    to rect when addChildWindow() fires (e.g. on sheet open). Direct contentView is the
        //    only position that survives addChildWindow() without regression.
        //
        //    .regular is the required public-API base that puts the compositor in the right
        //    ballpark (darker, prominent material matching system panels). The three _KVC calls
        //    below fine-tune on top of it — observed to have no effect without .regular as the
        //    base (unverified against Apple source; may change in future OS releases).
        //    Default (.automatic) renders as light/clear glass — too bright for a dark popover.
        let glassView = NSGlassEffectView(frame: NSRect(origin: .zero, size: initialSize))
        glassView.cornerRadius = cornerRadius
        glassView.style = .regular
        glassView.autoresizingMask = [.width, .height]
        // Private KVC — fine-tunes glass depth on top of .regular.
        // Counter-intuitive: value 1 produces darker/richer glass than 0 in this
        // panel context. Do NOT revert to 0 — empirically verified lighter on macOS 26.
        // These keys are undocumented and may change in a future OS update.
        glassView.setValue(GlassConfig.subduedState, forKey: "_subduedState")
        glassView.setValue(GlassConfig.variant, forKey: "_variant")
        glassView.setValue(GlassConfig.scrimState, forKey: "_scrimState")

        // Hosting view — transparent so glass shows through.
        //    wantsLayer = true forces immediate layer creation — layer is non-nil right after.
        //    layer?.backgroundColor must follow wantsLayer = true, but can precede or follow
        //    the contentView assignment below. The contentView assignment is irrelevant to
        //    layer creation; only wantsLayer = true matters for layer to be non-nil.
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = CGColor.clear
        hostingController.view.frame = glassView.bounds
        hostingController.view.autoresizingMask = [.width, .height]
        glassView.contentView = hostingController.view

        panel.contentView = glassView

        // Clip the AppKit NSThemeFrame layer — suppresses faint square border pixels.
        //    NO masksToBounds (see clipWindowFrameBacking) — would sever glass compositor.
        clipWindowFrameBacking(panel, cornerRadius: cornerRadius)
        mbkLog("PopoverController", "setupPanel — initialSize=(\(initialSize.width),\(initialSize.height))")
    }

    /// Clips the AppKit frame-backing layer that lives *outside* contentView.
    /// A borderless NSPanel still composites a faint rectangular frame layer
    /// at window edges even with isOpaque=false + backgroundColor=.clear.
    /// Rounding that layer's corners removes the square pixel artefacts without
    /// touching the glass view hierarchy or triggering an offscreen pass.
    private func clipWindowFrameBacking(_ panel: NSPanel, cornerRadius: CGFloat) {
        // panel.contentView?.superview is NSThemeFrame — AppKit's private window-chrome
        // view that wraps the entire window. It exists on borderless panels and composites
        // a faint rectangular frame at window edges, visible as square pixel artefacts
        // when backgroundColor = .clear. We round its layer without masksToBounds (see below).
        guard let frameView = panel.contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
        frameView.layer?.cornerRadius = cornerRadius
        frameView.layer?.cornerCurve = .continuous
        // DO NOT set masksToBounds = true — NSThemeFrame is an ancestor of
        // NSGlassEffectView. masksToBounds forces the entire window into an
        // offscreen compositing pass, severing the live backdrop connection.
        // The glass falls back to flat/washed-out. cornerRadius alone is
        // sufficient to suppress the faint square border pixel artefacts.
    }

    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width:  min(max(size.width,  minWidth), maxWidth),
            height: min(max(size.height, 1),        maxHeight)
        )
    }

    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else {
            mbkLog("PopoverController", "applyContentSize — skipped: degenerate after clamp")
            return
        }
        let currentSize = panel.frame.size
        // Sub-pixel filter: skip setFrame if the size delta is less than 1pt.
        // SwiftUI can emit fractional preferredContentSize changes that round to
        // the same display point — calling setFrame on every one causes unnecessary thrash.
        guard abs(currentSize.width  - clamped.width)  >= 1
           || abs(currentSize.height - clamped.height) >= 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard panel.isVisible else {
            panel.setContentSize(clamped)
            mbkLog("PopoverController", "applyContentSize — not visible, pre-sized to (\(clamped.width),\(clamped.height))")
            return
        }

        guard let screen = panel.screen ?? NSScreen.main else {
            mbkLog("PopoverController", "applyContentSize — aborted: no screen")
            return
        }
        // Left-align panel to button's leading edge, clamped within the visible screen frame.
        let clampedX = min(anchorX, screen.visibleFrame.maxX - clamped.width)
        let newOrigin = NSPoint(
            x: round(max(clampedX, screen.visibleFrame.minX)),
            y: round(anchorY - clamped.height)
        )
        let newFrame = NSRect(origin: newOrigin, size: clamped)
        mbkLog("PopoverController",
               "applyContentSize — (\(currentSize.width),\(currentSize.height))"
               + "→(\(clamped.width),\(clamped.height)) origin=(\(newOrigin.x),\(newOrigin.y))")
        panel.setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - Workspace observer

    // Closes the panel when the user switches to another app, matching the
    // auto-dismiss behaviour of system status-bar panels (Spotlight, Control Centre).
    // The overlayGate guard keeps it open while a sheet or picker is active.
    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspace observer — self-activation, ignoring")
                    return
                }
                guard !self.overlayGate.hasActiveOverlay else {
                    mbkLog("PopoverController", "workspace observer — overlay active, keeping open")
                    return
                }
                mbkLog("PopoverController", "workspace observer — other app active, closing")
                self.closePanel()
            }
        }
    }

    // MARK: - Event monitor

    // Global mouse-down monitor closes the panel on outside clicks.
    // MUST be removed on close — a leaked monitor fires on every click system-wide,
    // even with the panel hidden. startEventMonitor/stopEventMonitor are always paired.
    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        }
        mbkLog("PopoverController", "event monitor started")
    }

    private func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PopoverController", "event monitor stopped")
    }

    deinit {
        sizeObservation?.invalidate()
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

private extension NSView {
    /// Returns all NSScrollView descendants in the view tree.
    func descendantScrollViews() -> [NSScrollView] {
        var result: [NSScrollView] = []
        for sub in subviews {
            if let sv = sub as? NSScrollView { result.append(sv) }
            result.append(contentsOf: sub.descendantScrollViews())
        }
        return result
    }
}
