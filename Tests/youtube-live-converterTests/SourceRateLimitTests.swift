import Testing
@testable import youtube_live_converter

@MainActor
struct SourceRateLimitTests {
    @Test(arguments: [true, false])
    func streamlinkRateLimitSurvivesSplitLogChunks(logMonitoring: Bool) {
        let pipeline = StreamPipeline()
        pipeline.setLogMonitoringEnabled(logMonitoring)
        pipeline.ingestLogChunk("error: Unable to open URL (429 Client", source: "streamlink", key: "test")
        #expect(pipeline.status == "Idle")
        pipeline.ingestLogChunk(" Error: Too Many Requests)\nadditional source output\n", source: "streamlink", key: "test")

        #expect(!pipeline.isRunning)
        #expect(pipeline.status == "Source Rate Limited (429)")
        #expect(pipeline.parsedStatus.sourceState == "Rate Limited (429)")
        #expect(pipeline.parsedStatus.reconnectDelay == "None")
        #expect(pipeline.parsedStatus.lastError.contains("Automatic retries stopped"))
        #expect(pipeline.logLines.contains { $0.contains("Automatic retries stopped") })
        #expect(!pipeline.logLines.contains { $0.contains("additional source output") })
    }

    @Test
    func ytDlpRateLimitIsAlsoHandled() {
        let pipeline = StreamPipeline()
        pipeline.ingestLogChunk("ERROR: HTTP Error 429: Too Many Requests\n", source: "yt-dlp", key: "test")
        #expect(pipeline.status == "Source Rate Limited (429)")
    }

    @Test
    func otherErrorsAndFrameCountsDoNotStopThePipeline() {
        let pipeline = StreamPipeline()
        pipeline.ingestLogChunk("error: HTTP Error 403: Forbidden\n", source: "streamlink", key: "source")
        pipeline.ingestLogChunk("frame=429 fps=30\n", source: "ffmpeg", key: "output")
        #expect(pipeline.status == "Idle")
    }
}
