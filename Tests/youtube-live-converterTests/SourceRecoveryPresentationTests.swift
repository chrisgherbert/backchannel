import Testing
@testable import youtube_live_converter

struct SourceRecoveryPresentationTests {
    private let url = "https://www.youtube.com/watch?v=abcdefghijk"

    @Test
    func authenticationEvidenceSurvivesFallbackAndGenericError() {
        var recovery = StreamSourceRecovery()
        recovery.launched(tool: "streamlink", browser: "Brave")
        _ = recovery.observe(message: "Browser cookies imported from Brave and attached to Streamlink.", source: "streamlink", sourceURL: url)
        _ = recovery.observe(message: "error: YouTube authentication required (LOGIN_REQUIRED).", source: "streamlink", sourceURL: url)
        #expect(recovery.phase == .switching)
        #expect(recovery.failureTitle == "YouTube rejected Streamlink authentication")
        _ = recovery.observe(message: "error: No playable streams found on this URL", source: "streamlink", sourceURL: url)
        #expect(recovery.failureTitle == "YouTube rejected Streamlink authentication")
        recovery.launched(tool: "yt-dlp", browser: "Brave")
        #expect(recovery.phase == .trying)
        #expect(recovery.sourceToolLabel == "yt-dlp · Fallback")
        #expect(recovery.attemptDetail.contains("Brave"))
        recovery.outputStarted()
        #expect(recovery.phase == .restored)
        #expect(recovery.failureDetail.contains("Browser cookies were loaded"))
        recovery.stopped()
        #expect(recovery.phase == .stopped)
    }

    @Test
    func genericFailureDoesNotClaimAuthenticationWasRequired() {
        var recovery = StreamSourceRecovery()
        _ = recovery.observe(message: "No playable streams found on this URL", source: "streamlink", sourceURL: url)
        #expect(recovery.failureTitle == "Streamlink couldn’t open this source")
        recovery.launched(tool: "yt-dlp", browser: nil)
        recovery.failed(message: "The source is unavailable.")
        #expect(recovery.phase == .failed)
        #expect(recovery.fallbackError == "The source is unavailable.")
        recovery.outputStarted()
        #expect(recovery.phase == .failed)
    }

    @Test
    func signInWithoutImportedCookiesDoesNotClaimCookiesWereLoaded() {
        var recovery = StreamSourceRecovery()
        _ = recovery.observe(message: "LOGIN_REQUIRED", source: "streamlink", sourceURL: url)
        #expect(recovery.failureTitle == "YouTube requires authentication")
        #expect(!recovery.failureDetail.contains("cookies were loaded"))
    }

    @MainActor @Test
    func publishingRequiresAdvancingOutputAndDoesNotMaskLaterErrors() {
        let pipeline = StreamPipeline()
        pipeline.parseStatus(from: "[ffmpeg] out_time_us=0")
        #expect(pipeline.parsedStatus.outputState != "Publishing")
        pipeline.parseStatus(from: "[ffmpeg] out_time_us=1000000")
        #expect(pipeline.parsedStatus.outputState == "Publishing")
        pipeline.parseStatus(from: "[ffmpeg] Error opening output")
        #expect(pipeline.parsedStatus.outputState == "Output Error")
        pipeline.parseStatus(from: "[app] Source stopped")
        #expect(pipeline.parsedStatus.outputState == "Output Error")
    }
}
