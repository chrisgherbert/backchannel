import Foundation

enum ManagedComponentHealth {
    case ready
    case bundledFallback
    case missing
    case installing
    case error
}

enum ManagedSupportAvailability: Equatable {
    case unknown
    case checking
    case available
    case unavailable(String)
}

struct ManagedComponentStatus: Identifiable {
    let kind: ManagedComponentKind
    let installedVersion: String?
    let availableVersion: String?
    let runtimeVersion: String?
    let executableURL: URL?
    let health: ManagedComponentHealth
    let message: String
    let lastError: String?
    let canRollback: Bool

    var id: String { kind.rawValue }
}

@MainActor
final class ExternalToolsManager: ObservableObject {
    @Published private(set) var bundledStatuses: [BundledToolStatus] = []
    @Published private(set) var managedStatuses: [ManagedComponentStatus] = []
    @Published private(set) var activityMessage = ""
    @Published private(set) var lastError = ""
    @Published private(set) var isPerformingAction = false
    @Published private(set) var latestManifest: ManagedSupportManifest?
    @Published private(set) var lastManifestSyncAt: Date?
    @Published private(set) var managedSupportAvailability: ManagedSupportAvailability = .unknown

    private let resourceURLProvider: () -> URL?
    private var statusRefreshTask: Task<Void, Never>?
    private var manifestRefreshTask: Task<Void, Never>?
    private let manifestRefreshInterval: TimeInterval = 300

    init(resourceURLProvider: @escaping () -> URL? = { Bundle.main.resourceURL }) {
        self.resourceURLProvider = resourceURLProvider
    }

    var requiresInitialSetup: Bool {
        guard canInstallManagedSupport else { return false }
        return managedStatuses.contains(where: { status in
            switch status.health {
            case .missing, .error:
                return true
            case .ready, .bundledFallback, .installing:
                return false
            }
        })
    }

    var canInstallManagedSupport: Bool {
        if case .available = managedSupportAvailability {
            return true
        }
        return false
    }

    var managedSupportStatusMessage: String {
        switch managedSupportAvailability {
        case .unknown:
            return "Checking whether managed support packages are available."
        case .checking:
            return "Checking for published support packages..."
        case .available:
            return "Managed support packages are available."
        case .unavailable(let message):
            return message
        }
    }

    func refreshStatus(forceManifestRefresh: Bool = false) {
        let resourceURL = resourceURLProvider()
        let manifest = latestManifest

        bundledStatuses = ExternalToolResolver.quickBundledStatuses(resourceURL: resourceURL)

        statusRefreshTask?.cancel()
        statusRefreshTask = Task.detached(priority: .utility) {
            let bundled = ExternalToolResolver.bundledStatuses(resourceURL: resourceURL)
            let bundledByKind = Dictionary(uniqueKeysWithValues: bundled.map { ($0.kind, $0) })
            let store = ExternalToolResolver.loadManagedStateStore()
            let managed = ManagedComponentKind.allCases.map { kind in
                Self.status(
                    for: kind,
                    store: store,
                    manifest: manifest,
                    resourceURL: resourceURL,
                    bundledFallbackStatus: bundledByKind[kind.toolKind]
                )
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.bundledStatuses = bundled
                self.managedStatuses = managed
                self.statusRefreshTask = nil
            }
        }

        refreshManifestAvailability(force: forceManifestRefresh)
    }

    func setUpManagedSupport() async {
        guard canInstallManagedSupport else {
            lastError = managedSupportStatusMessage
            return
        }
        await performAction(description: "Setting up managed support...") {
            let manifestAndAssets = try await Self.fetchManifestAndAssets()
            for kind in ManagedComponentKind.allCases {
                try await Self.installLatestComponent(kind, using: manifestAndAssets.manifest, assetsByName: manifestAndAssets.assetsByName, repairExisting: false)
            }
        }
    }

    func update(_ kind: ManagedComponentKind) async {
        guard canInstallManagedSupport else {
            lastError = managedSupportStatusMessage
            return
        }
        await performAction(description: "Updating \(kind.displayName)...") {
            let manifestAndAssets = try await Self.fetchManifestAndAssets()
            try await Self.installLatestComponent(kind, using: manifestAndAssets.manifest, assetsByName: manifestAndAssets.assetsByName, repairExisting: false)
        }
    }

