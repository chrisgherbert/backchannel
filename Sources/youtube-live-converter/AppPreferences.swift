import Foundation

enum AppPreferenceKeys {
    static let rtmpPresetsJSON = "rtmp_presets_json"
    static let defaultEncodeMode = "default_encode_mode"
}

struct RtmpPreset: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var serverURL: String
    var streamKey: String
    var fullURLOverride: String
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
}

