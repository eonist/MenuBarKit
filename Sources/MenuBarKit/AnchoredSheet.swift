// AnchoredSheet.swift
// MenuBarKit
//
// PROBLEM:
//   SwiftUI's .sheet() creates a plain borderless NSWindow with no parent.
//   macOS treats it as a peer of the popover window, so:
//     - The sheet hides when the user clicks away from the app.
//     - The popover can be closed by an outside-click while the sheet is open.
//
// SOLUTION:
//   After SwiftUI presents the sheet, walk NSApp.windows to find the new
//   borderless+key window and call addChildWindow(_:ordered:) on the popover
//   window. Once it is a child it follows the popover and stays visible when
//   the popover window loses focus.
//
//   In addition, the modifier sets overlayGate.hasActiveOverlay = true when
//   the sheet opens and false when it closes. MBKPopoverController reads this
//   flag in popoverShouldClose to block dismiss.
//
// WHY TWO ASYNC HOPS:
//   Hop 1 — Task { @MainActor } in onChange:
//     Actor-isolation crossing only. Gets us onto MainActor so we can call
//     @MainActor-isolated code. Does NOT guarantee the NSWindow exists yet.
//
//   Hop 2 — DispatchQueue.main.async inside anchorSheetWindow():
//     Drains one more run-loop turn, by which point SwiftUI has created the
//     sheet NSWindow and NSApp.windows contains it.
//
//   They solve different problems. Collapsing to one hop loses either actor
//   isolation (if only DispatchQueue) or the window (if only Task { @MainActor }).
//
// WHY onChange MAY FIRE TWICE ON FIRST PRESENTATION:
//   SwiftUI performs a double render on first sheet presentation — onChange
//   fires for false→true and may fire again as SwiftUI stabilises its state.
//   addChildWindow(_:ordered:) on an already-child window is a no-op on all
//   tested macOS versions, so the duplicate call is safe. The TARGET
//   IMPLEMENTATION (notification-based) eliminates this by construction since
//   the notification only fires once per window becoming key.
//
// SHEET WINDOW DISCRIMINATOR — why .borderless && isKeyWindow:
//   The sheet window is matched by: not the popover window, borderless styleMask,
//   and isKeyWindow at the moment Hop 2 fires.
//
//   An earlier version used `contentViewController is NSHostingController<AnyView>`
//   as a stronger discriminator, but SwiftUI's internal sheet window does NOT use
//   that exact generic specialisation — the check never matched in practice and
//   was reverted. Do not re-attempt this without first verifying the concrete
//   NSHostingController generic type SwiftUI uses for sheet windows on the
//   target OS version.
//
//   isKeyWindow is the most reliable signal available at the moment the sheet
//   is presented — SwiftUI makes the sheet window key immediately on creation.
//   Known fragility: other transient borderless windows (OS animations, fast
//   NSOpenPanel re-open) may be key at the same moment. Both races are
//   eliminated by the TARGET IMPLEMENTATION below.
//
// DISMISS-SAFETY GAP — gate clears before child-window teardown completes:
//   The false path in onChange clears overlayGate.hasActiveOverlay = false
//   synchronously, before SwiftUI has finished animating the sheet out and
//   before the child-window relationship is removed by AppKit. If
//   popoverShouldClose fires in this window (e.g. from a pending outside-click
//   Task), the gate is already false and the popover closes while the sheet is
//   still visible and animating out.
//
//   This is a known spike limitation — it is the same fundamental race that
//   the TARGET IMPLEMENTATION (NSWindow.didBecomeKeyNotification) resolves,
//   because notification-based tracking ties the gate lifetime to the actual
//   window lifecycle rather than to SwiftUI's binding state. Do not paper over
//   this with an artificial delay; fix it properly during the migration PR.
//
//   Both the isPresented and item variants share this gap. They will be fixed
//   together when the TARGET IMPLEMENTATION lands.
//
// TARGET IMPLEMENTATION (deferred — see notes):
//   Replace Hop 2 with NSWindow.didBecomeKeyNotification observation:
//
//   @MainActor
//   private func waitForSheetWindow(excluding popoverWindow: NSWindow) async -> NSWindow? {
//       await withCheckedContinuation { continuation in
//           var observer: NSObjectProtocol?
//           observer = NotificationCenter.default.addObserver(
//               forName: NSWindow.didBecomeKeyNotification,
//               object: nil, queue: .main
//           ) { notification in
//               guard
//                   let window = notification.object as? NSWindow,
//                   window !== popoverWindow,
//                   window.styleMask.contains(.borderless)
//               else { return }
//               NotificationCenter.default.removeObserver(observer!)
//               continuation.resume(returning: window)
//           }
//       }
//   }
//
//   Deferred because withCheckedContinuation leaks if the sheet is dismissed
//   before its NSWindow ever becomes key. Needs a cancellation path before
//   this enters production. Implement with the migration PR.
//
// MIGRATION NOTE:
//   The DispatchQueue.main.async mixes GCD with Swift concurrency and bypasses
//   actor checking. It must be replaced with the NSWindow.didBecomeKeyNotification
//   approach above before this code enters the main app.
//
// WHY Item: Identifiable & Equatable (not just Identifiable):
//   onChange(of:) requires the observed value to conform to Equatable so SwiftUI
//   can diff old vs new values. Optional<Item> conditionally conforms to Equatable
//   only when Item itself is Equatable. Without this constraint the compiler
//   rejects .onChange(of: item) with "requires that 'Item' conform to 'Equatable'".
//   SwiftUI's own .sheet(item:) only requires Identifiable — but that modifier
//   does not need to diff values, it only needs to know whether item is nil.
//   MBKAnchoredSheetItemModifier uses onChange to observe the full item so it
//   can re-anchor on non-nil→non-nil identity swaps, which requires Equatable.

