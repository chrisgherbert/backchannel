import Foundation

enum OutputType: String, CaseIterable, Identifiable {
    case rtmp = "RTMP"
    case hls = "HLS"

    var id: String { rawValue }
}

enum EncodeMode: String, CaseIterable, Identifiable {
    case copy = "Stream Copy"
    case transcode = "High Compatibility"

    var id: String { rawValue }
}

struct StreamConfig {
    var sourceURL: String = ""
    var outputTarget: String = ""
    var hlsPlaylistPath: String = ""
    var rtmpServerURL: String = ""
    var rtmpStreamKey: String = ""
    var rtmpFullURLOverride: String = ""
    var outputType: OutputType = .rtmp
    var encodeMode: EncodeMode = .transcode
    var bufferSeconds: Int = 30
    var useDiskBackedBuffer: Bool = true
    var autoAVSync: Bool = true
    var avSyncOffsetMs: Int = 0
    var audioBoostEnabled: Bool = false
    var audioBoostDb: Int = 0
    var audioContinuityEnabled: Bool = true

    func resolvedOutputTarget() -> String {
        switch outputType {
        case .hls:
            return hlsPlaylistPath.trimmingCharacters(in: .whitespacesAndNewlines)
        case .rtmp:
            let explicitTarget = rtmpFullURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !explicitTarget.isEmpty {
                return explicitTarget
            }

            let server = rtmpServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rtmpStreamKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !server.isEmpty, !key.isEmpty else { return "" }

            let normalizedServer = server.hasSuffix("/") ? server : server + "/"
            return normalizedServer + key
        }
    }
}

struct ParsedStatus {
    var sourceState = "Idle"
    var outputState = "Idle"
    var lastAppEvent = "No activity yet"
    var lastFFmpegEvent = "No activity yet"
    var lastYtDlpEvent = "No activity yet"
    var lastError = ""
    var reconnectDelay = ""
    var ffmpegTime = ""
    var ffmpegBitrate = ""
    var ffmpegSpeed = ""
    var bufferState = "Off"
    var bufferProgress: Double = 0
    var avSyncState = "Auto"
}

struct StreamPreview {
    var title: String
    var descriptionExcerpt: String
    var thumbnailURL: URL?
    var publishState: PublishState
    var scheduledStartLabel: String
    var resolutionLabel: String
    var frameRateLabel: String
    var bitrateLabel: String
    var codecLabel: String
}

enum PublishState: String {
    case live = "LIVE"
    case upcoming = "UPCOMING"
    case published = "PUBLISHED"
    case unknown = "UNKNOWN"
}
