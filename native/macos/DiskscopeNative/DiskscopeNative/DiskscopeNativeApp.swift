import AppKit
import SwiftUI

final class NativeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var store: NativeScanStore?
    private weak var mainWindow: NSWindow?

    func bind(store: NativeScanStore) {
        self.store = store
    }

    func attachMainWindowIfNeeded() {
        guard mainWindow == nil else {
            return
        }
        guard let window = NSApp.windows.first else {
            return
        }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store?.handleDockReopen()
        attachMainWindowIfNeeded()
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@main
struct DiskscopeNativeApp: App {
    @NSApplicationDelegateAdaptor(NativeAppDelegate.self) private var appDelegate
    @StateObject private var store: NativeScanStore

    init() {
        let launch = NativeLaunchOptions(arguments: CommandLine.arguments)
        _store = StateObject(wrappedValue: NativeScanStore(launch: launch))
    }

    var body: some Scene {
        Window("Diskscope Native", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1200, minHeight: 760)
                .onAppear {
                    appDelegate.bind(store: store)
                    appDelegate.attachMainWindowIfNeeded()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Select Folder…") {
                    store.selectFolderFromDialog()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("Start Scan") {
                    store.startScan()
                }
                .disabled(!store.canStartScan)

                Button("Cancel Scan") {
                    store.cancelScan()
                }
                .disabled(!store.canCancelScan)

                Button("Rescan") {
                    store.rescan()
                }
                .disabled(!store.canRescan)

                Divider()

                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            CommandGroup(before: .toolbar) {
                Button("Show Setup") {
                    store.showSetupScreen()
                }

                Button("Show Results") {
                    store.showResultsScreenIfAvailable()
                }
                .disabled(!store.canShowResultsScreen)

                Divider()

                Button("Reset Zoom") {
                    store.resetZoom()
                }
                .disabled(!store.canResetZoom)
            }
        }
    }
}
