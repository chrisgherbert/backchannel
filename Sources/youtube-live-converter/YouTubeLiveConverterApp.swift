import SwiftUI
import AppKit
import Darwin

@main
struct YouTubeLiveConverterApp: App {
    @StateObject private var pipeline = StreamPipeline()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppPreferenceKeys.appearanceMode) private var appearanceModeRaw = AppearanceMode.automatic.rawValue
    private let launchOptions: LaunchOptions

    init() {
        launchOptions = LaunchOptionsParser.parseOrExit(arguments: CommandLine.arguments)
        AppDelegate.installSignalHandlersInThisRun = launchOptions.hasRuntimeOverrides
    }

    var body: some Scene {
        WindowGroup {
            ContentView(pipeline: pipeline, launchOptions: launchOptions)
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    appDelegate.pipeline = pipeline
                }
        }

        Settings {
            SettingsView()
        }
    }

    private var preferredColorScheme: ColorScheme? {
        guard let mode = AppearanceMode(rawValue: appearanceModeRaw) else { return nil }
        switch mode {
        case .automatic:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var installSignalHandlersInThisRun = false
    var pipeline: StreamPipeline?
    private var signalIntSource: DispatchSourceSignal?
    private var signalTermSource: DispatchSourceSignal?
    private var terminateWithoutPrompt = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        if Self.installSignalHandlersInThisRun {
            installSignalHandlers()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminateWithoutPrompt {
            pipeline?.stopForAppTermination()
            return .terminateNow
        }

        guard let pipeline, pipeline.isRunning else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Streaming is in progress"
        alert.informativeText = "Quitting will stop the active stream. Are you sure you want to quit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            pipeline.stopForAppTermination()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        signalIntSource?.cancel()
        signalIntSource = nil
        signalTermSource?.cancel()
        signalTermSource = nil
        pipeline?.stopForAppTermination()
    }

    @objc private func handleWorkspaceWillSleep() {
        pipeline?.handleSystemWillSleep()
    }

    @objc private func handleWorkspaceDidWake() {
        pipeline?.handleSystemDidWake()
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in
            self?.handleTerminationSignal(name: "SIGINT")
        }
        intSource.resume()
        signalIntSource = intSource

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in
            self?.handleTerminationSignal(name: "SIGTERM")
        }
        termSource.resume()
        signalTermSource = termSource
    }

    private func handleTerminationSignal(name: String) {
        terminateWithoutPrompt = true
        fputs("[app] Received \(name). Stopping session and exiting.\n", stderr)
        fflush(stderr)
        NSApplication.shared.terminate(nil)
    }
}
