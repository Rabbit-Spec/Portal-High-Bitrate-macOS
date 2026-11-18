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
        if args.count >= 3 && args[1] == "--export-appicon" {
            do {
                try AppIconRenderer.exportAppIconPNG(to: args[2], pixelSize: 1024, isDark: false)
                exit(0)
            } catch {
                fputs("Failed to export appicon: \(error)\n", stderr)
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
    private var sleepObservers: [NSObjectProtocol] = []
    private var wakeResumeWorkItem: DispatchWorkItem?
    private var isSystemAsleep: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        PortalAppIconManager.shared.startObservingSystemAppearance()
        let wsCenter = NSWorkspace.shared.notificationCenter

        let sleepObserver = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillSleep()
            }
        }

        let powerOffObserver = wsCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillSleep()
            }
        }

        let wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidWake()
            }
        }

        sleepObservers = [sleepObserver, powerOffObserver, wakeObserver]
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepObservers.removeAll()
        wakeResumeWorkItem?.cancel()
        wakeResumeWorkItem = nil
        PortalRelayManager.shared.stopRelaySynchronouslyForTermination()
    }

    private func handleWillSleep() {
        wakeResumeWorkItem?.cancel()
        wakeResumeWorkItem = nil
        guard !isSystemAsleep else { return }
        isSystemAsleep = true
        PortalRelayManager.shared.handleWillSleep()
    }

    private func handleDidWake() {
        isSystemAsleep = false
        wakeResumeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isSystemAsleep else { return }
                PortalRelayManager.shared.resumeFromWake()
            }
        }
        wakeResumeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}
