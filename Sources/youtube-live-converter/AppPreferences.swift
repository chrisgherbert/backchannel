import Foundation

enum AppPreferenceKeys {
    static let rtmpPresetsJSON = "rtmp_presets_json"
    static let sourcePresetsJSON = "source_presets_json"
    static let defaultEncodeMode = "default_encode_mode"
    static let defaultBufferSeconds = "default_buffer_seconds"
    static let defaultUseDiskBackedBuffer = "default_use_disk_backed_buffer"
    static let defaultAVSyncOffsetMs = "default_av_sync_offset_ms"
    static let defaultAudioBoostEnabled = "default_audio_boost_enabled"
    static let defaultAudioBoostDb = "default_audio_boost_db"
    static let defaultAudioContinuityEnabled = "default_audio_continuity_enabled"
    static let defaultLogMonitoringEnabled = "log_monitoring_enabled"
    static let runtimeLogMonitoringEnabled = "runtime_log_monitoring_enabled"
    static let appearanceMode = "appearance_mode"
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

struct RtmpPreset: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var serverURL: String
    var streamKey: String
    var fullURLOverride: String
}

struct SourcePreset: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
}

enum AppPreferencesCodec {
    static func decodePresets(from json: String) -> [RtmpPreset] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RtmpPreset].self, from: data)) ?? []
    }

    static func encodePresets(_ presets: [RtmpPreset]) -> String {
        guard let data = try? JSONEncoder().encode(presets),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    static func decodeSourcePresets(from json: String) -> [SourcePreset] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SourcePreset].self, from: data)) ?? []
    }

    static func encodeSourcePresets(_ presets: [SourcePreset]) -> String {
        guard let data = try? JSONEncoder().encode(presets),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
