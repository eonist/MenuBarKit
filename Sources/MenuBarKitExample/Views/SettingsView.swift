// SettingsView.swift
// MenuBarKitExample

import AppKit
import MenuBarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var showSheet = false

    // Captured once on appear — avoids querying NSScreen.main on every render.
    @State private var scrollMaxHeight: CGFloat = (NSScreen.main?.visibleFrame.height ?? 800) * 0.80

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if appState.settingsItems.isEmpty {
                        Text("Loading runners…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(appState.settingsItems, id: \.self) { item in
                            HStack {
                                Image(systemName: "server.rack").foregroundStyle(.blue)
                                Text(item).font(.caption)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden) // ← nuke grey ScrollView bg
            .background(.clear)               // ← belt-and-braces
            .frame(maxHeight: scrollMaxHeight)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button("Open sheet") { showSheet = true }
                    .mbkSheet(isPresented: $showSheet, overlayGate: overlayGate) {
                        SheetView()
                            .environment(appState)
                            .environment(overlayGate)
                    }

                Button("Pick folder (popover)") {
                    mbkOpenFilePicker(target: .popover, overlayGate: overlayGate) { url in
                        appState.pickedURL = url
                    }
                }
                if let url = appState.pickedURL {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }

                // GroupBox removed — it paints an opaque grouped background
                // that blocks liquid glass refraction. Replaced with plain VStack.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alert from popover")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Show alert") { appState.showAlert = true }
                    Text("Alert should appear. Popover stays alive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .mbkAlert("Test Alert", isPresented: $appState.showAlert, overlayGate: overlayGate) {
                    Button("OK", role: .cancel) { appState.showAlert = false }
                } message: {
                    Text("Popover must stay open.")
                }

                Button("← Back") { appState.route = .main }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.clear) // ← nuke root VStack default opaque bg
        .frame(width: 320)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            print("[SettingsView] onAppear")
            guard appState.settingsItems.isEmpty else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                appState.settingsItems = [
                    "runner-mac-01 (idle)",
                    "runner-mac-02 (busy)",
                    "runner-linux-01 (idle)",
                    "runner-linux-02 (idle)",
                    "runner-linux-03 (busy)",
                ]
            }
        }
    }
}
