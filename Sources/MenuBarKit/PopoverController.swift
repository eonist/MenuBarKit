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
//   applyContentSize calls panel.setFrame() — free resize, no re-anchor.
//
// POSITIONING MODEL:
//   On open: panel left edge aligns with the left edge of the status button,
//   clamped so the panel never overflows the screen's visible frame.
//   On resize: anchorX (button.minX in screen coords) + anchorY are
//   re-used to recompute origin from the new size.
//
// ┌──────────────────────────────────────────────────────────────────────────┐
// │  !! DO NOT TOUCH — ROUNDED CORNER SYSTEM !!                            │
// │                                                                         │
// │  Rounded corners survive addChildWindow() ONLY because of the exact     │
// │  two-layer structure below. Every other approach was tried and failed.   │
// │  Do NOT change the view hierarchy, maskImage setup, or                  │
// │  roundedMaskImage() without reading the full history below.             │
// │                                                                         │
// │  WHAT BREAKS CORNERS (do not re-introduce these):                       │
// │    • NSVisualEffectView.cornerRadius / masksToBounds                    │
// │    • CAShapeLayer mask on any layer                                      │
// │    • NSGlassEffectView.cornerRadius alone                               │
// │    • NSGlassEffectView.clipsToBounds                                    │
// │    • Any async re-assertion of cornerRadius after addChildWindow()       │
// │    • Removing the outer NSVisualEffectView clipView                      │
// │    • Making NSGlassEffectView the direct panel.contentView               │
// │    • Subclassing NSPanel to override addChildWindow/removeChildWindow    │
// │    • maskImage on NSGlassEffectView — it has NO maskImage property       │
// │      (NSGlassEffectView does NOT inherit NSVisualEffectView)             │
// │                                                                         │
// │  WHAT KEEPS CORNERS ALIVE (do not remove or alter):                     │
// │    • clipView (NSVisualEffectView) as panel.contentView                  │
// │    • clipView.maskImage = roundedMaskImage(radius: cornerRadius)         │
// │    • roundedMaskImage() using NSBezierPath + capInsets + .stretch        │
// │    • NSGlassEffectView pinned inside clipView via Auto Layout            │
// └──────────────────────────────────────────────────────────────────────────┘
//
// VISUAL CHROME — TWO-LAYER APPROACH:
//   NSPanel(.borderless) has no chrome. We use two nested views:
//
//   1. Outer — NSVisualEffectView (clipView)
//      Set as panel.contentView. Its ONLY job is maskImage corner clipping.
//      blendingMode = .withinWindow is REQUIRED. With .withinWindow there is
//      nothing behind the VEV in the window's own layer tree, so it renders
//      as fully transparent — zero compositor content contributed.
//      Using .behindWindow causes the VEV to render its own dark vibrancy
//      layer that the glass then composites on top of, making the panel
//      look grey/dark instead of live liquid glass.
//      material is left at its default (.appearanceBased) — it has no effect
//      when blendingMode = .withinWindow and there is no backing content.
//
//   2. Inner — NSGlassEffectView
//      Pinned to fill clipView. Provides the Tahoe liquid-glass material.
//      hostingController.view is assigned to its contentView property.
//      Do NOT set .style on glassView — the default style is correct for a
//      floating panel. .regular adds a tinting overlay that makes it grey.
//      Do NOT set wantsLayer or layer.backgroundColor on glassView — it
//      interferes with the private glass compositor.
//
// HOSTING CONTROLLER VIEW TRANSPARENCY:
//   NSHostingController creates its NSView with an opaque system background
//   at the AppKit CALayer level. SwiftUI's .background(.clear) does NOT reach
//   this layer — it only affects SwiftUI's own render tree above it.
//   We zero the layer background AFTER glassView.contentView = hostingView
//   so that the view is attached to a layer tree and .layer is non-nil.
//   Zeroing it before attachment is a silent no-op (layer is nil at that point).
//
// ROUNDED CORNERS — HISTORY:
//   Approaches tried and rejected (ALL regress to rect corners on sheet open):
//   1. NSVisualEffectView.cornerRadius / masksToBounds  → reset by addChildWindow()
//   2. CAShapeLayer mask                                → clips pixels, not blur compositor
//   3. NSGlassEffectView.cornerRadius alone             → reset by addChildWindow()
//   4. NSGlassEffectView.clipsToBounds                  → reset by addChildWindow()
//   5. NSPanel subclass overriding addChildWindow()     → AppKit resets again async after super
//   6. DispatchQueue.main.async re-assertion            → still a race, still regresses
//   7. NSVisualEffectView.maskImage wrapping NSGlassEffectView — WORKS. (current approach)
//   8. maskImage on NSGlassEffectView directly          → COMPILE ERROR: no maskImage property
//   9. clipView.material = .clear                       → COMPILE ERROR: no such member
//  10. clipView.blendingMode = .behindWindow            → VEV renders dark vibrancy, grey panel
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
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    /// Left edge of the status button in screen coordinates, captured at open time.
    private var anchorX: CGFloat = 0
    /// Bottom edge of the status button in screen coordinates, captured at open time.
    private var anchorY: CGFloat = 0

    private let cornerRadius: CGFloat = 20

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

    private var pendingRootView: AnyView

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
        // Zero drawsBackground on any scroll views that SwiftUI may have created
        // during the first layout pass (they don't exist at setupPanel time).
        panel.contentView?.descendantScrollViews().forEach { $0.drawsBackground = false }
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

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true


        // ── View hierarchy ────────────────────────────────────────────────────────────
        //
        //   panel.contentView → NSGlassEffectView  (cornerRadius set here)
        //                           contentView → hostingController.view
        //
        //   + clipWindowFrameBacking(panel) clips the AppKit frame-backing layer
        //     that lives *outside* contentView — suppresses the faint square pixels
        //     at the window border without affecting glass compositing.
        //
        // WHY NO masksToBounds on any view:
        //   masksToBounds = true on any ancestor of NSGlassEffectView forces the
        //   entire window into an offscreen compositing pass, severing the live
        //   backdrop connection. The glass falls back to a flat dark rectangle
        //   whenever a sheet / alert child-window is attached.
        //
        //   NSGlassEffectView.cornerRadius clips the glass content natively inside
        //   the private glass compositor — no offscreen pass, survives addChildWindow.
        //
        // WHY NSGlassEffectView IS the direct panel.contentView here (not a wrapper):
        //   The previous pattern (plain NSView wrapper + masksToBounds) caused the
        //   glass-goes-square-on-sheet bug shown in the screenshot. Removing the
        //   wrapper and using .cornerRadius directly is the correct fix.
        // ─────────────────────────────────────────────────────────────────────────────

        // 1. Glass view as contentView — cornerRadius clips natively, no offscreen pass.
        //    .regular style gives a darker prominent material (like a menu or panel).
        //    Default (.automatic) renders as light/clear glass — too bright for a
        //    dark menu-bar popover sitting over a light desktop.
        let glassView = NSGlassEffectView(frame: NSRect(origin: .zero, size: initialSize))
        glassView.cornerRadius = cornerRadius
        glassView.style = .regular
        glassView.autoresizingMask = [.width, .height]

        // 2. Hosting view — transparent so glass shows through.
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = CGColor.clear
        hostingController.view.frame = glassView.bounds
        hostingController.view.autoresizingMask = [.width, .height]
        glassView.contentView = hostingController.view

        // 3. Zero drawsBackground on any NSScrollView — SwiftUI's
        //    .scrollContentBackground(.hidden) only hides SwiftUI's layer.
        hostingController.view.descendantScrollViews().forEach { $0.drawsBackground = false }

        panel.contentView = glassView

        // 4. Clip the AppKit frame-backing layer that sits outside contentView.
        //    This suppresses the faint rectangular border pixels at window edges
        //    without touching the glass compositor.
        clipWindowFrameBacking(panel, cornerRadius: cornerRadius)
        mbkLog("PopoverController", "setupPanel — initialSize=(\(initialSize.width),\(initialSize.height))")
    }

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // !! DO NOT TOUCH — roundedMaskImage() !!                               !!
    //
    // Produces the maskImage that keeps corners rounded through addChildWindow().
    // capInsets + .stretch let it scale to any panel size without regenerating.
    // Do not change the drawing, capInsets, or resizingMode.
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    /// Clips the AppKit frame-backing layer that lives *outside* contentView.
    /// A borderless NSPanel still composites a faint rectangular frame layer
    /// at window edges even with isOpaque=false + backgroundColor=.clear.
    /// Rounding that layer's corners removes the square pixel artefacts without
    /// touching the glass view hierarchy or triggering an offscreen pass.
    private func clipWindowFrameBacking(_ panel: NSPanel, cornerRadius: CGFloat) {
        guard let frameView = panel.contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
        frameView.layer?.cornerRadius = cornerRadius
        frameView.layer?.cornerCurve = .continuous
        frameView.layer?.masksToBounds = true
    }

    private func roundedMaskImage(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
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

        let newOrigin = NSPoint(
            x: round(anchorX - clamped.width / 2),
            y: round(anchorY - clamped.height)
        )
        let newFrame = NSRect(origin: newOrigin, size: clamped)
        mbkLog("PopoverController",
               "applyContentSize — (\(currentSize.width),\(currentSize.height))"
               + "→(\(clamped.width),\(clamped.height)) origin=(\(newOrigin.x),\(newOrigin.y))")
        panel.setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - Workspace observer

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
