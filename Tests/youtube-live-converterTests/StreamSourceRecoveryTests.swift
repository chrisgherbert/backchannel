import Testing
@testable import youtube_live_converter

struct StreamSourceRecoveryTests {
    @Test
    func unavailableYouTubeStreamFallsBackOnlyOncePerSession() {
        var recovery = StreamSourceRecovery()
        let message = "error: No playable streams found on this URL: https://www.youtube.com/watch?v=iipR5yUp36o"
        let url = "https://www.youtube.com/watch?v=iipR5yUp36o"
        let result1 = recovery.observe(message: message, source: "streamlink", sourceURL: url)
        #expect(result1)
        #expect(recovery.usesYtDlp)
        let result2 = !recovery.observe(message: message, source: "streamlink", sourceURL: url)
        #expect(result2)
        #expect(!StreamSourceRecovery().usesYtDlp)
    }

    @Test
    func botChallengeCanTriggerFallback() {
        var recovery = StreamSourceRecovery()
        let result3 = recovery.observe(message: "LOGIN_REQUIRED: Sign in to confirm you’re not a bot", source: "streamlink", sourceURL: "https://youtu.be/iipR5yUp36o")
        #expect(result3)
    }

    @Test(arguments: ["https://twitch.tv/example", "https://youtube.com.example.org/watch?v=example", "invalid"])
    func unrelatedSourcesDoNotSwitch(sourceURL: String) {
        var recovery = StreamSourceRecovery()
        let result4 = !recovery.observe(message: "No playable streams found on this URL", source: "streamlink", sourceURL: sourceURL)
        #expect(result4)
        #expect(!recovery.usesYtDlp)
    }

    @Test
    func rateLimitAndYtDlpErrorsDoNotTriggerAnotherExtractorAttempt() {
        var recovery = StreamSourceRecovery()
        let url = "https://www.youtube.com/watch?v=iipR5yUp36o"
        let result5 = !recovery.observe(message: "429 Client Error: Too Many Requests", source: "streamlink", sourceURL: url)
        #expect(result5)
        let result6 = !recovery.observe(message: "No playable streams found on this URL", source: "yt-dlp", sourceURL: url)
        #expect(result6)
        #expect(!recovery.usesYtDlp)
    }
}
