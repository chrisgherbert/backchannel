import Foundation

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
    private var ytDlpErrorPipe: Pipe?
    private var ffmpegErrorPipe: Pipe?
    private var stagedMediaPipe: Pipe?
    private var stagedInputPipe: Pipe?
    private var startupRelay: AnyStartupRelay?
    private var delayedFfmpegTask: Task<Void, Never>?
    private var relayDrainTask: Task<Void, Never>?
    private var relayReadTask: Task<Void, Never>?
    private var outputFreezeMonitorTask: Task<Void, Never>?
    private var currentConfig: StreamConfig?

    private var shouldKeepRunning = false
    private var restartScheduled = false
    private var generation = 0
    private var restartAttempts = 0
    private var toolPaths: ToolPaths?
    private var logMonitoringEnabled = true
    private var bufferCountdownTask: Task<Void, Never>?
    private var previewRequestID = 0
    private var lastStatsParseUpdate = Date.distantPast
    private var lastYtDlpEventUpdate = Date.distantPast
    private var lastFfmpegEventUpdate = Date.distantPast
    private var lastFfmpegProgressSeconds: Double = 0
    private var lastFfmpegProgressAt = Date.distantPast
    private var hasSeenFfmpegProgress = false
    private var outputFreezeActive = false
    private var outputFreezeStartedAt = Date.distantPast
    private var lastOutputFreezeHeartbeatAt = Date.distantPast
    private var lastFfmpegDupCount: Int?
    private var lastFfmpegDupSampleAt = Date.distantPast
    private var duplicationFreezeActive = false
    private var duplicationFreezeStartedAt = Date.distantPast
    private var lastDuplicationAlertAt = Date.distantPast
    private var lastHighDupAt = Date.distantPast
    private var stallRecoveryTriggered = false
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

    func start(config: StreamConfig) {
        guard !config.sourceURL.isEmpty, !config.outputTarget.isEmpty else {
            appendLog("[app] Source URL and output target are required.")
            return
        }

        guard let paths = resolveToolPaths() else {
            status = "Missing Tools"
            return
        }

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
        hasSeenFfmpegProgress = false
        outputFreezeActive = false
        outputFreezeStartedAt = Date.distantPast
        lastOutputFreezeHeartbeatAt = Date.distantPast
        lastFfmpegDupCount = nil
        lastFfmpegDupSampleAt = Date.distantPast
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
        outputFreezeActive = false
        outputFreezeStartedAt = Date.distantPast
        lastOutputFreezeHeartbeatAt = Date.distantPast
        lastFfmpegDupCount = nil
        lastFfmpegDupSampleAt = Date.distantPast
        duplicationFreezeActive = false
        duplicationFreezeStartedAt = Date.distantPast
        lastDuplicationAlertAt = Date.distantPast
        lastHighDupAt = Date.distantPast
        stallRecoveryTriggered = false
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

        Task { [weak self] in
            guard let self else { return }
            let metadata = await self.fetchPreviewMetadata(for: trimmed)
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
        let useStartupGate = supportsStartupBuffer(config.encodeMode) && config.bufferSeconds > 0

        ytDlp.standardOutput = mediaPipe
        if let ytError {
            ytDlp.standardError = ytError
        } else {
            ytDlp.standardError = FileHandle.nullDevice
        }

        ytDlpErrorPipe = ytError
        ffmpegErrorPipe = ffError

        if let ytError {
            observe(pipe: ytError, source: "yt-dlp")
        }
        if let ffError {
            observe(pipe: ffError, source: "ffmpeg")
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
            var relayForGate: AnyStartupRelay?
            let ffmpegInput: Pipe
            if useStartupGate {
                let relay: AnyStartupRelay
                if config.encodeMode == .transcode && config.useDiskBackedBuffer {
                    relay = try makeDiskBackedRelay(delaySeconds: Double(config.bufferSeconds))
                } else {
                    relay = AnyStartupRelay(StartupGateRelay(delaySeconds: Double(config.bufferSeconds)))
                }
                relayForGate = relay
                startupRelay = relay
                stagedMediaPipe = mediaPipe
                let delayedInput = Pipe()
                stagedInputPipe = delayedInput
                ffmpegInput = delayedInput

                let relaySourceHandle = mediaPipe.fileHandleForReading
                let relayReadChunkSize = Self.relayReadChunkSize
                relayReadTask?.cancel()
                relayReadTask = Task.detached(priority: .userInitiated) {
                    while !Task.isCancelled {
                        do {
                            let data = try relaySourceHandle.read(upToCount: relayReadChunkSize) ?? Data()
                            if data.isEmpty {
                                await relay.finishInput()
                                break
                            }
                            await relay.ingest(data)
                        } catch {
                            await relay.finishInput()
                            break
                        }
                    }
                }
            } else {
                ffmpegInput = mediaPipe
            }

            let ffmpeg = makeFFmpegProcess(
                paths: paths,
                config: config,
                generation: currentGeneration,
                ffError: ffError,
                input: ffmpegInput,
                ffmpegToolsDir: ffmpegToolsDir
            )

            try ytDlp.run()
            ytDlpProcess = ytDlp

            if useStartupGate {
                isRunning = true
                status = "Running"
                parsedStatus.sourceState = "Running"
                parsedStatus.outputState = "Buffering"
                appendLog("[app] Pipeline started (startup gate active).")
                appendLog("[app] Output publish will begin after \(config.bufferSeconds)s buffer fill.")
                if config.encodeMode == .transcode {
                    let storage = config.useDiskBackedBuffer ? "Disk" : "Memory"
                    appendLog("[app] Buffer storage: \(storage)")
                }
                delayedFfmpegTask = Task { [weak self] in
                    guard let self, let relay = relayForGate else { return }
                    let targetDelay = Double(config.bufferSeconds)
                    while !Task.isCancelled {
                        guard self.shouldKeepRunning, currentGeneration == self.generation else { return }

                        let report = await relay.drainReady()
                        await MainActor.run {
                            self.applyBufferReport(report, config: config)
                        }

                        if report.isInputEnded || report.bufferedDelaySeconds >= targetDelay {
                            break
                        }

                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }

                    guard self.shouldKeepRunning, currentGeneration == self.generation else { return }
                    await self.startBufferedPublisher(
                        ffmpeg: ffmpeg,
                        relay: relay,
                        generation: currentGeneration
                    )
                }
            } else {
                try ffmpeg.run()
                ffmpegProcess = ffmpeg

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
            if config.encodeMode == .transcode {
                let encoder = paths.supportsVideoToolboxH264 ? "h264_videotoolbox (hardware)" : "libx264 (software)"
                appendLog("[app] High compatibility video encoder: \(encoder)")
            }
            if let deno = paths.deno {
                appendLog("[app] Using deno: \(deno.path)")
            } else {
                appendLog("[app] Deno runtime not found. YouTube extraction may be limited.")
            }
            startBufferCountdownIfNeeded(config: config, generation: currentGeneration)
            startOutputFreezeMonitorIfNeeded()
        } catch {
            appendLog("[app] Failed to start pipeline: \(error.localizedDescription)")
            terminatePipeline()
            scheduleRestart(generation: currentGeneration)
        }
    }

    private func makeDiskBackedRelay(delaySeconds: TimeInterval) throws -> AnyStartupRelay {
        let relayDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-live-converter-relay", isDirectory: true)
        try FileManager.default.createDirectory(at: relayDirectory, withIntermediateDirectories: true)
        let relay = try DiskBackedStartupRelay(
            delaySeconds: delaySeconds,
            tempDirectory: relayDirectory
        )
        return AnyStartupRelay(relay)
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

    private func startBufferedPublisher(ffmpeg: Process, relay: AnyStartupRelay, generation: Int) async {
        guard shouldKeepRunning, generation == self.generation else { return }
        do {
            try ffmpeg.run()
            ffmpegProcess = ffmpeg
            parsedStatus.outputState = "Running"
            appendLog("[app] Startup buffer filled. Publishing to destination.")
            if let inputPipe = stagedInputPipe {
                await relay.attachSink(inputPipe.fileHandleForWriting)
                relayDrainTask?.cancel()
                relayDrainTask = Task { [weak self] in
                    while let self, !Task.isCancelled {
                        let report = await relay.drainReady()
                        if let config = self.currentConfig {
                            self.applyBufferReport(report, config: config)
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        if !self.shouldKeepRunning {
                            return
                        }
                    }
                }
            }
        } catch {
            appendLog("[app] Failed to start publisher after buffer fill: \(error.localizedDescription)")
            scheduleRestart(generation: generation)
        }
    }

    private func terminatePipeline() {
        ytDlpProcess?.terminationHandler = nil
        ffmpegProcess?.terminationHandler = nil
        delayedFfmpegTask?.cancel()
        delayedFfmpegTask = nil
        relayDrainTask?.cancel()
        relayDrainTask = nil
        relayReadTask?.cancel()
        relayReadTask = nil
        outputFreezeMonitorTask?.cancel()
        outputFreezeMonitorTask = nil
        bufferCountdownTask?.cancel()
        bufferCountdownTask = nil

        if ytDlpProcess?.isRunning == true {
            ytDlpProcess?.terminate()
        }
        if ffmpegProcess?.isRunning == true {
            ffmpegProcess?.terminate()
        }

        ytDlpProcess = nil
        ffmpegProcess = nil
        stagedMediaPipe?.fileHandleForReading.readabilityHandler = nil
        stagedMediaPipe = nil
        if let relay = startupRelay {
            Task { await relay.closeNow() }
        }
        startupRelay = nil
        stagedInputPipe = nil
        ytDlpErrorPipe?.fileHandleForReading.readabilityHandler = nil
        ffmpegErrorPipe?.fileHandleForReading.readabilityHandler = nil
        ytDlpErrorPipe = nil
        ffmpegErrorPipe = nil
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
                    scheduleRestart(generation: generation)
                } else {
                    Task { @MainActor in
                        self.isRunning = false
                        self.status = "Stopped"
                    }
                }
                return
            }
        }

        terminatePipeline()

        if shouldKeepRunning {
            scheduleRestart(generation: generation)
        } else {
            Task { @MainActor in
                self.isRunning = false
                self.status = "Stopped"
            }
        }
    }

    private func scheduleRestart(generation: Int) {
        guard generation == self.generation else { return }
        guard shouldKeepRunning else { return }
        guard !restartScheduled else { return }

        restartScheduled = true
        restartAttempts += 1
        let delay = min(pow(2.0, Double(restartAttempts)), 30.0)

        status = "Reconnecting (\(Int(delay))s)"
        parsedStatus.reconnectDelay = "\(Int(delay))s"
        appendLog("[app] Restarting pipeline in \(Int(delay))s.")

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

    private func ffmpegArguments(for config: StreamConfig) -> [String] {
        let syncOffsetMs = config.avSyncOffsetMs
        let extraAudioDelayMs = max(0, syncOffsetMs)
        let extraVideoDelaySeconds = syncOffsetMs < 0 ? Double(-syncOffsetMs) / 1_000.0 : 0
        // Startup buffering is handled by relay gating; filters should only apply A/V sync offsets.
        let totalVideoDelaySeconds = extraVideoDelaySeconds
        let totalAudioDelayMs = extraAudioDelayMs
        var audioFilters: [String] = []
        var inputArgs: [String] = []
        if config.encodeMode == .copy || config.encodeMode == .copyPaced {
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
        if config.encodeMode == .copyPaced {
            // Keep copy mode stable while smoothing bursty input pacing.
            inputArgs += ["-thread_queue_size", "8192"]
        }
        var args = [
            "-hide_banner",
            "-loglevel",
            "info"
        ]
        args += inputArgs
        args += ["-i", "pipe:0"]
        // Keep stream selection deterministic to avoid stream switching side-effects.
        args += ["-map", "0:v:0", "-map", "0:a:0?"]

        let useVideoToolbox = toolPaths?.supportsVideoToolboxH264 == true
        switch config.encodeMode {
        case .copy:
            args += ["-c:v", "copy", "-c:a", "copy"]
        case .copyPaced:
            args += [
                "-fps_mode", "passthrough",
                "-c:v", "copy",
                "-c:a", "copy"
            ]
        case .transcode:
            // Keep audio timeline aligned to stream PTS to reduce long-run A/V drift.
            audioFilters.append("aresample=async=1000:min_hard_comp=0.050:first_pts=0")
            // Re-stamp audio to a monotonic timeline to reduce long freezes caused by discontinuous source PTS.
            audioFilters.append("asetpts=N/SR/TB")
            let targetFps = 30
            var videoSetptsExpr = "N/(\(targetFps)*TB)"
            if totalVideoDelaySeconds > 0 {
                let delay = String(format: "%.3f", totalVideoDelaySeconds)
                videoSetptsExpr += "+\(delay)/TB"
            }
            let videoFilter = "settb=AVTB,setpts=\(videoSetptsExpr)"
            if useVideoToolbox {
                // Prefer hardware encoding on macOS for stable real-time throughput.
                args += [
                    "-fps_mode", "cfr",
                    "-r", "\(targetFps)",
                    "-c:v", "h264_videotoolbox",
                    "-allow_sw", "1",
                    "-realtime", "1",
                    "-pix_fmt", "yuv420p",
                    "-g", "60",
                    "-bf", "0",
                    "-b:v", "3500k",
                    "-maxrate", "4500k",
                    "-bufsize", "9000k",
                    "-vf", videoFilter,
                    "-c:a", "aac",
                    "-ar", "48000",
                    "-ac", "2",
                    "-b:a", "128k"
                ]
            } else {
                args += [
                    "-fps_mode", "cfr",
                    "-r", "\(targetFps)",
                    "-c:v", "libx264",
                    "-preset", "ultrafast",
                    "-tune", "zerolatency",
                    "-crf", "27",
                    "-pix_fmt", "yuv420p",
                    "-g", "60",
                    "-keyint_min", "60",
                    "-sc_threshold", "0",
                    "-profile:v", "main",
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
            if config.encodeMode == .copy || config.encodeMode == .copyPaced {
                // Improve RTMP receiver compatibility when remuxing bursty MPEG-TS input.
                args += ["-bsf:v", "extract_extradata"]
            }
            // Keep muxing latency/interleave tight so audio/video stay closer under jitter.
            args += [
                "-flvflags", "no_duration_filesize",
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

    private func bufferStateText(for config: StreamConfig) -> String {
        guard supportsStartupBuffer(config.encodeMode) else {
            return "Off (Stream Copy)"
        }
        if config.bufferSeconds <= 0 {
            return "Off"
        }
        return "On (\(config.bufferSeconds)s delay)"
    }

    private func initialBufferProgress(for config: StreamConfig) -> Double {
        if !supportsStartupBuffer(config.encodeMode) {
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
        let storageLabel = config.useDiskBackedBuffer ? "disk" : "memory"
        let monitoringLabel = logMonitoringEnabled ? "on" : "off"
        appendLog(
            "[app] Session config: mode=\(config.encodeMode.rawValue), format=\(config.outputType.rawValue), buffer=\(config.bufferSeconds)s, storage=\(storageLabel), avOffset=\(config.avSyncOffsetMs)ms, audioBoost=\(boostLabel), logMonitoring=\(monitoringLabel), output=\(outputTarget)"
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
        let appPart = pathParts.first.map(String.init) ?? "app"
        return "\(scheme)://\(host)\(portSuffix)/\(appPart)/<redacted>"
    }

    private func observe(pipe: Pipe, source: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    self?.flushPendingLogChunk(for: source)
                    self?.flushSuppressedMetadataIfNeeded(force: true)
                    self?.flushSuppressedProgressIfNeeded(force: true)
                    self?.flushPendingUiLogs()
                }
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.ingestLogChunk(chunk, source: source)
            }
        }
    }

    private func ingestLogChunk(_ chunk: String, source: String) {
        let existing = pendingLogChunkBySource[source] ?? ""
        let combined = existing + chunk
        let parts = combined.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let endsWithNewline = combined.last?.isNewline == true
        let completeCount = endsWithNewline ? parts.count : max(0, parts.count - 1)

        if endsWithNewline {
            pendingLogChunkBySource[source] = ""
        } else {
            pendingLogChunkBySource[source] = String(parts.last ?? "")
        }

        if completeCount == 0 { return }
        for index in 0..<completeCount {
            let raw = String(parts[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            appendLog("[\(source)] \(normalizedLogPayload(raw))")
        }
    }

    private func flushPendingLogChunk(for source: String) {
        let remainder = (pendingLogChunkBySource[source] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            pendingLogChunkBySource[source] = ""
            return
        }
        pendingLogChunkBySource[source] = ""
        appendLog("[\(source)] \(normalizedLogPayload(remainder))")
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
        if !isFrameStatsLine {
            updateSourceEvent(source: source, message: message, now: now, throttleFrameLines: false)
        } else {
            updateSourceEvent(source: source, message: message, now: now, throttleFrameLines: true)
        }

        if message.contains("ERROR:") || message.lowercased().contains(" error") {
            parsedStatus.lastError = message
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
            if let bps = parseBitrateToBps(parsedStatus.ffmpegBitrate) {
                estimatedOutputBitrateBps = bps
            }
            updateDuplicationFreezeDetection(from: message, now: now)

            if let progressSeconds = parseClockToSeconds(parsedStatus.ffmpegTime) {
                if progressSeconds > lastFfmpegProgressSeconds + 0.2 {
                    lastFfmpegProgressSeconds = progressSeconds
                    lastFfmpegProgressAt = now
                    hasSeenFfmpegProgress = true
                    if outputFreezeActive {
                        outputFreezeActive = false
                        let freezeDuration = max(0, now.timeIntervalSince(outputFreezeStartedAt))
                        appendLog("[app] Output freeze recovered after \(Int(freezeDuration.rounded()))s.")
                    }
                    stallRecoveryTriggered = false
                } else if !stallRecoveryTriggered &&
                    shouldKeepRunning &&
                    isRunning &&
                    shouldMonitorStallRecovery() &&
                    parsedStatus.outputState == "Publishing" &&
                    now.timeIntervalSince(lastFfmpegProgressAt) >= Self.outputStallThreshold {
                    stallRecoveryTriggered = true
                    appendLog("[app] Output appears stalled (no ffmpeg time advance for \(Int(Self.outputStallThreshold))s). Restarting pipeline.")
                    terminatePipeline()
                    scheduleRestart(generation: generation)
                    return
                }
            }
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

    private func captureInt(regex: NSRegularExpression, in text: String) -> Int? {
        let captured = capture(regex: regex, in: text)
        guard !captured.isEmpty else { return nil }
        return Int(captured)
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
            } else if now.timeIntervalSince(lastDuplicationAlertAt) >= Self.duplicationFreezeHeartbeatInterval {
                lastDuplicationAlertAt = now
                appendLog("[app] Visual freeze ongoing: duplicate-frame rate ~\(Int(dupPerSecond.rounded())) fps.")
            }
            return
        }

        if duplicationFreezeActive && now.timeIntervalSince(lastHighDupAt) >= Self.duplicationFreezeRecoveryWindow {
            duplicationFreezeActive = false
            let freezeDuration = max(0, now.timeIntervalSince(duplicationFreezeStartedAt))
            appendLog("[app] Visual freeze recovered after \(Int(freezeDuration.rounded()))s.")
        }
    }

    private func startBufferCountdownIfNeeded(config: StreamConfig, generation: Int) {
        bufferCountdownTask?.cancel()
        bufferCountdownTask = nil

        guard supportsStartupBuffer(config.encodeMode), config.bufferSeconds > 0 else {
            parsedStatus.bufferState = bufferStateText(for: config)
            parsedStatus.bufferProgress = initialBufferProgress(for: config)
            return
        }

        let total = config.bufferSeconds
        parsedStatus.outputState = "Buffering"
        parsedStatus.bufferState = "Filling (target \(total)s)"
        parsedStatus.bufferProgress = 0
        appendLog("[app] Buffer priming started (target \(total)s).")
    }

    private func applyBufferReport(_ report: RelayBufferReport, config: StreamConfig) {
        guard supportsStartupBuffer(config.encodeMode), config.bufferSeconds > 0 else { return }

        let now = Date()
        let target = max(1.0, Double(config.bufferSeconds))
        let bufferedSecondsFromBitrate: Double? = {
            guard estimatedOutputBitrateBps > 32_000 else { return nil }
            return (Double(report.unreadBytes) * 8.0) / estimatedOutputBitrateBps
        }()
        let bufferedSeconds = max(
            report.bufferedDelaySeconds,
            bufferedSecondsFromBitrate ?? 0
        )

        let exhaustionThreshold = min(1.0, report.targetDelaySeconds * 0.2)
        let recoveryThreshold = exhaustionThreshold + 0.8
        let shouldMarkExhausted: Bool
        if bufferExhausted {
            shouldMarkExhausted = bufferedSeconds < recoveryThreshold
        } else {
            shouldMarkExhausted = bufferedSeconds < exhaustionThreshold
        }

        let isExhausted = report.hasSink &&
            !report.isInputEnded &&
            shouldMarkExhausted

        let exhaustionChanged = bufferExhausted != isExhausted
        guard exhaustionChanged || now.timeIntervalSince(lastBufferUiUpdate) >= 0.5 else { return }
        lastBufferUiUpdate = now

        let fill = min(1.0, max(0.0, bufferedSeconds / target))

        // Before publishing begins, show true media-buffer progress toward target.
        if !report.hasSink && !report.isInputEnded {
            let rounded = Int(bufferedSeconds.rounded())
            let remaining = max(0, config.bufferSeconds - rounded)
            if remaining > 0 {
                parsedStatus.bufferState = "Filling (\(remaining)s remaining)"
            } else {
                parsedStatus.bufferState = "Primed (\(config.bufferSeconds)s delay)"
            }
            parsedStatus.bufferProgress = fill
            parsedStatus.outputState = "Buffering"
            return
        }

        if isExhausted {
            if !bufferExhausted {
                appendLog("[app] Buffer exhausted. Waiting for source to refill.")
            }
            bufferExhausted = true
            parsedStatus.bufferState = "Exhausted (\(Int(bufferedSeconds.rounded()))s/\(config.bufferSeconds)s)"
            parsedStatus.bufferProgress = fill
            parsedStatus.outputState = "Buffering"
            return
        }

        if bufferExhausted {
            appendLog("[app] Buffer recovered. Publishing resumed.")
        }
        bufferExhausted = false

        if !parsedStatus.bufferState.contains("Filling") {
            let rounded = Int(bufferedSeconds.rounded())
            if rounded >= config.bufferSeconds {
                parsedStatus.bufferState = "Primed (\(config.bufferSeconds)s delay)"
                parsedStatus.bufferProgress = 1.0
            } else {
                parsedStatus.bufferState = "Buffered (\(rounded)s/\(config.bufferSeconds)s)"
                parsedStatus.bufferProgress = fill
            }
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let statsParseInterval: TimeInterval = 0.5
    private static let statsEventInterval: TimeInterval = 0.5
    private static let outputStallThreshold: TimeInterval = 12.0
    private static let outputFreezeLogThreshold: TimeInterval = 6.0
    private static let outputFreezeHeartbeatInterval: TimeInterval = 10.0
    private static let outputFreezeMonitorPollInterval: TimeInterval = 1.0
    private static let duplicationFreezeDupPerSecondThreshold: Double = 10.0
    private static let duplicationFreezeHeartbeatInterval: TimeInterval = 10.0
    private static let duplicationFreezeRecoveryWindow: TimeInterval = 3.0
    private static let metadataSummaryInterval: TimeInterval = 2.0
    private static let progressSummaryInterval: TimeInterval = 2.0
    private static let logFlushInterval: TimeInterval = 0.2
    private static let relayReadChunkSize: Int = 262_144
    private static let maxToolLogPayloadLength: Int = 800
    private static let processTimeoutExitCode: Int32 = -999
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

    private func supportsStartupBuffer(_ mode: EncodeMode) -> Bool {
        mode == .transcode || mode == .copyPaced
    }

    private func supportsBufferedDrainOnSourceExit() -> Bool {
        guard let config = currentConfig else { return false }
        return supportsStartupBuffer(config.encodeMode) && config.bufferSeconds > 0
    }

    private func shouldMonitorStallRecovery() -> Bool {
        guard let config = currentConfig else { return true }
        let usesDelayedRelay = supportsStartupBuffer(config.encodeMode) && config.bufferSeconds > 0
        return !usesDelayedRelay
    }

    private func startOutputFreezeMonitorIfNeeded() {
        outputFreezeMonitorTask?.cancel()
        outputFreezeMonitorTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.outputFreezeMonitorPollInterval * 1_000_000_000)
                )
                guard self.shouldKeepRunning, self.isRunning else { continue }
                guard self.logMonitoringEnabled else { continue }
                guard self.ffmpegProcess?.isRunning == true else { continue }
                guard self.hasSeenFfmpegProgress else { continue }

                let outputState = self.parsedStatus.outputState.lowercased()
                guard outputState.contains("publish") || outputState.contains("running") else { continue }

                let now = Date()
                let stalledFor = now.timeIntervalSince(self.lastFfmpegProgressAt)
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
                    continue
                }

                if now.timeIntervalSince(self.lastOutputFreezeHeartbeatAt) >= Self.outputFreezeHeartbeatInterval {
                    self.lastOutputFreezeHeartbeatAt = now
                    self.appendLog(
                        "[app] Output freeze ongoing: ffmpeg output time stagnant for \(Int(stalledFor.rounded()))s."
                    )
                }
            }
        }
    }

    private func fetchPreviewMetadata(for sourceURL: String) async -> (preview: StreamPreview?, message: String) {
        guard let paths = resolveToolPaths() else {
            return (nil, "Tools unavailable")
        }

        let ffmpegToolsDir = paths.ffmpeg.deletingLastPathComponent().path
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
        if let deno = paths.deno {
            args += ["--js-runtimes", "deno:\(deno.path)"]
        }
        args += [
            "--paths", "home:\(ytDlpWorkDir.path)",
            "--paths", "temp:\(ytDlpWorkDir.path)",
            "--ffmpeg-location", ffmpegToolsDir,
            sourceURL
        ]

        guard let result = await runProcessCapture(
            executableURL: paths.ytDlp,
            arguments: args,
            environment: mergedEnvironment(prependingPath: ffmpegToolsDir),
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

private final class AnyStartupRelay: @unchecked Sendable {
    private let ingestFn: (Data) async -> Void
    private let attachSinkFn: (FileHandle) async -> Void
    private let drainReadyFn: () async -> RelayBufferReport
    private let finishInputFn: () async -> Void
    private let closeNowFn: () async -> Void

    init(_ relay: StartupGateRelay) {
        ingestFn = { data in await relay.ingest(data) }
        attachSinkFn = { handle in await relay.attachSink(handle) }
        drainReadyFn = { await relay.drainReady() }
        finishInputFn = { await relay.finishInput() }
        closeNowFn = { await relay.closeNow() }
    }

    init(_ relay: DiskBackedStartupRelay) {
        ingestFn = { data in await relay.ingest(data) }
        attachSinkFn = { handle in await relay.attachSink(handle) }
        drainReadyFn = { await relay.drainReady() }
        finishInputFn = { await relay.finishInput() }
        closeNowFn = { await relay.closeNow() }
    }

    func ingest(_ data: Data) async {
        await ingestFn(data)
    }

    func attachSink(_ handle: FileHandle) async {
        await attachSinkFn(handle)
    }

    func drainReady() async -> RelayBufferReport {
        await drainReadyFn()
    }

    func finishInput() async {
        await finishInputFn()
    }

    func closeNow() async {
        await closeNowFn()
    }
}

private actor DiskBackedStartupRelay {
    private struct ChunkMeta {
        let byteCount: Int
        let enqueuedAt: Date
    }

    private let delaySeconds: TimeInterval
    private let fileURL: URL
    private let writeHandle: FileHandle
    private let readHandle: FileHandle
    private let minimumPaceBytesPerSecond: Double = 64_000 // 512 kbps floor

    private var nextOffset: UInt64 = 0
    private var readOffset: UInt64 = 0
    private var sink: FileHandle?
    private var inputEnded = false
    private var isClosed = false
    private var totalIngestedBytes: UInt64 = 0
    private var firstIngestAt: Date?
    private var lastDrainAt: Date?
    private var writeBudgetBytes: Double = 0
    private var chunkMetas: [ChunkMeta] = []
    private var metaReadIndex = 0
    private var metaReadOffset = 0
    private var unreadMetaBytes: Int = 0

    init(delaySeconds: TimeInterval, tempDirectory: URL) throws {
        self.delaySeconds = max(0, delaySeconds)
        self.fileURL = tempDirectory.appendingPathComponent("relay-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.writeHandle = try FileHandle(forWritingTo: fileURL)
        self.readHandle = try FileHandle(forReadingFrom: fileURL)
    }

    func ingest(_ data: Data) {
        guard !isClosed else { return }
        writeHandle.seekToEndOfFile()
        writeHandle.write(data)
        nextOffset += UInt64(data.count)
        totalIngestedBytes += UInt64(data.count)
        chunkMetas.append(ChunkMeta(byteCount: data.count, enqueuedAt: Date()))
        unreadMetaBytes += data.count
        if firstIngestAt == nil {
            firstIngestAt = Date()
        }
        if sink != nil {
            _ = drainReady()
        }
    }

    func attachSink(_ handle: FileHandle) {
        guard !isClosed else { return }
        sink = handle
        _ = drainReady()
    }

    func drainReady(now: Date = Date()) -> RelayBufferReport {
        guard !isClosed else {
            return RelayBufferReport(
                bufferedDelaySeconds: 0,
                unreadBytes: 0,
                targetDelaySeconds: delaySeconds,
                hasSink: false,
                isInputEnded: true
            )
        }
        guard let sink else {
            return makeReport(now: now)
        }

        let estimatedBytesPerSecond = estimatedIngressBytesPerSecond(now: now)
        if let last = lastDrainAt {
            let elapsed = max(0, now.timeIntervalSince(last))
            writeBudgetBytes += elapsed * estimatedBytesPerSecond
        } else {
            // Let publishing begin promptly without draining in one burst.
            writeBudgetBytes = max(writeBudgetBytes, estimatedBytesPerSecond * 0.2)
        }
        lastDrainAt = now

        let releasableBytes = releasableBytesByTime(now: now)
        let maxBudget = max(estimatedBytesPerSecond * 2.0, 128_000)
        writeBudgetBytes = min(writeBudgetBytes, maxBudget)

        var remaining = releasableBytes
        var writes = 0
        while remaining > 0 && writeBudgetBytes >= 1 && writes < 8 {
            let batchCap = max(32_768, Int(estimatedBytesPerSecond * 0.2))
            let count = min(remaining, min(Int(writeBudgetBytes), batchCap))
            if count <= 0 { break }

            readHandle.seek(toFileOffset: readOffset)
            let payload = readHandle.readData(ofLength: count)
            if payload.isEmpty { break }

            do {
                try sink.write(contentsOf: payload)
            } catch {
                closeNow()
                return makeReport(now: now)
            }

            let written = payload.count
            readOffset += UInt64(written)
            writeBudgetBytes = max(0, writeBudgetBytes - Double(written))
            remaining -= written
            writes += 1
            consumeMetaBytes(written)

            if written < count {
                break
            }
        }

        if inputEnded && readOffset >= nextOffset {
            closeNow()
        }

        return makeReport(now: now)
    }

    private func releasableBytesByTime(now: Date) -> Int {
        let threshold = now.addingTimeInterval(-delaySeconds)
        var releasable = 0
        var index = metaReadIndex
        var offset = metaReadOffset

        while index < chunkMetas.count {
            let meta = chunkMetas[index]
            if !inputEnded && meta.enqueuedAt > threshold {
                break
            }
            let available = max(0, meta.byteCount - offset)
            releasable += available
            index += 1
            offset = 0
        }
        return releasable
    }

    func finishInput() {
        guard !isClosed else { return }
        inputEnded = true
        _ = drainReady()
    }

    func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        sink?.closeFile()
        sink = nil
        writeHandle.closeFile()
        readHandle.closeFile()
        nextOffset = 0
        readOffset = 0
        totalIngestedBytes = 0
        firstIngestAt = nil
        lastDrainAt = nil
        writeBudgetBytes = 0
        chunkMetas.removeAll(keepingCapacity: false)
        metaReadIndex = 0
        metaReadOffset = 0
        unreadMetaBytes = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func makeReport(now: Date) -> RelayBufferReport {
        let unreadBytes = max(0, unreadMetaBytes)
        let ageBasedDelay = oldestUnreadChunkEnqueuedAt().map { max(0, now.timeIntervalSince($0)) } ?? 0
        let ingressBytesPerSecond = estimatedIngressBytesPerSecond(now: now)
        let byteBasedDelay = ingressBytesPerSecond > 0
            ? Double(unreadBytes) / ingressBytesPerSecond
            : 0
        let bufferedDelay = unreadBytes > 0
            ? min(ageBasedDelay, byteBasedDelay)
            : 0
        return RelayBufferReport(
            bufferedDelaySeconds: bufferedDelay,
            unreadBytes: unreadBytes,
            targetDelaySeconds: delaySeconds,
            hasSink: sink != nil,
            isInputEnded: inputEnded
        )
    }

    private func oldestUnreadChunkEnqueuedAt() -> Date? {
        guard unreadMetaBytes > 0 else { return nil }
        guard metaReadIndex < chunkMetas.count else { return nil }
        return chunkMetas[metaReadIndex].enqueuedAt
    }

    private func consumeMetaBytes(_ count: Int) {
        guard count > 0 else { return }
        unreadMetaBytes = max(0, unreadMetaBytes - count)

        var remaining = count
        while remaining > 0, metaReadIndex < chunkMetas.count {
            let current = chunkMetas[metaReadIndex]
            let available = current.byteCount - metaReadOffset
            if remaining >= available {
                remaining -= available
                metaReadIndex += 1
                metaReadOffset = 0
            } else {
                metaReadOffset += remaining
                remaining = 0
            }
        }

        if metaReadIndex > 512 && metaReadIndex >= chunkMetas.count / 2 {
            chunkMetas.removeFirst(metaReadIndex)
            metaReadIndex = 0
        }
    }

    private func estimatedIngressBytesPerSecond(now: Date) -> Double {
        guard let firstIngestAt, totalIngestedBytes > 0 else {
            return minimumPaceBytesPerSecond
        }
        let elapsed = max(1.0, now.timeIntervalSince(firstIngestAt))
        let average = Double(totalIngestedBytes) / elapsed
        return max(minimumPaceBytesPerSecond, average)
    }
}

private actor StartupGateRelay {
    private struct Chunk {
        let data: Data
        let enqueuedAt: Date
    }

    private let delaySeconds: TimeInterval
    private let minimumPaceBytesPerSecond: Double = 64_000 // 512 kbps floor
    private var bufferedChunks: [Chunk] = []
    private var readIndex = 0
    private var unreadByteCount = 0
    private var totalIngestedBytes: UInt64 = 0
    private var firstIngestAt: Date?
    private var sink: FileHandle?
    private var inputEnded = false
    private var isClosed = false

    init(delaySeconds: TimeInterval) {
        self.delaySeconds = max(0, delaySeconds)
    }

    func ingest(_ data: Data) {
        guard !isClosed else { return }
        bufferedChunks.append(Chunk(data: data, enqueuedAt: Date()))
        unreadByteCount += data.count
        totalIngestedBytes += UInt64(data.count)
        if firstIngestAt == nil {
            firstIngestAt = Date()
        }
        if sink != nil {
            _ = drainReady()
        }
    }

    func attachSink(_ handle: FileHandle) {
        guard !isClosed else { return }
        sink = handle
        _ = drainReady()
    }

    func drainReady(now: Date = Date()) -> RelayBufferReport {
        guard !isClosed else {
            return RelayBufferReport(
                bufferedDelaySeconds: 0,
                unreadBytes: 0,
                targetDelaySeconds: delaySeconds,
                hasSink: false,
                isInputEnded: true
            )
        }
        guard let sink else {
            return makeReport(now: now)
        }

        let threshold = now.addingTimeInterval(-delaySeconds)
        var writes = 0
        while readIndex < bufferedChunks.count {
            let chunk = bufferedChunks[readIndex]
            if !inputEnded && chunk.enqueuedAt > threshold {
                break
            }
            try? sink.write(contentsOf: chunk.data)
            readIndex += 1
            unreadByteCount = max(0, unreadByteCount - chunk.data.count)
            writes += 1
            if writes >= 128 {
                break
            }
        }

        if readIndex > 256 && readIndex >= bufferedChunks.count / 2 {
            bufferedChunks.removeFirst(readIndex)
            readIndex = 0
        }

        if inputEnded && readIndex >= bufferedChunks.count {
            closeNow()
        }

        return makeReport(now: now)
    }

    func finishInput() {
        guard !isClosed else { return }
        inputEnded = true
        _ = drainReady()
    }

    func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        sink?.closeFile()
        sink = nil
        bufferedChunks.removeAll(keepingCapacity: false)
        readIndex = 0
        unreadByteCount = 0
        totalIngestedBytes = 0
        firstIngestAt = nil
    }

    private func makeReport(now: Date) -> RelayBufferReport {
        let unread = max(0, bufferedChunks.count - readIndex)
        let ageBasedDelay: TimeInterval = unread > 0
            ? max(0, now.timeIntervalSince(bufferedChunks[readIndex].enqueuedAt))
            : 0
        let ingressBytesPerSecond = estimatedIngressBytesPerSecond(now: now)
        let byteBasedDelay: TimeInterval = ingressBytesPerSecond > 0
            ? Double(unreadByteCount) / ingressBytesPerSecond
            : 0
        let bufferedDelay = unread > 0 ? min(ageBasedDelay, byteBasedDelay) : 0
        return RelayBufferReport(
            bufferedDelaySeconds: bufferedDelay,
            unreadBytes: unreadByteCount,
            targetDelaySeconds: delaySeconds,
            hasSink: sink != nil,
            isInputEnded: inputEnded
        )
    }

    private func estimatedIngressBytesPerSecond(now: Date) -> Double {
        guard let firstIngestAt, totalIngestedBytes > 0 else {
            return minimumPaceBytesPerSecond
        }
        let elapsed = max(1.0, now.timeIntervalSince(firstIngestAt))
        let average = Double(totalIngestedBytes) / elapsed
        return max(minimumPaceBytesPerSecond, average)
    }
}

private struct RelayBufferReport {
    let bufferedDelaySeconds: TimeInterval
    let unreadBytes: Int
    let targetDelaySeconds: TimeInterval
    let hasSink: Bool
    let isInputEnded: Bool
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

    func parsePublishState(from object: [String: Any]) -> PublishState {
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

    func parseTechnicalSummary(from object: [String: Any]) -> (resolution: String, fps: String, bitrate: String, codec: String) {
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

    func pixelCount(of format: [String: Any]) -> Int {
        let width = intValue(from: format["width"]) ?? 0
        let height = intValue(from: format["height"]) ?? 0
        return width * height
    }

    func intValue(from raw: Any?) -> Int? {
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

    func doubleValue(from raw: Any?) -> Double? {
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

    func codecValue(from raw: Any?) -> String? {
        guard let codec = raw as? String else { return nil }
        let trimmed = codec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
        return trimmed
    }
}
