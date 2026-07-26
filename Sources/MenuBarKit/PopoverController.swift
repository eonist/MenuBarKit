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
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?
    private var anchorPoint: NSPoint?
    private var onWillCloseFired = false

    /// Snapshot taken on the FIRST applyContentSize call in menubar-hidden mode.
    /// chromeW/chromeH = window-frame minus content-size (stable for lifetime of popover).
    /// buttonMidX = snapped from the button window while it was still on-screen;
    /// used to re-centre the window on every hidden-mode setFrame.
    private struct HiddenModeSnapshot {
        let chromeW: CGFloat
        let chromeH: CGFloat
        let buttonMidX: CGFloat
    }
    private var hiddenModeSnapshot: HiddenModeSnapshot?

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
        mbkLog("PopoverController", "init -- minW=\(minWidth) maxW=\(maxWidth) maxH=\(maxHeight)")
    }

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        mbkLog("PopoverController", "setup -- START")
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    public func setRootView(_ view: AnyView) {
        mbkLog("PopoverController", "setRootView -- isSetUp=\(isSetUp)")
        rootView = view
        guard isSetUp else { return }
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView -- rootView replaced")
    }

    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    // MARK: - Reposition guard

    private enum RepositionMode {
        case normal        // screen visible, use live buttonMidX
        case hidden        // screen nil or buttonY > screenH, use snapshot
        case skip          // no button at all
    }

    private var repositionMode: RepositionMode {
        guard let button = statusItem.button else {
            mbkLog("PopoverController", "repositionMode=skip (no button)")
            return .skip
        }
        guard let screen = button.window?.screen else {
            mbkLog("PopoverController", "repositionMode=hidden (nil screen) buttonWinFrame=\(String(describing: button.window?.frame))")
            return .hidden
        }
        let screenH = screen.frame.height
        let buttonY = button.window?.frame.maxY ?? -1
        if buttonY > screenH {
            mbkLog("PopoverController", "repositionMode=hidden (buttonY=\(buttonY) > screenH=\(screenH))")
            return .hidden
        }
        mbkLog("PopoverController", "repositionMode=normal buttonY=\(buttonY) screenH=\(screenH)")
        return .normal
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
            mbkLog("PopoverController", "setupStatusItem -- button configured")
        }
    }

    @objc private func togglePopover() {
        mbkLog("PopoverController", "togglePopover -- isShown=\(popover.isShown)")
        if popover.isShown { popover.performClose(nil) } else { openPopover() }
    }

    private func openPopover() {
        mbkLog("PopoverController", "openPopover -- START")
        guard let button = statusItem.button else { return }
        mbkLog("PopoverController", "openPopover -- button.frame=\(button.frame) buttonWin.frame=\(String(describing: button.window?.frame))")
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let mode = repositionMode
        if mode == .normal {
            hostingController.view.layoutSubtreeIfNeeded()
            let fitting = hostingController.view.fittingSize
            mbkLog("PopoverController", "openPopover -- layoutSubtreeIfNeeded fittingSize=\(fitting)")
            if fitting.width > 0, fitting.height > 0 {
                let c = clamp(fitting)
                popover.contentSize = c
                mbkLog("PopoverController", "openPopover -- pre-show contentSize=(\(c.width),\(c.height))")
            }
        } else {
            mbkLog("PopoverController", "openPopover -- mode=\(mode), skip pre-show layoutSubtreeIfNeeded")
        }

        guard let rect = positioningRect(for: button) else { return }
        mbkLog("PopoverController", "openPopover -- contentSize BEFORE show=(\(popover.contentSize.width),\(popover.contentSize.height))")
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        if let w = hostingController.view.window {
            mbkLog("PopoverController", "openPopover -- window AFTER show frame=\(w.frame) #\(w.windowNumber)")
        }
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
        !(panelWindow?.childWindows ?? []).isEmpty
    }

    private func fireOnWillClose(wasForced: Bool) {
        guard !onWillCloseFired else { return }
        onWillCloseFired = true
        mbkLog("PopoverController", "calling onWillClose wasForced=\(wasForced)")
        onWillClose?(wasForced)
        mbkLog("PopoverController", "onWillClose fired")
    }

    private func forceClose() {
        fireOnWillClose(wasForced: true)
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            for child in (pw.childWindows ?? []) {
                pw.removeChildWindow(child); child.close()
            }
        }
        popover.performClose(nil)
    }

    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let b = button.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        return NSRect(x: b.midX - 0.5, y: b.minY, width: 1, height: b.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    private func setupPopover() {
        hostingController = NSHostingController(rootView: wrapped(rootView))
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
        mbkLog("PopoverController", "setupPopover -- done")
    }

    private func wrapped(_ view: AnyView) -> AnyView {
        AnyView(view
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size) { [weak self] old, newSize in
                            self?.mbkLog2("wrapped.onChange old=(\(old.width),\(old.height)) new=(\(newSize.width),\(newSize.height))")
                            self?.applyContentSize(newSize, trigger: "onChange")
                        }
                        .onAppear { [weak self] in
                            let s = geo.size
                            self?.mbkLog2("wrapped.onAppear size=(\(s.width),\(s.height))")
                            self?.applyContentSize(s, trigger: "onAppear")
                        }
                }
            )
        )
    }

    private func mbkLog2(_ msg: String) { mbkLog("PopoverController", msg) }

    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, minWidth), maxWidth),
               height: min(size.height, maxHeight))
    }

    // MARK: - applyContentSize

    private func applyContentSize(_ preferred: CGSize, trigger: String = "?") {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }
        let dw = abs(popover.contentSize.width - clamped.width)
        let dh = abs(popover.contentSize.height - clamped.height)
        guard dw > 1 || dh > 1 else {
            mbkLog("PopoverController", "applyContentSize -- BAIL delta too small dw=\(dw) dh=\(dh) trigger=\(trigger)")
            return
        }

        mbkLog("PopoverController", "applyContentSize -- trigger=\(trigger) clamped=(\(clamped.width),\(clamped.height)) isShown=\(popover.isShown) anchor=\(String(describing: anchorPoint)) snapshot=\(String(describing: hiddenModeSnapshot.map { "midX=\($0.buttonMidX) chromeW=\($0.chromeW) chromeH=\($0.chromeH)" }))")

        guard popover.isShown,
              let window = hostingController.view.window,
              let anchor = anchorPoint else {
            let prev = popover.contentSize
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize -- NOT SHOWN WRITE (\(clamped.width),\(clamped.height)) prev=(\(prev.width),\(prev.height))")
            return
        }

        let mode = repositionMode
        mbkLog("PopoverController", "applyContentSize -- mode=\(mode) window=\(window.frame)")

        switch mode {
        case .skip:
            // No button at all — write contentSize only so NSPopover stays consistent.
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize -- WRITE only (no button) (\(clamped.width),\(clamped.height))")

        case .hidden:
            // Menubar hidden / nil screen.
            // Snapshot chrome + buttonMidX on first call (button window is about to
            // slide off-screen; grab values while still valid or use show-time anchor).
            // Then recompute originX on every call so window stays centred regardless
            // of how many times width changes.
            let snap: HiddenModeSnapshot
            if let existing = hiddenModeSnapshot {
                snap = existing
                mbkLog("PopoverController", "applyContentSize -- hidden: reuse snapshot midX=\(snap.buttonMidX) chromeW=\(snap.chromeW) chromeH=\(snap.chromeH)")
            } else {
                // Derive from current window state.
                let chromeW = window.frame.width - popover.contentSize.width
                let chromeH = window.frame.height - popover.contentSize.height
                // buttonMidX: try live first; fall back to anchor.x from show-time.
                let liveMidX: CGFloat
                if let btn = statusItem.button, let bw = btn.window {
                    liveMidX = bw.frame.minX + btn.frame.midX
                } else {
                    liveMidX = anchor.x  // anchor.x = window.frame.midX at show-time
                }
                snap = HiddenModeSnapshot(chromeW: chromeW, chromeH: chromeH, buttonMidX: liveMidX)
                hiddenModeSnapshot = snap
                mbkLog("PopoverController", "applyContentSize -- hidden: NEW snapshot midX=\(snap.buttonMidX) chromeW=\(snap.chromeW) chromeH=\(snap.chromeH)")
            }

            let targetW = clamped.width + snap.chromeW
            let targetH = clamped.height + snap.chromeH
            let originX = snap.buttonMidX - targetW / 2
            let originY = anchor.y - targetH
            let targetFrame = NSRect(x: originX, y: originY, width: targetW, height: targetH)
            mbkLog("PopoverController", "applyContentSize -- hidden SETFRAME targetFrame=\(targetFrame) clamped=(\(clamped.width),\(clamped.height))")
            window.setFrame(targetFrame, display: true)
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize -- hidden DONE window.frame=\(window.frame)")

        case .normal:
            // Menubar visible. Derive chrome from current window, buttonMidX live.
            guard let button = statusItem.button, let buttonWin = button.window else {
                popover.contentSize = clamped
                mbkLog("PopoverController", "applyContentSize -- normal: no button/win, WRITE only (\(clamped.width),\(clamped.height))")
                return
            }
            let chromeW = window.frame.width - popover.contentSize.width
            let chromeH = window.frame.height - popover.contentSize.height
            let targetW = clamped.width + chromeW
            let targetH = clamped.height + chromeH
            let buttonMidX = buttonWin.frame.minX + button.frame.midX
            let originX = buttonMidX - targetW / 2
            let originY = anchor.y - targetH
            let targetFrame = NSRect(x: originX, y: originY, width: targetW, height: targetH)
            mbkLog("PopoverController", "applyContentSize -- normal SETFRAME buttonMidX=\(buttonMidX) targetFrame=\(targetFrame) clamped=(\(clamped.width),\(clamped.height))")
            window.setFrame(targetFrame, display: true)
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize -- normal DONE window.frame=\(window.frame)")
        }
    }

    // MARK: - Workspace observer

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspace observer -- self-activation, ignoring")
                    return
                }
                guard !overlayGate.hasActiveOverlay else { return }
                self.popover.performClose(nil)
            }
        }
    }

    // MARK: - Event monitor

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hasOverlay = self.overlayGate.hasActiveOverlay
                let hasFilePicker = self.overlayGate.hasFilePickerOverlay
                mbkLog("PopoverController", "event monitor fired -- hasActiveOverlay=\(hasOverlay) hasFilePickerOverlay=\(hasFilePicker)")
                if hasOverlay {
                    if !hasFilePicker, self.hasSheetChildWindow { self.forceClose() }
                } else {
                    self.popover.performClose(nil)
                }
            }
        }
        mbkLog("PopoverController", "event monitor started")
    }

    private func stopEventMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        mbkLog("PopoverController", "event monitor stopped")
    }

    deinit {
        if let o = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }
}

// MARK: - NSPopoverDelegate

extension MBKPopoverController: NSPopoverDelegate {
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "popoverWillShow -- no hostingWindow")
            return
        }
        anchorPoint = NSPoint(x: window.frame.midX, y: window.frame.maxY)
        mbkLog("PopoverController", "popoverWillShow -- anchor=\(anchorPoint!) win=\(window.frame) #\(window.windowNumber) contentSize=(\(popover.contentSize.width),\(popover.contentSize.height))")
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidClose -- START")
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        anchorPoint = nil
        hiddenModeSnapshot = nil  // clear so next show gets a fresh snapshot
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
