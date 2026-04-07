import Foundation
@preconcurrency import AVFoundation
import HaishinKit
import RTMPHaishinKit

struct SegmentPublisherProgress {
    let mediaSeconds: Double
    let speed: Double
    let containsVideo: Bool
}

@MainActor
final class HaishinRTMPPublisher {
    private enum FeatureFlags {
        static let disableAudio = ProcessInfo.processInfo.environment["BACKCHANNEL_HAISHIN_DISABLE_AUDIO"] == "1"
        static let disableVideo = ProcessInfo.processInfo.environment["BACKCHANNEL_HAISHIN_DISABLE_VIDEO"] == "1"
    }

    enum ScheduledPayload {
        case video(CMSampleBuffer)
        case audio(AVAudioBuffer, AVAudioTime)
    }

    struct ScheduledSample {
        let scheduledSeconds: Double
        let progressSeconds: Double
        let containsVideo: Bool
        let payload: ScheduledPayload
    }

    private struct SegmentReadResult {
        let samples: [ScheduledSample]
        let duration: Double
    }

    struct PreparedSegment {
        let samples: [ScheduledSample]
        let duration: Double
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

    enum PublisherError: LocalizedError {
        case invalidTarget(String)
        case failedToReadSegment(URL)
        case failedToCreateReader(URL)
        case failedToCreatePCMBuffer
        case failedToRetimeVideo
        case noSamples(URL)
        case unsupportedAudioFormat

        var errorDescription: String? {
            switch self {
            case .invalidTarget(let rawValue):
                return "Invalid RTMP target: \(rawValue)"
            case .failedToReadSegment(let url):
                return "Failed to read segment \(url.lastPathComponent)"
            case .failedToCreateReader(let url):
                return "Failed to create asset reader for \(url.lastPathComponent)"
            case .failedToCreatePCMBuffer:
                return "Failed to create PCM audio buffer"
            case .failedToRetimeVideo:
                return "Failed to retime video sample buffer"
            case .noSamples(let url):
                return "No playable samples found in \(url.lastPathComponent)"
            case .unsupportedAudioFormat:
                return "Unsupported audio sample format"
            }
        }
    }

    private let target: RTMPPublishTarget
    private let connection = RTMPConnection()
    private let stream: RTMPStream
    private var publishOriginDate: Date?
    private var publishOriginHostTime: UInt64?
    private var isConnected = false

    init(outputTarget: String) throws {
        self.target = try RTMPPublishTarget(outputTarget)
        self.stream = RTMPStream(connection: connection)
    }

    func connectAndPublish() async throws {
        guard !isConnected else { return }
        _ = try await connection.connect(target.command)
        _ = try await stream.publish(target.streamName)
        publishOriginDate = nil
        publishOriginHostTime = nil
        isConnected = true
    }

    func close() async {
        guard isConnected else { return }
        try? await connection.close()
        isConnected = false
        publishOriginDate = nil
        publishOriginHostTime = nil
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
        return try await publishPreparedSegment(prepared, onProgress: onProgress)
    }

    func prepareSegment(
        _ segment: QueuedSegment,
        scheduledMediaStartSeconds: Double
    ) async throws -> PreparedSegment {
        try await connectAndPublish()
        let originDate: Date
        if let publishOriginDate {
            originDate = publishOriginDate
        } else {
            let newOrigin = Date().addingTimeInterval(-scheduledMediaStartSeconds)
            publishOriginDate = newOrigin
            originDate = newOrigin
        }
        let originHostTime: UInt64
        if let publishOriginHostTime {
            originHostTime = publishOriginHostTime
        } else {
            let newOriginHostTime = mach_absolute_time() &- AVAudioTime.hostTime(forSeconds: scheduledMediaStartSeconds)
            publishOriginHostTime = newOriginHostTime
            originHostTime = newOriginHostTime
        }
        _ = originDate
        let fileURL = segment.fileURL
        let fallbackDuration = max(segment.duration, 0.1)
        let segmentResult = try await Task.detached(priority: .userInitiated) {
            try Self.readSegment(
                from: fileURL,
                scheduledMediaStartSeconds: scheduledMediaStartSeconds,
                fallbackDuration: fallbackDuration,
                hostTimeOrigin: originHostTime
            )
        }.value
        return PreparedSegment(samples: segmentResult.samples, duration: segmentResult.duration)
    }

