import CryptoKit
import Foundation

enum ExternalToolKind: String, CaseIterable, Identifiable, Codable {
    case ytDlp = "yt-dlp"
    case streamlink = "streamlink"
    case ffmpeg = "ffmpeg"
    case ffprobe = "ffprobe"
    case deno = "deno"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ytDlp:
            return "yt-dlp"
        case .streamlink:
            return "Streamlink"
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
        case .ffmpeg, .ffprobe:
            return true
        case .ytDlp, .streamlink, .deno:
            return false
        }
    }

    var allowsBundledRuntimeFallback: Bool {
        switch self {
        case .ytDlp, .streamlink:
            return false
        case .ffmpeg, .ffprobe, .deno:
            return true
        }
    }

    var versionArguments: [String] {
        switch self {
        case .ffmpeg, .ffprobe:
            return ["-version"]
        case .ytDlp, .streamlink, .deno:
            return ["--version"]
        }
    }

    var validationTimeout: TimeInterval {
        switch self {
        case .ytDlp:
            return 8
        case .streamlink:
            return 6
        case .deno:
            return 4
        case .ffmpeg, .ffprobe:
            return 3
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
            return "Managed Python Source Runtime"
        case .deno:
            return "JavaScript Runtime"
        }
    }

    var managedExecutableRelativePath: String {
        switch self {
        case .ytDlp:
            return "yt-dlp/python/bin/python3"
        case .deno:
            return "\(rawValue)/\(rawValue)"
        }
    }

    var legacyExecutableRelativePaths: [String] {
        switch self {
        case .ytDlp:
            return ["yt-dlp/yt-dlp"]
        case .deno:
            return []
        }
    }

    func defaultInvocationPrefix(for executableRelativePath: String?) -> [String] {
        switch self {
        case .ytDlp:
            let path = executableRelativePath ?? managedExecutableRelativePath
            return path == managedExecutableRelativePath ? ["-m", "yt_dlp"] : []
        case .deno:
            return []
        }
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
    let executableURL: URL
    let argumentsPrefix: [String]
    let source: ExternalToolSource
    let version: String?
    let runtimeVersion: String?

    var url: URL { executableURL }

    var launchDescription: String {
        ([executableURL.path] + argumentsPrefix).joined(separator: " ")
    }

    func arguments(appending arguments: [String]) -> [String] {
        argumentsPrefix + arguments
    }
}

struct ResolvedToolchain: Sendable {
    let ytDlp: ResolvedExternalTool
    let streamlink: ResolvedExternalTool?
    let ffmpeg: ResolvedExternalTool
    let ffprobe: ResolvedExternalTool
    let deno: ResolvedExternalTool?
    let environment: [String: String]
}

struct ExternalToolResolution: Sendable {
    let toolchain: ResolvedToolchain?
    let logLines: [String]
}

enum BundledToolHealth {
    case verified
    case present
    case missing
}

struct BundledToolStatus: Identifiable {
    let kind: ExternalToolKind
    let path: URL?
    let version: String?
    let health: BundledToolHealth
    let message: String

    var id: String { kind.rawValue }

    var payloadExists: Bool {
        switch health {
        case .verified, .present:
            return true
        case .missing:
            return false
        }
    }
}

private struct ProcessRunResult {
    let terminationStatus: Int32
    let output: String
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
    var argumentsPrefix: [String]?
    var toolVersion: String?
    var runtimeVersion: String?
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
    static let managedSupportReleaseTag = "managed-support"

    static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    static var managedSupportReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/tags/\(managedSupportReleaseTag)")!
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
        let current = managedCurrentLink(kind)
        let manifestPath = current.appendingPathComponent("component.json")
        let manifestRelativePath: String? = {
            guard
                let data = try? Data(contentsOf: manifestPath),
                let component = try? JSONDecoder().decode(ManagedSupportComponent.self, from: data)
            else {
                return nil
            }
            return component.executableRelativePath
        }()

        let candidates = ([manifestRelativePath, kind.managedExecutableRelativePath] + kind.legacyExecutableRelativePaths)
            .compactMap { $0 }