    func repair(_ kind: ManagedComponentKind) async {
        guard canInstallManagedSupport else {
            lastError = managedSupportStatusMessage
            return
        }
        await performAction(description: "Repairing \(kind.displayName)...") {
            let manifestAndAssets = try await Self.fetchManifestAndAssets()
            try await Self.installLatestComponent(kind, using: manifestAndAssets.manifest, assetsByName: manifestAndAssets.assetsByName, repairExisting: true)
        }
    }

    func rollback(_ kind: ManagedComponentKind) async {
        await performAction(description: "Rolling back \(kind.displayName)...") {
            try Self.rollbackComponent(kind)
        }
    }

    func refreshManifestAvailability(force: Bool = false) {
        if !force, manifestRefreshTask != nil {
            return
        }

        if !force,
           let lastManifestSyncAt,
           Date().timeIntervalSince(lastManifestSyncAt) < manifestRefreshInterval {
            return
        }

        let resourceURL = resourceURLProvider()
        let bundledSnapshot = bundledStatuses
        manifestRefreshTask?.cancel()
        managedSupportAvailability = .checking

        manifestRefreshTask = Task.detached(priority: .utility) {
            do {
                let manifestAndAssets = try await Self.withTimeout(seconds: 12, operationDescription: "Managed support check") {
                    try await Self.fetchManifestAndAssets()
                }
                let bundledByKind = Dictionary(uniqueKeysWithValues: bundledSnapshot.map { ($0.kind, $0) })
                let store = ExternalToolResolver.loadManagedStateStore()
                let managed = ManagedComponentKind.allCases.map { kind in
                    Self.status(
                        for: kind,
                        store: store,
                        manifest: manifestAndAssets.manifest,
                        resourceURL: resourceURL,
                        bundledFallbackStatus: bundledByKind[kind.toolKind]
                    )
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.latestManifest = manifestAndAssets.manifest
                    self.lastManifestSyncAt = Date()
                    self.managedSupportAvailability = .available
                    self.managedStatuses = managed
                    self.manifestRefreshTask = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.latestManifest = nil
                    self.lastManifestSyncAt = Date()
                    self.managedSupportAvailability = .unavailable(error.localizedDescription)
                    self.manifestRefreshTask = nil
                }
            }
        }
    }

    private func performAction(description: String, operation: @Sendable @escaping () async throws -> Void) async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        activityMessage = description
        lastError = ""

