import AppKit
import CryptoKit
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

struct PreparedAppUpdate: Equatable {
    let release: AppReleaseInfo
    let archiveURL: URL
    let extractedAppURL: URL
    let stagedAt: Date
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case downloading
    case readyToInstall
    case installing
    case failed
}

enum AppUpdaterError: LocalizedError {
    case latestReleaseMissingAsset
    case invalidReleaseURL
    case invalidChecksum
    case stagedAppMissing
    case installNotWritable
    case translocatedApp
    case helperLaunchFailed
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .latestReleaseMissingAsset:
            return "The latest GitHub release is missing the app update asset or checksum."
        case .invalidReleaseURL:
            return "The latest GitHub release contains an invalid download URL."
        case .invalidChecksum:
            return "Downloaded update failed checksum verification."
        case .stagedAppMissing:
            return "The downloaded update could not be prepared for installation."
        case .installNotWritable:
            return "Back Channel does not have permission to replace the current app. Move it to a writable location such as /Applications."
        case .translocatedApp:
            return "Move Back Channel out of its translocated launch path before installing updates. Opening it from /Applications is recommended."
        case .helperLaunchFailed:
            return "Back Channel could not launch the installer helper."
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
    @Published private(set) var preparedUpdate: PreparedAppUpdate?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var activityMessage = ""
    @Published private(set) var lastError = ""
    @Published var shouldPresentUpdateSheet = false

    private let session: URLSession
    private let bundle: Bundle
    private let updateRoot: URL
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

        self.updateRoot = ExternalSupportPaths.applicationSupportRoot()
            .appendingPathComponent("Updates", isDirectory: true)

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

    var canCheckForUpdates: Bool {
        state != .checking && state != .downloading && state != .installing
    }

    var canDownloadUpdate: Bool {
        latestRelease != nil && state != .downloading && state != .installing
    }

