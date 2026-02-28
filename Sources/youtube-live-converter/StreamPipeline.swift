import Foundation
import Darwin

@MainActor
final class StreamPipeline: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Idle"
    @Published private(set) var logLines: [String] = []
    @Published private(set) var parsedStatus = ParsedStatus()
    @Published private(set) var preview: StreamPreview?
    @Published private(set) var previewStatus = ""
    @Published private(set) var previewSourceURL = ""

    private var ytDlpProcess: Process?
    private var ffmpegProcess: Process?
    private var normalizerProcess: Process?
    private var ytDlpErrorPipe: Pipe?
    private var ffmpegErrorPipe: Pipe?
    private var normalizerErrorPipe: Pipe?
    private var dvrBufferMonitorTask: Task<Void, Never>?
    private var outputFreezeMonitorTask: Task<Void, Never>?
    private var diagnosticHeartbeatTask: Task<Void, Never>?
    private var currentConfig: StreamConfig?
    private var dvrSessionDirectory: URL?
    private var dvrPlaylistURL: URL?
    private var dvrSegmentPattern: String?

    private var shouldKeepRunning = false
    private var restartScheduled = false
    private var generation = 0
    private var restartAttempts = 0
    private var toolPaths: ToolPaths?
    private var logMonitoringEnabled = true
    private var cliLogMirroringEnabled = false
    private var forceSoftwareEncoderForSession = false
    private var freezeRestartTimestamps: [Date] = []
    private var bufferCountdownTask: Task<Void, Never>?
    private var previewRequestID = 0
    private var lastStatsParseUpdate = Date.distantPast
    private var lastYtDlpEventUpdate = Date.distantPast
    private var lastFfmpegEventUpdate = Date.distantPast
    private var lastFfmpegProgressSeconds: Double = 0
    private var lastFfmpegProgressAt = Date.distantPast
    private var hasSeenFfmpegProgress = false
    private var lowSpeedSince = Date.distantPast
    private var lowSpeedHealthySince = Date.distantPast
    private var outputFreezeActive = false
    private var outputFreezeStartedAt = Date.distantPast
    private var lastOutputFreezeHeartbeatAt = Date.distantPast
    private var lastFfmpegDupCount: Int?
    private var lastFfmpegDupSampleAt = Date.distantPast
    private var lastFfmpegFrameCount: Int?
    private var lastVideoFrameAdvanceAt = Date.distantPast
    private var videoCadenceFreezeActive = false
    private var videoCadenceFreezeStartedAt = Date.distantPast
    private var lastVideoCadenceHeartbeatAt = Date.distantPast
    private var duplicationFreezeActive = false
    private var duplicationFreezeStartedAt = Date.distantPast
    private var lastDuplicationAlertAt = Date.distantPast
    private var lastHighDupAt = Date.distantPast
    private var stallRecoveryTriggered = false
    private var freezeRecoveryTriggered = false
    private var pendingRestartAfterDrain = false
    private var bufferExhausted = false
    private var lastBufferUiUpdate = Date.distantPast
    private var estimatedOutputBitrateBps: Double = 0
    private var pendingLogChunkBySource: [String: String] = [:]
    private var suppressedMetadataLineCount = 0
    private var lastSuppressedMetadataFlushAt = Date.distantPast
    private var suppressedProgressLineCount = 0
    private var lastSuppressedProgressFlushAt = Date.distantPast
    private var pendingUiLogLines: [String] = []
    private var logFlushTask: Task<Void, Never>?
    private var ffmpegDiagnosticCounters: [String: Int] = [:]
    private var recentFfmpegDiagnosticLines: [String] = []
    private var lastDiagnosticSnapshotAt = Date.distantPast
    private var lastSpeedDriftLogAt = Date.distantPast
    private var destinationBusyUntil = Date.distantPast
    private var highSpeedSince = Date.distantPast
    private var lastPublishStartedAt = Date.distantPast
    private var publisherRestartScheduled = false
    private var lastFfmpegProgressLogAt = Date.distantPast
    private var pendingReprimeAfterRestart = false
    private var startupReprimeActive = false
    private var catchUpExpiresAt = Date.distantPast

    func start(config: StreamConfig) {
        guard !config.sourceURL.isEmpty, !config.outputTarget.isEmpty else {
            appendLog("[app] Source URL and output target are required.")
            return
        }

        guard let paths = resolveToolPaths() else {
            status = "Missing Tools"
            return
        }

        forceSoftwareEncoderForSession = false
        freezeRestartTimestamps = []
        pendingReprimeAfterRestart = false
        startupReprimeActive = false
        catchUpExpiresAt = Date.distantPast
        destinationBusyUntil = Date.distantPast
        highSpeedSince = Date.distantPast
        lastPublishStartedAt = Date.distantPast
        publisherRestartScheduled = false
        startPipeline(config: config, paths: paths)
    }

    func stop() {
        shouldKeepRunning = false
        generation += 1
        restartScheduled = false
        bufferCountdownTask?.cancel()
        bufferCountdownTask = nil
        terminatePipeline()
        isRunning = false
        status = "Stopped"
        flushPendingUiLogs()
        flushSuppressedMetadataIfNeeded(force: true)
        flushSuppressedProgressIfNeeded(force: true)
        parsedStatus.sourceState = "Stopped"
        parsedStatus.outputState = "Stopped"
        parsedStatus.bufferState = "Stopped"
        parsedStatus.bufferProgress = 0
        stallRecoveryTriggered = false
        freezeRecoveryTriggered = false
        hasSeenFfmpegProgress = false
        lowSpeedSince = Date.distantPast
        lowSpeedHealthySince = Date.distantPast
        outputFreezeActive = false
        outputFreezeStartedAt = Date.distantPast
        lastOutputFreezeHeartbeatAt = Date.distantPast
        lastFfmpegDupCount = nil
        lastFfmpegDupSampleAt = Date.distantPast
        lastFfmpegFrameCount = nil
        lastVideoFrameAdvanceAt = Date.distantPast
        videoCadenceFreezeActive = false
        videoCadenceFreezeStartedAt = Date.distantPast
        lastVideoCadenceHeartbeatAt = Date.distantPast
        duplicationFreezeActive = false
        duplicationFreezeStartedAt = Date.distantPast
        lastDuplicationAlertAt = Date.distantPast
        lastHighDupAt = Date.distantPast
        pendingRestartAfterDrain = false
        bufferExhausted = false
        lastBufferUiUpdate = Date.distantPast
        estimatedOutputBitrateBps = 0
        pendingLogChunkBySource = [:]
        suppressedMetadataLineCount = 0
        lastSuppressedMetadataFlushAt = Date.distantPast
        suppressedProgressLineCount = 0
        lastSuppressedProgressFlushAt = Date.distantPast
        ffmpegDiagnosticCounters = [:]
        recentFfmpegDiagnosticLines = []
        lastDiagnosticSnapshotAt = Date.distantPast
        lastSpeedDriftLogAt = Date.distantPast
        lastFfmpegProgressLogAt = Date.distantPast
        pendingReprimeAfterRestart = false
        startupReprimeActive = false
        catchUpExpiresAt = Date.distantPast
        destinationBusyUntil = Date.distantPast
        highSpeedSince = Date.distantPast
        lastPublishStartedAt = Date.distantPast
        publisherRestartScheduled = false
        dvrBufferMonitorTask?.cancel()
        dvrBufferMonitorTask = nil
        cleanupDvrSessionFiles()
        dvrSessionDirectory = nil
        dvrPlaylistURL = nil
        dvrSegmentPattern = nil
    }

    private func startPipeline(config: StreamConfig, paths: ToolPaths) {
        stop()
        currentConfig = config
        toolPaths = paths
        shouldKeepRunning = true
        restartAttempts = 0
        parsedStatus = ParsedStatus()
        parsedStatus.sourceState = "Starting"
        parsedStatus.outputState = "Starting"
        parsedStatus.bufferState = bufferStateText(for: config)
        parsedStatus.bufferProgress = initialBufferProgress(for: config)
        parsedStatus.avSyncState = avSyncStateText(for: config)
        lastFfmpegProgressSeconds = 0
        lastFfmpegProgressAt = Date()
        hasSeenFfmpegProgress = false
        lowSpeedSince = Date.distantPast
        lowSpeedHealthySince = Date.distantPast
        outputFreezeActive = false
        outputFreezeStartedAt = Date.distantPast
        lastOutputFreezeHeartbeatAt = Date.distantPast
        lastFfmpegDupCount = nil
        lastFfmpegDupSampleAt = Date.distantPast
        lastFfmpegFrameCount = nil
        lastVideoFrameAdvanceAt = Date.distantPast
        videoCadenceFreezeActive = false
        videoCadenceFreezeStartedAt = Date.distantPast
        lastVideoCadenceHeartbeatAt = Date.distantPast
        duplicationFreezeActive = false
        duplicationFreezeStartedAt = Date.distantPast
        lastDuplicationAlertAt = Date.distantPast
        lastHighDupAt = Date.distantPast
        stallRecoveryTriggered = false
        freezeRecoveryTriggered = false
        pendingRestartAfterDrain = false
        bufferExhausted = false
        lastBufferUiUpdate = Date.distantPast
        estimatedOutputBitrateBps = 0
        pendingLogChunkBySource = [:]
        suppressedMetadataLineCount = 0
        lastSuppressedMetadataFlushAt = Date.distantPast
        suppressedProgressLineCount = 0
        lastSuppressedProgressFlushAt = Date.distantPast
        pendingUiLogLines = []
        logFlushTask?.cancel()
        logFlushTask = nil
        ffmpegDiagnosticCounters = [:]
        recentFfmpegDiagnosticLines = []
        lastDiagnosticSnapshotAt = Date.distantPast
        lastSpeedDriftLogAt = Date.distantPast
        lastFfmpegProgressLogAt = Date.distantPast
        destinationBusyUntil = Date.distantPast
        highSpeedSince = Date.distantPast
        lastPublishStartedAt = Date.distantPast
        publisherRestartScheduled = false

        launchPipeline()
    }

    func clearLogs() {
        logFlushTask?.cancel()
        logFlushTask = nil
        pendingUiLogLines = []
        logLines = []
        parsedStatus = ParsedStatus()
        suppressedMetadataLineCount = 0
        lastSuppressedMetadataFlushAt = Date.distantPast
        suppressedProgressLineCount = 0
        lastSuppressedProgressFlushAt = Date.distantPast
    }

    func setLogMonitoringEnabled(_ enabled: Bool) {
        guard logMonitoringEnabled != enabled else { return }
        logMonitoringEnabled = enabled
        let appliesNote = isRunning ? " (applies on next start)." : "."
        appendLog("[app] Log monitoring \(enabled ? "enabled" : "disabled")\(appliesNote)")
        if !enabled {
            parsedStatus.ffmpegTime = ""
            parsedStatus.ffmpegBitrate = ""
            parsedStatus.ffmpegSpeed = ""
        }
    }

    func setCliLogMirroringEnabled(_ enabled: Bool) {
        cliLogMirroringEnabled = enabled
    }

    func loadPreview(for sourceURL: String) {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preview = nil
            previewStatus = ""
            previewSourceURL = ""
            return
        }

        previewRequestID += 1
        let requestID = previewRequestID
        previewStatus = "Loading source info..."

        Task.detached(priority: .userInitiated) {
            let metadata = await StreamPipeline.fetchPreviewMetadata(for: trimmed)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard requestID == self.previewRequestID else { return }
                self.previewSourceURL = trimmed

                if let preview = metadata.preview {
                    self.preview = preview
                    self.previewStatus = self.previewStatusText(for: preview.publishState)
                } else {
                    self.preview = nil
                    self.previewStatus = metadata.message
                }
            }
        }
    }

    private func previewStatusText(for state: PublishState) -> String {
        switch state {
        case .live:
            return "Source is live"
        case .upcoming:
            return "Source is upcoming"
        case .published:
            return "Source is not live (pre-recorded or ended)"
        case .unknown:
            return "Source info loaded (live status unknown)"
        }
    }

    private func launchPipeline() {
        guard shouldKeepRunning, let config = currentConfig else { return }
        generation += 1
        let currentGeneration = generation

        let ytDlp = Process()
        guard let paths = toolPaths else {
            appendLog("[app] Tool paths are unavailable.")
            status = "Missing Tools"
            return
        }

        ytDlp.executableURL = paths.ytDlp
        let ffmpegToolsDir = paths.ffmpeg.deletingLastPathComponent().path
        let ytDlpWorkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-live-converter", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: ytDlpWorkDir,
                withIntermediateDirectories: true
            )
            ytDlp.currentDirectoryURL = ytDlpWorkDir
        } catch {
            appendLog("[app] Failed to create yt-dlp temp directory: \(error.localizedDescription)")
        }

        var ytDlpArguments = ["--no-part", "--no-progress"]
        if let deno = paths.deno {
            ytDlpArguments += ["--js-runtimes", "deno:\(deno.path)"]
        }
        ytDlpArguments += [
            "--paths", "home:\(ytDlpWorkDir.path)",
            "--paths", "temp:\(ytDlpWorkDir.path)",
            "--ffmpeg-location",
            ffmpegToolsDir,
            "-o",
            "-",
            config.sourceURL
        ]
        ytDlp.arguments = ytDlpArguments
        ytDlp.environment = mergedEnvironment(
            prependingPath: ffmpegToolsDir
        )

        let mediaPipe = Pipe()
        let monitorLogs = logMonitoringEnabled
        let ytError = monitorLogs ? Pipe() : nil
        let ffError = monitorLogs ? Pipe() : nil
        let normalizerError = (monitorLogs && config.encodeMode == .transcode) ? Pipe() : nil
        let useDvrPipeline = config.encodeMode == .transcode
        startupReprimeActive = false
        pendingReprimeAfterRestart = false

        ytDlp.standardOutput = mediaPipe
        if let ytError {
            ytDlp.standardError = ytError
        } else {
            ytDlp.standardError = FileHandle.nullDevice
        }

        ytDlpErrorPipe = ytError
        ffmpegErrorPipe = ffError
        normalizerErrorPipe = normalizerError

        resetPerLaunchState(config: config)

        if let ytError {
            observe(pipe: ytError, source: "yt-dlp", generation: currentGeneration)
        }
        if let ffError {
            observe(pipe: ffError, source: "ffmpeg", generation: currentGeneration)
        }
        if let normalizerError {
            observe(pipe: normalizerError, source: "ffmpeg-normalizer", generation: currentGeneration)
        }

        ytDlp.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(
                    generation: currentGeneration,
                    source: "yt-dlp",
                    status: proc.terminationStatus
                )
            }
        }

        do {
            let ffmpeg: Process
            var normalizer: Process?
            let ffmpegInput: Pipe
            if useDvrPipeline {
                let dvr = try makeDvrSessionDirectory()
                dvrSessionDirectory = dvr.directory
                dvrPlaylistURL = dvr.playlistURL
                dvrSegmentPattern = dvr.segmentPattern
                ffmpegInput = Pipe()
                let norm = makeDvrNormalizerProcess(
                    paths: paths,
                    config: config,
                    generation: currentGeneration,
                    normalizerError: normalizerError,
                    input: mediaPipe,
                    playlistURL: dvr.playlistURL,
                    segmentPattern: dvr.segmentPattern,
                    ffmpegToolsDir: ffmpegToolsDir
                )
                normalizer = norm
                ffmpeg = makeDvrPublisherProcess(
                    paths: paths,
                    config: config,
                    generation: currentGeneration,
                    ffError: ffError,
                    playlistURL: dvr.playlistURL,
                    ffmpegToolsDir: ffmpegToolsDir
                )
            } else {
                ffmpegInput = mediaPipe
                ffmpeg = makeFFmpegProcess(
                    paths: paths,
                    config: config,
                    generation: currentGeneration,
                    ffError: ffError,
                    input: ffmpegInput,
                    ffmpegToolsDir: ffmpegToolsDir
                )
            }

            try ytDlp.run()
            ytDlpProcess = ytDlp

            if useDvrPipeline {
                isRunning = true
                status = "Running"
                parsedStatus.sourceState = "Running"
                parsedStatus.outputState = "Buffering"
                appendLog("[app] Pipeline started (dvr-to-live staging active).")
                if config.bufferSeconds > 0 {
                    appendLog("[app] Output publish will begin after \(config.bufferSeconds)s staged media fill.")
                } else {
                    appendLog("[app] Output publish will begin as soon as staged playlist is ready.")
                }
                if let normalizer {
                    try normalizer.run()
                    normalizerProcess = normalizer
                    appendLog("[app] Normalizer started. Writing staged DVR playlist.")
                }
                startDvrBufferMonitorAndPublisher(
                    publisher: ffmpeg,
                    config: config,
                    generation: currentGeneration
                )
            } else {
                if let normalizer {
                    try normalizer.run()
                    normalizerProcess = normalizer
                }
                try ffmpeg.run()
                ffmpegProcess = ffmpeg
                lastPublishStartedAt = Date()
                highSpeedSince = Date.distantPast

                isRunning = true
                status = "Running"
                parsedStatus.sourceState = "Running"
                parsedStatus.outputState = "Running"
                appendLog("[app] Pipeline started.")
            }

            appendLog("[app] Using yt-dlp: \(paths.ytDlp.path)")
            appendLog("[app] Using ffmpeg: \(paths.ffmpeg.path)")
            appendLog("[app] Using ffprobe: \(paths.ffprobe.path)")
            appendSessionConfigurationLog(config)
            if isCatchUpActive() {
                let remaining = max(1, Int(catchUpExpiresAt.timeIntervalSinceNow.rounded()))
                appendLog("[app] Catch-up mode active (\(remaining)s remaining): realtime pacing (-re) disabled.")
            }
            if config.encodeMode == .transcode {
                let encoder = paths.supportsVideoToolboxH264 ? "h264_videotoolbox (hardware)" : "libx264 (software)"
                appendLog("[app] High compatibility video encoder: \(encoder)")
                appendLog("[app] High compatibility normalizer stage: enabled (normalize -> staged DVR -> publish).")
            }
            if let deno = paths.deno {
                appendLog("[app] Using deno: \(deno.path)")
            } else {
                appendLog("[app] Deno runtime not found. YouTube extraction may be limited.")
            }
            startBufferCountdownIfNeeded(config: config, generation: currentGeneration)
            startOutputFreezeMonitorIfNeeded()
            startDiagnosticHeartbeatIfNeeded()
        } catch {
            appendLog("[app] Failed to start pipeline: \(error.localizedDescription)")
            terminatePipeline()
            scheduleRestart(generation: currentGeneration)
        }
    }

    private func makeFFmpegProcess(
        paths: ToolPaths,
        config: StreamConfig,
        generation: Int,
        ffError: Pipe?,
        input: Pipe,
        ffmpegToolsDir: String
    ) -> Process {
        let ffmpeg = Process()
        ffmpeg.executableURL = paths.ffmpeg
        ffmpeg.arguments = ffmpegArguments(for: config)
        ffmpeg.environment = mergedEnvironment(prependingPath: ffmpegToolsDir)
        ffmpeg.standardInput = input
        ffmpeg.standardOutput = FileHandle.nullDevice
        if let ffError {
            ffmpeg.standardError = ffError
        } else {
            ffmpeg.standardError = FileHandle.nullDevice
        }
        ffmpeg.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(
                    generation: generation,
                    source: "ffmpeg",
                    status: proc.terminationStatus
                )
            }
        }
        return ffmpeg
    }

    private struct DvrSession {
        let directory: URL
        let playlistURL: URL
        let segmentPattern: String
    }

    private func makeDvrSessionDirectory() throws -> DvrSession {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-live-converter-dvr", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let playlistURL = sessionDir.appendingPathComponent("staged.m3u8")
        let segmentPattern = sessionDir.appendingPathComponent("seg-%09d.ts").path
        return DvrSession(directory: sessionDir, playlistURL: playlistURL, segmentPattern: segmentPattern)
    }

    private func makeDvrNormalizerProcess(
        paths: ToolPaths,
        config: StreamConfig,
        generation: Int,
        normalizerError: Pipe?,
        input: Pipe,
        playlistURL: URL,
        segmentPattern: String,
        ffmpegToolsDir: String
    ) -> Process {
        let normalizer = Process()
        normalizer.executableURL = paths.ffmpeg
        normalizer.arguments = normalizerToDvrArguments(
            for: config,
            playlistURL: playlistURL,
            segmentPattern: segmentPattern
        )
        normalizer.environment = mergedEnvironment(prependingPath: ffmpegToolsDir)
        normalizer.standardInput = input
        normalizer.standardOutput = FileHandle.nullDevice
        if let normalizerError {
            normalizer.standardError = normalizerError
        } else {
            normalizer.standardError = FileHandle.nullDevice
        }
        normalizer.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(
                    generation: generation,
                    source: "normalizer",
                    status: proc.terminationStatus
                )
            }
        }
        return normalizer
    }

    private func makeDvrPublisherProcess(
        paths: ToolPaths,
        config: StreamConfig,
        generation: Int,
        ffError: Pipe?,
        playlistURL: URL,
        ffmpegToolsDir: String
    ) -> Process {
        let ffmpeg = Process()
        ffmpeg.executableURL = paths.ffmpeg
        ffmpeg.arguments = dvrPublisherArguments(for: config, playlistURL: playlistURL)
        ffmpeg.environment = mergedEnvironment(prependingPath: ffmpegToolsDir)
        ffmpeg.standardInput = FileHandle.nullDevice
        ffmpeg.standardOutput = FileHandle.nullDevice
        if let ffError {
            ffmpeg.standardError = ffError
        } else {
            ffmpeg.standardError = FileHandle.nullDevice
        }
        ffmpeg.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(
                    generation: generation,
                    source: "ffmpeg",
                    status: proc.terminationStatus
                )
            }
        }
        return ffmpeg
    }

    private func startDvrBufferMonitorAndPublisher(
        publisher: Process,
        config: StreamConfig,
        generation: Int
    ) {
        dvrBufferMonitorTask?.cancel()
        dvrBufferMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let playlistURL = self.dvrPlaylistURL else { return }
            let targetDelay = max(0.0, Double(config.bufferSeconds))
            var startedPublishing = false

            while !Task.isCancelled {
                guard self.shouldKeepRunning, generation == self.generation else { return }

                let playlistDuration = self.readPlaylistDurationSeconds(from: playlistURL)
                let outputSeconds = self.parseClockToSeconds(self.parsedStatus.ffmpegTime) ?? 0
                let availableSeconds = max(0.0, playlistDuration - outputSeconds)
                self.updateDvrBufferState(
                    config: config,
                    availableSeconds: availableSeconds,
                    targetDelay: targetDelay,
                    publishingStarted: startedPublishing
                )

                if !startedPublishing {
                    let reachedTarget = targetDelay <= 0 || playlistDuration >= targetDelay
                    let canStartEarlyOnEnd = self.ytDlpProcess?.isRunning != true && playlistDuration > 0.5
                    if reachedTarget || canStartEarlyOnEnd {
                        do {
                            try publisher.run()
                            self.ffmpegProcess = publisher
                            self.lastPublishStartedAt = Date()
                            self.highSpeedSince = Date.distantPast
                            self.publisherRestartScheduled = false
                            self.parsedStatus.outputState = "Publishing"
                            self.startupReprimeActive = false
                            self.appendLog("[app] Startup buffer filled. Publishing to destination.")
                            startedPublishing = true
                        } catch {
                            let nsError = error as NSError
                            self.appendLog(
                                "[app] Failed to start publisher after buffer fill: \(error.localizedDescription) [domain=\(nsError.domain) code=\(nsError.code)]"
                            )
                            self.terminatePipeline()
                            self.scheduleRestart(generation: generation)
                            return
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func terminatePipeline() {
        let ytProcess = ytDlpProcess
        let outProcess = ffmpegProcess
        let normProcess = normalizerProcess

        ytProcess?.terminationHandler = nil
        outProcess?.terminationHandler = nil
        normProcess?.terminationHandler = nil
        publisherRestartScheduled = false
        dvrBufferMonitorTask?.cancel()
        dvrBufferMonitorTask = nil
        outputFreezeMonitorTask?.cancel()
        outputFreezeMonitorTask = nil
        diagnosticHeartbeatTask?.cancel()
        diagnosticHeartbeatTask = nil
        bufferCountdownTask?.cancel()
        bufferCountdownTask = nil

        terminateProcessIfRunning(ytProcess, label: "yt-dlp")
        terminateProcessIfRunning(outProcess, label: "ffmpeg")
        terminateProcessIfRunning(normProcess, label: "normalizer")

        ytDlpProcess = nil
        ffmpegProcess = nil
        normalizerProcess = nil
        cleanupDvrSessionFiles()
        dvrSessionDirectory = nil
        dvrPlaylistURL = nil
        dvrSegmentPattern = nil
        ytDlpErrorPipe?.fileHandleForReading.readabilityHandler = nil
        ffmpegErrorPipe?.fileHandleForReading.readabilityHandler = nil
        normalizerErrorPipe?.fileHandleForReading.readabilityHandler = nil
        ytDlpErrorPipe = nil
        ffmpegErrorPipe = nil
        normalizerErrorPipe = nil
    }

    private func terminateProcessIfRunning(_ process: Process?, label: String) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard process.isRunning else { return }
            _ = Darwin.kill(pid_t(pid), SIGKILL)
            Task { @MainActor in
                self?.appendLog("[app] Force-killed lingering \(label) process (pid \(pid)).")
            }
        }
    }

    private func handleTermination(generation: Int, source: String, status: Int32) {
        guard generation == self.generation else { return }
        bufferCountdownTask?.cancel()
        bufferCountdownTask = nil
        Task { @MainActor in
            self.appendLog("[\(source)] exited with status \(status)")
        }
        if source == "yt-dlp" {
            parsedStatus.sourceState = "Stopped (\(status))"
            ytDlpProcess = nil
            ytDlpErrorPipe?.fileHandleForReading.readabilityHandler = nil
            ytDlpErrorPipe = nil

            // In delayed-buffer modes, let ffmpeg finish draining buffered data before restart.
            if supportsBufferedDrainOnSourceExit(),
               ffmpegProcess?.isRunning == true {
                pendingRestartAfterDrain = shouldKeepRunning
                appendLog("[app] Source ended. Draining buffered output before restart.")
                return
            }
        } else if source == "ffmpeg" {
            parsedStatus.outputState = "Stopped (\(status))"
            ffmpegProcess = nil
            ffmpegErrorPipe?.fileHandleForReading.readabilityHandler = nil
            ffmpegErrorPipe = nil

            if pendingRestartAfterDrain {
                pendingRestartAfterDrain = false
                terminatePipeline()
                if shouldKeepRunning {
                    scheduleRestart(generation: generation, reason: .processExit)
                } else {
                    Task { @MainActor in
                        self.isRunning = false
                        self.status = "Stopped"
                    }
                }
                return
            }
        } else if source == "normalizer" {
            normalizerProcess = nil
            normalizerErrorPipe?.fileHandleForReading.readabilityHandler = nil
            normalizerErrorPipe = nil

            if pendingRestartAfterDrain {
                // Source has already ended; let publisher drain and own restart timing.
                return
            }
        }

        terminatePipeline()

        if shouldKeepRunning {
            scheduleRestart(generation: generation, reason: .processExit)
        } else {
            Task { @MainActor in
                self.isRunning = false
                self.status = "Stopped"
            }
        }
    }

    private func scheduleRestart(generation: Int, reason: RestartReason = .general) {
        guard generation == self.generation else { return }
        guard shouldKeepRunning else { return }
        guard !restartScheduled else { return }

        if reason == .freeze {
            pendingReprimeAfterRestart = true
        }
        restartScheduled = true
        restartAttempts += 1
        let baseDelay = min(pow(2.0, Double(restartAttempts)), 30.0)
        let destinationBusyDelay = max(0, destinationBusyUntil.timeIntervalSinceNow)
        let delay = max(baseDelay, destinationBusyDelay)
        let reasonLabel = restartReasonLabel(reason)

        status = "Reconnecting (\(Int(delay))s)"
        parsedStatus.reconnectDelay = "\(Int(delay))s"
        appendLog("[app] Restarting pipeline in \(Int(delay))s (reason: \(reasonLabel)).")

        Task { @MainActor [weak self] in
            let duration = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)
            self?.restartIfNeeded(generation: generation)
        }
    }

    private func restartIfNeeded(generation: Int) {
        guard shouldKeepRunning else { return }
        guard generation == self.generation else { return }
        restartScheduled = false
        launchPipeline()
    }

    private func schedulePublisherOnlyRestart(
        generation: Int,
        reason: String,
        delay: TimeInterval = 1.5
    ) {
        guard !publisherRestartScheduled else { return }
        guard shouldKeepRunning, generation == self.generation else { return }
        guard let config = currentConfig,
              config.encodeMode == .transcode else {
            appendLog("[app] Publisher-only restart unavailable; falling back to full pipeline restart.")
            terminatePipeline()
            scheduleRestart(generation: generation, reason: .general)
            return
        }

        publisherRestartScheduled = true
        parsedStatus.outputState = "Reconnecting Output"
        appendLog("[app] Restarting publisher stage (\(reason)).")

        ffmpegProcess?.terminationHandler = nil
        terminateProcessIfRunning(ffmpegProcess, label: "ffmpeg")
        ffmpegProcess = nil
        ffmpegErrorPipe?.fileHandleForReading.readabilityHandler = nil
        ffmpegErrorPipe = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.shouldKeepRunning, generation == self.generation else {
                self.publisherRestartScheduled = false
                return
            }
            guard let paths = self.toolPaths,
                  let playlistURL = self.dvrPlaylistURL else {
                self.publisherRestartScheduled = false
                self.appendLog("[app] Publisher restart prerequisites missing; doing full restart.")
                self.terminatePipeline()
                self.scheduleRestart(generation: generation, reason: .general)
                return
            }

            let ffError = Pipe()
            self.ffmpegErrorPipe = ffError
            if self.logMonitoringEnabled {
                self.observe(pipe: ffError, source: "ffmpeg", generation: generation)
            }
            let ffmpegToolsDir = paths.ffmpeg.deletingLastPathComponent().path
            let publisher = self.makeDvrPublisherProcess(
                paths: paths,
                config: config,
                generation: generation,
                ffError: ffError,
                playlistURL: playlistURL,
                ffmpegToolsDir: ffmpegToolsDir
            )
            do {
                try publisher.run()
                self.ffmpegProcess = publisher
                self.lastPublishStartedAt = Date()
                self.highSpeedSince = Date.distantPast
                self.parsedStatus.outputState = "Publishing"
                self.appendLog("[app] Publisher restarted from staged DVR playlist.")
            } catch {
                self.appendLog("[app] Publisher restart failed: \(error.localizedDescription)")
                self.terminatePipeline()
                self.scheduleRestart(generation: generation, reason: .general)
            }
            self.publisherRestartScheduled = false
        }
    }

    private func ffmpegArguments(for config: StreamConfig) -> [String] {
        let syncOffsetMs = config.avSyncOffsetMs
        let extraAudioDelayMs = max(0, syncOffsetMs)
        let extraVideoDelaySeconds = syncOffsetMs < 0 ? Double(-syncOffsetMs) / 1_000.0 : 0
        // Startup buffering is handled by staged DVR playout; filters should only apply A/V sync offsets.
        let totalVideoDelaySeconds = extraVideoDelaySeconds
        let totalAudioDelayMs = extraAudioDelayMs
        var audioFilters: [String] = []
        var inputArgs: [String] = []
        if config.encodeMode == .copy {
            // Be more tolerant of HLS discontinuities and timestamp issues in copy-based modes.
            inputArgs += ["-fflags", "+genpts+discardcorrupt+igndts+sortdts", "-err_detect", "ignore_err"]
        }
        if config.encodeMode == .transcode {
            // High compatibility path: aggressively tolerate timestamp disorder and damaged packets.
            inputArgs += [
                "-thread_queue_size", "8192",
                "-fflags", "+genpts+discardcorrupt+igndts+sortdts",
                "-err_detect", "ignore_err"
            ]
        }
        var args = [
            "-hide_banner",
            "-loglevel",
            "info",
            "-stats_period",
            "1",
            "-progress",
            "pipe:2"
        ]
        if config.encodeMode == .transcode {
            // Keep publisher egress deterministic for receiver compatibility.
            args += ["-re"]
        }
        args += inputArgs
        args += ["-i", "pipe:0"]
        // Keep stream selection deterministic to avoid stream switching side-effects.
        args += ["-map", "0:v:0", "-map", "0:a:0?"]

        let useVideoToolbox = (toolPaths?.supportsVideoToolboxH264 == true) && !forceSoftwareEncoderForSession
        switch config.encodeMode {
        case .copy:
            args += ["-c:v", "copy", "-c:a", "copy"]
        case .transcode:
            // Rebuild a stable monotonic A/V timeline in compatibility mode.
            // Keep correction gentle to avoid audible pitch warble on long sessions.
            let asyncDepth = config.audioContinuityEnabled ? "1000" : "1"
            audioFilters.append("aresample=48000:async=\(asyncDepth):min_hard_comp=0.100:comp_duration=1.5:max_soft_comp=0.050:first_pts=0")
            audioFilters.append("asetpts=N/SR/TB")
            let targetFps = resolvedTargetFPS()
            // Build video timing from frame count to avoid inheriting source PTS discontinuities.
            var videoSetptsExpr = "N/\(targetFps)/TB"
            if totalVideoDelaySeconds > 0 {
                let delay = String(format: "%.3f", totalVideoDelaySeconds)
                videoSetptsExpr += "+\(delay)/TB"
            }
            let videoFilter = "fps=\(targetFps),settb=AVTB,setpts=\(videoSetptsExpr)"
            if useVideoToolbox {
                // Prefer hardware encoding on macOS for stable real-time throughput.
                args += [
                    "-fps_mode", "cfr",
                    "-vsync", "cfr",
                    "-r", "\(targetFps)",
                    "-c:v", "h264_videotoolbox",
                    "-allow_sw", "1",
                    "-realtime", "1",
                    "-pix_fmt", "yuv420p",
                    "-g", "30",
                    "-keyint_min", "30",
                    "-bf", "0",
                    "-b:v", "3500k",
                    "-maxrate", "4500k",
                    "-bufsize", "9000k",
                    "-profile:v", "baseline",
                    "-force_key_frames", "expr:gte(t,n_forced*1)",
                    "-vf", videoFilter,
                    "-c:a", "aac",
                    "-ar", "48000",
                    "-ac", "2",
                    "-b:a", "128k"
                ]
            } else {
                args += [
                    "-fps_mode", "cfr",
                    "-vsync", "cfr",
                    "-r", "\(targetFps)",
                    "-c:v", "libx264",
                    "-preset", "ultrafast",
                    "-tune", "zerolatency",
                    "-crf", "27",
                    "-x264-params", "force-cfr=1:keyint=30:min-keyint=30:scenecut=0:repeat-headers=1",
                    "-pix_fmt", "yuv420p",
                    "-g", "30",
                    "-keyint_min", "30",
                    "-sc_threshold", "0",
                    "-profile:v", "baseline",
                    "-force_key_frames", "expr:gte(t,n_forced*1)",
                    "-vf", videoFilter,
                    "-c:a", "aac",
                    "-ar", "48000",
                    "-ac", "2",
                    "-b:a", "128k"
                ]
            }
            if totalAudioDelayMs > 0 {
                audioFilters.append("adelay=\(totalAudioDelayMs)|\(totalAudioDelayMs)")
            }
            if config.audioBoostEnabled {
                let boostDb = config.audioBoostDb
                if boostDb > 0 {
                    audioFilters.append("volume=\(boostDb)dB")
                }
                // Hard limit to -1 dBFS to reduce clipping risk after gain.
                audioFilters.append("alimiter=limit=0.891251")
            }
            if !audioFilters.isEmpty {
                args += ["-af", audioFilters.joined(separator: ",")]
            }
        }

        if config.outputType == .rtmp {
            if config.encodeMode == .copy {
                // Improve RTMP receiver compatibility when remuxing bursty MPEG-TS input.
                args += ["-bsf:v", "extract_extradata"]
            }
            // Keep muxing latency low but not ultra-tight; more tolerant settings work better
            // across ingest stacks based on ffmpeg/vlc derivatives.
            args += [
                "-flvflags", "no_duration_filesize",
                "-fflags", "+flush_packets",
                "-flush_packets", "1",
                "-max_muxing_queue_size", "4096",
                "-muxdelay", "0",
                "-muxpreload", "0",
                "-max_interleave_delta", "0",
                "-rtmp_live", "live"
            ]
        }

        switch config.outputType {
        case .rtmp:
            args += ["-f", "flv", config.outputTarget]
        case .hls:
            args += [
                "-f", "hls",
                "-hls_time", "2",
                "-hls_list_size", "6",
                "-hls_flags", "delete_segments+append_list+independent_segments",
                config.outputTarget
            ]
        }

        return args
    }

    private func normalizerArguments(for config: StreamConfig) -> [String] {
        let syncOffsetMs = config.avSyncOffsetMs
        let extraAudioDelayMs = max(0, syncOffsetMs)
        let extraVideoDelaySeconds = syncOffsetMs < 0 ? Double(-syncOffsetMs) / 1_000.0 : 0
        let totalVideoDelaySeconds = extraVideoDelaySeconds
        let totalAudioDelayMs = extraAudioDelayMs
        var audioFilters: [String] = []

        var args = [
            "-hide_banner",
            "-loglevel",
            "info",
            "-stats_period",
            "1",
            "-progress",
            "pipe:2",
            "-thread_queue_size",
            "8192",
            "-fflags",
            "+genpts+discardcorrupt+igndts+sortdts",
            "-err_detect",
            "ignore_err",
            "-i",
            "pipe:0",
            "-map",
            "0:v:0",
            "-map",
            "0:a:0?"
        ]

        // Rebuild a stable monotonic A/V timeline in compatibility mode.
        let asyncDepth = config.audioContinuityEnabled ? "1000" : "1"
        audioFilters.append("aresample=48000:async=\(asyncDepth):min_hard_comp=0.100:comp_duration=1.5:max_soft_comp=0.050:first_pts=0")
        audioFilters.append("asetpts=N/SR/TB")
        let targetFps = resolvedTargetFPS()
        var videoSetptsExpr = "N/\(targetFps)/TB"
        if totalVideoDelaySeconds > 0 {
            let delay = String(format: "%.3f", totalVideoDelaySeconds)
            videoSetptsExpr += "+\(delay)/TB"
        }
        let videoFilter = "fps=\(targetFps),settb=AVTB,setpts=\(videoSetptsExpr)"
        let useVideoToolbox = (toolPaths?.supportsVideoToolboxH264 == true) && !forceSoftwareEncoderForSession
        if useVideoToolbox {
            args += [
                "-fps_mode", "cfr",
                "-vsync", "cfr",
                "-r", "\(targetFps)",
                "-c:v", "h264_videotoolbox",
                "-allow_sw", "1",
                "-realtime", "1",
                "-pix_fmt", "yuv420p",
                "-g", "30",
                "-keyint_min", "30",
                "-bf", "0",
                "-b:v", "3500k",
                "-maxrate", "4500k",
                "-bufsize", "9000k",
                "-profile:v", "baseline",
                "-force_key_frames", "expr:gte(t,n_forced*1)",
                "-vf", videoFilter,
                "-c:a", "aac",
                "-ar", "48000",
                "-ac", "2",
                "-b:a", "128k"
            ]
        } else {
            args += [
                "-fps_mode", "cfr",
                "-vsync", "cfr",
                "-r", "\(targetFps)",
                "-c:v", "libx264",
                "-preset", "ultrafast",
                "-tune", "zerolatency",
                "-crf", "27",
                "-x264-params", "force-cfr=1:keyint=30:min-keyint=30:scenecut=0:repeat-headers=1",
                "-pix_fmt", "yuv420p",
                "-g", "30",
                "-keyint_min", "30",
                "-sc_threshold", "0",
                "-profile:v", "baseline",
                "-force_key_frames", "expr:gte(t,n_forced*1)",
                "-vf", videoFilter,
                "-c:a", "aac",
                "-ar", "48000",
                "-ac", "2",
                "-b:a", "128k"
            ]
        }

        if totalAudioDelayMs > 0 {
            audioFilters.append("adelay=\(totalAudioDelayMs)|\(totalAudioDelayMs)")
        }
        if config.audioBoostEnabled {
            let boostDb = config.audioBoostDb
            if boostDb > 0 {
                audioFilters.append("volume=\(boostDb)dB")
            }
            audioFilters.append("alimiter=limit=0.891251")
        }
        if !audioFilters.isEmpty {
            args += ["-af", audioFilters.joined(separator: ",")]
        }

        args += [
            "-muxdelay", "0",
            "-muxpreload", "0",
            "-f", "mpegts",
            "pipe:1"
        ]
        return args
    }

    private func normalizerToDvrArguments(
        for config: StreamConfig,
        playlistURL: URL,
        segmentPattern: String
    ) -> [String] {
        var args = normalizerArguments(for: config)
        if let last = args.last, last == "pipe:1" {
            _ = args.popLast()
        }
        if args.suffix(2) == ["-f", "mpegts"] {
            _ = args.popLast()
            _ = args.popLast()
        }
        args += [
            "-f", "hls",
            "-hls_time", "1",
            "-hls_list_size", "0",
            "-hls_flags", "append_list+omit_endlist+independent_segments+program_date_time+temp_file",
            "-hls_segment_filename", segmentPattern,
            playlistURL.path
        ]
        return args
    }

    private func dvrPublisherArguments(for config: StreamConfig, playlistURL: URL) -> [String] {
        var args = [
            "-hide_banner",
            "-loglevel", "info",
            "-stats_period", "1",
            "-progress", "pipe:2",
            "-re",
            "-thread_queue_size", "8192",
            "-fflags", "+genpts+discardcorrupt+igndts+sortdts",
            "-err_detect", "ignore_err",
            "-i", playlistURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c:v", "copy",
            "-c:a", "copy"
        ]

        if config.outputType == .rtmp {
            args += [
                "-bsf:v", "extract_extradata",
                "-flvflags", "no_duration_filesize",
                "-fflags", "+flush_packets",
                "-flush_packets", "1",
                "-max_muxing_queue_size", "4096",
                "-muxdelay", "0",
                "-muxpreload", "0",
                "-max_interleave_delta", "0",
                "-rtmp_live", "live"
            ]
        }

        switch config.outputType {
        case .rtmp:
            args += ["-f", "flv", config.outputTarget]
        case .hls:
            args += [
                "-f", "hls",
                "-hls_time", "2",
                "-hls_list_size", "6",
                "-hls_flags", "delete_segments+append_list+independent_segments",
                config.outputTarget
            ]
        }
        return args
    }

    private func resolvedTargetFPS() -> Int {
        let fallback = 30
        guard let label = preview?.frameRateLabel.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return fallback
        }

        let lower = label.lowercased()
        if lower.contains("vfr") || lower.contains("variable") || lower.contains("unknown") {
            return fallback
        }

        if let match = lower.range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression),
           let value = Double(lower[match]) {
            let rounded = Int(value.rounded())
            if rounded >= 15 && rounded <= 120 {
                return rounded
            }
        }
        return fallback
    }

    private func bufferStateText(for config: StreamConfig) -> String {
        guard config.encodeMode == .transcode else {
            return "Off (Stream Copy)"
        }
        if config.bufferSeconds <= 0 {
            return "Off"
        }
        return "On (\(config.bufferSeconds)s delay)"
    }

    private func initialBufferProgress(for config: StreamConfig) -> Double {
        if config.encodeMode != .transcode {
            return 1.0
        }
        return config.bufferSeconds > 0 ? 0.0 : 1.0
    }

    private func avSyncStateText(for config: StreamConfig) -> String {
        if config.encodeMode != .transcode {
            return "Off (Stream Copy)"
        }
        if config.avSyncOffsetMs == 0 {
            return "0 ms"
        }
        if config.avSyncOffsetMs > 0 {
            return "+\(config.avSyncOffsetMs) ms (audio delayed)"
        }
        return "\(config.avSyncOffsetMs) ms (video delayed)"
    }

    private func appendSessionConfigurationLog(_ config: StreamConfig) {
        let outputTarget: String
        switch config.outputType {
        case .hls:
            outputTarget = config.outputTarget
        case .rtmp:
            outputTarget = redactedRTMPTarget(config.outputTarget)
        }

        let boostLabel = config.audioBoostEnabled ? "\(config.audioBoostDb)dB" : "off"
        let continuityLabel = config.audioContinuityEnabled ? "on" : "off"
        let storageLabel = config.useDiskBackedBuffer ? "disk" : "memory"
        let monitoringLabel = logMonitoringEnabled ? "on" : "off"
        let fpsLabel = config.encodeMode == .transcode ? "\(resolvedTargetFPS())fps" : "source"
        appendLog(
            "[app] Session config: mode=\(config.encodeMode.rawValue), format=\(config.outputType.rawValue), buffer=\(config.bufferSeconds)s, storage=\(storageLabel), avOffset=\(config.avSyncOffsetMs)ms, targetFps=\(fpsLabel), audioBoost=\(boostLabel), audioContinuity=\(continuityLabel), logMonitoring=\(monitoringLabel), output=\(outputTarget)"
        )
    }

    private func redactedRTMPTarget(_ raw: String) -> String {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme,
              let host = components.host else {
            return "<invalid rtmp target>"
        }

        let portSuffix = components.port.map { ":\($0)" } ?? ""
        let pathParts = components.path.split(separator: "/")

        // If target is only the app endpoint (e.g. rtmp://127.0.0.1/live),
        // keep it visible so logs do not imply a hidden stream key.
        if pathParts.count <= 1 && (components.query?.isEmpty ?? true) {
            let safePath = components.path.isEmpty ? "" : components.path
            return "\(scheme)://\(host)\(portSuffix)\(safePath)"
        }

        let appPart = pathParts.first.map(String.init) ?? "app"
        return "\(scheme)://\(host)\(portSuffix)/\(appPart)/<redacted>"
    }

    private func observe(pipe: Pipe, source: String, generation: Int) {
        let chunkKey = "\(generation):\(source)"
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    guard let self, generation == self.generation else { return }
                    self.flushPendingLogChunk(for: source, key: chunkKey)
                    self.flushSuppressedMetadataIfNeeded(force: true)
                    self.flushSuppressedProgressIfNeeded(force: true)
                    self.flushPendingUiLogs()
                }
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                self.ingestLogChunk(chunk, source: source, key: chunkKey)
            }
        }
    }

    private func ingestLogChunk(_ chunk: String, source: String, key: String) {
        let existing = pendingLogChunkBySource[key] ?? ""
        let combined = existing + chunk
        let parts = combined.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let endsWithNewline = combined.last?.isNewline == true
        let completeCount = endsWithNewline ? parts.count : max(0, parts.count - 1)

        if endsWithNewline {
            pendingLogChunkBySource[key] = ""
        } else {
            pendingLogChunkBySource[key] = String(parts.last ?? "")
        }

        if completeCount == 0 { return }
        for index in 0..<completeCount {
            let raw = String(parts[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            appendLog("[\(source)] \(normalizedLogPayload(raw))")
        }
    }

    private func flushPendingLogChunk(for source: String, key: String) {
        let remainder = (pendingLogChunkBySource[key] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            pendingLogChunkBySource[key] = ""
            return
        }
        pendingLogChunkBySource[key] = ""
        appendLog("[\(source)] \(normalizedLogPayload(remainder))")
    }

    private func resetPerLaunchState(config: StreamConfig) {
        parsedStatus.sourceState = "Starting"
        parsedStatus.outputState = "Starting"
        parsedStatus.bufferState = bufferStateText(for: config)
        parsedStatus.bufferProgress = initialBufferProgress(for: config)
        parsedStatus.avSyncState = avSyncStateText(for: config)
        parsedStatus.reconnectDelay = "None"
        parsedStatus.ffmpegTime = ""
        parsedStatus.ffmpegBitrate = ""
        parsedStatus.ffmpegSpeed = ""
        parsedStatus.lastAppEvent = "Session started"
        parsedStatus.lastFFmpegEvent = "No activity yet"
        parsedStatus.lastYtDlpEvent = "No activity yet"
        parsedStatus.lastError = "None"

        lastFfmpegProgressSeconds = 0
        lastFfmpegProgressAt = Date()
        hasSeenFfmpegProgress = false
        lowSpeedSince = Date.distantPast
        lowSpeedHealthySince = Date.distantPast
        outputFreezeActive = false
        outputFreezeStartedAt = Date.distantPast
        lastOutputFreezeHeartbeatAt = Date.distantPast
        lastFfmpegDupCount = nil
        lastFfmpegDupSampleAt = Date.distantPast
        lastFfmpegFrameCount = nil
        lastVideoFrameAdvanceAt = Date.distantPast
        videoCadenceFreezeActive = false
        videoCadenceFreezeStartedAt = Date.distantPast
        lastVideoCadenceHeartbeatAt = Date.distantPast
        duplicationFreezeActive = false
        duplicationFreezeStartedAt = Date.distantPast
        lastDuplicationAlertAt = Date.distantPast
        lastHighDupAt = Date.distantPast
        stallRecoveryTriggered = false
        freezeRecoveryTriggered = false
        bufferExhausted = false
        lastBufferUiUpdate = Date.distantPast
        estimatedOutputBitrateBps = 0
        ffmpegDiagnosticCounters = [:]
        recentFfmpegDiagnosticLines = []
        lastDiagnosticSnapshotAt = Date.distantPast
        lastSpeedDriftLogAt = Date.distantPast
        lastFfmpegProgressLogAt = Date.distantPast
        pendingLogChunkBySource = [:]
        suppressedMetadataLineCount = 0
        lastSuppressedMetadataFlushAt = Date.distantPast
        suppressedProgressLineCount = 0
        lastSuppressedProgressFlushAt = Date.distantPast
    }

    private func normalizedLogPayload(_ payload: String) -> String {
        if payload.count > Self.maxToolLogPayloadLength {
            let kept = payload.prefix(Self.maxToolLogPayloadLength)
            return "\(kept) ... [truncated]"
        }
        return payload
    }

    private func appendLog(_ message: String) {
        if shouldSuppressVerboseMetadata(message) {
            suppressedMetadataLineCount += 1
            flushSuppressedMetadataIfNeeded(force: false)
            return
        }
        if shouldSuppressHighFrequencyProgress(message) {
            parseStatus(from: message)
            suppressedProgressLineCount += 1
            flushSuppressedProgressIfNeeded(force: false)
            return
        }
        flushSuppressedMetadataIfNeeded(force: false)
        flushSuppressedProgressIfNeeded(force: false)
        appendLogCore(message)
    }

    private func appendLogCore(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        if cliLogMirroringEnabled {
            fputs(line + "\n", stdout)
            fflush(stdout)
        }
        pendingUiLogLines.append(line)
        scheduleLogFlushIfNeeded()
        parseStatus(from: message)
    }

    private func shouldSuppressVerboseMetadata(_ message: String) -> Bool {
        guard message.contains("[yt-dlp]") else { return false }
        return Self.verboseMetadataTokens.contains { token in
            message.contains(token)
        }
    }

    private func flushSuppressedMetadataIfNeeded(force: Bool) {
        guard suppressedMetadataLineCount > 0 else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastSuppressedMetadataFlushAt) < Self.metadataSummaryInterval {
            return
        }
        let count = suppressedMetadataLineCount
        suppressedMetadataLineCount = 0
        lastSuppressedMetadataFlushAt = now
        appendLogCore("[app] Suppressed \(count) verbose HLS metadata lines.")
    }

    private func shouldSuppressHighFrequencyProgress(_ message: String) -> Bool {
        if message.contains("[yt-dlp] frame=") || message.contains("[ffmpeg] frame=") {
            return true
        }
        if message.contains("[yt-dlp] [https @") && message.contains("Opening 'http") {
            return true
        }
        if message.contains("[yt-dlp] [hls @") && message.contains("Opening 'http") {
            return true
        }
        return false
    }

    private func flushSuppressedProgressIfNeeded(force: Bool) {
        guard suppressedProgressLineCount > 0 else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastSuppressedProgressFlushAt) < Self.progressSummaryInterval {
            return
        }
        let count = suppressedProgressLineCount
        suppressedProgressLineCount = 0
        lastSuppressedProgressFlushAt = now
        appendLogCore("[app] Suppressed \(count) high-frequency progress lines.")
    }

    private func scheduleLogFlushIfNeeded() {
        guard logFlushTask == nil else { return }
        logFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.logFlushInterval * 1_000_000_000))
            self?.flushPendingUiLogs()
        }
    }

    private func flushPendingUiLogs() {
        logFlushTask?.cancel()
        logFlushTask = nil
        guard !pendingUiLogLines.isEmpty else { return }
        logLines.append(contentsOf: pendingUiLogLines)
        pendingUiLogLines.removeAll(keepingCapacity: true)
        if logLines.count > 1_500 {
            logLines.removeFirst(logLines.count - 1_000)
        }
    }

    private func parseStatus(from message: String) {
        let source = eventSource(for: message)
        let isFrameStatsLine = message.contains("frame=") &&
            (message.contains("[ffmpeg]") || message.contains("[yt-dlp]"))
        let now = Date()
        updateDiagnosticSignals(from: message, now: now)
        if !isFrameStatsLine {
            updateSourceEvent(source: source, message: message, now: now, throttleFrameLines: false)
        } else {
            updateSourceEvent(source: source, message: message, now: now, throttleFrameLines: true)
        }

        if message.contains("ERROR:") || message.lowercased().contains(" error") {
            parsedStatus.lastError = message
        }

        if message.contains("[ffmpeg] out_time_us=") || message.contains("[ffmpeg] out_time_ms=") {
            let micros = progressMicros(from: message)
            if micros > 0 {
                let progressSeconds = micros / 1_000_000.0
                parsedStatus.ffmpegTime = formatClock(seconds: progressSeconds)
                if progressSeconds > lastFfmpegProgressSeconds + 0.2 {
                    lastFfmpegProgressSeconds = progressSeconds
                    lastFfmpegProgressAt = now
                    hasSeenFfmpegProgress = true
                    stallRecoveryTriggered = false
                    freezeRecoveryTriggered = false
                }
                if now.timeIntervalSince(lastFfmpegProgressLogAt) >= Self.ffmpegProgressLogInterval {
                    lastFfmpegProgressLogAt = now
                    appendLogCore("[app] ffmpeg progress: t=\(parsedStatus.ffmpegTime)")
                }
            }
        } else if message.contains("[ffmpeg] speed=") {
            let speedValue = progressValue(from: message, key: "speed")
            if !speedValue.isEmpty {
                parsedStatus.ffmpegSpeed = speedValue
            }
        } else if message.contains("[ffmpeg] bitrate=") {
            let bitrateValue = progressValue(from: message, key: "bitrate")
            if !bitrateValue.isEmpty {
                parsedStatus.ffmpegBitrate = bitrateValue
            }
        }

        if message.contains("[yt-dlp] [youtube] Extracting URL") {
            parsedStatus.sourceState = "Resolving Source"
        } else if message.contains("[yt-dlp] [download] Destination: -") {
            parsedStatus.sourceState = "Streaming Source"
        }

        if message.contains("[ffmpeg]") && message.contains("frame=") {
            let now = Date()
            guard now.timeIntervalSince(lastStatsParseUpdate) >= Self.statsParseInterval else {
                return
            }
            lastStatsParseUpdate = now
            if parsedStatus.bufferState.contains("Filling") || bufferExhausted {
                parsedStatus.outputState = "Buffering"
            } else {
                parsedStatus.outputState = "Publishing"
            }
            parsedStatus.ffmpegTime = capture(regex: Self.ffmpegTimeRegex, in: message)
            parsedStatus.ffmpegBitrate = capture(regex: Self.ffmpegBitrateRegex, in: message)
            parsedStatus.ffmpegSpeed = capture(regex: Self.ffmpegSpeedRegex, in: message)
            if let speed = parseSpeedFactor(parsedStatus.ffmpegSpeed) {
                if speed > Self.speedDriftThreshold,
                   now.timeIntervalSince(lastSpeedDriftLogAt) >= Self.speedDriftLogInterval {
                    lastSpeedDriftLogAt = now
                    ffmpegDiagnosticCounters["speed_drift", default: 0] += 1
                    let speedText = String(format: "%.2f", speed)
                    appendLog(
                        "[app] Output speed drift detected (\(speedText)x). Receiver-side jitter/freezes are more likely when publishing faster than realtime."
                    )
                    appendDiagnosticSnapshot(reason: "speed-drift")
                }

                let publishAge = now.timeIntervalSince(lastPublishStartedAt)
                let outputState = parsedStatus.outputState.lowercased()
                let canEnforceHighSpeed = shouldKeepRunning &&
                    isRunning &&
                    outputState.contains("publish") &&
                    publishAge >= Self.highSpeedRestartGracePeriod
                if canEnforceHighSpeed && speed > Self.highSpeedRestartThreshold {
                    if highSpeedSince == Date.distantPast {
                        highSpeedSince = now
                    }
                    let highSpeedDuration = now.timeIntervalSince(highSpeedSince)
                    if highSpeedDuration >= Self.highSpeedRestartDuration {
                        let speedText = String(format: "%.2f", speed)
                        ffmpegDiagnosticCounters["speed_high_restart", default: 0] += 1
                        appendLog(
                            "[app] Output speed stayed high (\(speedText)x for \(Int(highSpeedDuration.rounded()))s). Restarting publisher stage with strict pacing."
                        )
                        appendDiagnosticSnapshot(reason: "high-speed-publisher-restart")
                        highSpeedSince = Date.distantPast
                        schedulePublisherOnlyRestart(
                            generation: generation,
                            reason: "sustained speed \(speedText)x"
                        )
                        return
                    }
                } else {
                    highSpeedSince = Date.distantPast
                }

                if speed < Self.lowSpeedThreshold {
                    if lowSpeedSince == Date.distantPast {
                        lowSpeedSince = now
                    }
                    let lowSpeedDuration = now.timeIntervalSince(lowSpeedSince)
                    let bufferedSeconds = estimatedBufferedSeconds()
                    let bufferStarved = bufferedSeconds <= Self.lowSpeedRestartBufferCeiling
                    if bufferStarved &&
                        lowSpeedDuration >= Self.lowSpeedRestartThreshold &&
                        !freezeRecoveryTriggered &&
                        shouldKeepRunning &&
                        isRunning {
                        freezeRecoveryTriggered = true
                        ffmpegDiagnosticCounters["speed_low_restart", default: 0] += 1
                        let lowSpeedText = String(format: "%.2f", speed)
                        let bufferText = String(format: "%.1f", bufferedSeconds)
                        appendLog(
                            "[app] Output speed remained low (\(lowSpeedText)x for \(Int(lowSpeedDuration.rounded()))s) with low staged buffer (\(bufferText)s). Restarting pipeline."
                        )
                        appendDiagnosticSnapshot(reason: "low-speed-restart")
                        terminatePipeline()
                        scheduleRestart(generation: generation, reason: .lowSpeed)
                        return
                    }

                    let bufferHealthy = bufferedSeconds >= Self.catchUpBufferFloor
                    let catchUpEligibleSpeed = speed < Self.catchUpLowSpeedThreshold
                    if bufferHealthy && catchUpEligibleSpeed {
                        if lowSpeedHealthySince == Date.distantPast {
                            lowSpeedHealthySince = now
                        }
                        let healthyLowSpeedDuration = now.timeIntervalSince(lowSpeedHealthySince)
                        if healthyLowSpeedDuration >= Self.catchUpTriggerThreshold &&
                            !isCatchUpActive(now: now) &&
                            shouldKeepRunning &&
                            isRunning {
                            let speedText = String(format: "%.2f", speed)
                            let bufferText = String(format: "%.1f", bufferedSeconds)
                            catchUpExpiresAt = now.addingTimeInterval(Self.catchUpDuration)
                            ffmpegDiagnosticCounters["speed_low_catchup", default: 0] += 1
                            appendLog(
                                "[app] Output speed stayed below realtime (\(speedText)x for \(Int(healthyLowSpeedDuration.rounded()))s) with healthy staged buffer (\(bufferText)s). Enabling temporary catch-up mode (no -re) for \(Int(Self.catchUpDuration))s."
                            )
                            appendDiagnosticSnapshot(reason: "catch-up-enable")
                            terminatePipeline()
                            scheduleRestart(generation: generation, reason: .catchUp)
                            return
                        }
                    } else {
                        lowSpeedHealthySince = Date.distantPast
                    }
                } else {
                    lowSpeedSince = Date.distantPast
                    lowSpeedHealthySince = Date.distantPast
                }
            }
            if let bps = parseBitrateToBps(parsedStatus.ffmpegBitrate) {
                estimatedOutputBitrateBps = bps
            }
            updateVideoCadence(from: message, now: now)
            updateDuplicationFreezeDetection(from: message, now: now)

            if let progressSeconds = parseClockToSeconds(parsedStatus.ffmpegTime) {
                if progressSeconds > lastFfmpegProgressSeconds + 0.2 {
                    let progressGap = now.timeIntervalSince(lastFfmpegProgressAt)
                    let wasPublishing = parsedStatus.outputState.lowercased().contains("publish")
                    if hasSeenFfmpegProgress &&
                        wasPublishing &&
                        progressGap >= Self.transientStallLogThreshold &&
                        progressGap < Self.outputFreezeLogThreshold {
                        ffmpegDiagnosticCounters["transient_stall", default: 0] += 1
                        appendLog(
                            "[app] Short output stall recovered after \(Int(progressGap.rounded()))s (no restart needed)."
                        )
                    }
                    lastFfmpegProgressSeconds = progressSeconds
                    lastFfmpegProgressAt = now
                    hasSeenFfmpegProgress = true
                    if outputFreezeActive {
                        outputFreezeActive = false
                        let freezeDuration = max(0, now.timeIntervalSince(outputFreezeStartedAt))
                        appendLog("[app] Output freeze recovered after \(Int(freezeDuration.rounded()))s.")
                        appendDiagnosticSnapshot(reason: "freeze-recovered")
                    }
                    stallRecoveryTriggered = false
                    freezeRecoveryTriggered = false
                } else if !stallRecoveryTriggered &&
                    shouldKeepRunning &&
                    isRunning &&
                    shouldMonitorStallRecovery() &&
                    parsedStatus.outputState == "Publishing" &&
                    now.timeIntervalSince(lastFfmpegProgressAt) >= Self.outputStallThreshold {
                    stallRecoveryTriggered = true
                    appendLog("[app] Output appears stalled (no ffmpeg time advance for \(Int(Self.outputStallThreshold))s). Restarting pipeline.")
                    appendDiagnosticSnapshot(reason: "stall-restart")
                    terminatePipeline()
                    scheduleRestart(generation: generation, reason: .stall)
                    return
                }
            }
        }

        if message.contains("[ffmpeg]") && message.contains("Server error: Stream already publishing") {
            parsedStatus.outputState = "Destination Busy"
            destinationBusyUntil = now.addingTimeInterval(Self.destinationBusyRetryDelay)
            appendLog("[app] Destination reported an active publisher. Waiting before retry.")
            appendDiagnosticSnapshot(reason: "destination-busy")
            terminatePipeline()
            scheduleRestart(generation: generation, reason: .destinationBusy)
            return
        }

        if message.contains("[ffmpeg]") && message.contains("Error opening") {
            parsedStatus.outputState = "Output Error"
        }
    }

    private func capture(regex: NSRegularExpression, in text: String) -> String {
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return ""
        }
        guard let captureRange = Range(match.range(at: 1), in: text) else { return "" }
        return String(text[captureRange])
    }

    private func parseClockToSeconds(_ clock: String) -> Double? {
        let parts = clock.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return (hours * 3600.0) + (minutes * 60.0) + seconds
    }

    private func parseBitrateToBps(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "n/a" {
            return nil
        }

        let units: [(suffix: String, scale: Double)] = [
            ("gbits/s", 1_000_000_000),
            ("mbits/s", 1_000_000),
            ("kbits/s", 1_000),
            ("bits/s", 1)
        ]

        for (suffix, scale) in units {
            if trimmed.hasSuffix(suffix) {
                let valueString = trimmed.replacingOccurrences(of: suffix, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Double(valueString) {
                    return value * scale
                }
            }
        }
        return nil
    }

    private func parseSpeedFactor(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let value = trimmed.hasSuffix("x") ? String(trimmed.dropLast()) : trimmed
        return Double(value)
    }

    private func progressValue(from message: String, key: String) -> String {
        guard let range = message.range(of: "[ffmpeg] \(key)=") else { return "" }
        let raw = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw
    }

    private func progressMicros(from message: String) -> Double {
        let us = progressValue(from: message, key: "out_time_us")
        if let value = Double(us), value > 0 {
            return value
        }

        let ms = progressValue(from: message, key: "out_time_ms")
        if let value = Double(ms), value > 0 {
            // ffmpeg exposes out_time_ms but value is in microseconds.
            return value
        }
        return 0
    }

    private func formatClock(seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let wholeSeconds = total % 60
        let fractional = Int(((clamped - floor(clamped)) * 100).rounded())
        return String(format: "%02d:%02d:%02d.%02d", hours, minutes, wholeSeconds, fractional)
    }

    private func captureInt(regex: NSRegularExpression, in text: String) -> Int? {
        let captured = capture(regex: regex, in: text)
        guard !captured.isEmpty else { return nil }
        return Int(captured)
    }

    private func updateVideoCadence(from message: String, now: Date) {
        guard let frameCount = captureInt(regex: Self.ffmpegFrameRegex, in: message) else { return }
        defer {
            lastFfmpegFrameCount = frameCount
        }

        if let prior = lastFfmpegFrameCount {
            if frameCount > prior {
                lastVideoFrameAdvanceAt = now
                if videoCadenceFreezeActive {
                    let freezeDuration = max(0, now.timeIntervalSince(videoCadenceFreezeStartedAt))
                    videoCadenceFreezeActive = false
                    appendLog("[app] Video cadence recovered after \(Int(freezeDuration.rounded()))s.")
                    appendDiagnosticSnapshot(reason: "video-cadence-recovered")
                }
            }
        } else {
            lastVideoFrameAdvanceAt = now
        }
    }

    private func updateDuplicationFreezeDetection(from message: String, now: Date) {
        guard let dupCount = captureInt(regex: Self.ffmpegDupRegex, in: message) else { return }

        defer {
            lastFfmpegDupCount = dupCount
            lastFfmpegDupSampleAt = now
        }

        guard let priorDupCount = lastFfmpegDupCount else { return }
        guard lastFfmpegDupSampleAt > Date.distantPast else { return }

        let elapsed = max(0.001, now.timeIntervalSince(lastFfmpegDupSampleAt))
        let deltaDup = max(0, dupCount - priorDupCount)
        let dupPerSecond = Double(deltaDup) / elapsed

        let outputState = parsedStatus.outputState.lowercased()
        let shouldInspect = outputState.contains("publish") || outputState.contains("running")
        guard shouldInspect else { return }

        if dupPerSecond >= Self.duplicationFreezeDupPerSecondThreshold {
            lastHighDupAt = now
            if !duplicationFreezeActive {
                duplicationFreezeActive = true
                duplicationFreezeStartedAt = now
                lastDuplicationAlertAt = now
                appendLog("[app] Possible visual freeze: ffmpeg duplicated frames at ~\(Int(dupPerSecond.rounded())) fps.")
                appendDiagnosticSnapshot(reason: "dup-freeze-detected")
            } else if now.timeIntervalSince(lastDuplicationAlertAt) >= Self.duplicationFreezeHeartbeatInterval {
                lastDuplicationAlertAt = now
                appendLog("[app] Visual freeze ongoing: duplicate-frame rate ~\(Int(dupPerSecond.rounded())) fps.")
                appendDiagnosticSnapshot(reason: "dup-freeze-ongoing")
            }
            let freezeDuration = now.timeIntervalSince(duplicationFreezeStartedAt)
            if !freezeRecoveryTriggered &&
                shouldKeepRunning &&
                isRunning &&
                freezeDuration >= Self.duplicationFreezeRestartThreshold {
                freezeRecoveryTriggered = true
                appendLog("[app] Visual freeze persisted for \(Int(freezeDuration.rounded()))s. Restarting pipeline.")
                appendDiagnosticSnapshot(reason: "dup-freeze-restart")
                terminatePipeline()
                scheduleRestart(generation: generation, reason: .freeze)
            }
            return
        }

        if duplicationFreezeActive && now.timeIntervalSince(lastHighDupAt) >= Self.duplicationFreezeRecoveryWindow {
            duplicationFreezeActive = false
            let freezeDuration = max(0, now.timeIntervalSince(duplicationFreezeStartedAt))
            appendLog("[app] Visual freeze recovered after \(Int(freezeDuration.rounded()))s.")
            freezeRecoveryTriggered = false
            appendDiagnosticSnapshot(reason: "dup-freeze-recovered")
        }
    }

    private func startBufferCountdownIfNeeded(config: StreamConfig, generation: Int) {
        bufferCountdownTask?.cancel()
        bufferCountdownTask = nil

        guard config.encodeMode == .transcode, config.bufferSeconds > 0 else {
            parsedStatus.bufferState = bufferStateText(for: config)
            parsedStatus.bufferProgress = initialBufferProgress(for: config)
            return
        }

        let total = config.bufferSeconds
        parsedStatus.outputState = "Buffering"
        parsedStatus.bufferState = startupReprimeActive ? "Re-priming (target \(total)s)" : "Filling (target \(total)s)"
        parsedStatus.bufferProgress = 0
        if startupReprimeActive {
            appendLog("[app] Buffer re-priming started (target \(total)s).")
        } else {
            appendLog("[app] Buffer priming started (target \(total)s).")
        }
    }

    private func readPlaylistDurationSeconds(from playlistURL: URL) -> Double {
        guard let text = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            return 0
        }
        var total: Double = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("#EXTINF:") else { continue }
            let raw = line.dropFirst("#EXTINF:".count)
            let valueText = raw.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
            if let seconds = Double(valueText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                total += max(0, seconds)
            }
        }
        return total
    }

    private func updateDvrBufferState(
        config: StreamConfig,
        availableSeconds: Double,
        targetDelay: Double,
        publishingStarted: Bool
    ) {
        guard config.encodeMode == .transcode else { return }
        let now = Date()
        guard now.timeIntervalSince(lastBufferUiUpdate) >= 0.25 else { return }
        lastBufferUiUpdate = now

        let target = max(1.0, targetDelay)
        let fill = min(1.0, max(0.0, availableSeconds / target))
        let exhaustionThreshold = min(1.0, target * 0.15)
        let recoveryThreshold = exhaustionThreshold + 1.0

        if publishingStarted {
            if bufferExhausted {
                if availableSeconds >= recoveryThreshold {
                    bufferExhausted = false
                    appendLog("[app] Buffer recovered. Publishing resumed.")
                }
            } else if availableSeconds < exhaustionThreshold {
                bufferExhausted = true
                appendLog("[app] Buffer exhausted. Waiting for staged media to refill.")
            }
        } else {
            bufferExhausted = false
        }

        if !publishingStarted {
            let remaining = max(0, Int((targetDelay - availableSeconds).rounded(.up)))
            parsedStatus.outputState = "Buffering"
            if remaining > 0 {
                parsedStatus.bufferState = startupReprimeActive
                    ? "Re-priming (\(remaining)s remaining)"
                    : "Filling (\(remaining)s remaining)"
            } else {
                parsedStatus.bufferState = targetDelay > 0 ? "Primed (\(config.bufferSeconds)s delay)" : "Primed"
            }
            parsedStatus.bufferProgress = targetDelay > 0 ? fill : 1.0
            return
        }

        if bufferExhausted {
            parsedStatus.outputState = "Buffering"
            parsedStatus.bufferState = "Exhausted (\(Int(availableSeconds.rounded()))s/\(config.bufferSeconds)s)"
            parsedStatus.bufferProgress = fill
            return
        }

        parsedStatus.outputState = "Publishing"
        if targetDelay <= 0 {
            parsedStatus.bufferState = "Live (no delay)"
            parsedStatus.bufferProgress = 1.0
        } else if availableSeconds >= targetDelay {
            parsedStatus.bufferState = "Primed (\(config.bufferSeconds)s delay)"
            parsedStatus.bufferProgress = 1.0
        } else {
            parsedStatus.bufferState = "Buffered (\(Int(availableSeconds.rounded()))s/\(config.bufferSeconds)s)"
            parsedStatus.bufferProgress = fill
        }
    }

    private func cleanupDvrSessionFiles() {
        guard let dir = dvrSessionDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let statsParseInterval: TimeInterval = 0.5
    private static let statsEventInterval: TimeInterval = 0.5
    private static let outputStallThreshold: TimeInterval = 12.0
    private static let transientStallLogThreshold: TimeInterval = 2.5
    private static let outputFreezeLogThreshold: TimeInterval = 6.0
    private static let outputFreezeHeartbeatInterval: TimeInterval = 10.0
    private static let outputFreezeRestartThreshold: TimeInterval = 12.0
    private static let outputFreezeMonitorPollInterval: TimeInterval = 1.0
    private static let videoCadenceProgressFreshThreshold: TimeInterval = 2.5
    private static let videoCadenceLogThreshold: TimeInterval = 6.0
    private static let videoCadenceHeartbeatInterval: TimeInterval = 10.0
    private static let videoCadenceRestartThreshold: TimeInterval = 12.0
    private static let duplicationFreezeDupPerSecondThreshold: Double = 10.0
    private static let duplicationFreezeHeartbeatInterval: TimeInterval = 10.0
    private static let duplicationFreezeRecoveryWindow: TimeInterval = 3.0
    private static let duplicationFreezeRestartThreshold: TimeInterval = 8.0
    private static let metadataSummaryInterval: TimeInterval = 2.0
    private static let progressSummaryInterval: TimeInterval = 2.0
    private static let ffmpegProgressLogInterval: TimeInterval = 10.0
    private static let speedDriftThreshold: Double = 1.15
    private static let speedDriftLogInterval: TimeInterval = 8.0
    private static let lowSpeedThreshold: Double = 0.92
    private static let lowSpeedRestartThreshold: TimeInterval = 18.0
    private static let lowSpeedRestartBufferCeiling: TimeInterval = 3.0
    private static let highSpeedRestartThreshold: Double = 1.05
    private static let highSpeedRestartDuration: TimeInterval = 8.0
    private static let highSpeedRestartGracePeriod: TimeInterval = 20.0
    private static let catchUpLowSpeedThreshold: Double = 0.98
    private static let catchUpTriggerThreshold: TimeInterval = 10.0
    private static let catchUpBufferFloor: TimeInterval = 8.0
    private static let catchUpDuration: TimeInterval = 90.0
    private static let destinationBusyRetryDelay: TimeInterval = 8.0
    private static let publishRampDelay: TimeInterval = 2.0
    private static let logFlushInterval: TimeInterval = 0.2
    private static let diagnosticSnapshotInterval: TimeInterval = 20.0
    private static let diagnosticSnapshotMinGap: TimeInterval = 4.0
    private static let maxDiagnosticLines: Int = 24
    private static let maxToolLogPayloadLength: Int = 800
    nonisolated private static let processTimeoutExitCode: Int32 = -999
    private static let verboseMetadataTokens: [String] = [
        "Skip ('#EXT-X-DATERANGE",
        "Skip ('#EXT-X-CUEPOINT",
        "Skip ('#EXT-X-PROGRAM-DATE-TIME",
        "Skip ('#EXT-X-DISCONTINUITY",
        "Skip ('#EXT-X-DISCONTINUITY-SEQUENCE",
        "Skip ('#EXT-X-VERSION"
    ]
    private static let ffmpegTimeRegex = try! NSRegularExpression(pattern: #"time=\s*([0-9:\.]+)"#)
    private static let ffmpegBitrateRegex = try! NSRegularExpression(pattern: #"bitrate=\s*([^\s]+)"#)
    private static let ffmpegSpeedRegex = try! NSRegularExpression(pattern: #"speed=\s*([^\s]+)"#)
    private static let ffmpegFrameRegex = try! NSRegularExpression(pattern: #"frame=\s*([0-9]+)"#)
    private static let ffmpegDupRegex = try! NSRegularExpression(pattern: #"dup=\s*([0-9]+)"#)

    private enum MessageSource {
        case app
        case ffmpeg
        case ytDlp
        case unknown
    }

    private func eventSource(for message: String) -> MessageSource {
        if message.hasPrefix("[app] ") {
            return .app
        }
        if message.hasPrefix("[ffmpeg] ") {
            return .ffmpeg
        }
        if message.hasPrefix("[yt-dlp] ") {
            return .ytDlp
        }
        return .unknown
    }

    private func updateSourceEvent(
        source: MessageSource,
        message: String,
        now: Date,
        throttleFrameLines: Bool
    ) {
        switch source {
        case .app:
            parsedStatus.lastAppEvent = message
        case .ffmpeg:
            if !throttleFrameLines || now.timeIntervalSince(lastFfmpegEventUpdate) >= Self.statsEventInterval {
                parsedStatus.lastFFmpegEvent = message
                lastFfmpegEventUpdate = now
            }
        case .ytDlp:
            if !throttleFrameLines || now.timeIntervalSince(lastYtDlpEventUpdate) >= Self.statsEventInterval {
                parsedStatus.lastYtDlpEvent = message
                lastYtDlpEventUpdate = now
            }
        case .unknown:
            // Fallback so unknown lines still appear somewhere useful.
            parsedStatus.lastAppEvent = message
        }
    }

    private func isCatchUpActive(now: Date = Date()) -> Bool {
        now < catchUpExpiresAt
    }

    private func supportsBufferedDrainOnSourceExit() -> Bool {
        guard let config = currentConfig else { return false }
        return config.encodeMode == .transcode && config.bufferSeconds > 0
    }

    private func shouldMonitorStallRecovery() -> Bool {
        guard let config = currentConfig else { return true }
        let usesDelayedBuffer = config.encodeMode == .transcode && config.bufferSeconds > 0
        return !usesDelayedBuffer
    }

    private func estimatedBufferedSeconds() -> Double {
        guard let config = currentConfig,
              config.encodeMode == .transcode,
              config.bufferSeconds > 0 else {
            return 0
        }
        return max(0, min(Double(config.bufferSeconds), Double(config.bufferSeconds) * parsedStatus.bufferProgress))
    }

    private func startOutputFreezeMonitorIfNeeded() {
        outputFreezeMonitorTask?.cancel()
        outputFreezeMonitorTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.outputFreezeMonitorPollInterval * 1_000_000_000)
                )
                guard self.shouldKeepRunning, self.isRunning else { continue }
                guard self.ffmpegProcess?.isRunning == true else { continue }
                guard self.hasSeenFfmpegProgress else { continue }

                let outputState = self.parsedStatus.outputState.lowercased()
                guard outputState.contains("publish") || outputState.contains("running") else { continue }

                let now = Date()
                let stalledFor = now.timeIntervalSince(self.lastFfmpegProgressAt)
                let frameStalledFor = self.lastVideoFrameAdvanceAt == Date.distantPast
                    ? 0
                    : now.timeIntervalSince(self.lastVideoFrameAdvanceAt)

                // Detect video-only freezes where audio/output time still advances.
                if self.lastVideoFrameAdvanceAt != Date.distantPast &&
                    stalledFor < Self.videoCadenceProgressFreshThreshold &&
                    frameStalledFor >= Self.videoCadenceLogThreshold {
                    if !self.videoCadenceFreezeActive {
                        self.videoCadenceFreezeActive = true
                        self.videoCadenceFreezeStartedAt = self.lastVideoFrameAdvanceAt
                        self.lastVideoCadenceHeartbeatAt = now
                        self.appendLog(
                            "[app] Video cadence freeze detected: video frames have not advanced for \(Int(frameStalledFor.rounded()))s while output timeline is still moving."
                        )
                        self.appendDiagnosticSnapshot(reason: "video-cadence-freeze-detected")
                    } else if now.timeIntervalSince(self.lastVideoCadenceHeartbeatAt) >= Self.videoCadenceHeartbeatInterval {
                        self.lastVideoCadenceHeartbeatAt = now
                        self.appendLog(
                            "[app] Video cadence freeze ongoing: no frame advance for \(Int(frameStalledFor.rounded()))s."
                        )
                        self.appendDiagnosticSnapshot(reason: "video-cadence-freeze-ongoing")
                    }

                    if !self.freezeRecoveryTriggered &&
                        frameStalledFor >= Self.videoCadenceRestartThreshold {
                        self.freezeRecoveryTriggered = true
                        self.appendLog(
                            "[app] Video cadence freeze persisted for \(Int(frameStalledFor.rounded()))s. Restarting pipeline."
                        )
                        self.appendDiagnosticSnapshot(reason: "video-cadence-freeze-restart")
                        self.terminatePipeline()
                        self.scheduleRestart(generation: self.generation, reason: .freeze)
                        continue
                    }
                }

                if stalledFor < Self.outputFreezeLogThreshold {
                    continue
                }

                if !self.outputFreezeActive {
                    self.outputFreezeActive = true
                    self.outputFreezeStartedAt = self.lastFfmpegProgressAt
                    self.lastOutputFreezeHeartbeatAt = now
                    self.appendLog(
                        "[app] Output freeze detected: ffmpeg output time has not advanced for \(Int(stalledFor.rounded()))s."
                    )
                    self.appendDiagnosticSnapshot(reason: "output-freeze-detected")
                    continue
                }

                if now.timeIntervalSince(self.lastOutputFreezeHeartbeatAt) >= Self.outputFreezeHeartbeatInterval {
                    self.lastOutputFreezeHeartbeatAt = now
                    self.appendLog(
                        "[app] Output freeze ongoing: ffmpeg output time stagnant for \(Int(stalledFor.rounded()))s."
                    )
                    self.appendDiagnosticSnapshot(reason: "output-freeze-ongoing")
                }
                if !self.freezeRecoveryTriggered &&
                    stalledFor >= Self.outputFreezeRestartThreshold {
                    self.freezeRecoveryTriggered = true
                    self.appendLog(
                        "[app] Output freeze persisted for \(Int(stalledFor.rounded()))s. Restarting pipeline."
                    )
                    self.appendDiagnosticSnapshot(reason: "output-freeze-restart")
                    self.terminatePipeline()
                    self.scheduleRestart(generation: self.generation, reason: .freeze)
                }
            }
        }
    }

    private enum RestartReason {
        case general
        case freeze
        case lowSpeed
        case catchUp
        case stall
        case processExit
        case destinationBusy
    }

    private func restartReasonLabel(_ reason: RestartReason) -> String {
        switch reason {
        case .general:
            return "general"
        case .freeze:
            return "output-freeze"
        case .lowSpeed:
            return "low-speed-with-low-buffer"
        case .catchUp:
            return "low-speed-with-healthy-buffer-catchup"
        case .stall:
            return "progress-stall"
        case .processExit:
            return "process-exit"
        case .destinationBusy:
            return "destination-busy"
        }
    }

    private func startDiagnosticHeartbeatIfNeeded() {
        diagnosticHeartbeatTask?.cancel()
        diagnosticHeartbeatTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.diagnosticSnapshotInterval * 1_000_000_000)
                )
                guard self.shouldKeepRunning, self.isRunning else { continue }
                self.appendDiagnosticSnapshot(reason: "periodic")
            }
        }
    }

    private func updateDiagnosticSignals(from message: String, now: Date) {
        guard message.contains("[ffmpeg]") else { return }
        let lower = message.lowercased()
        func bump(_ key: String) {
            ffmpegDiagnosticCounters[key, default: 0] += 1
            if recentFfmpegDiagnosticLines.count >= Self.maxDiagnosticLines {
                recentFfmpegDiagnosticLines.removeFirst(recentFfmpegDiagnosticLines.count - Self.maxDiagnosticLines + 1)
            }
            recentFfmpegDiagnosticLines.append(message)
        }

        if lower.contains("non-monotonous dts") || lower.contains("non monotonically increasing dts") {
            bump("dts_non_monotonic")
        }
        if lower.contains("backward in time") || lower.contains("queue input is backward") {
            bump("timestamp_backward")
        }
        if lower.contains("past duration") {
            bump("past_duration")
        }
        if lower.contains("error while decoding") || lower.contains("invalid nal") || lower.contains("corrupt") {
            bump("decode_corrupt")
        }
        if lower.contains("rtmp") && (lower.contains("broken pipe") || lower.contains("connection reset") || lower.contains("io error") || lower.contains("failed")) {
            bump("rtmp_io")
        }
        if lower.contains("delay between the first packet and last packet") || lower.contains("max delay reached") {
            bump("mux_delay")
        }

        if now.timeIntervalSince(lastDiagnosticSnapshotAt) >= Self.diagnosticSnapshotInterval &&
            !ffmpegDiagnosticCounters.isEmpty &&
            logMonitoringEnabled {
            appendDiagnosticSnapshot(reason: "signal")
        }
    }

    private func appendDiagnosticSnapshot(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticSnapshotAt) >= Self.diagnosticSnapshotMinGap else { return }
        lastDiagnosticSnapshotAt = now

        let stalledFor = hasSeenFfmpegProgress ? max(0, now.timeIntervalSince(lastFfmpegProgressAt)) : 0
        let counters = ffmpegDiagnosticCounters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let lastDiagLine = recentFfmpegDiagnosticLines.last?.replacingOccurrences(of: "\n", with: " ") ?? "-"
        let countersText = counters.isEmpty ? "none" : counters
        let stagedBufferText = String(format: "%.1fs", estimatedBufferedSeconds())

        appendLogCore(
            "[app] diag(\(reason)): output=\(parsedStatus.outputState), ffmpegTime=\(parsedStatus.ffmpegTime.isEmpty ? "-" : parsedStatus.ffmpegTime), speed=\(parsedStatus.ffmpegSpeed.isEmpty ? "-" : parsedStatus.ffmpegSpeed), bitrate=\(parsedStatus.ffmpegBitrate.isEmpty ? "-" : parsedStatus.ffmpegBitrate), stalled=\(Int(stalledFor.rounded()))s, buffer=\(parsedStatus.bufferState), staged=\(stagedBufferText), counters={\(countersText)}, lastFFmpegDiag=\(lastDiagLine)"
        )
    }

    nonisolated private static func fetchPreviewMetadata(for sourceURL: String) async -> (preview: StreamPreview?, message: String) {
        guard
            let ytDlp = resolveToolForPreview(named: "yt-dlp"),
            let ffmpeg = resolveToolForPreview(named: "ffmpeg")
        else {
            return (nil, "Tools unavailable")
        }

        let deno = resolveToolForPreview(named: "deno")
        let ffmpegToolsDir = ffmpeg.deletingLastPathComponent().path
        let ytDlpWorkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-live-converter", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: ytDlpWorkDir,
                withIntermediateDirectories: true
            )
        } catch {
            return (nil, "Failed to prepare temp directory")
        }

        var args = ["--dump-single-json", "--skip-download", "--no-warnings"]
        if let deno {
            args += ["--js-runtimes", "deno:\(deno.path)"]
        }
        args += [
            "--paths", "home:\(ytDlpWorkDir.path)",
            "--paths", "temp:\(ytDlpWorkDir.path)",
            "--ffmpeg-location", ffmpegToolsDir,
            sourceURL
        ]

        guard let result = await runProcessCaptureForPreview(
            executableURL: ytDlp,
            arguments: args,
            environment: mergedEnvironmentForPreview(prependingPath: ffmpegToolsDir),
            currentDirectoryURL: ytDlpWorkDir,
            timeoutSeconds: 20
        ) else {
            return (nil, "Failed to run metadata lookup")
        }

        if result.exitCode == Self.processTimeoutExitCode {
            return (nil, "Source info lookup timed out")
        }

        guard result.exitCode == 0 else {
            return (nil, "Could not load source info")
        }

        do {
            guard
                let object = try JSONSerialization.jsonObject(with: result.stdoutData) as? [String: Any]
            else {
                return (nil, "Metadata response was invalid")
            }

            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = (object["description"] as? String) ?? ""
            let thumbnailString = (object["thumbnail"] as? String) ?? ""
            let publishState = parsePublishState(from: object)
            let streamTechnical = parseTechnicalSummary(from: object)
            let excerpt = description
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let shortExcerpt = String(excerpt.prefix(220))

            if title.isEmpty {
                return (nil, "Source title unavailable")
            }

            return (
                StreamPreview(
                    title: title,
                    descriptionExcerpt: shortExcerpt,
                    thumbnailURL: URL(string: thumbnailString),
                    publishState: publishState,
                    resolutionLabel: streamTechnical.resolution,
                    frameRateLabel: streamTechnical.fps,
                    bitrateLabel: streamTechnical.bitrate,
                    codecLabel: streamTechnical.codec
                ),
                "Source info loaded"
            )
        } catch {
            return (nil, "Could not parse source info")
        }
    }
}

