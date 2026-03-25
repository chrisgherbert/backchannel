import AppKit
import Foundation

struct GitHubAppReleaseAsset: Codable, Equatable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubAppReleaseResponse: Codable {
    let tagName: String
    let name: String?
    let body: String
    let htmlURL: String
    let publishedAt: String?
    let assets: [GitHubAppReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

struct AppReleaseInfo: Identifiable, Equatable {
    let version: String
    let tagName: String
    let displayName: String
    let notes: String
    let pageURL: URL
    let publishedAt: Date?
    let archiveAssetName: String
    let archiveURL: URL
    let checksumAssetName: String
    let checksumURL: URL

    var id: String { version }
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case failed
}

enum AppUpdaterError: LocalizedError {
    case latestReleaseMissingAsset
    case invalidReleaseURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .latestReleaseMissingAsset:
            return "The latest GitHub release is missing the app update asset or checksum."
        case .invalidReleaseURL:
            return "The latest GitHub release contains an invalid download URL."
        case .http(let statusCode):
            return "Update check failed with HTTP \(statusCode)."
        }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var currentVersion: String
    @Published private(set) var latestRelease: AppReleaseInfo?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var activityMessage = ""
    @Published private(set) var lastError = ""
    @Published var shouldPresentUpdateSheet = false

    private let session: URLSession
    private let bundle: Bundle
    private let checkInterval: TimeInterval = 60 * 60 * 24
    private let appArchivePrefix = "Back-Channel-macOS-v"
    private var automaticCheckTask: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        self.currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)

        if let storedInterval = UserDefaults.standard.object(forKey: AppPreferenceKeys.lastUpdateCheckTimeInterval) as? Double,
           storedInterval > 0 {
            self.lastCheckedAt = Date(timeIntervalSince1970: storedInterval)
        }
    }

    var automaticChecksEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: AppPreferenceKeys.automaticUpdateChecksEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: AppPreferenceKeys.automaticUpdateChecksEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppPreferenceKeys.automaticUpdateChecksEnabled)
        }
    }

    var skippedVersion: String {
        get { UserDefaults.standard.string(forKey: AppPreferenceKeys.skippedUpdateVersion) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: AppPreferenceKeys.skippedUpdateVersion) }
    }

    var isBusy: Bool {
        state == .checking
    }

    var canCheckForUpdates: Bool {
        state != .checking
    }

    var canDownloadUpdate: Bool {
        latestRelease != nil && state != .checking
    }

    var statusSummary: String {
        switch state {
        case .idle:
            return "No update check has run yet."
        case .checking:
            return activityMessage.isEmpty ? "Checking GitHub Releases..." : activityMessage
        case .upToDate:
            return "Back Channel is up to date."
        case .updateAvailable:
            if let latestRelease {
                return "Version \(latestRelease.version) is available. Installation is manual."
            }
            return "An update is available."
        case .failed:
            return lastError.isEmpty ? "Update check failed." : lastError
        }
    }

    var manualInstallMessage: String {
        "Back Channel can check for updates and open the latest release in your browser. Installation is manual."
    }

    func scheduleAutomaticCheck() {
        guard automaticChecksEnabled else { return }
        guard shouldRunAutomaticCheck else { return }

        automaticCheckTask?.cancel()
        automaticCheckTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await checkForUpdates(userInitiated: false)
        }
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard canCheckForUpdates else { return }
        state = .checking
        activityMessage = "Checking GitHub Releases..."
        if userInitiated {
            lastError = ""
        }

        do {
            let release = try await Self.fetchLatestRelease(using: session, matchingPrefix: appArchivePrefix)
            let now = Date()
            lastCheckedAt = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: AppPreferenceKeys.lastUpdateCheckTimeInterval)

            latestRelease = release
            if Self.isVersion(release.version, newerThan: currentVersion) {
                state = .updateAvailable
                activityMessage = "Version \(release.version) is available."
                if userInitiated || skippedVersion != release.version {
                    shouldPresentUpdateSheet = true
                }
            } else {
                state = .upToDate
                activityMessage = "Back Channel is up to date."
                if userInitiated {
                    shouldPresentUpdateSheet = true
                }
            }
        } catch {
            if userInitiated {
                lastError = error.localizedDescription
                state = .failed
                activityMessage = "Update check failed."
                shouldPresentUpdateSheet = true
            } else {
                activityMessage = ""
                state = .idle
            }
        }
    }

    func skipAvailableUpdate() {
        if let latestRelease {
            skippedVersion = latestRelease.version
        }
        shouldPresentUpdateSheet = false
    }

    func openReleasePage() {
        guard let url = latestRelease?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openLatestDownloadInBrowser() {
        guard let url = latestRelease?.archiveURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var shouldRunAutomaticCheck: Bool {
        guard let lastCheckedAt else { return true }
        return Date().timeIntervalSince(lastCheckedAt) >= checkInterval
    }

    private static func fetchLatestRelease(using session: URLSession, matchingPrefix prefix: String) async throws -> AppReleaseInfo {
        var request = URLRequest(url: ExternalSupportConfiguration.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BackChannel/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubAppReleaseResponse.self, from: data)

        guard let pageURL = URL(string: release.htmlURL) else {
            throw AppUpdaterError.invalidReleaseURL
        }

        let archiveAsset = release.assets.first(where: { asset in
            asset.name.hasPrefix(prefix) && asset.name.hasSuffix(".zip") && !asset.name.hasSuffix(".zip.sha256")
        })
        guard let archiveAsset else {
            throw AppUpdaterError.latestReleaseMissingAsset
        }

        let checksumAssetName = archiveAsset.name + ".sha256"
        guard let checksumAsset = release.assets.first(where: { $0.name == checksumAssetName }) else {
            throw AppUpdaterError.latestReleaseMissingAsset
        }

        guard let archiveURL = URL(string: archiveAsset.browserDownloadURL),
              let checksumURL = URL(string: checksumAsset.browserDownloadURL) else {
            throw AppUpdaterError.invalidReleaseURL
        }

        let trimmedTag = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let publishedAt: Date?
        if let publishedRaw = release.publishedAt {
            publishedAt = ISO8601DateFormatter().date(from: publishedRaw)
        } else {
            publishedAt = nil
        }

        return AppReleaseInfo(
            version: trimmedTag,
            tagName: release.tagName,
            displayName: release.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? release.name! : release.tagName,
            notes: release.body,
            pageURL: pageURL,
            publishedAt: publishedAt,
            archiveAssetName: archiveAsset.name,
            archiveURL: archiveURL,
            checksumAssetName: checksumAsset.name,
            checksumURL: checksumURL
        )
    }

    private static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdaterError.http(http.statusCode)
        }
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        compareVersions(lhs, rhs) == .orderedDescending
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = normalizedVersionParts(lhs)
        let rhsParts = normalizedVersionParts(rhs)
        let maxCount = max(lhsParts.count, rhsParts.count)

        for index in 0..<maxCount {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }

        return .orderedSame
    }

    private static func normalizedVersionParts(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { component in
                Int(component.prefix { $0.isNumber }) ?? 0
            }
    }
}
