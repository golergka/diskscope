import SwiftUI

@main
struct DiskscopeNativeApp: App {
    @StateObject private var store: NativeScanStore

    init() {
        let launch = NativeLaunchOptions(arguments: CommandLine.arguments)
        _store = StateObject(wrappedValue: NativeScanStore(launch: launch))
    }

    var body: some Scene {
        WindowGroup("Diskscope Native") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1200, minHeight: 760)
        }
    }
}
