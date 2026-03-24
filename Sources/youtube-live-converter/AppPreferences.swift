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
    static let managedSupportSetupDismissedVersion = "managed_support_setup_dismissed_version"
    static let automaticUpdateChecksEnabled = "automatic_update_checks_enabled"
    static let skippedUpdateVersion = "skipped_update_version"
    static let lastUpdateCheckTimeInterval = "last_update_check_time_interval"
    static let downloadAuthenticationMode = "download_authentication_mode"
    static let browserCookiesSource = "browser_cookies_source"
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum DownloadAuthenticationMode: String, CaseIterable, Identifiable {
    case none = "none"
    case browserCookies = "browser_cookies"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "None"
        case .browserCookies:
            return "Use Browser Cookies"
        }
    }
}

enum BrowserCookiesSource: String, CaseIterable, Identifiable {
    case firefox
    case chrome
    case brave
    case edge
    case safari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firefox:
            return "Firefox"
        case .chrome:
            return "Chrome"
        case .brave:
            return "Brave"
        case .edge:
            return "Edge"
        case .safari:
            return "Safari"
        }
    }

    var ytDLPValue: String { rawValue }
}

enum DownloadAuthenticationCopy {
    static let helpText = "Use yt-dlp’s browser cookie import to access an existing signed-in session when needed. Back Channel does not display or store cookie values."
}

struct DownloadAuthenticationSettings: Equatable {
    var mode: DownloadAuthenticationMode
    var browserSource: BrowserCookiesSource

    static let defaultBrowserSource: BrowserCookiesSource = .safari

    static func load(from defaults: UserDefaults = .standard) -> DownloadAuthenticationSettings {
        let modeRaw = defaults.string(forKey: AppPreferenceKeys.downloadAuthenticationMode) ?? DownloadAuthenticationMode.none.rawValue
        let browserRaw = defaults.string(forKey: AppPreferenceKeys.browserCookiesSource) ?? defaultBrowserSource.rawValue

        return DownloadAuthenticationSettings(
            mode: DownloadAuthenticationMode(rawValue: modeRaw) ?? .none,
            browserSource: BrowserCookiesSource(rawValue: browserRaw) ?? defaultBrowserSource
        )
    }

    var ytDLPArguments: [String] {
        switch mode {
        case .none:
            return []
        case .browserCookies:
            return ["--cookies-from-browser", browserSource.ytDLPValue]
        }
    }
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
