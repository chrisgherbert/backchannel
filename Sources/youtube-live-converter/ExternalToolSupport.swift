import CryptoKit
import Foundation

enum ExternalToolKind: String, CaseIterable, Identifiable, Codable {
    case ytDlp = "yt-dlp"
    case ffmpeg = "ffmpeg"
    case ffprobe = "ffprobe"
    case deno = "deno"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ytDlp:
            return "yt-dlp"
        case .ffmpeg:
            return "FFmpeg"
        case .ffprobe:
            return "FFprobe"
        case .deno:
            return "JavaScript Runtime"
        }
    }

    var bundledByDefault: Bool {
        switch self {
        case .ytDlp, .ffmpeg, .ffprobe:
            return true
        case .deno:
            return false
        }
    }

    var versionArguments: [String] {
        switch self {
        case .ffmpeg, .ffprobe:
            return ["-version"]
        case .ytDlp, .deno:
            return ["--version"]
        }
    }
}

enum ManagedComponentKind: String, CaseIterable, Identifiable, Codable {
    case ytDlp = "yt-dlp"
    case deno = "deno"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ytDlp:
            return "Managed yt-dlp"
        case .deno:
            return "JavaScript Runtime"
        }
    }

    var executableName: String {
        rawValue
    }

    var toolKind: ExternalToolKind {
        switch self {
        case .ytDlp:
            return .ytDlp
        case .deno:
            return .deno
        }
    }
}

enum ExternalToolSource: String, Codable {
    case bundled
    case managed
}

struct ResolvedExternalTool: Sendable {
    let kind: ExternalToolKind
    let url: URL
    let source: ExternalToolSource
    let version: String?
}

struct ResolvedToolchain: Sendable {
    let ytDlp: ResolvedExternalTool
    let ffmpeg: ResolvedExternalTool
    let ffprobe: ResolvedExternalTool
    let deno: ResolvedExternalTool?
    let environment: [String: String]
}

struct ExternalToolResolution: Sendable {
    let toolchain: ResolvedToolchain?
    let logLines: [String]
}

struct BundledToolStatus: Identifiable {
    let kind: ExternalToolKind
    let path: URL?
    let version: String?
    let isAvailable: Bool
    let message: String

    var id: String { kind.rawValue }
}

struct ManagedComponentStateRecord: Codable {
    var componentID: String
    var currentVersion: String?
    var previousVersion: String?
    var lastInstalledAt: Date?
    var lastError: String?
}

struct ManagedComponentStateStore: Codable {
    var updatedAt: Date
    var components: [ManagedComponentStateRecord]

    static let empty = ManagedComponentStateStore(updatedAt: .distantPast, components: [])

    func record(for kind: ManagedComponentKind) -> ManagedComponentStateRecord {
        components.first(where: { $0.componentID == kind.rawValue }) ??
            ManagedComponentStateRecord(componentID: kind.rawValue, currentVersion: nil, previousVersion: nil, lastInstalledAt: nil, lastError: nil)
    }
}

struct ManagedSupportManifest: Codable {
    var schemaVersion: Int
    var generatedAt: String
    var appVersion: String
    var components: [ManagedSupportComponent]
}

struct ManagedSupportComponent: Codable, Identifiable, Hashable {
    var id: String
    var version: String
    var assetName: String
    var sha256: String
    var executableRelativePath: String
    var minimumAppVersion: String?

    var componentKind: ManagedComponentKind? {
        ManagedComponentKind(rawValue: id)
    }
}

struct GitHubReleaseAsset: Codable {
    var name: String
    var browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubReleaseResponse: Codable {
    var tagName: String
    var assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

enum ExternalSupportConfiguration {
    static let appSupportDirectoryName = "Back Channel"
    static let githubOwner = "chrisgherbert"
    static let githubRepo = "backchannel"
    static let managedSupportManifestAssetName = "backchannel-managed-support.json"

    static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
    }
}

enum ExternalSupportPaths {
    static func applicationSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(ExternalSupportConfiguration.appSupportDirectoryName, isDirectory: true)
    }

    static func managedRoot() -> URL {
        applicationSupportRoot().appendingPathComponent("ManagedSupport", isDirectory: true)
    }

