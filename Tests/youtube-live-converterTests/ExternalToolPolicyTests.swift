import Foundation
import Testing
@testable import youtube_live_converter

struct ExternalToolPolicyTests {
    @Test
    func ytDlpNeverUsesBundledRuntimeFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalToolPolicyTests.\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let fakeYtDlp = bin.appendingPathComponent("yt-dlp", isDirectory: false)

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeYtDlp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeYtDlp.path)

        #expect(FileManager.default.isExecutableFile(atPath: fakeYtDlp.path))
        #expect(ExternalToolKind.ytDlp.allowsBundledRuntimeFallback == false)
        #expect(ExternalSupportPaths.bundledExecutable(for: .ytDlp, resourceURL: root) == nil)
    }

    @Test
    func ffmpegStillUsesBundledRuntimePayload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalToolPolicyTests.\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let fakeFFmpeg = bin.appendingPathComponent("ffmpeg", isDirectory: false)

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeFFmpeg, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFmpeg.path)

        #expect(ExternalToolKind.ffmpeg.allowsBundledRuntimeFallback)
        #expect(ExternalSupportPaths.bundledExecutable(for: .ffmpeg, resourceURL: root) == fakeFFmpeg)
    }
}