    var canInstallPreparedUpdate: Bool {
        preparedUpdate != nil && state == .readyToInstall
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
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
                return "Version \(latestRelease.version) is available."
            }
            return "An update is available."
        case .downloading:
            return activityMessage.isEmpty ? "Downloading update..." : activityMessage
        case .readyToInstall:
            if let preparedUpdate {
                return "Version \(preparedUpdate.release.version) is ready to install."
            }
            return "Update is ready to install."
        case .installing:
            return activityMessage.isEmpty ? "Back Channel is preparing to quit and relaunch." : activityMessage
        case .failed:
            return lastError.isEmpty ? "Update failed." : lastError
        }
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

            if Self.isVersion(release.version, newerThan: currentVersion) {
                latestRelease = release

                if preparedUpdate?.release.version == release.version {
                    state = .readyToInstall
                    activityMessage = "Version \(release.version) is ready to install."
                } else {
                    state = .updateAvailable
                    activityMessage = "Version \(release.version) is available."
                }

                if userInitiated || skippedVersion != release.version {
                    shouldPresentUpdateSheet = true
                }
            } else {
                latestRelease = release
                if preparedUpdate?.release.version == release.version {
                    state = .readyToInstall
                    activityMessage = "Version \(release.version) is ready to install."
                } else {
                    state = .upToDate
                    activityMessage = "Back Channel is up to date."
                }
                if userInitiated {
                    shouldPresentUpdateSheet = true
                }
            }
        } catch {
            if userInitiated {
                lastError = error.localizedDescription
                state = .failed
                activityMessage = "Update check failed."
            } else {
                activityMessage = ""
            }
        }
    }

    func downloadAndPrepareUpdate() async {
        guard let release = latestRelease else { return }
        guard state != .downloading && state != .installing else { return }

        state = .downloading
        activityMessage = "Downloading version \(release.version)..."
        lastError = ""

        do {
            let prepared = try await Self.downloadAndPrepare(release: release, into: updateRoot, using: session)
            preparedUpdate = prepared
            state = .readyToInstall
            activityMessage = "Version \(release.version) is ready to install."
            shouldPresentUpdateSheet = true
        } catch {
            lastError = error.localizedDescription
            state = .failed
            activityMessage = "Download failed."
        }
    }

    func installPreparedUpdate() {
        guard let preparedUpdate else { return }
        do {
            try Self.launchInstaller(for: preparedUpdate.extractedAppURL, replacing: bundle.bundleURL)
            state = .installing
            activityMessage = "Back Channel will quit and relaunch to finish installing version \(preparedUpdate.release.version)."
            NSApplication.shared.terminate(nil)
        } catch {
            lastError = error.localizedDescription
            state = .failed
            activityMessage = "Install failed."
        }
    }

    func skipAvailableUpdate() {
        if let latestRelease {
            skippedVersion = latestRelease.version
        }
        shouldPresentUpdateSheet = false
    }

    func clearPreparedUpdate() {
        preparedUpdate = nil
        if latestRelease != nil {
            state = .updateAvailable
        } else {
            state = .idle
        }
    }

    func openReleasePage() {
        guard let url = latestRelease?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var shouldRunAutomaticCheck: Bool {
        guard latestRelease == nil || preparedUpdate == nil else { return false }
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

    private static func downloadAndPrepare(release: AppReleaseInfo, into updateRoot: URL, using session: URLSession) async throws -> PreparedAppUpdate {
        try FileManager.default.createDirectory(at: updateRoot, withIntermediateDirectories: true)

        let downloadsRoot = updateRoot.appendingPathComponent("downloads", isDirectory: true)
        let stagingRoot = updateRoot.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let archiveURL = downloadsRoot.appendingPathComponent(release.archiveAssetName)
        let checksumURL = downloadsRoot.appendingPathComponent(release.checksumAssetName)
        let stageDirectory = stagingRoot.appendingPathComponent(release.version + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: true)

        let (archiveTempURL, archiveResponse) = try await session.download(from: release.archiveURL)
        try validateHTTPResponse(archiveResponse)
        try? FileManager.default.removeItem(at: archiveURL)
        try FileManager.default.moveItem(at: archiveTempURL, to: archiveURL)

        let (checksumData, checksumResponse) = try await session.data(from: release.checksumURL)
        try validateHTTPResponse(checksumResponse)
        try checksumData.write(to: checksumURL, options: .atomic)

        let expectedChecksum = parseChecksum(from: checksumData)
        let archiveChecksum = try sha256Hex(for: archiveURL)
        guard expectedChecksum.caseInsensitiveCompare(archiveChecksum) == .orderedSame else {
            throw AppUpdaterError.invalidChecksum
        }

        let extractedRoot = stageDirectory.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
        try runSystemTool(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archiveURL.path, extractedRoot.path])

        guard let extractedAppURL = findAppBundle(in: extractedRoot) else {
            throw AppUpdaterError.stagedAppMissing
        }

        return PreparedAppUpdate(
            release: release,
            archiveURL: archiveURL,
            extractedAppURL: extractedAppURL,
            stagedAt: Date()
        )
    }

    private static func launchInstaller(for stagedAppURL: URL, replacing currentAppURL: URL) throws {
        let currentAppPath = currentAppURL.path
        if currentAppPath.contains("/AppTranslocation/") {
            throw AppUpdaterError.translocatedApp
        }

        let parentDirectory = currentAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDirectory.path) else {
            throw AppUpdaterError.installNotWritable
        }

        let helperDirectory = ExternalSupportPaths.applicationSupportRoot().appendingPathComponent("Updates/helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let scriptURL = helperDirectory.appendingPathComponent("install-update-\(UUID().uuidString).sh")
        let script = """
        #!/bin/zsh
        set -euo pipefail
        APP_PATH="$1"
        STAGED_APP="$2"
        PID="$3"
        TARGET_PARENT="$(dirname "$APP_PATH")"
        TMP_APP="$TARGET_PARENT/.BackChannel-update-$$.app"
        BACKUP_APP="$TARGET_PARENT/.BackChannel-backup-$$.app"
        LOG_FILE="$HOME/Library/Logs/BackChannelUpdater.log"
        {
          print "[updater] Waiting for pid $PID to exit..."
          for ((i=0; i<120; i++)); do
            if ! kill -0 "$PID" 2>/dev/null; then
              break
            fi
            sleep 1
          done

          rm -rf "$TMP_APP" "$BACKUP_APP"
          /usr/bin/ditto "$STAGED_APP" "$TMP_APP"
          /usr/bin/xattr -dr com.apple.quarantine "$TMP_APP" 2>/dev/null || true

          if [[ -e "$APP_PATH" ]]; then
            /bin/mv "$APP_PATH" "$BACKUP_APP"
          fi

          /bin/mv "$TMP_APP" "$APP_PATH"
          rm -rf "$BACKUP_APP"
          /usr/bin/open -a "$APP_PATH"
        } >> "$LOG_FILE" 2>&1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, currentAppURL.path, stagedAppURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
    }

    private static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdaterError.http(http.statusCode)
        }
    }

    private static func parseChecksum(from data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .first ?? ""
    }

    private static func sha256Hex(for fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func runSystemTool(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdaterError.stagedAppMissing
        }
    }

    private static func findAppBundle(in root: URL) -> URL? {
        if root.pathExtension == "app" {
            return root
        }

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "app" {
                return url
            }
        }
        return nil
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