    static func managedComponentRoot(_ kind: ManagedComponentKind) -> URL {
        managedRoot().appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    static func managedVersionsDirectory(_ kind: ManagedComponentKind) -> URL {
        managedComponentRoot(kind).appendingPathComponent("versions", isDirectory: true)
    }

    static func managedVersionDirectory(_ kind: ManagedComponentKind, version: String) -> URL {
        managedVersionsDirectory(kind).appendingPathComponent(version, isDirectory: true)
    }

    static func managedCurrentLink(_ kind: ManagedComponentKind) -> URL {
        managedComponentRoot(kind).appendingPathComponent("current", isDirectory: true)
    }

    static func managedCurrentExecutable(_ kind: ManagedComponentKind) -> URL {
        managedCurrentLink(kind).appendingPathComponent(kind.executableName)
    }

    static func stateStoreURL() -> URL {
        applicationSupportRoot().appendingPathComponent("managed-support-state.json")
    }

    static func bundledExecutable(for kind: ExternalToolKind, resourceURL: URL?) -> URL? {
        guard let resourceURL else { return nil }
        let candidate = resourceURL.appendingPathComponent("bin/\(kind.rawValue)")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static func runtimeCertificateBundleURL() -> URL? {
        let bundled = applicationSupportRoot().appendingPathComponent("certs/cacert.pem")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        let systemCandidates = [
            "/etc/ssl/cert.pem",
            "/private/etc/ssl/cert.pem"
        ]

        for candidate in systemCandidates where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}

enum ExternalToolResolver {
    static func resolvePreviewTools(resourceURL: URL?) -> (ytDlp: URL, environment: [String: String], logLines: [String])? {
        var logLines: [String] = []

        guard let ytDlp = resolvePreferredTool(.ytDlp, resourceURL: resourceURL, logLines: &logLines) else {
            logLines.append("[app] Could not find yt-dlp in managed support or bundled resources.")
            return nil
        }

        let deno = resolveManagedTool(.deno, logLines: &logLines) ?? resolveBundledOptionalTool(.deno, resourceURL: resourceURL, logLines: &logLines)
        let environment = runtimeEnvironment(using: [ytDlp] + (deno.map { [$0] } ?? []))
        return (ytDlp.url, environment, logLines)
    }

    static func resolveCurrentToolchain(resourceURL: URL?) -> ExternalToolResolution {
        var logLines: [String] = []

        guard let ytDlp = resolvePreferredTool(.ytDlp, resourceURL: resourceURL, logLines: &logLines) else {
            logLines.append("[app] Could not find yt-dlp in managed support or bundled resources.")
            return ExternalToolResolution(toolchain: nil, logLines: logLines)
        }

        guard let ffmpeg = resolveBundledTool(.ffmpeg, resourceURL: resourceURL, logLines: &logLines) else {
            logLines.append("[app] Could not find bundled FFmpeg.")
            return ExternalToolResolution(toolchain: nil, logLines: logLines)
        }

        guard let ffprobe = resolveBundledTool(.ffprobe, resourceURL: resourceURL, logLines: &logLines) else {
            logLines.append("[app] Could not find bundled FFprobe.")
            return ExternalToolResolution(toolchain: nil, logLines: logLines)
        }

        let deno = resolveManagedTool(.deno, logLines: &logLines) ?? resolveBundledOptionalTool(.deno, resourceURL: resourceURL, logLines: &logLines)
        let environment = runtimeEnvironment(using: [ytDlp, ffmpeg, ffprobe] + (deno.map { [$0] } ?? []))

        return ExternalToolResolution(
            toolchain: ResolvedToolchain(
                ytDlp: ytDlp,
                ffmpeg: ffmpeg,
                ffprobe: ffprobe,
                deno: deno,
                environment: environment
            ),
            logLines: logLines
        )
    }

    static func bundledStatuses(resourceURL: URL?) -> [BundledToolStatus] {
        ExternalToolKind.allCases
            .filter(\.bundledByDefault)
            .map { kind in
                let url = ExternalSupportPaths.bundledExecutable(for: kind, resourceURL: resourceURL)
                guard let url else {
                    return BundledToolStatus(kind: kind, path: nil, version: nil, isAvailable: false, message: "Not bundled")
                }

                let version = detectedVersion(for: kind, url: url)
                let isValid = verifyExecutable(url, versionArguments: kind.versionArguments)
                return BundledToolStatus(
                    kind: kind,
                    path: url,
                    version: version,
                    isAvailable: isValid,
                    message: isValid ? "Ready" : "Found but cannot run"
                )
            }
    }

    static func runtimeEnvironment(using tools: [ResolvedExternalTool]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let directories = tools
            .map { $0.url.deletingLastPathComponent().path }
            .reduce(into: [String]()) { partialResult, path in
                if !partialResult.contains(path) {
                    partialResult.append(path)
                }
            }

        if !directories.isEmpty {
            environment["PATH"] = directories.joined(separator: ":") + ":" + existingPath
        }

        if let certBundle = ExternalSupportPaths.runtimeCertificateBundleURL() {
            environment["SSL_CERT_FILE"] = certBundle.path
            environment["REQUESTS_CA_BUNDLE"] = certBundle.path
            environment["CURL_CA_BUNDLE"] = certBundle.path
        }

        environment["DENO_TLS_CA_STORE"] = "system"
        return environment
    }

    static func verifyExecutable(_ url: URL, versionArguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = versionArguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func detectedVersion(for kind: ExternalToolKind, url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = kind.versionArguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            var data = stdout.fileHandleForReading.readDataToEndOfFile()
            data.append(stderr.fileHandleForReading.readDataToEndOfFile())
            let output = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }

    static func loadManagedStateStore() -> ManagedComponentStateStore {
        let url = ExternalSupportPaths.stateStoreURL()
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(ManagedComponentStateStore.self, from: data)
        else {
            return .empty
        }
        return decoded
    }

    static func saveManagedStateStore(_ store: ManagedComponentStateStore) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        try FileManager.default.createDirectory(at: ExternalSupportPaths.applicationSupportRoot(), withIntermediateDirectories: true)
        try data.write(to: ExternalSupportPaths.stateStoreURL(), options: .atomic)
    }

    static func sha256Hex(for fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func resolvePreferredTool(_ kind: ExternalToolKind, resourceURL: URL?, logLines: inout [String]) -> ResolvedExternalTool? {
        if let managedKind = ManagedComponentKind(rawValue: kind.rawValue),
           let managed = resolveManagedTool(managedKind, logLines: &logLines) {
            return managed
        }
        return resolveBundledTool(kind, resourceURL: resourceURL, logLines: &logLines)
    }

    private static func resolveManagedTool(_ kind: ManagedComponentKind, logLines: inout [String]) -> ResolvedExternalTool? {
        let executable = ExternalSupportPaths.managedCurrentExecutable(kind)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return nil
        }

        guard verifyExecutable(executable, versionArguments: kind.toolKind.versionArguments) else {
            logLines.append("[app] Managed \(kind.displayName) found at \(executable.path) but it cannot run.")
            return nil
        }

        return ResolvedExternalTool(
            kind: kind.toolKind,
            url: executable,
            source: .managed,
            version: detectedVersion(for: kind.toolKind, url: executable)
        )
    }

    private static func resolveBundledTool(_ kind: ExternalToolKind, resourceURL: URL?, logLines: inout [String]) -> ResolvedExternalTool? {
        guard let executable = ExternalSupportPaths.bundledExecutable(for: kind, resourceURL: resourceURL) else {
            return nil
        }

        guard verifyExecutable(executable, versionArguments: kind.versionArguments) else {
            logLines.append("[app] Bundled \(kind.displayName) found at \(executable.path) but it cannot run.")
            return nil
        }

        return ResolvedExternalTool(
            kind: kind,
            url: executable,
            source: .bundled,
            version: detectedVersion(for: kind, url: executable)
        )
    }

    private static func resolveBundledOptionalTool(_ kind: ExternalToolKind, resourceURL: URL?, logLines: inout [String]) -> ResolvedExternalTool? {
        resolveBundledTool(kind, resourceURL: resourceURL, logLines: &logLines)
    }
}