        defer {
            isPerformingAction = false
            if activityMessage == description {
                activityMessage = ""
            }
            refreshStatus(forceManifestRefresh: true)
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try await operation()
            }.value
            activityMessage = "Finished."
        } catch {
            lastError = error.localizedDescription
            activityMessage = "Action failed."
            var store = ExternalToolResolver.loadManagedStateStore()
            for kind in ManagedComponentKind.allCases where error.localizedDescription.contains(kind.rawValue) {
                var record = store.record(for: kind)
                record.lastError = error.localizedDescription
                Self.updateStore(&store, with: record)
            }
            try? ExternalToolResolver.saveManagedStateStore(store)
        }
    }

    nonisolated private static func status(
        for kind: ManagedComponentKind,
        store: ManagedComponentStateStore,
        manifest: ManagedSupportManifest? = nil,
        resourceURL: URL?,
        bundledFallbackStatus: BundledToolStatus? = nil
    ) -> ManagedComponentStatus {
        let record = store.record(for: kind)
        let currentExecutable = ExternalSupportPaths.managedCurrentExecutable(kind)
        let payloadExists = ExternalToolResolver.hasExecutablePayload(currentExecutable)
        let installedComponent = ExternalToolResolver.loadManagedInstalledComponent(kind)
        let inferredRelativePath = currentExecutable.standardizedFileURL.path
            .replacingOccurrences(of: ExternalSupportPaths.managedCurrentLink(kind).standardizedFileURL.path + "/", with: "")
        let managedTool = ResolvedExternalTool(
            kind: kind.toolKind,
            executableURL: currentExecutable,
            argumentsPrefix: installedComponent?.argumentsPrefix ?? kind.defaultInvocationPrefix(for: installedComponent?.executableRelativePath ?? inferredRelativePath),
            source: .managed,
            version: installedComponent?.toolVersion,
            runtimeVersion: installedComponent?.runtimeVersion
        )
        let executableExists = payloadExists && ExternalToolResolver.verifyExecutable(
            managedTool,
            timeout: kind.toolKind.validationTimeout
        )
        let bundledFallback = bundledFallbackStatus?.path ?? ExternalSupportPaths.bundledExecutable(for: kind.toolKind, resourceURL: resourceURL)
        let bundledFallbackExists = kind == .ytDlp
            ? false
            : bundledFallbackStatus?.payloadExists ?? bundledFallback.map {
                ExternalToolResolver.hasExecutablePayload($0)
            } ?? false
        let availableComponent = manifest?.components.first(where: { $0.componentKind == kind })
        let availableVersion = availableComponent?.toolVersion ?? availableComponent?.version
        let runtimeVersion = installedComponent?.runtimeVersion ?? availableComponent?.runtimeVersion

        if executableExists {
            let version = installedComponent?.toolVersion
                ?? ExternalToolResolver.detectedVersion(for: managedTool)
                ?? record.currentVersion
            let canRollback = record.previousVersion.flatMap { previous in
                let path = ExternalSupportPaths.managedVersionDirectory(kind, version: previous).path
                return FileManager.default.fileExists(atPath: path) ? previous : nil
            } != nil

            return ManagedComponentStatus(
                kind: kind,
                installedVersion: version,
                availableVersion: availableVersion,
                runtimeVersion: runtimeVersion,
                executableURL: currentExecutable,
                health: .ready,
                message: "Installed and ready",
                lastError: record.lastError,
                canRollback: canRollback
            )
        }

        if payloadExists {
            let canRollback = record.previousVersion.flatMap { previous in
                let path = ExternalSupportPaths.managedVersionDirectory(kind, version: previous).path
                return FileManager.default.fileExists(atPath: path) ? previous : nil
            } != nil
            let installedVersion = installedComponent?.toolVersion ?? record.currentVersion ?? availableVersion

            if bundledFallbackExists {
                return ManagedComponentStatus(
                    kind: kind,
                    installedVersion: installedVersion,
                    availableVersion: availableVersion,
                    runtimeVersion: runtimeVersion,
                    executableURL: currentExecutable,
                    health: .bundledFallback,
                    message: "Installed, using bundled fallback",
                    lastError: record.lastError,
                    canRollback: canRollback
                )
            }

            return ManagedComponentStatus(
                kind: kind,
                installedVersion: installedVersion,
                availableVersion: availableVersion,
                runtimeVersion: runtimeVersion,
                executableURL: currentExecutable,
                health: .error,
                message: "Installed but could not be validated",
                lastError: record.lastError,
                canRollback: canRollback
            )
        }

        if bundledFallbackExists {
            return ManagedComponentStatus(
                kind: kind,
                installedVersion: nil,
                availableVersion: availableVersion,
                runtimeVersion: runtimeVersion,
                executableURL: bundledFallback,
                health: .bundledFallback,
                message: "Using bundled fallback",
                lastError: record.lastError,
                canRollback: false
            )
        }

        if let lastError = record.lastError, !lastError.isEmpty {
            return ManagedComponentStatus(
                kind: kind,
                installedVersion: nil,
                availableVersion: availableVersion,
                runtimeVersion: runtimeVersion,
                executableURL: nil,
                health: .error,
                message: "Needs repair",
                lastError: lastError,
                canRollback: false
            )
        }

        return ManagedComponentStatus(
            kind: kind,
            installedVersion: nil,
            availableVersion: availableVersion,
            runtimeVersion: runtimeVersion,
            executableURL: nil,
            health: .missing,
            message: "Not installed",
            lastError: nil,
            canRollback: false
        )
    }

    nonisolated private static func fetchManifestAndAssets() async throws -> (manifest: ManagedSupportManifest, assetsByName: [String: GitHubReleaseAsset]) {
        let release = try await fetchManagedSupportRelease()
        let assetsByName = Dictionary(uniqueKeysWithValues: release.assets.map { ($0.name, $0) })

        guard let manifestAsset = assetsByName[ExternalSupportConfiguration.managedSupportManifestAssetName],
              let manifestURL = URL(string: manifestAsset.browserDownloadURL) else {
            throw ExternalToolsManagerError.manifestMissing
        }

        let (manifestData, response) = try await urlSession().data(from: manifestURL)
        try Self.validateHTTPResponse(response)

        let manifest = try JSONDecoder().decode(ManagedSupportManifest.self, from: manifestData)
        return (manifest, assetsByName)
    }

    nonisolated private static func fetchManagedSupportRelease() async throws -> GitHubReleaseResponse {
        do {
            return try await fetchRelease(from: ExternalSupportConfiguration.managedSupportReleaseAPIURL)
        } catch {
            return try await fetchLatestRelease()
        }
    }

    nonisolated private static func fetchLatestRelease() async throws -> GitHubReleaseResponse {
        try await fetchRelease(from: ExternalSupportConfiguration.latestReleaseAPIURL)
    }

    nonisolated private static func fetchRelease(from url: URL) async throws -> GitHubReleaseResponse {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BackChannel/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        let (data, response) = try await urlSession().data(for: request)
        try Self.validateHTTPResponse(response)
        return try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
    }

    nonisolated private static func installLatestComponent(
        _ kind: ManagedComponentKind,
        using manifest: ManagedSupportManifest,
        assetsByName: [String: GitHubReleaseAsset],
        repairExisting: Bool
    ) async throws {
        guard let component = manifest.components.first(where: { $0.componentKind == kind }) else {
            throw ExternalToolsManagerError.componentMissing(kind.displayName)
        }

        guard let asset = assetsByName[component.assetName],
              let assetURL = URL(string: asset.browserDownloadURL) else {
            throw ExternalToolsManagerError.assetMissing(component.assetName)
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backchannel-managed-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let archiveURL = temporaryDirectory.appendingPathComponent(component.assetName)
        let (downloadedFileURL, response) = try await urlSession().download(from: assetURL)
        try Self.validateHTTPResponse(response)
        try FileManager.default.moveItem(at: downloadedFileURL, to: archiveURL)

        let digest = try ExternalToolResolver.sha256Hex(for: archiveURL)
        guard digest.caseInsensitiveCompare(component.sha256) == .orderedSame else {
            throw ExternalToolsManagerError.invalidChecksum(kind.displayName)
        }

        let extractedDirectory = temporaryDirectory.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        try Self.runSystemTool(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archiveURL.path, extractedDirectory.path]
        )

        let executableURL = try locateExtractedExecutable(
            in: extractedDirectory,
            relativePath: component.executableRelativePath,
            fallbackRelativePaths: kind.legacyExecutableRelativePaths
        )
        guard ExternalToolResolver.hasExecutablePayload(executableURL) else {
            throw ExternalToolsManagerError.invalidPayload(kind.displayName)
        }
        let installedTool = ResolvedExternalTool(
            kind: kind.toolKind,
            executableURL: executableURL,
            argumentsPrefix: component.argumentsPrefix ?? kind.defaultInvocationPrefix(for: component.executableRelativePath),
            source: .managed,
            version: component.toolVersion,
            runtimeVersion: component.runtimeVersion
        )
        guard ExternalToolResolver.verifyExecutable(installedTool, timeout: kind.toolKind.validationTimeout) else {
            throw ExternalToolsManagerError.invalidPayload(kind.displayName)
        }

        let targetVersionDirectory = ExternalSupportPaths.managedVersionDirectory(kind, version: component.version)
        try FileManager.default.createDirectory(at: ExternalSupportPaths.managedVersionsDirectory(kind), withIntermediateDirectories: true)
        if repairExisting || FileManager.default.fileExists(atPath: targetVersionDirectory.path) {
            try? FileManager.default.removeItem(at: targetVersionDirectory)
        }
        try FileManager.default.moveItem(at: extractedDirectory, to: targetVersionDirectory)
        let metadataURL = ExternalSupportPaths.managedVersionMetadataURL(kind, version: component.version)
        let metadataData = try JSONEncoder().encode(component)
        try metadataData.write(to: metadataURL, options: .atomic)

        var store = ExternalToolResolver.loadManagedStateStore()
        var record = store.record(for: kind)
        let priorVersion = record.currentVersion
        try Self.replaceCurrentLink(for: kind, with: targetVersionDirectory)
        record.previousVersion = priorVersion != component.version ? priorVersion : record.previousVersion
        record.currentVersion = component.version
        record.lastInstalledAt = Date()
        record.lastError = nil
        updateStore(&store, with: record)
        try ExternalToolResolver.saveManagedStateStore(store)
    }

    nonisolated private static func locateExtractedExecutable(
        in extractedDirectory: URL,
        relativePath: String,
        fallbackRelativePaths: [String]
    ) throws -> URL {
        let candidatePaths = [relativePath] + fallbackRelativePaths
        let directCandidates = candidatePaths.map { extractedDirectory.appendingPathComponent($0) }
        if let match = directCandidates.first(where: { ExternalToolResolver.hasExecutablePayload($0) }) {
            return match
        }

        let fileManager = FileManager.default
        let topLevelEntries = (try? fileManager.contentsOfDirectory(
            at: extractedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        if topLevelEntries.count == 1, let topLevel = topLevelEntries.first {
            let nestedCandidates = candidatePaths.map { topLevel.appendingPathComponent($0) }
            if let match = nestedCandidates.first(where: { ExternalToolResolver.hasExecutablePayload($0) }) {
                return match
            }
        }

        return extractedDirectory.appendingPathComponent(relativePath)
    }

    nonisolated private static func rollbackComponent(_ kind: ManagedComponentKind) throws {
        var store = ExternalToolResolver.loadManagedStateStore()
        var record = store.record(for: kind)
        guard let previousVersion = record.previousVersion else {
            throw ExternalToolsManagerError.rollbackUnavailable(kind.displayName)
        }

        let previousDirectory = ExternalSupportPaths.managedVersionDirectory(kind, version: previousVersion)
        guard FileManager.default.fileExists(atPath: previousDirectory.path) else {
            throw ExternalToolsManagerError.rollbackUnavailable(kind.displayName)
        }

        try replaceCurrentLink(for: kind, with: previousDirectory)

        let currentVersion = record.currentVersion
        record.currentVersion = previousVersion
        record.previousVersion = currentVersion
        record.lastError = nil
        record.lastInstalledAt = Date()
        updateStore(&store, with: record)
        try ExternalToolResolver.saveManagedStateStore(store)
    }

    nonisolated private static func updateStore(_ store: inout ManagedComponentStateStore, with record: ManagedComponentStateRecord) {
        store.updatedAt = Date()
        if let existingIndex = store.components.firstIndex(where: { $0.componentID == record.componentID }) {
            store.components[existingIndex] = record
        } else {
            store.components.append(record)
        }
    }

    nonisolated private static func replaceCurrentLink(for kind: ManagedComponentKind, with directory: URL) throws {
        let componentRoot = ExternalSupportPaths.managedComponentRoot(kind)
        try FileManager.default.createDirectory(at: componentRoot, withIntermediateDirectories: true)

        let currentLink = ExternalSupportPaths.managedCurrentLink(kind)
        let newLink = componentRoot.appendingPathComponent("current.new")
        try? FileManager.default.removeItem(at: newLink)
        try FileManager.default.createSymbolicLink(at: newLink, withDestinationURL: directory)

        if FileManager.default.fileExists(atPath: currentLink.path) {
            try FileManager.default.removeItem(at: currentLink)
        }
        try FileManager.default.moveItem(at: newLink, to: currentLink)
    }

    nonisolated private static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ExternalToolsManagerError.http(http.statusCode)
        }
    }

    nonisolated private static func runSystemTool(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExternalToolsManagerError.systemToolFailed(executable.lastPathComponent)
        }
    }

    nonisolated private static func urlSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operationDescription: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let duration = UInt64(max(seconds, 0.1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: duration)
                throw ExternalToolsManagerError.timeout(operationDescription)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

enum ExternalToolsManagerError: LocalizedError {
    case manifestMissing
    case componentMissing(String)
    case assetMissing(String)
    case invalidChecksum(String)
    case invalidPayload(String)
    case rollbackUnavailable(String)
    case http(Int)
    case systemToolFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "Could not find managed support manifest in the published support channel."
        case .componentMissing(let name):
            return "No managed support package was published for \(name)."
        case .assetMissing(let name):
            return "The release is missing required asset \(name)."
        case .invalidChecksum(let name):
            return "Checksum verification failed for \(name)."
        case .invalidPayload(let name):
            return "The downloaded package for \(name) was not valid."
        case .rollbackUnavailable(let name):
            return "No rollback version is available for \(name)."
        case .http(let statusCode):
            return "Server request failed with HTTP \(statusCode)."
        case .systemToolFailed(let name):
            return "\(name) failed while preparing managed support."
        case .timeout(let context):
            return "\(context) timed out."
        }
    }
}
