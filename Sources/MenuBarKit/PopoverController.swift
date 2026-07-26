// PopoverController.swift
// MenuBarKit

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject, MBKPopoverControllerProtocol {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private var rootView: AnyView

    public var onWillShow: (() -> Void)?
    public var onDidShow: (() -> Void)?
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    private var isSetUp = false
    // Safe: registered and removed exclusively on the main thread via NSEvent monitor API.
    nonisolated(unsafe) private var eventMonitor: Any?
    // Safe: registered and removed exclusively on the main thread via NSWorkspace.notificationCenter.
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?
    // anchorY: window.frame.maxY captured once in popoverWillShow.
    // Used as the fixed Y reference for setFrameOrigin on width changes.
    // Y is stable — AppKit pins the popover's bottom to the button on height changes,
    // so Y never drifts regardless of how many times height changes.
    // nil until first show.
    private var anchorY: CGFloat?
    private var onWillCloseFired = false

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        minWidth: CGFloat = 200,
        maxWidth: CGFloat = 600,
        maxHeight: CGFloat = 600
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.rootView = AnyView(rootView)
    }

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    // MARK: - Root view replacement

    /// Replaces the popover's root view with `view`.
    /// The GeometryReader size observer picks up the change automatically —
    /// no need to call `popover.show()` again.
    /// ❌ NEVER call from a SwiftUI view — use callbacks only.
    public func setRootView(_ view: AnyView) {
        rootView = view
        guard isSetUp else { return }
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView — rootView replaced")
    }

    // MARK: - Status item image

    /// Updates the status-bar button image.
    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    // MARK: - Auto-hide menubar guard

    /// Returns true when the macOS auto-hide menubar is currently hidden (slid off-screen).
    ///
    /// When hidden, the status item button window slides above the top edge of the screen:
    /// button.window?.frame.maxY > screen.frame.height, or the button's screen drops to nil.
    /// Writing contentSize in this state causes AppKit to re-run full anchor geometry
    /// against the off-screen button position, collapsing the popover x-origin to 0 —
    /// the open-time side-jump. Guard the pre-show write in openPopover with this.
    ///
    /// WHY > and not >=:
    /// buttonY == screenH is the normal resting position of the status button window
    /// (flush with the screen top edge). Only buttonY > screenH means the menubar has
    /// actually slid off-screen in auto-hide mode. Using >= produced a false-positive on
    /// first open, causing the pre-show contentSize write to be skipped.
    ///
    /// screenH < 0 signals a nil screen — skip in both cases.
    private var isMenuBarHidden: Bool {
        guard let button = statusItem.button else { return false }
        let buttonScreen = button.window?.screen
        let screenH = buttonScreen.map { $0.frame.height } ?? -1
        let buttonY = button.window?.frame.maxY ?? -1
        let hidden = screenH < 0 || buttonY > screenH
        mbkLog("PopoverController", "isMenuBarHidden=\(hidden) buttonY=\(buttonY) screenH=\(screenH)")
        return hidden
    }

    /// The status bar button's horizontal midpoint in screen coordinates.
    /// This is the true, always-current center for the NSPopover arrow.
    /// Re-derived on every width-change reposition rather than relying on
    /// a stale one-time capture — the button never moves while the popover
    /// is open, so this value is stable within a session.
    private var buttonMidX: CGFloat? {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return nil }
        // Convert button bounds midX to screen coordinates.
        let buttonMid = button.convert(NSPoint(x: button.bounds.midX, y: 0), to: nil)
        return buttonWindow.convertPoint(toScreen: buttonMid).x
    }

    // MARK: - Private setup helpers

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        mbkLog("PopoverController", "togglePopover -- isShown=\(popover.isShown)")
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        // Pre-show fittingSize write — seeds contentSize before show() so AppKit
        // places the window at the correct size from the first frame.
        // GUARDED: skip if auto-hide menubar is hidden — writing contentSize
        // against an off-screen button causes the side-jump on open (#2237).
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            if isMenuBarHidden {
                mbkLog("PopoverController", "openPopover -- menubar hidden, SKIP pre-show contentSize write (\(fitting.width),\(fitting.height))")
            } else {
                popover.contentSize = clamp(fitting)
                mbkLog("PopoverController", "openPopover -- pre-show contentSize written (\(clamp(fitting).width),\(clamp(fitting).height))")
            }
        }

        guard let rect = positioningRect(for: button) else { return }
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()

        Task { @MainActor in
            mbkLog("PopoverController", "onDidShow Task hop -- calling onDidShow")
            self.onDidShow?()
            mbkLog("PopoverController", "onDidShow fired")
        }
    }

    private var panelWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) }
    }

    private var hasSheetChildWindow: Bool {
        let pw = panelWindow
        let pwChildren = pw?.childWindows ?? []
        return !pwChildren.isEmpty
    }

    private func fireOnWillClose(wasForced: Bool) {
        guard !onWillCloseFired else {
            mbkLog("PopoverController", "onWillClose already fired, skipping")
            return
        }
        onWillCloseFired = true
        mbkLog("PopoverController", "calling onWillClose wasForced=\(wasForced)")
        onWillClose?(wasForced)
        mbkLog("PopoverController", "onWillClose fired")
    }

    private func forceClose() {
        fireOnWillClose(wasForced: true)
        mbkLog("PopoverController", "forceClose -- clearing gate")
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            for child in (pw.childWindows ?? []) {
                mbkLog("PopoverController", "forceClose -- closing child #\(child.windowNumber)")
                pw.removeChildWindow(child)
                child.close()
            }
        } else {
            mbkLog("PopoverController", "forceClose -- no panelWindow found")
        }
        mbkLog("PopoverController", "forceClose -- calling performClose")
        popover.performClose(nil)
    }

    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect -- degenerate bounds \(bounds)")
            return nil
        }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        hostingController = NSHostingController(rootView: wrapped(rootView))
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    private func wrapped(_ view: AnyView) -> AnyView {
        AnyView(view
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size) { [weak self] _, newSize in
                            self?.applyContentSize(newSize)
                        }
                        .onAppear { [weak self] in
                            self?.applyContentSize(geo.size)
                        }
                }
            )
        )
    }

    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(size.height, maxHeight)
        )
    }

    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }
        guard abs(popover.contentSize.width - clamped.width) > 1
           || abs(popover.contentSize.height - clamped.height) > 1 else { return }
        guard popover.isShown,
              let window = hostingController.view.window,
              let anchorY = anchorY else {
            // Not shown — bare write, no window to reposition.
            popover.contentSize = clamped
            mbkLog("PopoverController",
                   "applyContentSize -- not shown, WRITE (\(clamped.width),\(clamped.height))")
            return
        }

        // Capture old width BEFORE the contentSize write.
        let oldWidth = popover.contentSize.width
        popover.contentSize = clamped

        // Only reposition on width changes.
        //
        // WHY skip height-only:
        // AppKit automatically adjusts the window's Y to keep the popover
        // pinned to the button bottom on height changes. Calling setFrameOrigin
        // on height-only changes accumulates floating-point rounding on every
        // row-expand event and drifts the window horizontally over time.
        //
        // WHY re-derive anchor.x from the button each time:
        // anchorPoint was previously captured once as window.frame.midX at
        // popoverWillShow. After the first setFrameOrigin call the window moved,
        // making the stale anchor wrong for all subsequent width-change repositions.
        // The status bar button never moves while the popover is open — its screen
        // midX is always the true horizontal center for the NSPopover arrow.
        if abs(clamped.width - oldWidth) > 1 {
            guard let liveAnchorX = buttonMidX else {
                mbkLog("PopoverController",
                       "applyContentSize -- WRITE only, width change but buttonMidX unavailable (\(clamped.width),\(clamped.height))")
                return
            }
            let newOrigin = NSPoint(
                x: liveAnchorX - window.frame.width / 2,
                y: anchorY - window.frame.height
            )
            window.setFrameOrigin(newOrigin)
            mbkLog("PopoverController",
                   "applyContentSize -- WRITE+REPOSITION (\(clamped.width),\(clamped.height)) liveAnchorX=\(liveAnchorX) w=\(window.frame.width) origin=\(newOrigin)")
        } else {
            mbkLog("PopoverController",
                   "applyContentSize -- WRITE only, height-only change (\(clamped.width),\(clamped.height)) — skipping setFrameOrigin")
        }
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspace observer -- self-activation, ignoring")
                    return
                }
                guard !overlayGate.hasActiveOverlay else {
                    mbkLog("PopoverController", "workspace observer -- overlay active, keeping popover open")
                    return
                }
                mbkLog("PopoverController", "workspace observer -- other app active, closing")
                self.popover.performClose(nil)
            }
        }
    }

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hasOverlay = self.overlayGate.hasActiveOverlay
                let hasFilePicker = self.overlayGate.hasFilePickerOverlay
                mbkLog("PopoverController",
                       "event monitor fired -- hasActiveOverlay=\(hasOverlay) hasFilePickerOverlay=\(hasFilePicker)")
                if hasOverlay {
                    if hasFilePicker {
                        mbkLog("PopoverController", "event monitor -- file picker active, ignoring outside click")
                    } else {
                        let hasSheet = self.hasSheetChildWindow
                        mbkLog("PopoverController", "event monitor -- hasSheet=\(hasSheet)")
                        if hasSheet {
                            mbkLog("PopoverController", "event monitor -- sheet overlay, force-closing")
                            self.forceClose()
                        } else {
                            mbkLog("PopoverController", "event monitor -- picker/alert overlay, ignoring outside click")
                        }
                    }
                } else {
                    mbkLog("PopoverController", "event monitor -- no overlay, performClose")
                    self.popover.performClose(nil)
                }
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
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

extension MBKPopoverController: NSPopoverDelegate {
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "popoverWillShow -- no hostingWindow (anchorY skipped)")
            return
        }
        // anchorY: window top edge at show-time. Used as the fixed Y reference
        // for setFrameOrigin on width changes. Y is stable because AppKit
        // automatically keeps the popover pinned to the button on height changes.
        //
        // anchorX is NOT stored here. Instead, buttonMidX is re-derived live
        // from the status bar button on every width-change reposition, so it is
        // never stale regardless of how many setFrameOrigin calls have occurred.
        anchorY = window.frame.maxY
        mbkLog("PopoverController",
               "popoverWillShow -- anchorY=\(anchorY!) win=\(window.frame) #\(window.windowNumber)")
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        anchorY = nil
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
