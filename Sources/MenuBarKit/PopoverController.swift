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
        mbkLog("PopoverController", "init -- minW=\(minWidth) maxW=\(maxWidth) maxH=\(maxHeight) symbol=\(symbolName)")
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
        mbkLog("PopoverController", "setRootView -- START isSetUp=\(isSetUp)")
        rootView = view
        guard isSetUp else {
            mbkLog("PopoverController", "setRootView -- not set up yet, returning")
            return
        }
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView -- rootView replaced")
    }

    public func setStatusItemImage(_ image: NSImage) {
        mbkLog("PopoverController", "setStatusItemImage -- size=\(image.size)")
        statusItem?.button?.image = image
    }

    // MARK: - shouldSkipReposition

    private var shouldSkipReposition: Bool {
        mbkLog("PopoverController", "shouldSkipReposition -- checking...")
        guard let button = statusItem.button else {
            mbkLog("PopoverController", "shouldSkipReposition=true REASON=no-button")
            return true
        }
        let buttonWin = button.window
        let screen = buttonWin?.screen
        let buttonWinFrame = buttonWin?.frame
        let screenFrame = screen?.frame
        mbkLog("PopoverController", "shouldSkipReposition -- button.window=\(String(describing: buttonWin)) screen=\(String(describing: screen)) buttonWinFrame=\(String(describing: buttonWinFrame)) screenFrame=\(String(describing: screenFrame))")
        guard let screen = screen else {
            mbkLog("PopoverController", "shouldSkipReposition=true REASON=nil-screen buttonWin=\(String(describing: buttonWin))")
            return true
        }
        let screenH = screen.frame.height
        let buttonY = buttonWin?.frame.maxY ?? -1
        let hidden = buttonY > screenH
        mbkLog("PopoverController", "shouldSkipReposition=\(hidden) REASON=buttonY-check buttonY=\(buttonY) screenH=\(screenH) diff=\(buttonY - screenH)")
        return hidden
    }

    // MARK: - Setup helpers

    private func setupStatusItem() {
        mbkLog("PopoverController", "setupStatusItem -- START")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
            mbkLog("PopoverController", "setupStatusItem -- button configured frame=\(button.frame) window=\(String(describing: button.window))")
        } else {
            mbkLog("PopoverController", "setupStatusItem -- WARNING: no button")
        }
    }

    @objc private func togglePopover() {
        let shown = popover.isShown
        mbkLog("PopoverController", "togglePopover -- isShown=\(shown)")
        if shown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        mbkLog("PopoverController", "openPopover -- START")
        guard let button = statusItem.button else {
            mbkLog("PopoverController", "openPopover -- ABORT no button")
            return
        }
        mbkLog("PopoverController", "openPopover -- button.frame=\(button.frame) button.window=\(String(describing: button.window)) button.window.frame=\(String(describing: button.window?.frame))")
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let skipRepos = shouldSkipReposition
        mbkLog("PopoverController", "openPopover -- skipReposition=\(skipRepos)")
        if !skipRepos {
            mbkLog("PopoverController", "openPopover -- calling layoutSubtreeIfNeeded")
            hostingController.view.layoutSubtreeIfNeeded()
            let fitting = hostingController.view.fittingSize
            mbkLog("PopoverController", "openPopover -- fittingSize=\(fitting) after layoutSubtreeIfNeeded")
            if fitting.width > 0, fitting.height > 0 {
                let clamped = clamp(fitting)
                let prev = popover.contentSize
                popover.contentSize = clamped
                mbkLog("PopoverController", "openPopover -- pre-show contentSize written prev=(\(prev.width),\(prev.height)) new=(\(clamped.width),\(clamped.height))")
            } else {
                mbkLog("PopoverController", "openPopover -- fittingSize degenerate, skipping contentSize write")
            }
        } else {
            mbkLog("PopoverController", "openPopover -- skip guard active, SKIP pre-show contentSize write")
        }

        guard let rect = positioningRect(for: button) else {
            mbkLog("PopoverController", "openPopover -- ABORT positioningRect degenerate")
            return
        }
        mbkLog("PopoverController", "openPopover -- positioningRect=\(rect) preferredEdge=minY")
        mbkLog("PopoverController", "openPopover -- popover.contentSize BEFORE show=(\(popover.contentSize.width),\(popover.contentSize.height))")
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        mbkLog("PopoverController", "openPopover -- popover.contentSize AFTER show=(\(popover.contentSize.width),\(popover.contentSize.height))")
        if let w = hostingController.view.window {
            mbkLog("PopoverController", "openPopover -- hostingWindow AFTER show frame=\(w.frame) #\(w.windowNumber)")
        }
        startEventMonitor()

        Task { @MainActor in
            mbkLog("PopoverController", "onDidShow Task hop -- calling onDidShow")
            self.onDidShow?()
            mbkLog("PopoverController", "onDidShow fired")
        }
    }

    private var panelWindow: NSWindow? {
        let w = NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) }
        mbkLog("PopoverController", "panelWindow -- \(w.map { "found #\($0.windowNumber) frame=\($0.frame)" } ?? "nil")")
        return w
    }

    private var hasSheetChildWindow: Bool {
        let children = panelWindow?.childWindows ?? []
        mbkLog("PopoverController", "hasSheetChildWindow -- childCount=\(children.count)")
        return !children.isEmpty
    }

    private func fireOnWillClose(wasForced: Bool) {
        mbkLog("PopoverController", "fireOnWillClose -- wasForced=\(wasForced) alreadyFired=\(onWillCloseFired)")
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
        mbkLog("PopoverController", "forceClose -- START")
        fireOnWillClose(wasForced: true)
        mbkLog("PopoverController", "forceClose -- clearing gate")
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            for child in (pw.childWindows ?? []) {
                mbkLog("PopoverController", "forceClose -- closing child #\(child.windowNumber) frame=\(child.frame)")
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
        mbkLog("PopoverController", "positioningRect -- button.bounds=\(bounds)")
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect -- DEGENERATE bounds, returning nil")
            return nil
        }
        let r = NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
        mbkLog("PopoverController", "positioningRect -- result=\(r)")
        return r
    }

    private func setButtonHighlight(_ on: Bool) {
        mbkLog("PopoverController", "setButtonHighlight -- \(on)")
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        mbkLog("PopoverController", "setupPopover -- START minW=\(minWidth)")
        hostingController = NSHostingController(rootView: wrapped(rootView))
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
        mbkLog("PopoverController", "setupPopover -- done popover.contentSize=(\(popover.contentSize.width),\(popover.contentSize.height))")
    }

    private func wrapped(_ view: AnyView) -> AnyView {
        AnyView(view
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size) { [weak self] old, newSize in
                            self?.mbkLogMain("wrapped.onChange -- old=(\(old.width),\(old.height)) new=(\(newSize.width),\(newSize.height))")
                            self?.applyContentSize(newSize, trigger: "onChange")
                        }
                        .onAppear { [weak self] in
                            let s = geo.size
                            self?.mbkLogMain("wrapped.onAppear -- size=(\(s.width),\(s.height))")
                            self?.applyContentSize(s, trigger: "onAppear")
                        }
                }
            )
        )
    }

    private func mbkLogMain(_ msg: String) {
        mbkLog("PopoverController", msg)
    }

    private func clamp(_ size: CGSize) -> CGSize {
        let w = min(max(size.width, minWidth), maxWidth)
        let h = min(size.height, maxHeight)
        mbkLog("PopoverController", "clamp -- in=(\(size.width),\(size.height)) out=(\(w),\(h)) minW=\(minWidth) maxW=\(maxWidth) maxH=\(maxHeight)")
        return CGSize(width: w, height: h)
    }

    // MARK: - applyContentSize

    private func applyContentSize(_ preferred: CGSize, trigger: String = "?") {
        mbkLog("PopoverController", "applyContentSize -- ENTER trigger=\(trigger) preferred=(\(preferred.width),\(preferred.height)) popover.isShown=\(popover.isShown) currentContentSize=(\(popover.contentSize.width),\(popover.contentSize.height)) anchorPoint=\(String(describing: anchorPoint))")
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else {
            mbkLog("PopoverController", "applyContentSize -- BAIL clamped degenerate (\(clamped.width),\(clamped.height))")
            return
        }
        let dw = abs(popover.contentSize.width - clamped.width)
        let dh = abs(popover.contentSize.height - clamped.height)
        mbkLog("PopoverController", "applyContentSize -- delta dw=\(dw) dh=\(dh)")
        guard dw > 1 || dh > 1 else {
            mbkLog("PopoverController", "applyContentSize -- BAIL delta too small (dw=\(dw) dh=\(dh))")
            return
        }

        let isShown = popover.isShown
        let window = hostingController.view.window
        let anchor = anchorPoint
        mbkLog("PopoverController", "applyContentSize -- isShown=\(isShown) window=\(window.map { "#\($0.windowNumber) frame=\($0.frame)" } ?? "nil") anchor=\(String(describing: anchor))")

        guard isShown, let window = window, let anchor = anchor else {
            // Not shown — bare write only.
            let prev = popover.contentSize
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize -- NOT SHOWN, WRITE (\(clamped.width),\(clamped.height)) prev=(\(prev.width),\(prev.height))")
            return
        }

        // Check skip conditions.
        let button = statusItem.button
        let buttonWin = button?.window
        let screen = buttonWin?.screen
        let buttonWinFrame = buttonWin?.frame
        let screenH = screen?.frame.height ?? -1
        let buttonY = buttonWin?.frame.maxY ?? -1
        mbkLog("PopoverController", "applyContentSize -- skipCheck: button=\(String(describing: button)) buttonWin=\(String(describing: buttonWin)) screen=\(String(describing: screen)) buttonWinFrame=\(String(describing: buttonWinFrame)) screenH=\(screenH) buttonY=\(buttonY)")

        if screen == nil {
            // NIL SCREEN — menubar hidden or transient nav teardown.
            // Skip BOTH setFrame AND contentSize write.
            // Writing contentSize lets AppKit resize the window in-place from
            // an off-screen origin, which IS the visible jump (run-bot #2268).
            mbkLog("PopoverController", "applyContentSize -- SKIP ALL nil-screen (\(clamped.width),\(clamped.height)) window.frame=\(window.frame) popover.contentSize=(\(popover.contentSize.width),\(popover.contentSize.height))")
            return
        }

        if buttonY > screenH {
            // MENUBAR HIDDEN — button above screen top edge.
            // Same: skip both.
            mbkLog("PopoverController", "applyContentSize -- SKIP ALL menubar-hidden buttonY=\(buttonY) screenH=\(screenH) diff=\(buttonY-screenH) (\(clamped.width),\(clamped.height))")
            return
        }

        // Safe to reposition.
        guard let button = button, let buttonWin = buttonWin else {
            let prev = popover.contentSize
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize -- no button/buttonWin, WRITE only prev=(\(prev.width),\(prev.height)) new=(\(clamped.width),\(clamped.height))")
            return
        }

        let chromeW = window.frame.width - popover.contentSize.width
        let chromeH = window.frame.height - popover.contentSize.height
        let targetW = clamped.width + chromeW
        let targetH = clamped.height + chromeH
        let buttonMidX = buttonWin.frame.minX + button.frame.midX
        let targetOriginX = buttonMidX - targetW / 2
        let targetOriginY = anchor.y - targetH
        let targetOrigin = NSPoint(x: targetOriginX, y: targetOriginY)
        let targetFrame = NSRect(origin: targetOrigin, size: NSSize(width: targetW, height: targetH))

        mbkLog("PopoverController", "applyContentSize -- ATOMIC SETFRAME compute: chromeW=\(chromeW) chromeH=\(chromeH) targetW=\(targetW) targetH=\(targetH) buttonWin.frame=\(buttonWin.frame) button.frame=\(button.frame) buttonMidX=\(buttonMidX) anchor=\(anchor) targetOrigin=\(targetOrigin) targetFrame=\(targetFrame) currentWindow.frame=\(window.frame) clamped=(\(clamped.width),\(clamped.height))")

        window.setFrame(targetFrame, display: true)
        mbkLog("PopoverController", "applyContentSize -- window.setFrame called, window.frame now=\(window.frame)")
        let prev = popover.contentSize
        popover.contentSize = clamped
        mbkLog("PopoverController", "applyContentSize -- DONE: contentSize prev=(\(prev.width),\(prev.height)) new=(\(clamped.width),\(clamped.height)) window.frame=\(window.frame)")
    }

    // MARK: - Workspace observer

    private func setupWorkspaceObserver() {
        mbkLog("PopoverController", "setupWorkspaceObserver -- START")
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                mbkLog("PopoverController", "workspace observer -- activated=\(activated?.bundleIdentifier ?? "nil") self=\(NSRunningApplication.current.bundleIdentifier ?? "nil")")
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
        mbkLog("PopoverController", "setupWorkspaceObserver -- done")
    }

    // MARK: - Event monitor

    private func startEventMonitor() {
        guard eventMonitor == nil else {
            mbkLog("PopoverController", "startEventMonitor -- already running, skip")
            return
        }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hasOverlay = self.overlayGate.hasActiveOverlay
                let hasFilePicker = self.overlayGate.hasFilePickerOverlay
                mbkLog("PopoverController", "event monitor fired -- type=\(event.type.rawValue) hasActiveOverlay=\(hasOverlay) hasFilePickerOverlay=\(hasFilePicker)")
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
        guard let monitor = eventMonitor else {
            mbkLog("PopoverController", "stopEventMonitor -- nothing to stop")
            return
        }
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

// MARK: - NSPopoverDelegate

extension MBKPopoverController: NSPopoverDelegate {
    public func popoverWillShow(_ notification: Notification) {
        mbkLog("PopoverController", "popoverWillShow -- START")
        setButtonHighlight(true)
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "popoverWillShow -- no hostingWindow (anchor skipped)")
            return
        }
        anchorPoint = NSPoint(x: window.frame.midX, y: window.frame.maxY)
        mbkLog("PopoverController", "popoverWillShow -- anchor=\(anchorPoint!) win=\(window.frame) #\(window.windowNumber) contentSize=(\(popover.contentSize.width),\(popover.contentSize.height))")
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidClose -- START anchorWas=\(String(describing: anchorPoint))")
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        anchorPoint = nil
        let prevActive = overlayGate.hasActiveOverlay
        let prevFile = overlayGate.hasFilePickerOverlay
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset hasActiveOverlay: \(prevActive) -> false hasFilePickerOverlay: \(prevFile) -> false")
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