        for relativePath in candidates {
            let candidate = current.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return current.appendingPathComponent(manifestRelativePath ?? kind.managedExecutableRelativePath)
    }

    static func managedCurrentMetadataURL(_ kind: ManagedComponentKind) -> URL {
        managedCurrentLink(kind).appendingPathComponent("component.json")
    }

    static func managedVersionMetadataURL(_ kind: ManagedComponentKind, version: String) -> URL {
        managedVersionDirectory(kind, version: version).appendingPathComponent("component.json")
    }

    static func stateStoreURL() -> URL {
        applicationSupportRoot().appendingPathComponent("managed-support-state.json")
    }

    static func bundledExecutable(for kind: ExternalToolKind, resourceURL: URL?) -> URL? {
        guard kind.allowsBundledRuntimeFallback else {
            return nil
        }
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
    static func resolvePreviewTools(resourceURL: URL?) -> (ytDlp: ResolvedExternalTool, environment: [String: String], logLines: [String])? {
        var logLines: [String] = []

        guard let ytDlp = resolveManagedToolBestEffort(.ytDlp, logLines: &logLines) else {
            logLines.append("[app] Managed Python source runtime is required. Open Settings > Tools and install managed support.")
            return nil
        }

        let deno = resolveManagedToolBestEffort(.deno, logLines: &logLines)
            ?? resolveBundledOptionalToolBestEffort(.deno, resourceURL: resourceURL, logLines: &logLines)
        let environment = runtimeEnvironment(using: [ytDlp] + (deno.map { [$0] } ?? []))
        return (ytDlp, environment, logLines)
    }

    static func resolveCurrentToolchain(resourceURL: URL?) -> ExternalToolResolution {
        var logLines: [String] = []

        guard let ytDlp = resolveManagedToolBestEffort(.ytDlp, logLines: &logLines) else {
            logLines.append("[app] Managed Python source runtime is required. Open Settings > Tools and install managed support.")
            return ExternalToolResolution(toolchain: nil, logLines: logLines)
        }

        guard let ffmpeg = resolveBundledToolBestEffort(.ffmpeg, resourceURL: resourceURL, logLines: &logLines) else {
            logLines.append("[app] Could not find bundled FFmpeg.")
            return ExternalToolResolution(toolchain: nil, logLines: logLines)
        }

        guard let ffprobe = resolveBundledToolBestEffort(.ffprobe, resourceURL: resourceURL, logLines: &logLines) else {
            logLines.append("[app] Could not find bundled FFprobe.")
            return ExternalToolResolution(toolchain: nil, logLines: logLines)
        }

        let streamlink = resolveManagedPythonModuleBestEffort(
            moduleName: "streamlink",
            kind: .streamlink,
            pythonRuntime: ytDlp,
            logLines: &logLines
        )
        let deno = resolveManagedToolBestEffort(.deno, logLines: &logLines)
            ?? resolveBundledOptionalToolBestEffort(.deno, resourceURL: resourceURL, logLines: &logLines)
        let environment = runtimeEnvironment(
            using: [ytDlp] + (streamlink.map { [$0] } ?? []) + [ffmpeg, ffprobe] + (deno.map { [$0] } ?? [])
        )

        return ExternalToolResolution(
            toolchain: ResolvedToolchain(
                ytDlp: ytDlp,
                streamlink: streamlink,
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
                    return BundledToolStatus(kind: kind, path: nil, version: nil, health: .missing, message: "Not bundled")
                }

                let version = detectedVersion(for: kind, url: url)
                let isValid = verifyExecutable(url, versionArguments: kind.versionArguments)
                let health: BundledToolHealth = if isValid {
                    .verified
                } else if hasExecutablePayload(url) {
                    .present
                } else {
                    .missing
                }
                return BundledToolStatus(
                    kind: kind,
                    path: url,
                    version: version,
                    health: health,
                    message: isValid ? "Ready" : "Present"
                )
            }
    }

    static func quickBundledStatuses(resourceURL: URL?) -> [BundledToolStatus] {
        ExternalToolKind.allCases
            .filter(\.bundledByDefault)
            .map { kind in
                let url = ExternalSupportPaths.bundledExecutable(for: kind, resourceURL: resourceURL)
                let health: BundledToolHealth = url == nil ? .missing : .present
                return BundledToolStatus(
                    kind: kind,
                    path: url,
                    version: nil,
                    health: health,
                    message: url == nil ? "Not bundled" : "Checking..."
                )
            }
    }

    static func runtimeEnvironment(using tools: [ResolvedExternalTool]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let directories = tools
            .map { $0.executableURL.deletingLastPathComponent().path }
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
        verifyExecutable(url, versionArguments: versionArguments, timeout: 2.5)
    }

    static func verifyExecutable(_ url: URL, versionArguments: [String], timeout: TimeInterval) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return runProcess(executable: url, arguments: versionArguments, timeout: timeout)?.terminationStatus == 0
    }

