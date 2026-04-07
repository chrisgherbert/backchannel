import Foundation

struct QueuedSegment: Sendable {
    let index: Int
    let duration: Double
    let fileURL: URL
}

enum SegmentQueueSupport {
    static func readQueuedSegments(from playlistURL: URL) -> [QueuedSegment] {
        guard let text = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            return []
        }

        let baseDirectory = playlistURL.deletingLastPathComponent()
        var segments: [QueuedSegment] = []
        var pendingDuration: Double?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXTINF:") {
                let valueText = line
                    .dropFirst("#EXTINF:".count)
                    .split(separator: ",", maxSplits: 1)
                    .first
                    .map(String.init) ?? ""
                pendingDuration = Double(valueText.trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }

            guard !line.hasPrefix("#") else { continue }

            let fileURL: URL
            if line.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: line).standardizedFileURL
            } else {
                fileURL = baseDirectory.appendingPathComponent(line).standardizedFileURL
            }

            segments.append(
                QueuedSegment(
                    index: segments.count,
                    duration: max(0, pendingDuration ?? 0),
                    fileURL: fileURL
                )
            )
            pendingDuration = nil
        }

        return segments
    }

    static func queuedDuration(for segments: ArraySlice<QueuedSegment>) -> Double {
        segments.reduce(0) { partial, segment in
            partial + max(0, segment.duration)
        }
    }

    static func queuedDuration(for segments: [QueuedSegment], startingAt startIndex: Int) -> Double {
        guard startIndex < segments.count else { return 0 }
        return queuedDuration(for: segments.suffix(from: startIndex))
    }

    static func segmentIndex(forElapsed elapsed: Double, in segments: [QueuedSegment], startingAt startIndex: Int) -> Int {
        guard startIndex < segments.count else { return segments.count }
        guard elapsed > 0 else { return startIndex }

        var accumulated = 0.0
        for index in startIndex..<segments.count {
            accumulated += max(0, segments[index].duration)
            if accumulated > elapsed {
                return index
            }
        }
        return segments.count
    }

    static func rewindIndex(
        from index: Int,
        retainSeconds: Double,
        in segments: [QueuedSegment],
        lowerBound: Int
    ) -> Int {
        guard retainSeconds > 0, lowerBound < index, !segments.isEmpty else { return max(lowerBound, min(index, segments.count)) }

        var current = min(index, segments.count)
        var retained = 0.0
        while current > lowerBound && retained < retainSeconds {
            current -= 1
            retained += max(0, segments[current].duration)
        }
        return max(lowerBound, current)
    }

    static func playlistContents(
        for segments: ArraySlice<QueuedSegment>,
        baseDirectory: URL,
        mediaSequence: Int,
        includeDiscontinuityAtStart: Bool,
        includeEndList: Bool
    ) -> String {
        let targetDuration = max(
            1,
            Int(
                ceil(
                    segments.map { max(0, $0.duration) }.max() ?? 1
                )
            )
        )

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)"
        ]

        if includeDiscontinuityAtStart && !segments.isEmpty {
            lines.append("#EXT-X-DISCONTINUITY")
        }

        for segment in segments {
            let duration = max(0, segment.duration)
            lines.append(String(format: "#EXTINF:%.3f,", duration))
            lines.append(relativePath(for: segment.fileURL, baseDirectory: baseDirectory))
        }

        if includeEndList {
            lines.append("#EXT-X-ENDLIST")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func relativePath(for fileURL: URL, baseDirectory: URL) -> String {
        let standardizedBase = baseDirectory.standardizedFileURL.path
        let standardizedFile = fileURL.standardizedFileURL.path
        if standardizedFile.hasPrefix(standardizedBase + "/") {
            return String(standardizedFile.dropFirst(standardizedBase.count + 1))
        }
        return fileURL.lastPathComponent
    }
}
