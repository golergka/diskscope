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
        let candidate = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
            ?? NSApp.windows.first
        guard let window = candidate else {
            return
        }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
    }

    func applyWindowLayout(for screen: NativeScreen, animated: Bool = true) {
        attachMainWindowIfNeeded()
        guard let window = mainWindow else {
            return
        }

        let targetContentSize: NSSize
        let targetMinSize: NSSize
        switch screen {
        case .setup:
            targetContentSize = NSSize(width: 460, height: 320)
            targetMinSize = NSSize(width: 420, height: 290)
        case .results:
            targetContentSize = NSSize(width: 1200, height: 760)
            targetMinSize = NSSize(width: 1080, height: 680)
        }

        window.contentMinSize = targetMinSize

        let current = window.contentRect(forFrameRect: window.frame).size
        let delta = abs(current.width - targetContentSize.width) + abs(current.height - targetContentSize.height)
        guard delta > 12 else {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().setContentSize(targetContentSize)
            }
        } else {
            window.setContentSize(targetContentSize)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store?.handleDockReopen()
        attachMainWindowIfNeeded()
        if let screen = store?.currentScreen {
            applyWindowLayout(for: screen, animated: false)
        }
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
                .frame(minWidth: 420, minHeight: 290)
                .onAppear {
                    appDelegate.bind(store: store)
                    appDelegate.attachMainWindowIfNeeded()
                    appDelegate.applyWindowLayout(for: store.currentScreen, animated: false)
                    DispatchQueue.main.async {
                        appDelegate.attachMainWindowIfNeeded()
                        appDelegate.applyWindowLayout(for: store.currentScreen, animated: false)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        appDelegate.attachMainWindowIfNeeded()
                        appDelegate.applyWindowLayout(for: store.currentScreen, animated: false)
                    }
                }
                .onChange(of: store.currentScreen) { screen in
                    appDelegate.applyWindowLayout(for: screen)
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