    static func hasExecutablePayload(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func detectedVersion(for kind: ExternalToolKind, url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        guard let result = runProcess(executable: url, arguments: kind.versionArguments, timeout: kind.validationTimeout),
              result.terminationStatus == 0 else {
            return nil
        }
        let output = result.output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    static func verifyExecutable(_ tool: ResolvedExternalTool, timeout: TimeInterval? = nil) -> Bool {
        verifyExecutable(
            tool.executableURL,
            versionArguments: tool.arguments(appending: tool.kind.versionArguments),
            timeout: timeout ?? tool.kind.validationTimeout
        )
    }

    static func detectedVersion(for tool: ResolvedExternalTool) -> String? {
        guard hasExecutablePayload(tool.executableURL) else {
            return nil
        }
        guard let result = runProcess(
            executable: tool.executableURL,
            arguments: tool.arguments(appending: tool.kind.versionArguments),
            timeout: tool.kind.validationTimeout
        ), result.terminationStatus == 0 else {
            return nil
        }
        let output = result.output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    static func loadManagedInstalledComponent(_ kind: ManagedComponentKind) -> ManagedSupportComponent? {
        let metadataURL = ExternalSupportPaths.managedCurrentMetadataURL(kind)
        guard
            let data = try? Data(contentsOf: metadataURL),
            let component = try? JSONDecoder().decode(ManagedSupportComponent.self, from: data)
        else {
            return nil
        }
        return component
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

    private static func resolveManagedTool(_ kind: ManagedComponentKind, logLines: inout [String]) -> ResolvedExternalTool? {
        let executable = ExternalSupportPaths.managedCurrentExecutable(kind)
        guard hasExecutablePayload(executable) else {
            return nil
        }

        let installedMetadata = loadManagedInstalledComponent(kind)
        let tool = makeResolvedManagedTool(kind, executable: executable, component: installedMetadata)

        guard verifyExecutable(tool, timeout: kind.toolKind.validationTimeout) else {
            logLines.append("[app] \(kind.displayName) found at \(tool.launchDescription) but it cannot run.")
            return nil
        }

        return ResolvedExternalTool(
            kind: kind.toolKind,
            executableURL: tool.executableURL,
            argumentsPrefix: tool.argumentsPrefix,
            source: .managed,
            version: installedMetadata?.toolVersion ?? detectedVersion(for: tool),
            runtimeVersion: installedMetadata?.runtimeVersion
        )
    }

    private static func resolveManagedToolBestEffort(_ kind: ManagedComponentKind, logLines: inout [String]) -> ResolvedExternalTool? {
        let executable = ExternalSupportPaths.managedCurrentExecutable(kind)
        guard hasExecutablePayload(executable) else {
            return nil
        }

        let installedMetadata = loadManagedInstalledComponent(kind)
        let tool = makeResolvedManagedTool(kind, executable: executable, component: installedMetadata)
        logLines.append("[app] Using \(kind.displayName): \(tool.launchDescription)")
        return tool
    }

    private static func resolveBundledTool(_ kind: ExternalToolKind, resourceURL: URL?, logLines: inout [String]) -> ResolvedExternalTool? {
        guard let executable = ExternalSupportPaths.bundledExecutable(for: kind, resourceURL: resourceURL) else {
            return nil
        }

        guard verifyExecutable(executable, versionArguments: kind.versionArguments, timeout: kind.validationTimeout) else {
            logLines.append("[app] Bundled \(kind.displayName) found at \(executable.path) but it cannot run.")
            return nil
        }

        return ResolvedExternalTool(
            kind: kind,
            executableURL: executable,
            argumentsPrefix: [],
            source: .bundled,
            version: detectedVersion(for: kind, url: executable),
            runtimeVersion: nil
        )
    }

    private static func resolveBundledToolBestEffort(_ kind: ExternalToolKind, resourceURL: URL?, logLines: inout [String]) -> ResolvedExternalTool? {
        guard let executable = ExternalSupportPaths.bundledExecutable(for: kind, resourceURL: resourceURL),
              hasExecutablePayload(executable) else {
            return nil
        }

        logLines.append("[app] Using bundled \(kind.displayName): \(executable.path)")
        return ResolvedExternalTool(
            kind: kind,
            executableURL: executable,
            argumentsPrefix: [],
            source: .bundled,
            version: nil,
            runtimeVersion: nil
        )
    }

    private static func resolveBundledOptionalTool(_ kind: ExternalToolKind, resourceURL: URL?, logLines: inout [String]) -> ResolvedExternalTool? {
        resolveBundledTool(kind, resourceURL: resourceURL, logLines: &logLines)
    }

    private static func resolveBundledOptionalToolBestEffort(_ kind: ExternalToolKind, resourceURL: URL?, logLines: inout [String]) -> ResolvedExternalTool? {
        resolveBundledToolBestEffort(kind, resourceURL: resourceURL, logLines: &logLines)
    }

    private static func resolveManagedPythonModuleBestEffort(
        moduleName: String,
        kind: ExternalToolKind,
        pythonRuntime: ResolvedExternalTool,
        logLines: inout [String]
    ) -> ResolvedExternalTool? {
        let tool = ResolvedExternalTool(
            kind: kind,
            executableURL: pythonRuntime.executableURL,
            argumentsPrefix: ["-m", moduleName],
            source: .managed,
            version: nil,
            runtimeVersion: pythonRuntime.runtimeVersion
        )

        guard verifyExecutable(tool, timeout: kind.validationTimeout) else {
            return nil
        }

        logLines.append("[app] Using Managed \(kind.displayName): \(tool.launchDescription)")
        return ResolvedExternalTool(
            kind: kind,
            executableURL: tool.executableURL,
            argumentsPrefix: tool.argumentsPrefix,
            source: .managed,
            version: detectedVersion(for: tool),
            runtimeVersion: tool.runtimeVersion
        )
    }

    private static func makeResolvedManagedTool(
        _ kind: ManagedComponentKind,
        executable: URL,
        component: ManagedSupportComponent?
    ) -> ResolvedExternalTool {
        let inferredRelativePath = component?.executableRelativePath
            ?? relativePath(of: executable, relativeTo: ExternalSupportPaths.managedCurrentLink(kind))
        return ResolvedExternalTool(
            kind: kind.toolKind,
            executableURL: executable,
            argumentsPrefix: component?.argumentsPrefix ?? kind.defaultInvocationPrefix(for: inferredRelativePath),
            source: .managed,
            version: component?.toolVersion,
            runtimeVersion: component?.runtimeVersion
        )
    }

    private static func relativePath(of url: URL, relativeTo base: URL) -> String? {
        let urlPath = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        guard urlPath.hasPrefix(basePath) else {
            return nil
        }
        let trimmed = String(urlPath.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func runProcess(executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessRunResult? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            _ = semaphore.wait(timeout: .now() + 1)
            return nil
        }

        var data = stdout.fileHandleForReading.readDataToEndOfFile()
        data.append(stderr.fileHandleForReading.readDataToEndOfFile())

        return ProcessRunResult(
            terminationStatus: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}