    func publishPreparedSegment(
        _ prepared: PreparedSegment,
        onProgress: @escaping @MainActor (SegmentPublisherProgress) -> Void
    ) async throws -> Double {
        try await connectAndPublish()
        let originDate: Date
        if let publishOriginDate {
            originDate = publishOriginDate
        } else {
            let firstScheduledSeconds = prepared.samples.first?.scheduledSeconds ?? 0
            let newOrigin = Date().addingTimeInterval(-firstScheduledSeconds)
            publishOriginDate = newOrigin
            originDate = newOrigin
        }

        for sample in prepared.samples {
            try Task.checkCancellation()
            let dueDate = originDate.addingTimeInterval(sample.scheduledSeconds)
            let delay = dueDate.timeIntervalSinceNow
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            switch sample.payload {
            case .video(let sampleBuffer):
                guard !FeatureFlags.disableVideo else { continue }
                await stream.append(sampleBuffer)
            case .audio(let audioBuffer, let when):
                guard !FeatureFlags.disableAudio else { continue }
                await stream.append(audioBuffer, when: when)
            }

            let wallElapsed = max(Date().timeIntervalSince(originDate), 0.001)
            let speed = sample.progressSeconds / wallElapsed
            onProgress(
                SegmentPublisherProgress(
                    mediaSeconds: sample.progressSeconds,
                    speed: speed,
                    containsVideo: sample.containsVideo
                )
            )
        }

        return prepared.duration
    }

    nonisolated private static func readSegment(
        from fileURL: URL,
        scheduledMediaStartSeconds: Double,
        fallbackDuration: Double,
        hostTimeOrigin: UInt64
    ) throws -> SegmentReadResult {
        let asset = AVURLAsset(url: fileURL)
        let reader = try AVAssetReader(asset: asset)

        let videoTrack = asset.tracks(withMediaType: .video).first
        let audioTrack = asset.tracks(withMediaType: .audio).first

        let videoOutput: AVAssetReaderTrackOutput?
        if let videoTrack {
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw PublisherError.failedToCreateReader(fileURL)
            }
            reader.add(output)
            videoOutput = output
        } else {
            videoOutput = nil
        }

