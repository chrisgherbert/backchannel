import Foundation

#if canImport(CFFmpeg)
import CFFmpeg

enum FFmpegLibraryBridge {
    static func runtimeVersionSummary() -> String {
        let avutil = String(cString: av_version_info())
        let avformat = avformat_version()
        let avcodec = avcodec_version()
        return "libavutil \(avutil), avformat 0x\(String(avformat, radix: 16)), avcodec 0x\(String(avcodec, radix: 16))"
    }

    static func networkInitSucceeded() -> Bool {
        avformat_network_init() >= 0
    }

    static func networkDeinit() {
        avformat_network_deinit()
    }
}
#else
enum FFmpegLibraryBridge {
    static func runtimeVersionSummary() -> String {
        "libavformat bridge unavailable"
    }

    static func networkInitSucceeded() -> Bool {
        false
    }

    static func networkDeinit() {}
}
#endif
