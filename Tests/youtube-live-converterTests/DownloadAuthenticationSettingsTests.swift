import Foundation
import Testing
@testable import youtube_live_converter

struct DownloadAuthenticationSettingsTests {
    @Test
    func defaultsToNoneWithoutStoredPreferences() {
        let suiteName = "DownloadAuthenticationSettingsTests.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = DownloadAuthenticationSettings.load(from: defaults)

        #expect(settings.mode == .none)
        #expect(settings.browserSource == .safari)
        #expect(settings.ytDLPArguments.isEmpty)
    }

    @Test
    func browserCookiesAddsExpectedArguments() {
        let suiteName = "DownloadAuthenticationSettingsTests.browser.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(DownloadAuthenticationMode.browserCookies.rawValue, forKey: AppPreferenceKeys.downloadAuthenticationMode)
        defaults.set(BrowserCookiesSource.brave.rawValue, forKey: AppPreferenceKeys.browserCookiesSource)

        let settings = DownloadAuthenticationSettings.load(from: defaults)

        #expect(settings.mode == .browserCookies)
        #expect(settings.browserSource == .brave)
        #expect(settings.ytDLPArguments == ["--cookies-from-browser", "brave"])
    }

    @Test
    func invalidStoredValuesFallBackSafely() {
        let suiteName = "DownloadAuthenticationSettingsTests.invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("invalid-mode", forKey: AppPreferenceKeys.downloadAuthenticationMode)
        defaults.set("invalid-browser", forKey: AppPreferenceKeys.browserCookiesSource)

        let settings = DownloadAuthenticationSettings.load(from: defaults)

        #expect(settings.mode == .none)
        #expect(settings.browserSource == .safari)
        #expect(settings.ytDLPArguments.isEmpty)
    }
}
