import Foundation
import RTMPHaishinKit

actor DirectTSRTMPPublisher {
    private enum FeatureFlags {
        static let disableAudio = ProcessInfo.processInfo.environment["BACKCHANNEL_HAISHIN_DISABLE_AUDIO"] == "1"
        static let disableVideo = ProcessInfo.processInfo.environment["BACKCHANNEL_HAISHIN_DISABLE_VIDEO"] == "1"
        private static let defaultPlayoutLeadSeconds = 0.18
        private static let defaultBucketDurationSeconds = 0.05
        static let playoutLeadSeconds = max(
            0,
            Double(ProcessInfo.processInfo.environment["BACKCHANNEL_DIRECT_RTMP_LEAD_SECONDS"] ?? "") ?? defaultPlayoutLeadSeconds
        )
        static let bucketDurationSeconds = max(
            0,
            Double(ProcessInfo.processInfo.environment["BACKCHANNEL_DIRECT_RTMP_BUCKET_SECONDS"] ?? "") ?? defaultBucketDurationSeconds
        )
    }

    fileprivate enum StreamKind {
        case video
        case audio
    }

    fileprivate struct ScheduledPacket: Sendable {
        let scheduledSeconds: Double
        let progressSeconds: Double
        let timestampSeconds: Double
        let containsVideo: Bool
        let kind: StreamKind
        let payload: Data
    }

    struct PreparedSegment: Sendable {
        fileprivate let packets: [ScheduledPacket]
        let duration: Double
        let endProgressSeconds: Double
        fileprivate let videoSequenceHeader: Data?
        fileprivate let audioSequenceHeader: Data?
        var packetCount: Int { packets.count }
        var firstScheduledSeconds: Double { packets.first?.scheduledSeconds ?? 0 }
        var lastScheduledSeconds: Double { packets.last?.scheduledSeconds ?? 0 }
        var scheduleSpanSeconds: Double {
            max(0, lastScheduledSeconds - firstScheduledSeconds)
        }
        var maxInterPacketGapSeconds: Double {
            guard packets.count >= 2 else { return 0 }
            var maxGap = 0.0
            for index in 1..<packets.count {
                maxGap = max(maxGap, packets[index].scheduledSeconds - packets[index - 1].scheduledSeconds)
            }
            return maxGap
        }
    }

    struct SendMetrics: Sendable {
        var payloadBytes: Int = 0
        var chunkCount: Int = 0
        var buildSeconds: Double = 0
        var enqueueSeconds: Double = 0
        var sendCallSeconds: Double = 0
        var bucketSleepSeconds: Double = 0
        var endSleepSeconds: Double = 0
        var videoTimestampDeltaMilliseconds: UInt64 = 0
        var audioTimestampDeltaMilliseconds: UInt64 = 0
        var videoPacketCount: Int = 0
        var audioPacketCount: Int = 0

        mutating func add(_ metrics: RTMPStream.RawSendMetrics) {
            payloadBytes += metrics.payloadBytes
            chunkCount += metrics.chunkCount
            buildSeconds += metrics.buildSeconds
            enqueueSeconds += metrics.enqueueSeconds
        }

        fileprivate mutating func addDelta(kind: StreamKind, milliseconds: UInt32) {
            switch kind {
            case .video:
                videoTimestampDeltaMilliseconds += UInt64(milliseconds)
                videoPacketCount += 1
            case .audio:
                audioTimestampDeltaMilliseconds += UInt64(milliseconds)
                audioPacketCount += 1
            }
        }
    }

    struct TransportMetrics: Sendable {
        let queueBytesOut: Int
        let totalBytesIn: Int
        let totalBytesOut: Int
    }

    private struct RTMPPublishTarget {
        let command: String
        let streamName: String

        init(_ rawValue: String) throws {
            guard let url = URL(string: rawValue),
                  let scheme = url.scheme,
                  let host = url.host,
                  scheme.lowercased().hasPrefix("rtmp") else {
                throw PublisherError.invalidTarget(rawValue)
            }

            var components = url.pathComponents
            if components.first == "/" {
                components.removeFirst()
            }
            guard components.count >= 1 else {
                throw PublisherError.invalidTarget(rawValue)
            }

            let streamPath = components.dropFirst()
            let streamNameBase = streamPath.joined(separator: "/")
            if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query,
               !query.isEmpty {
                streamName = streamNameBase.isEmpty ? "" : streamNameBase + "?" + query
            } else {
                streamName = streamNameBase
            }

            var commandURL = "\(scheme)://\(host)"
            if let port = url.port {
                commandURL += ":\(port)"
            }
            commandURL += "/\(components[0])"
            command = commandURL
        }
    }

    private struct TimestampDeltaState {
        var lastSeconds: Double?
        var fractionMilliseconds: Double = 0

        mutating func nextDelta(for seconds: Double) -> UInt32 {
            guard let lastSeconds else {
                self.lastSeconds = seconds
                return 0
            }
            let clampedSeconds = max(seconds, lastSeconds)
            var deltaMilliseconds = (clampedSeconds - lastSeconds) * 1000
            fractionMilliseconds += deltaMilliseconds.truncatingRemainder(dividingBy: 1)
            if fractionMilliseconds >= 1 {
                let carry = floor(fractionMilliseconds)
                fractionMilliseconds -= carry
                deltaMilliseconds += carry
            }
            self.lastSeconds = clampedSeconds
            return UInt32(max(0, deltaMilliseconds.rounded(.down)))
        }

        mutating func reset() {
            lastSeconds = nil
            fractionMilliseconds = 0
        }
    }

    private struct ProgramMap {
        var pmtPID: Int?
        var videoPID: Int?
        var audioPID: Int?
    }

    private struct PESPacket {
        let kind: StreamKind
        let pts90k: Int64?
        let dts90k: Int64?
        let payload: [UInt8]
    }

    private struct ADTSFrame {
        let payload: Data
        let sampleRate: Double
        let channelConfig: Int
        let audioObjectType: Int
        let durationSeconds: Double
    }

    enum PublisherError: LocalizedError {
        case invalidTarget(String)
        case invalidTransportStream(URL)
        case failedToReadSegment(URL)
        case missingProgramMap(URL)
        case noPackets(URL)

        var errorDescription: String? {
            switch self {
            case .invalidTarget(let rawValue):
                return "Invalid RTMP target: \(rawValue)"
            case .invalidTransportStream(let url):
                return "Invalid TS segment \(url.lastPathComponent)"
            case .failedToReadSegment(let url):
                return "Failed to read segment \(url.lastPathComponent)"
            case .missingProgramMap(let url):
                return "Missing TS program map in \(url.lastPathComponent)"
            case .noPackets(let url):
                return "No playable TS packets found in \(url.lastPathComponent)"
            }
        }
    }

    private let target: RTMPPublishTarget
    private let connection = RTMPConnection()
    private let stream: RTMPStream
    private var publishOriginDate: Date?
    private var isConnected = false
    private var sentVideoSequenceHeader = false
    private var sentAudioSequenceHeader = false
    private var videoTimestampState = TimestampDeltaState()
    private var audioTimestampState = TimestampDeltaState()

    nonisolated static func outputTargetValidationMessage(for rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Experimental Direct RTMP requires an RTMP output target." }
        do {
            _ = try RTMPPublishTarget(trimmed)
            return nil
        } catch PublisherError.invalidTarget {
            return "Experimental Direct RTMP requires an RTMP URL with a host and application path, for example rtmp://server/app or rtmp://server/app/stream."
        } catch {
            return error.localizedDescription
        }
    }

    init(outputTarget: String) throws {
        self.target = try RTMPPublishTarget(outputTarget)
        self.stream = RTMPStream(connection: connection)
    }

    func connectAndPublish() async throws {
        guard !isConnected else { return }
        _ = try await connection.connect(target.command)
        _ = try await stream.publish(target.streamName)
        publishOriginDate = nil
        sentVideoSequenceHeader = false
        sentAudioSequenceHeader = false
        videoTimestampState.reset()
        audioTimestampState.reset()
        isConnected = true
    }

    func close() async {
        guard isConnected else { return }
        try? await connection.close()
        isConnected = false
        publishOriginDate = nil
        sentVideoSequenceHeader = false
        sentAudioSequenceHeader = false
        videoTimestampState.reset()
        audioTimestampState.reset()
    }

    func currentTransportMetrics() async -> TransportMetrics? {
        guard let metrics = await connection.currentTransportMetrics() else {
            return nil
        }
        return TransportMetrics(
            queueBytesOut: metrics.queueBytesOut,
            totalBytesIn: metrics.totalBytesIn,
            totalBytesOut: metrics.totalBytesOut
        )
    }

    func advancePlayoutSchedule(by seconds: Double) {
        guard seconds > 0 else { return }
        if let publishOriginDate {
            self.publishOriginDate = publishOriginDate.addingTimeInterval(-seconds)
        }
    }

    func prepareSegment(
        _ segment: QueuedSegment,
        scheduledMediaStartSeconds: Double
    ) async throws -> PreparedSegment {
        try await connectAndPublish()
        return try await Self.prepareSegmentOffline(
            segment,
            scheduledMediaStartSeconds: scheduledMediaStartSeconds
        )
    }

    nonisolated static func prepareSegmentOffline(
        _ segment: QueuedSegment,
        scheduledMediaStartSeconds: Double
    ) async throws -> PreparedSegment {
        let fileURL = segment.fileURL
        let fallbackDuration = max(segment.duration, 0.1)
        return try await Task.detached(priority: .userInitiated) {
            try Self.parseSegment(
                at: fileURL,
                scheduledMediaStartSeconds: scheduledMediaStartSeconds,
                fallbackDuration: fallbackDuration
            )
        }.value
    }

    func publishSegment(
        _ segment: QueuedSegment,
        scheduledMediaStartSeconds: Double,
        onProgress: @escaping @MainActor (SegmentPublisherProgress) -> Void
    ) async throws -> Double {
        let prepared = try await prepareSegment(
            segment,
            scheduledMediaStartSeconds: scheduledMediaStartSeconds
        )
        let result = try await publishPreparedSegment(prepared, onProgress: onProgress)
        return result.duration
    }

    func publishPreparedSegment(
        _ prepared: PreparedSegment,
        onProgress: (@MainActor (SegmentPublisherProgress) -> Void)?
    ) async throws -> (duration: Double, sendMetrics: SendMetrics) {
        try await connectAndPublish()
        let originDate: Date
        if let publishOriginDate {
            originDate = publishOriginDate
        } else {
            let firstScheduledSeconds = prepared.packets.first?.scheduledSeconds ?? 0
            let newOrigin = Date().addingTimeInterval(FeatureFlags.playoutLeadSeconds - firstScheduledSeconds)
            publishOriginDate = newOrigin
            originDate = newOrigin
        }

        if !FeatureFlags.disableVideo, !sentVideoSequenceHeader, let videoSequenceHeader = prepared.videoSequenceHeader {
            await stream.sendRawVideoPayload(videoSequenceHeader, timestamp: 0, isSequenceHeader: true)
            sentVideoSequenceHeader = true
        }
        if !FeatureFlags.disableAudio, !sentAudioSequenceHeader, let audioSequenceHeader = prepared.audioSequenceHeader {
            await stream.sendRawAudioPayload(audioSequenceHeader, timestamp: 0, isSequenceHeader: true)
            sentAudioSequenceHeader = true
        }

        let bucketDurationSeconds = FeatureFlags.bucketDurationSeconds
        var bucketStartIndex = 0
        var sendMetrics = SendMetrics()
        while bucketStartIndex < prepared.packets.count {
            let currentBucketStartSeconds = prepared.packets[bucketStartIndex].scheduledSeconds
            var bucketEndIndex = bucketStartIndex + 1
            while bucketEndIndex < prepared.packets.count,
                  prepared.packets[bucketEndIndex].scheduledSeconds - currentBucketStartSeconds < bucketDurationSeconds {
                bucketEndIndex += 1
            }

            let dueDate = originDate.addingTimeInterval(currentBucketStartSeconds)
            let delay = dueDate.timeIntervalSinceNow
            if delay > 0 {
                sendMetrics.bucketSleepSeconds += delay
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            var bucketPackets: [RTMPStream.RawPayloadPacket] = []
            bucketPackets.reserveCapacity(bucketEndIndex - bucketStartIndex)
            for packetIndex in bucketStartIndex..<bucketEndIndex {
                try Task.checkCancellation()
                let packet = prepared.packets[packetIndex]
                let preparedPacket = makeRawPayloadPacket(packet)
                bucketPackets.append(preparedPacket.packet)
                sendMetrics.addDelta(kind: packet.kind, milliseconds: preparedPacket.timestampDelta)
            }
            let sendStartedAt = Date()
            let bucketMetrics = await stream.sendRawPayloadsMeasured(bucketPackets)
            sendMetrics.sendCallSeconds += Date().timeIntervalSince(sendStartedAt)
            sendMetrics.add(bucketMetrics)
            bucketStartIndex = bucketEndIndex
        }

        let segmentEndDueDate = originDate.addingTimeInterval(prepared.endProgressSeconds)
        let segmentEndDelay = segmentEndDueDate.timeIntervalSinceNow
        if segmentEndDelay > 0 {
            sendMetrics.endSleepSeconds += segmentEndDelay
            try await Task.sleep(nanoseconds: UInt64(segmentEndDelay * 1_000_000_000))
        }

        if let onProgress {
            let finalWallElapsed = max(Date().timeIntervalSince(originDate), 0.001)
            let finalSpeed = prepared.endProgressSeconds / finalWallElapsed
            await onProgress(
                SegmentPublisherProgress(
                    mediaSeconds: prepared.endProgressSeconds,
                    speed: finalSpeed,
                    containsVideo: prepared.packets.contains(where: \.containsVideo)
                )
            )
        }

        return (prepared.duration, sendMetrics)
    }

    func publishPreparedSegment(
        _ prepared: PreparedSegment,
        onProgress: @escaping @MainActor (SegmentPublisherProgress) -> Void
    ) async throws -> (duration: Double, sendMetrics: SendMetrics) {
        try await publishPreparedSegment(prepared, onProgress: Optional(onProgress))
    }

    func publishPreparedSegment(
        _ prepared: PreparedSegment
    ) async throws -> (duration: Double, sendMetrics: SendMetrics) {
        try await publishPreparedSegment(prepared, onProgress: nil)
    }

    private func makeRawPayloadPacket(_ packet: ScheduledPacket) -> (packet: RTMPStream.RawPayloadPacket, timestampDelta: UInt32) {
        switch packet.kind {
        case .video:
            let delta = videoTimestampState.nextDelta(for: packet.timestampSeconds)
            return (.init(kind: .video, payload: packet.payload, timestamp: delta), delta)
        case .audio:
            let delta = audioTimestampState.nextDelta(for: packet.timestampSeconds)
            return (.init(kind: .audio, payload: packet.payload, timestamp: delta), delta)
        }
    }

    private func sendPacket(_ packet: ScheduledPacket) async -> RTMPStream.RawSendMetrics {
        switch packet.kind {
        case .video:
            guard !FeatureFlags.disableVideo else { return .init(payloadBytes: 0, chunkCount: 0, buildSeconds: 0, enqueueSeconds: 0) }
            let delta = videoTimestampState.nextDelta(for: packet.timestampSeconds)
            return await stream.sendRawVideoPayloadMeasured(packet.payload, timestamp: delta)
        case .audio:
            guard !FeatureFlags.disableAudio else { return .init(payloadBytes: 0, chunkCount: 0, buildSeconds: 0, enqueueSeconds: 0) }
            let delta = audioTimestampState.nextDelta(for: packet.timestampSeconds)
            return await stream.sendRawAudioPayloadMeasured(packet.payload, timestamp: delta)
        }
    }

    nonisolated private static func parseSegment(
        at fileURL: URL,
        scheduledMediaStartSeconds: Double,
        fallbackDuration: Double
    ) throws -> PreparedSegment {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw PublisherError.failedToReadSegment(fileURL)
        }
        guard data.count >= 188, data.count % 188 == 0 else {
            throw PublisherError.invalidTransportStream(fileURL)
        }

        let bytes = Array(data)
        var program = ProgramMap()
        var pesBuffers: [Int: [UInt8]] = [:]
        var pesPackets: [PESPacket] = []

        func finalizePES(for pid: Int) {
            guard let buffer = pesBuffers[pid], !buffer.isEmpty else { return }
            let kind: StreamKind
            if pid == program.videoPID {
                kind = .video
            } else if pid == program.audioPID {
                kind = .audio
            } else {
                pesBuffers[pid] = nil
                return
            }
            if let packet = parsePES(buffer, kind: kind) {
                pesPackets.append(packet)
            }
            pesBuffers[pid] = nil
        }

        for offset in stride(from: 0, to: bytes.count, by: 188) {
            guard bytes[offset] == 0x47 else {
                throw PublisherError.invalidTransportStream(fileURL)
            }

            let payloadUnitStart = (bytes[offset + 1] & 0x40) != 0
            let pid = (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
            let adaptationFieldControl = (bytes[offset + 3] >> 4) & 0x03

            var index = offset + 4
            if adaptationFieldControl == 0 || adaptationFieldControl == 2 {
                continue
            }
            if adaptationFieldControl == 3 {
                let adaptationLength = Int(bytes[index])
                index += 1 + adaptationLength
                if index >= offset + 188 {
                    continue
                }
            }

            if pid == 0 {
                if payloadUnitStart {
                    let pointerField = Int(bytes[index])
                    index += 1 + pointerField
                }
                if index + 8 < offset + 188, let pmtPID = parsePAT(bytes[index..<(offset + 188)]) {
                    program.pmtPID = pmtPID
                }
                continue
            }

            if let pmtPID = program.pmtPID, pid == pmtPID {
                if payloadUnitStart {
                    let pointerField = Int(bytes[index])
                    index += 1 + pointerField
                }
                if index + 12 < offset + 188 {
                    let parsed = parsePMT(bytes[index..<(offset + 188)])
                    if program.videoPID == nil { program.videoPID = parsed.videoPID }
                    if program.audioPID == nil { program.audioPID = parsed.audioPID }
                }
                continue
            }

            if pid == program.videoPID || pid == program.audioPID {
                if payloadUnitStart {
                    finalizePES(for: pid)
                    pesBuffers[pid] = []
                }
                guard index < offset + 188 else { continue }
                pesBuffers[pid, default: []].append(contentsOf: bytes[index..<(offset + 188)])
            }
        }

        if let videoPID = program.videoPID { finalizePES(for: videoPID) }
        if let audioPID = program.audioPID { finalizePES(for: audioPID) }

        guard program.videoPID != nil || program.audioPID != nil else {
            throw PublisherError.missingProgramMap(fileURL)
        }
        guard !pesPackets.isEmpty else {
            throw PublisherError.noPackets(fileURL)
        }

        let baseTimestamp90k = pesPackets.compactMap { packet -> Int64? in
            switch packet.kind {
            case .video:
                return packet.dts90k ?? packet.pts90k
            case .audio:
                return packet.pts90k
            }
        }.min() ?? 0

        var packets: [ScheduledPacket] = []
        var videoSequenceHeader: Data?
        var audioSequenceHeader: Data?
        var latestSPS: Data?
        var latestPPS: Data?
        var maxEndSeconds = fallbackDuration

        for pes in pesPackets {
            switch pes.kind {
            case .video:
                let nalUnits = extractAnnexBNALUnits(from: pes.payload)
                guard !nalUnits.isEmpty else { continue }
                for nalu in nalUnits {
                    let nalType = Int(nalu.first.map { $0 & 0x1F } ?? 0)
                    if nalType == 7 { latestSPS = nalu }
                    if nalType == 8 { latestPPS = nalu }
                }
                if videoSequenceHeader == nil,
                   let sps = latestSPS,
                   let pps = latestPPS {
                    videoSequenceHeader = makeVideoSequenceHeader(sps: sps, pps: pps)
                }

                let sampleNALUs = nalUnits.filter { nalu in
                    guard let first = nalu.first else { return false }
                    let nalType = Int(first & 0x1F)
                    return nalType != 9
                }
                guard !sampleNALUs.isEmpty else { continue }

                let dts90k = pes.dts90k ?? pes.pts90k ?? baseTimestamp90k
                let pts90k = pes.pts90k ?? dts90k
                let timestampSeconds = scheduledMediaStartSeconds + max(0, Double(dts90k - baseTimestamp90k) / 90_000.0)
                let progressSeconds = scheduledMediaStartSeconds + max(0, Double(max(pts90k, dts90k) - baseTimestamp90k) / 90_000.0)
                let compositionTimeMilliseconds = Int32(((pts90k - dts90k) * 1000) / 90_000)
                let isKeyframe = sampleNALUs.contains { (Int($0.first ?? 0) & 0x1F) == 5 }
                let payload = makeVideoPayload(
                    nalUnits: sampleNALUs,
                    keyframe: isKeyframe,
                    compositionTimeMilliseconds: compositionTimeMilliseconds
                )
                packets.append(
                    ScheduledPacket(
                        scheduledSeconds: timestampSeconds,
                        progressSeconds: progressSeconds,
                        timestampSeconds: timestampSeconds,
                        containsVideo: true,
                        kind: .video,
                        payload: payload
                    )
                )
                maxEndSeconds = max(maxEndSeconds, progressSeconds - scheduledMediaStartSeconds)

            case .audio:
                guard let pts90k = pes.pts90k else { continue }
                let adtsFrames = extractADTSFrames(from: pes.payload)
                guard !adtsFrames.isEmpty else { continue }
                if audioSequenceHeader == nil {
                    audioSequenceHeader = makeAudioSequenceHeader(from: adtsFrames[0])
                }

                var frameTimestampSeconds = scheduledMediaStartSeconds + max(0, Double(pts90k - baseTimestamp90k) / 90_000.0)
                for frame in adtsFrames {
                    let payload = makeAudioPayload(frame.payload)
                    let progressSeconds = frameTimestampSeconds + frame.durationSeconds
                    packets.append(
                        ScheduledPacket(
                            scheduledSeconds: frameTimestampSeconds,
                            progressSeconds: progressSeconds,
                            timestampSeconds: frameTimestampSeconds,
                            containsVideo: false,
                            kind: .audio,
                            payload: payload
                        )
                    )
                    maxEndSeconds = max(maxEndSeconds, progressSeconds - scheduledMediaStartSeconds)
                    frameTimestampSeconds += frame.durationSeconds
                }
            }
        }

        packets.sort { lhs, rhs in
            if abs(lhs.scheduledSeconds - rhs.scheduledSeconds) > 0.0001 {
                return lhs.scheduledSeconds < rhs.scheduledSeconds
            }
            return lhs.containsVideo && !rhs.containsVideo
        }

        guard !packets.isEmpty else {
            throw PublisherError.noPackets(fileURL)
        }

        return PreparedSegment(
            packets: packets,
            duration: max(maxEndSeconds, fallbackDuration),
            endProgressSeconds: packets.map(\.progressSeconds).max() ?? (scheduledMediaStartSeconds + max(maxEndSeconds, fallbackDuration)),
            videoSequenceHeader: videoSequenceHeader,
            audioSequenceHeader: audioSequenceHeader
        )
    }

    nonisolated private static func parsePAT(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard bytes.count >= 12 else { return nil }
        let tableID = bytes[bytes.startIndex]
        guard tableID == 0x00 else { return nil }
        let sectionLength = (Int(bytes[bytes.startIndex + 1] & 0x0F) << 8) | Int(bytes[bytes.startIndex + 2])
        let sectionEnd = bytes.startIndex + 3 + sectionLength - 4
        var index = bytes.startIndex + 8
        while index + 3 < sectionEnd {
            let programNumber = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
            let pid = (Int(bytes[index + 2] & 0x1F) << 8) | Int(bytes[index + 3])
            if programNumber != 0 {
                return pid
            }
            index += 4
        }
        return nil
    }

    nonisolated private static func parsePMT(_ bytes: ArraySlice<UInt8>) -> ProgramMap {
        var map = ProgramMap()
        guard bytes.count >= 16 else { return map }
        let tableID = bytes[bytes.startIndex]
        guard tableID == 0x02 else { return map }
        let sectionLength = (Int(bytes[bytes.startIndex + 1] & 0x0F) << 8) | Int(bytes[bytes.startIndex + 2])
        let programInfoLength = (Int(bytes[bytes.startIndex + 10] & 0x0F) << 8) | Int(bytes[bytes.startIndex + 11])
        let sectionEnd = bytes.startIndex + 3 + sectionLength - 4
        var index = bytes.startIndex + 12 + programInfoLength
        while index + 4 < sectionEnd {
            let streamType = bytes[index]
            let elementaryPID = (Int(bytes[index + 1] & 0x1F) << 8) | Int(bytes[index + 2])
            let esInfoLength = (Int(bytes[index + 3] & 0x0F) << 8) | Int(bytes[index + 4])
            if map.videoPID == nil, streamType == 0x1B {
                map.videoPID = elementaryPID
            } else if map.audioPID == nil, streamType == 0x0F {
                map.audioPID = elementaryPID
            }
            index += 5 + esInfoLength
        }
        return map
    }

    nonisolated private static func parsePES(_ bytes: [UInt8], kind: StreamKind) -> PESPacket? {
        guard bytes.count >= 9,
              bytes[0] == 0x00,
              bytes[1] == 0x00,
              bytes[2] == 0x01 else {
            return nil
        }
        let flags = bytes[7]
        let headerLength = Int(bytes[8])
        let payloadStart = 9 + headerLength
        guard payloadStart <= bytes.count else { return nil }

        let ptsDtsFlags = (flags >> 6) & 0x03
        var pts90k: Int64?
        var dts90k: Int64?
        if ptsDtsFlags == 0x02 || ptsDtsFlags == 0x03 {
            guard bytes.count >= 14 else { return nil }
            pts90k = parsePESClock(bytes[9...13])
        }
        if ptsDtsFlags == 0x03 {
            guard bytes.count >= 19 else { return nil }
            dts90k = parsePESClock(bytes[14...18])
        }

        return PESPacket(
            kind: kind,
            pts90k: pts90k,
            dts90k: dts90k,
            payload: Array(bytes[payloadStart...])
        )
    }

    nonisolated private static func parsePESClock(_ bytes: ArraySlice<UInt8>) -> Int64 {
        let array = Array(bytes)
        guard array.count == 5 else { return 0 }
        let a = Int64((array[0] >> 1) & 0x07)
        let b = Int64(array[1])
        let c = Int64((array[2] >> 1) & 0x7F)
        let d = Int64(array[3])
        let e = Int64((array[4] >> 1) & 0x7F)
        return (a << 30) | (b << 22) | (c << 15) | (d << 7) | e
    }

    nonisolated private static func extractAnnexBNALUnits(from payload: [UInt8]) -> [Data] {
        guard !payload.isEmpty else { return [] }
        var units: [Data] = []
        let count = payload.count
        var index = 0

        func startCodeLength(at offset: Int) -> Int {
            guard offset + 3 < count else { return 0 }
            if payload[offset] == 0, payload[offset + 1] == 0, payload[offset + 2] == 1 {
                return 3
            }
            if offset + 4 < count,
               payload[offset] == 0,
               payload[offset + 1] == 0,
               payload[offset + 2] == 0,
               payload[offset + 3] == 1 {
                return 4
            }
            return 0
        }

        while index < count {
            let codeLength = startCodeLength(at: index)
            guard codeLength > 0 else {
                index += 1
                continue
            }
            let naluStart = index + codeLength
            var next = naluStart
            while next < count {
                if startCodeLength(at: next) > 0 {
                    break
                }
                next += 1
            }
            if naluStart < next {
                units.append(Data(payload[naluStart..<next]))
            }
            index = next
        }
        return units
    }

    nonisolated private static func extractADTSFrames(from payload: [UInt8]) -> [ADTSFrame] {
        guard !payload.isEmpty else { return [] }
        var frames: [ADTSFrame] = []
        var index = 0
        while index + 7 <= payload.count {
            guard payload[index] == 0xFF, (payload[index + 1] & 0xF0) == 0xF0 else {
                index += 1
                continue
            }
            let protectionAbsent = Int(payload[index + 1] & 0x01)
            let profile = Int((payload[index + 2] & 0xC0) >> 6)
            let sampleRateIndex = Int((payload[index + 2] & 0x3C) >> 2)
            let channelConfig = Int((payload[index + 2] & 0x01) << 2) | Int((payload[index + 3] & 0xC0) >> 6)
            let frameLength = (Int(payload[index + 3] & 0x03) << 11) | (Int(payload[index + 4]) << 3) | Int((payload[index + 5] & 0xE0) >> 5)
            let headerLength = protectionAbsent == 1 ? 7 : 9
            guard frameLength > headerLength, index + frameLength <= payload.count else {
                break
            }
            let sampleRates: [Double] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
            guard sampleRateIndex < sampleRates.count else {
                break
            }
            let sampleRate = sampleRates[sampleRateIndex]
            let audioObjectType = profile + 1
            let framePayload = Data(payload[(index + headerLength)..<(index + frameLength)])
            frames.append(
                ADTSFrame(
                    payload: framePayload,
                    sampleRate: sampleRate,
                    channelConfig: channelConfig,
                    audioObjectType: audioObjectType,
                    durationSeconds: 1024.0 / sampleRate
                )
            )
            index += frameLength
        }
        return frames
    }

    nonisolated private static func makeVideoSequenceHeader(sps: Data, pps: Data) -> Data {
        var config = Data()
        config.append(0x01)
        config.append(sps.count > 1 ? sps[1] : 0x42)
        config.append(sps.count > 2 ? sps[2] : 0xC0)
        config.append(sps.count > 3 ? sps[3] : 0x1F)
        config.append(0xFF)
        config.append(0xE1)
        config.append(contentsOf: UInt16(sps.count).bigEndianBytes)
        config.append(sps)
        config.append(0x01)
        config.append(contentsOf: UInt16(pps.count).bigEndianBytes)
        config.append(pps)

        var payload = Data([0x17, 0x00, 0x00, 0x00, 0x00])
        payload.append(config)
        return payload
    }

    nonisolated private static func makeVideoPayload(
        nalUnits: [Data],
        keyframe: Bool,
        compositionTimeMilliseconds: Int32
    ) -> Data {
        var payload = Data([keyframe ? 0x17 : 0x27, 0x01])
        let composition = UInt32(bitPattern: compositionTimeMilliseconds) & 0x00FF_FFFF
        payload.append(UInt8((composition >> 16) & 0xFF))
        payload.append(UInt8((composition >> 8) & 0xFF))
        payload.append(UInt8(composition & 0xFF))
        for nalu in nalUnits {
            payload.append(contentsOf: UInt32(nalu.count).bigEndianBytes)
            payload.append(nalu)
        }
        return payload
    }

    nonisolated private static func makeAudioSequenceHeader(from frame: ADTSFrame) -> Data {
        let audioSpecificConfig = UInt16((frame.audioObjectType & 0x1F) << 11 | sampleRateIndex(for: frame.sampleRate) << 7 | (frame.channelConfig & 0x0F) << 3)
        var payload = Data([0xAF, 0x00])
        payload.append(contentsOf: audioSpecificConfig.bigEndianBytes)
        return payload
    }

    nonisolated private static func sampleRateIndex(for sampleRate: Double) -> Int {
        let sampleRates: [Double] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        return sampleRates.firstIndex(of: sampleRate) ?? 3
    }

    nonisolated private static func makeAudioPayload(_ framePayload: Data) -> Data {
        var payload = Data([0xAF, 0x01])
        payload.append(framePayload)
        return payload
    }
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] {
        let value = self
        return [
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let value = self
        return [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}
