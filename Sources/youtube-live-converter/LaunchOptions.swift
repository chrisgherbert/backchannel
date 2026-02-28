import Foundation

struct LaunchOptions {
    var sourceURL: String?
    var outputType: OutputType?
    var outputTarget: String?
    var rtmpServerURL: String?
    var rtmpStreamKey: String?
    var rtmpFullURLOverride: String?
    var hlsPlaylistPath: String?
    var encodeMode: EncodeMode?
    var bufferSeconds: Int?
    var useDiskBackedBuffer: Bool?
    var avSyncOffsetMs: Int?
    var audioBoostEnabled: Bool?
    var audioBoostDb: Int?
    var audioContinuityEnabled: Bool?
    var extendedLogging: Bool?
    var autoStart = false
    var noAutoStart = false

    var hasRuntimeOverrides: Bool {
        sourceURL != nil ||
        outputType != nil ||
        outputTarget != nil ||
        rtmpServerURL != nil ||
        rtmpStreamKey != nil ||
        rtmpFullURLOverride != nil ||
        hlsPlaylistPath != nil ||
        encodeMode != nil ||
        bufferSeconds != nil ||
        useDiskBackedBuffer != nil ||
        avSyncOffsetMs != nil ||
        audioBoostEnabled != nil ||
        audioBoostDb != nil ||
        audioContinuityEnabled != nil ||
        extendedLogging != nil
    }

    var shouldAutoStart: Bool {
        if noAutoStart { return false }
        return autoStart || hasRuntimeOverrides
    }
}

enum LaunchOptionsParser {
    static func parseOrExit(arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1

        func fail(_ message: String) -> Never {
            fputs("Error: \(message)\n\n", stderr)
            fputs(usageText, stderr)
            exit(2)
        }

        func readValue(_ flag: String) -> String {
            guard index + 1 < arguments.count else {
                fail("Missing value for \(flag)")
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--help", "-h":
                print(usageText)
                exit(0)
            case "--source-url":
                options.sourceURL = readValue(arg)
            case "--format":
                let value = readValue(arg).lowercased()
                switch value {
                case "rtmp":
                    options.outputType = .rtmp
                case "hls":
                    options.outputType = .hls
                default:
                    fail("Invalid format '\(value)'. Expected 'rtmp' or 'hls'.")
                }
            case "--output", "--output-target":
                options.outputTarget = readValue(arg)
            case "--rtmp-server-url":
                options.rtmpServerURL = readValue(arg)
            case "--rtmp-stream-key":
                options.rtmpStreamKey = readValue(arg)
            case "--rtmp-url", "--rtmp-full-url":
                options.rtmpFullURLOverride = readValue(arg)
            case "--hls-playlist":
                options.hlsPlaylistPath = readValue(arg)
            case "--mode":
                let value = readValue(arg).lowercased()
                switch value {
                case "compatible", "high-compatibility", "high_compatibility":
                    options.encodeMode = .transcode
                case "stream-copy", "stream_copy", "copy":
                    options.encodeMode = .copy
                case "stream-copy-paced", "stream_copy_paced", "copy-paced", "copy_paced", "paced":
                    options.encodeMode = .copy
                default:
                    fail("Invalid mode '\(value)'. Expected 'compatible' or 'stream-copy'.")
                }
            case "--buffer-seconds":
                let value = readValue(arg)
                guard let seconds = Int(value), [0, 5, 15, 30, 60, 120].contains(seconds) else {
                    fail("Invalid --buffer-seconds '\(value)'. Expected one of: 0, 5, 15, 30, 60, 120.")
                }
                options.bufferSeconds = seconds
            case "--disk-buffer":
                options.useDiskBackedBuffer = parseBool(readValue(arg), flag: arg, fail: fail)
            case "--av-sync-offset-ms":
                let value = readValue(arg)
                guard let offset = Int(value), (-2000...2000).contains(offset) else {
                    fail("Invalid --av-sync-offset-ms '\(value)'. Expected -2000...2000.")
                }
                options.avSyncOffsetMs = offset
            case "--audio-boost":
                options.audioBoostEnabled = parseBool(readValue(arg), flag: arg, fail: fail)
            case "--audio-boost-db":
                let value = readValue(arg)
                guard let db = Int(value), [0, 5, 10, 20].contains(db) else {
                    fail("Invalid --audio-boost-db '\(value)'. Expected one of: 0, 5, 10, 20.")
                }
                options.audioBoostDb = db
            case "--audio-continuity":
                options.audioContinuityEnabled = parseBool(readValue(arg), flag: arg, fail: fail)
            case "--extended-logging":
                options.extendedLogging = parseBool(readValue(arg), flag: arg, fail: fail)
            case "--auto-start":
                options.autoStart = true
            case "--no-auto-start":
                options.noAutoStart = true
            default:
                fail("Unknown argument '\(arg)'")
            }
            index += 1
        }

        return options
    }

    private static func parseBool(_ value: String, flag: String, fail: (String) -> Never) -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            fail("Invalid value '\(value)' for \(flag). Expected true/false.")
        }
    }

    private static let usageText = """
    Backchannel CLI options:
      --help, -h
      --source-url <url>
      --format <rtmp|hls>
      --output <target>                  (full target; interpreted by format)
      --rtmp-server-url <url>
      --rtmp-stream-key <key>
      --rtmp-url <full-url>
      --hls-playlist <path>
      --mode <compatible|stream-copy>
      --buffer-seconds <0|5|15|30|60|120>
      --disk-buffer <true|false>
      --av-sync-offset-ms <-2000..2000>
      --audio-boost <true|false>
      --audio-boost-db <0|5|10|20>
      --audio-continuity <true|false>
      --extended-logging <true|false>
      --auto-start
      --no-auto-start
    """
}