private struct ToolPaths {
    let ytDlp: URL
    let ffmpeg: URL
    let ffprobe: URL
    let deno: URL?
    let supportsVideoToolboxH264: Bool
}

private final class ProcessCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var continuation: CheckedContinuation<(exitCode: Int32, stdoutData: Data, stderrData: Data)?, Never>?

    init(continuation: CheckedContinuation<(exitCode: Int32, stdoutData: Data, stderrData: Data)?, Never>) {
        self.continuation = continuation
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stdoutData.append(data)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderrData.append(data)
        lock.unlock()
    }

    func finish(
        exitCode: Int32,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        drainRemaining: Bool
    ) {
        if drainRemaining {
            let outTail = stdoutHandle.readDataToEndOfFile()
            if !outTail.isEmpty {
                appendStdout(outTail)
            }
            let errTail = stderrHandle.readDataToEndOfFile()
            if !errTail.isEmpty {
                appendStderr(errTail)
            }
        }

        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let out = stdoutData
        let err = stderrData
        lock.unlock()
        continuation.resume(returning: (exitCode, out, err))
    }
}

private extension StreamPipeline {
    func resolveToolPaths() -> ToolPaths? {
        guard let ytDlp = resolveTool(named: "yt-dlp") else {
            appendLog("[app] Could not find yt-dlp. Bundle it in Contents/Resources/bin or install it in /opt/homebrew/bin or /usr/local/bin.")
            return nil
        }
        guard let ffmpeg = resolveTool(named: "ffmpeg") else {
            appendLog("[app] Could not find ffmpeg. Bundle it in Contents/Resources/bin or install it in /opt/homebrew/bin or /usr/local/bin.")
            return nil
        }
        guard let ffprobe = resolveTool(named: "ffprobe") else {
            appendLog("[app] Could not find ffprobe. Bundle it in Contents/Resources/bin or install it in /opt/homebrew/bin or /usr/local/bin.")
            return nil
        }

        guard verifyExecutable(ytDlp, probeArgument: "--version") else {
            appendLog("[app] Found yt-dlp at \(ytDlp.path) but it cannot run. Use a standalone yt-dlp binary for distribution.")
            return nil
        }
        guard verifyExecutable(ffmpeg, probeArgument: "-version") else {
            appendLog("[app] Found ffmpeg at \(ffmpeg.path) but it cannot run.")
            return nil
        }
        guard verifyExecutable(ffprobe, probeArgument: "-version") else {
            appendLog("[app] Found ffprobe at \(ffprobe.path) but it cannot run.")
            return nil
        }

        var denoURL: URL?
        if let deno = resolveTool(named: "deno") {
            if verifyExecutable(deno, probeArgument: "--version") {
                denoURL = deno
            } else {
                appendLog("[app] Found deno at \(deno.path) but it cannot run. Continuing without JS runtime.")
            }
        }

        let supportsVideoToolboxH264 = supportsFFmpegEncoder(ffmpeg, encoderName: "h264_videotoolbox")
        if !supportsVideoToolboxH264 {
            appendLog("[app] Hardware H.264 encoder not available; falling back to software x264.")
        }

        return ToolPaths(
            ytDlp: ytDlp,
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            deno: denoURL,
            supportsVideoToolboxH264: supportsVideoToolboxH264
        )
    }