        let audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw PublisherError.failedToCreateReader(fileURL)
            }
            reader.add(output)
            audioOutput = output
        } else {
            audioOutput = nil
        }

        guard reader.startReading() else {
            throw reader.error ?? PublisherError.failedToReadSegment(fileURL)
        }

        var nextVideo = videoOutput?.copyNextSampleBuffer()
        var nextAudio = audioOutput?.copyNextSampleBuffer()
        var segmentBaseTime: CMTime?
        var scheduledSamples: [ScheduledSample] = []
        var maxEndSeconds = 0.0

        while nextVideo != nil || nextAudio != nil {
            while let sampleBuffer = nextVideo, !isUsableVideoSample(sampleBuffer) {
                nextVideo = videoOutput?.copyNextSampleBuffer()
            }
            while let sampleBuffer = nextAudio, !isUsableAudioSample(sampleBuffer) {
                nextAudio = audioOutput?.copyNextSampleBuffer()
            }

            guard nextVideo != nil || nextAudio != nil else {
                break
            }

            let chooseVideo: Bool
            if let videoSample = nextVideo, let audioSample = nextAudio {
                chooseVideo = CMTimeCompare(
                    deliveryTime(for: videoSample),
                    deliveryTime(for: audioSample)
                ) <= 0
            } else {
                chooseVideo = nextVideo != nil
            }

            if chooseVideo, let sampleBuffer = nextVideo {
                let timingBase = segmentBaseTime ?? deliveryTime(for: sampleBuffer)
                segmentBaseTime = timingBase

                let durationSeconds = positiveSeconds(sampleBuffer.duration)
                let deliverySeconds = max(
                    0,
                    positiveSeconds(CMTimeSubtract(deliveryTime(for: sampleBuffer), timingBase))
                )
                let progressSeconds = scheduledMediaStartSeconds + deliverySeconds + durationSeconds
                let retimedSample = try retimedVideoSampleBuffer(
                    sampleBuffer,
                    baseTime: timingBase,
                    scheduledMediaStartSeconds: scheduledMediaStartSeconds
                )
                scheduledSamples.append(
                    ScheduledSample(
                        scheduledSeconds: scheduledMediaStartSeconds + deliverySeconds,
                        progressSeconds: progressSeconds,
                        containsVideo: true,
                        payload: .video(retimedSample)
                    )
                )
                maxEndSeconds = max(maxEndSeconds, deliverySeconds + durationSeconds)
                nextVideo = videoOutput?.copyNextSampleBuffer()
                continue
            }

            if let sampleBuffer = nextAudio {
                let timingBase = segmentBaseTime ?? deliveryTime(for: sampleBuffer)
                segmentBaseTime = timingBase

                let deliverySeconds = max(
                    0,
                    positiveSeconds(CMTimeSubtract(deliveryTime(for: sampleBuffer), timingBase))
                )
                let audioPayload = try makeAudioPayload(
                    from: sampleBuffer,
                    absoluteMediaSeconds: scheduledMediaStartSeconds + deliverySeconds,
                    hostTimeOrigin: hostTimeOrigin
                )
                let progressSeconds = scheduledMediaStartSeconds + deliverySeconds + audioPayload.durationSeconds
                scheduledSamples.append(
                    ScheduledSample(
                        scheduledSeconds: scheduledMediaStartSeconds + deliverySeconds,
                        progressSeconds: progressSeconds,
                        containsVideo: false,
                        payload: .audio(audioPayload.buffer, audioPayload.time)
                    )
                )
                maxEndSeconds = max(maxEndSeconds, deliverySeconds + audioPayload.durationSeconds)
                nextAudio = audioOutput?.copyNextSampleBuffer()
            }
        }

        if reader.status == .failed {
            throw reader.error ?? PublisherError.failedToReadSegment(fileURL)
        }
        guard !scheduledSamples.isEmpty else {
            throw PublisherError.noSamples(fileURL)
        }

        return SegmentReadResult(
            samples: scheduledSamples,
            duration: max(maxEndSeconds, fallbackDuration)
        )
    }

    private struct AudioPayload {
        let buffer: AVAudioBuffer
        let time: AVAudioTime
        let durationSeconds: Double
    }

    nonisolated private static func deliveryTime(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let decodeTimeStamp = sampleBuffer.decodeTimeStamp
        if decodeTimeStamp.isValid {
            return decodeTimeStamp
        }
        return sampleBuffer.presentationTimeStamp
    }

    nonisolated private static func isUsableVideoSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let formatDescription = sampleBuffer.formatDescription,
              formatDescription.mediaType == .video,
              sampleBuffer.dataBuffer != nil,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            return false
        }
        let presentationTime = sampleBuffer.presentationTimeStamp
        return presentationTime.isValid && presentationTime.seconds.isFinite
    }

    nonisolated private static func isUsableAudioSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let formatDescription = sampleBuffer.formatDescription,
              formatDescription.mediaType == .audio,
              sampleBuffer.dataBuffer != nil,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            return false
        }
        let presentationTime = sampleBuffer.presentationTimeStamp
        return presentationTime.isValid && presentationTime.seconds.isFinite
    }

    nonisolated private static func positiveSeconds(_ time: CMTime) -> Double {
        guard time.isValid else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        if seconds.isFinite && seconds > 0 {
            return seconds
        }
        return 0
    }

    nonisolated private static func retimedVideoSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        baseTime: CMTime,
        scheduledMediaStartSeconds: Double
    ) throws -> CMSampleBuffer {
        let originalPTS = sampleBuffer.presentationTimeStamp
        let originalDTS = sampleBuffer.decodeTimeStamp

        let relativePTS = max(0, positiveSeconds(CMTimeSubtract(originalPTS, baseTime)))
        let absolutePTS = CMTime(seconds: scheduledMediaStartSeconds + relativePTS, preferredTimescale: 1_000_000)

        let absoluteDTS: CMTime
        if originalDTS.isValid {
            let relativeDTS = max(0, positiveSeconds(CMTimeSubtract(originalDTS, baseTime)))
            absoluteDTS = CMTime(seconds: scheduledMediaStartSeconds + relativeDTS, preferredTimescale: 1_000_000)
        } else {
            absoluteDTS = .invalid
        }

        var timing = CMSampleTimingInfo(
            duration: sampleBuffer.duration,
            presentationTimeStamp: absolutePTS,
            decodeTimeStamp: absoluteDTS
        )
        var retimedSampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimedSampleBuffer
        )
        guard status == noErr, let retimedSampleBuffer else {
            throw PublisherError.failedToRetimeVideo
        }
        return retimedSampleBuffer
    }

    nonisolated private static func makeAudioPayload(
        from sampleBuffer: CMSampleBuffer,
        absoluteMediaSeconds: Double,
        hostTimeOrigin: UInt64
    ) throws -> AudioPayload {
        guard let formatDescription = sampleBuffer.formatDescription,
              let dataBuffer = sampleBuffer.dataBuffer else {
            throw PublisherError.unsupportedAudioFormat
        }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let packetCount = max(1, CMSampleBufferGetNumSamples(sampleBuffer))
        var packetSizes: [Int] = []
        packetSizes.reserveCapacity(packetCount)
        var totalByteCount = 0
        var maximumPacketSize = 0
        for index in 0..<packetCount {
            let sampleSize = CMSampleBufferGetSampleSize(sampleBuffer, at: index)
            packetSizes.append(sampleSize)
            totalByteCount += sampleSize
            maximumPacketSize = max(maximumPacketSize, sampleSize)
        }
        let compressedBuffer = AVAudioCompressedBuffer(
            format: audioFormat,
            packetCapacity: AVAudioPacketCount(packetCount),
            maximumPacketSize: max(1, maximumPacketSize)
        )

        compressedBuffer.packetCount = AVAudioPacketCount(packetCount)
        compressedBuffer.byteLength = UInt32(totalByteCount)
        let status = CMBlockBufferCopyDataBytes(
            dataBuffer,
            atOffset: 0,
            dataLength: totalByteCount,
            destination: compressedBuffer.data
        )
        guard status == noErr else {
            throw PublisherError.failedToCreatePCMBuffer
        }
        if let packetDescriptions = compressedBuffer.packetDescriptions {
            var packetOffset = 0
            for (index, packetSize) in packetSizes.enumerated() {
                packetDescriptions[index] = AudioStreamPacketDescription(
                    mStartOffset: Int64(packetOffset),
                    mVariableFramesInPacket: 0,
                    mDataByteSize: UInt32(packetSize)
                )
                packetOffset += packetSize
            }
        }

        let sampleRate = audioFormat.sampleRate > 0 ? audioFormat.sampleRate : 48_000
        let hostTimeOffset = AVAudioTime.hostTime(forSeconds: max(absoluteMediaSeconds, 0))
        let audioTime = AVAudioTime(hostTime: hostTimeOrigin &+ hostTimeOffset)
        let durationSeconds: Double
        if sampleBuffer.duration.isValid {
            durationSeconds = positiveSeconds(sampleBuffer.duration)
        } else {
            durationSeconds = sampleRate > 0 ? (Double(packetCount) * 1024.0 / sampleRate) : 0
        }

        return AudioPayload(buffer: compressedBuffer, time: audioTime, durationSeconds: durationSeconds)
    }
}
