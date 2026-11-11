import SwiftUI
import AppKit

@main
struct PortalHighBitrateApp: App {
    @NSApplicationDelegateAdaptor(PortalAppDelegate.self) private var appDelegate
    @StateObject private var navState = AppNavigationState.shared

    init() {
        let args = CommandLine.arguments
        if args.count >= 3 && args[1] == "--generate-icons" {
            do {
                try AppIconRenderer.generateIconset(at: args[2])
                exit(0)
            } catch {
                fputs("Failed to generate iconset: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            PortalMainView(selectedTab: $navState.selectedTab)
                .frame(minWidth: 1200, minHeight: 822)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 822)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Portal-High-Bitrate") {
                    navState.selectedTab = .about
                }
            }
        }
    }
}

@MainActor
final class AppNavigationState: ObservableObject {
    static let shared = AppNavigationState()
    @Published var selectedTab: AppTab = .booster
}

@MainActor
final class PortalAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        PortalRelayManager.shared.stopRelay()
    }
}