    func resolveTool(named name: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let bundleURL = Bundle.main.resourceURL {
            candidates.append(bundleURL.appendingPathComponent("bin/\(name)"))
            candidates.append(bundleURL.appendingPathComponent(name))
        }

        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(name)"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/\(name)"))

        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    func verifyExecutable(_ url: URL, probeArgument: String) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = [probeArgument]
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

    func supportsFFmpegEncoder(_ ffmpegURL: URL, encoderName: String) -> Bool {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-hide_banner", "-encoders"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            var combined = outputData
            combined.append(errorData)
            let output = String(decoding: combined, as: UTF8.self)
            return output.contains(encoderName)
        } catch {
            return false
        }
    }

    func mergedEnvironment(prependingPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(prependingPath):\(existing)"
        return env
    }

    func runProcessCapture(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        timeoutSeconds: TimeInterval = 20
    ) async -> (exitCode: Int32, stdoutData: Data, stderrData: Data)? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let timeoutExitCode = Self.processTimeoutExitCode

        return await withCheckedContinuation { continuation in
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            let captureState = ProcessCaptureState(continuation: continuation)

            stdoutHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                captureState.appendStdout(chunk)
            }

            stderrHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                captureState.appendStderr(chunk)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                guard process.isRunning else { return }
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    if process.isRunning {
                        process.interrupt()
                    }
                }
                captureState.finish(
                    exitCode: timeoutExitCode,
                    stdoutHandle: stdoutHandle,
                    stderrHandle: stderrHandle,
                    drainRemaining: false
                )
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                captureState.finish(
                    exitCode: proc.terminationStatus,
                    stdoutHandle: stdoutHandle,
                    stderrHandle: stderrHandle,
                    drainRemaining: true
                )
            }
        }
    }

    nonisolated private static func resolveToolForPreview(named name: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let bundleURL = Bundle.main.resourceURL {
            candidates.append(bundleURL.appendingPathComponent("bin/\(name)"))
            candidates.append(bundleURL.appendingPathComponent(name))
        }

        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(name)"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/\(name)"))

        return candidates.first(where: { fm.isExecutableFile(atPath: $0.path) })
    }

    nonisolated private static func mergedEnvironmentForPreview(prependingPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(prependingPath):\(existing)"
        return env
    }

    nonisolated private static func runProcessCaptureForPreview(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        timeoutSeconds: TimeInterval = 20
    ) async -> (exitCode: Int32, stdoutData: Data, stderrData: Data)? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let timeoutExitCode = Self.processTimeoutExitCode

        return await withCheckedContinuation { continuation in
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            let captureState = ProcessCaptureState(continuation: continuation)

            stdoutHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                captureState.appendStdout(chunk)
            }

            stderrHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                captureState.appendStderr(chunk)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                guard process.isRunning else { return }
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    if process.isRunning {
                        process.interrupt()
                    }
                }
                captureState.finish(
                    exitCode: timeoutExitCode,
                    stdoutHandle: stdoutHandle,
                    stderrHandle: stderrHandle,
                    drainRemaining: false
                )
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                captureState.finish(
                    exitCode: proc.terminationStatus,
                    stdoutHandle: stdoutHandle,
                    stderrHandle: stderrHandle,
                    drainRemaining: true
                )
            }
        }
    }

    nonisolated private static func parsePublishState(from object: [String: Any]) -> PublishState {
        if let liveStatus = object["live_status"] as? String {
            switch liveStatus {
            case "is_live":
                return .live
            case "is_upcoming":
                return .upcoming
            case "not_live", "post_live", "was_live":
                return .published
            default:
                break
            }
        }

        if let isLive = object["is_live"] as? Bool, isLive {
            return .live
        }
        if let wasLive = object["was_live"] as? Bool, wasLive {
            return .published
        }
        if let releaseTs = object["release_timestamp"] as? Int, releaseTs > Int(Date().timeIntervalSince1970) {
            return .upcoming
        }
        if let duration = object["duration"] as? Double, duration > 0 {
            return .published
        }
        return .unknown
    }

    nonisolated private static func parseTechnicalSummary(from object: [String: Any]) -> (resolution: String, fps: String, bitrate: String, codec: String) {
        var width = intValue(from: object["width"])
        var height = intValue(from: object["height"])
        var fps = doubleValue(from: object["fps"])
        var tbr = doubleValue(from: object["tbr"])
        var codec = codecValue(from: object["vcodec"])

        if let requestedFormats = object["requested_formats"] as? [[String: Any]] {
            let selectedVideo = requestedFormats.first {
                ((($0["vcodec"] as? String) ?? "none") != "none")
            } ?? requestedFormats.first

            if let selectedVideo {
                width = width ?? intValue(from: selectedVideo["width"])
                height = height ?? intValue(from: selectedVideo["height"])
                fps = fps ?? doubleValue(from: selectedVideo["fps"])
                tbr = tbr ?? doubleValue(from: selectedVideo["tbr"])
                codec = codec ?? codecValue(from: selectedVideo["vcodec"])
            }
        }

        if let formats = object["formats"] as? [[String: Any]] {
            if width == nil || height == nil {
                if let bestVideo = formats
                    .filter({ ((($0["vcodec"] as? String) ?? "none") != "none") })
                    .max(by: { pixelCount(of: $0) < pixelCount(of: $1) }) {
                    width = width ?? intValue(from: bestVideo["width"])
                    height = height ?? intValue(from: bestVideo["height"])
                }
            }
            if fps == nil {
                fps = formats.compactMap { doubleValue(from: $0["fps"]) }.max()
            }
            if tbr == nil {
                tbr = formats.compactMap { doubleValue(from: $0["tbr"]) }.max()
            }
            if codec == nil {
                for format in formats {
                    if let detected = codecValue(from: format["vcodec"]) {
                        codec = detected
                        break
                    }
                }
            }
        }

        let resolutionText: String
        if let width, let height {
            resolutionText = "\(width)x\(height)"
        } else {
            resolutionText = "Unknown"
        }

        let fpsText: String
        if let fps {
            fpsText = "\(Int(fps.rounded())) fps"
        } else {
            fpsText = "Unknown"
        }

        let bitrateText: String
        if let tbr {
            if tbr >= 1000 {
                bitrateText = String(format: "%.2f Mbps", tbr / 1000.0)
            } else {
                bitrateText = "\(Int(tbr.rounded())) kbps"
            }
        } else {
            bitrateText = "Unknown"
        }

        let codecText = codec ?? "Unknown"

        return (resolutionText, fpsText, bitrateText, codecText)
    }

    nonisolated private static func pixelCount(of format: [String: Any]) -> Int {
        let width = intValue(from: format["width"]) ?? 0
        let height = intValue(from: format["height"]) ?? 0
        return width * height
    }

    nonisolated private static func intValue(from raw: Any?) -> Int? {
        if let int = raw as? Int {
            return int
        }
        if let double = raw as? Double {
            return Int(double.rounded())
        }
        if let string = raw as? String, let int = Int(string) {
            return int
        }
        return nil
    }

    nonisolated private static func doubleValue(from raw: Any?) -> Double? {
        if let double = raw as? Double {
            return double
        }
        if let int = raw as? Int {
            return Double(int)
        }
        if let string = raw as? String, let double = Double(string) {
            return double
        }
        return nil
    }

    nonisolated private static func codecValue(from raw: Any?) -> String? {
        guard let codec = raw as? String else { return nil }
        let trimmed = codec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
        return trimmed
    }
}
