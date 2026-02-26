import SwiftUI
import AppKit

@main
struct YouTubeLiveConverterApp: App {
    @StateObject private var pipeline = StreamPipeline()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(pipeline: pipeline)
                .frame(minWidth: 1080, minHeight: 700)
                .onAppear {
                    appDelegate.pipeline = pipeline
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pipeline: StreamPipeline?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
            pipeline.stop()
            return .terminateNow
        }
        return .terminateCancel
    }
}