import AppKit
import SwiftUI

/// View extension providing `mbkSheet` modifiers for popover-anchored sheet presentation.
public extension View {

    /// Presents a sheet anchored as a child of the popover window so it
    /// survives outside-clicks and stays visible when the popover loses focus.
    ///
    /// Also manages `overlayGate.hasActiveOverlay` automatically — the host
    /// view does not need to touch the gate directly.
    func mbkSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        overlayGate: MBKOverlayGate,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetModifier(
            isPresented: isPresented,
            overlayGate: overlayGate,
            sheetContent: content
        ))
    }

    /// Presents a sheet anchored as a child of the popover window, driven by
    /// an optional item binding — matching SwiftUI's `.sheet(item:)` API shape.
    ///
    /// The sheet is presented when `item` becomes non-nil and dismissed when it
    /// returns to nil. `overlayGate.hasActiveOverlay` is managed automatically
    /// for the full sheet lifetime — the host view does not need to call
    /// `mbkSetOverlay()` directly.
    ///
    /// `Item` must conform to both `Identifiable` and `Equatable`. The `Equatable`
    /// requirement is imposed by `onChange(of: item)` — see WHY Item: Identifiable
    /// & Equatable in the file header.
    ///
    /// If `item` changes from one non-nil value to a different non-nil value,
    /// `onChange(of: item)` fires, `anchorSheetWindow()` is called again for
    /// the incoming sheet, and the gate stays armed continuously. This is safe
    /// because `addChildWindow(_:ordered:)` on an already-child window is a
    /// no-op. Standard SwiftUI `.sheet(item:)` callers nil the item before
    /// re-assigning, so this path is defensive rather than commonly exercised.
    ///
    /// Same anchoring and dismiss-safety characteristics as the `isPresented`
    /// variant — see DISMISS-SAFETY GAP in the file header.
    func mbkSheet<Item: Identifiable & Equatable, SheetContent: View>(
        item: Binding<Item?>,
        overlayGate: MBKOverlayGate,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetItemModifier(
            item: item,
            overlayGate: overlayGate,
            sheetContent: content
        ))
    }
}

// MARK: - isPresented variant

