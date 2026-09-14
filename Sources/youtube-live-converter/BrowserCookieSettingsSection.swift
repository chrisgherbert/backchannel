import SwiftUI

struct BrowserCookieSettingsSection: View {
    @AppStorage(AppPreferenceKeys.downloadAuthenticationMode) private var mode = DownloadAuthenticationMode.none.rawValue
    @AppStorage(AppPreferenceKeys.browserCookiesSource) private var browser = DownloadAuthenticationSettings.defaultBrowserSource.rawValue

    var body: some View {
        Section("Browser Cookies") {
            Picker("Authentication", selection: $mode) {
                ForEach(DownloadAuthenticationMode.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            if mode == DownloadAuthenticationMode.browserCookies.rawValue {
                Picker("Browser", selection: $browser) {
                    ForEach(BrowserCookiesSource.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            }
            Text(DownloadAuthenticationCopy.helpText).font(.caption).foregroundStyle(.secondary)
            if mode == DownloadAuthenticationMode.browserCookies.rawValue {
                Text(DownloadAuthenticationCopy.permissionHelpText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BrowserCookieSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form { BrowserCookieSettingsSection() }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 520, height: 340)
    }
}
