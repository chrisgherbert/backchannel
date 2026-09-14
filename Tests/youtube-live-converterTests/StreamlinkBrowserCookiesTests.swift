import Testing
@testable import youtube_live_converter

struct StreamlinkBrowserCookiesTests {
    @Test(arguments: BrowserCookiesSource.allCases)
    func browserSelectionIsPassedToManagedRuntime(browser: BrowserCookiesSource) {
        let streamArguments = ["--stdout", "https://www.youtube.com/watch?v=HAQ1fCqy84E", "best"]
        let arguments = StreamlinkBrowserCookies.arguments(browser: browser, streamArguments: streamArguments)
        #expect(arguments.prefix(3) == ["-c", StreamlinkBrowserCookies.bootstrap, browser.rawValue])
        #expect(Array(arguments.dropFirst(3)) == streamArguments)
    }

    @Test @MainActor
    func importConfirmationIsVisibleWithMonitoringOff() {
        let pipeline = StreamPipeline()
        pipeline.setLogMonitoringEnabled(false)
        pipeline.ingestLogChunk("Browser cookies imported from Brave and attached to Streamlink.\n", source: "streamlink", key: "test")
        pipeline.stop() // Flush queued UI log lines.
        #expect(pipeline.logLines.contains { $0.contains("Browser cookies imported from Brave") })
    }

    @Test @MainActor
    func cookieImportFailureStopsWithGuidanceEvenWhenMonitoringIsOff() {
        let pipeline = StreamPipeline()
        pipeline.setLogMonitoringEnabled(false)
        pipeline.ingestLogChunk("error: Browser cookie import failed. Open the selected browser and sign in.\n", source: "streamlink", key: "test")
        #expect(!pipeline.isRunning)
        #expect(pipeline.status == "Browser Cookies Unavailable")
        #expect(pipeline.parsedStatus.sourceState == "Cookie Import Failed")
        #expect(pipeline.parsedStatus.reconnectDelay == "None")
        #expect(pipeline.parsedStatus.lastError.contains("Open the selected browser"))
    }
}