/// ViewModifier that anchors a SwiftUI sheet as a child window of the popover
/// and manages the `MBKOverlayGate` for the sheet's lifetime.
public struct MBKAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    /// Whether the sheet is currently presented.
    @Binding public var isPresented: Bool
    /// The shared overlay gate that blocks popover dismiss while the sheet is live.
    public let overlayGate: MBKOverlayGate
    /// Closure that produces the sheet's content view.
    public let sheetContent: () -> SheetContent

    /// Applies the sheet presentation and anchoring logic to the wrapped view.
    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                // Set the dismiss gate synchronously — before the window
                // lookup so popoverShouldClose sees the flag immediately.
                // NOTE: the false path clears the gate before teardown completes
                // — see DISMISS-SAFETY GAP in the file header.
                overlayGate.hasActiveOverlay = newValue
                if newValue {
                    // Hop 1: actor-isolation crossing only (see WHY TWO ASYNC HOPS).
                    Task { @MainActor in anchorSheetWindow() }
                }
                // NOTE: onChange may fire twice on first presentation due to
                // SwiftUI's double render. See WHY onChange MAY FIRE TWICE in
                // the file header. The second addChildWindow call is a no-op.
            }
    }

    /// Finds the sheet NSWindow and wires it as a child of the popover window.
    @MainActor
    private func anchorSheetWindow() {
        // Single-instance assumption: picks the first .nonactivatingPanel window.
        // If the host app creates two MBKPopoverController instances (two status
        // items), this may resolve the wrong popover window. See FilePicker.swift
        // for the same note. Fine for the current single-popover use case.
        guard let popoverWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            mbkLog("AnchoredSheet", "no nonactivatingPanel window — sheet will not be anchored")
            return
        }
        // Hop 2: drain one run-loop turn so the sheet NSWindow exists.
        // ⚠️ SPIKE ONLY — replace with NSWindow.didBecomeKeyNotification before migrating.
        // See SHEET WINDOW DISCRIMINATOR in the file header before strengthening the predicate.
        #warning("SPIKE ONLY: replace DispatchQueue.main.async with NSWindow.didBecomeKeyNotification — see DISMISS-SAFETY GAP and TARGET IMPLEMENTATION in file header")
        DispatchQueue.main.async {
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== popoverWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                mbkLog("AnchoredSheet", "addChildWindow")
                popoverWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                mbkLog("AnchoredSheet", "no borderless+key window found")
            }
        }
    }
}

// MARK: - item variant

/// ViewModifier that anchors a SwiftUI `.sheet(item:)` as a child window of the
/// popover and manages `MBKOverlayGate` for the sheet's lifetime.
///
/// `Item` must conform to `Identifiable & Equatable`. The `Equatable` requirement
/// is imposed by `onChange(of: item)` — see WHY Item: Identifiable & Equatable
/// in the file header.
///
/// Uses `onChange(of: item)` rather than `onChange(of: item != nil)` so that
/// gate management and anchoring fire on *every* item identity change, including
/// non-nil → non-nil swaps. A Bool-derived predicate would stay true→true on
/// such a swap, silently skipping `anchorSheetWindow()` and leaving the incoming
/// sheet un-anchored. Observing `item` directly is correct regardless of whether
/// callers nil-before-reassign (the standard SwiftUI pattern) or swap directly.
///
/// Same two-hop anchoring strategy and DISMISS-SAFETY GAP as
/// `MBKAnchoredSheetModifier` — see the file header for full rationale.
/// Both gaps are fixed together when the TARGET IMPLEMENTATION lands.
public struct MBKAnchoredSheetItemModifier<Item: Identifiable & Equatable, SheetContent: View>: ViewModifier {
    /// The item driving presentation. Non-nil = sheet shown; nil = sheet dismissed.
    @Binding public var item: Item?
    /// The shared overlay gate that blocks popover dismiss while the sheet is live.
    public let overlayGate: MBKOverlayGate
    /// Closure that produces the sheet's content view for a given item.
    public let sheetContent: (Item) -> SheetContent

    /// Applies the sheet presentation and anchoring logic to the wrapped view.
    public func body(content: Content) -> some View {
        content
            .sheet(item: $item, content: sheetContent)
            // onChange(of: item) — NOT onChange(of: item != nil):
            // Observing the full item fires on every identity change, including
            // non-nil→non-nil swaps. A Bool predicate would evaluate true→true
            // on a swap, onChange would not fire, and the incoming sheet would
            // open un-anchored with the gate not re-armed.
            // Equatable is required by onChange — see file header.
            .onChange(of: item) { _, newValue in
                let isPresented = newValue != nil
                // Gate management mirrors MBKAnchoredSheetModifier exactly.
                // See DISMISS-SAFETY GAP in the file header — the false path
                // clears the gate before AppKit finishes tearing down the sheet
                // window. Fixed together with the isPresented variant.
                overlayGate.hasActiveOverlay = isPresented
                if isPresented {
                    Task { @MainActor in anchorSheetWindow() }
                }
            }
    }

    /// Finds the sheet NSWindow and wires it as a child of the popover window.
    @MainActor
    private func anchorSheetWindow() {
        // Single-instance assumption: same as isPresented variant above.
        guard let popoverWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            mbkLog("AnchoredSheet[item]", "no nonactivatingPanel window — sheet will not be anchored")
            return
        }
        #warning("SPIKE ONLY: replace DispatchQueue.main.async with NSWindow.didBecomeKeyNotification — see DISMISS-SAFETY GAP and TARGET IMPLEMENTATION in file header")
        DispatchQueue.main.async {
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== popoverWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                mbkLog("AnchoredSheet[item]", "addChildWindow")
                popoverWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                mbkLog("AnchoredSheet[item]", "no borderless+key window found")
            }
        }
    }
}
