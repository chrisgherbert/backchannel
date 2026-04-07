import Testing
@testable import youtube_live_converter

struct FFmpegLibraryBridgeTests {
    @Test
    func ffmpegLibraryBridgeInitializesNetworkStackWhenAvailable() {
        #if canImport(CFFmpeg)
        #expect(FFmpegLibraryBridge.networkInitSucceeded())
        #expect(FFmpegLibraryBridge.runtimeVersionSummary().contains("libavutil"))
        FFmpegLibraryBridge.networkDeinit()
        #else
        #expect(FFmpegLibraryBridge.runtimeVersionSummary() == "libavformat bridge unavailable")
        #endif
    }
}
