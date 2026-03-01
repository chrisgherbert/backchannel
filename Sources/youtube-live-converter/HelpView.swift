import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Back Channel Help")
                        .font(.title2.weight(.semibold))
                    Text("Everything you need to go from source URL to reliable output.")
                        .foregroundStyle(.secondary)
                }

                HelpSection(title: "Before You Start") {
                    Bullet("Confirm you are on macOS 13+ with Apple Silicon.")
                    Bullet("Get your output destination ready first (RTMP URL/key or HLS path).")
                    Bullet("Use a livestream URL rather than a prerecorded video URL.")
                }

                HelpSection(title: "Quick Start") {
                    StepRow(number: 1, text: "Paste a livestream URL in Input Source.")
                    StepRow(number: 2, text: "Wait for source info to load automatically, then verify title/thumbnail.")
                    StepRow(number: 3, text: "Select RTMP or HLS output and set destination fields.")
                    StepRow(number: 4, text: "Choose Compatible mode for most production use.")
                    StepRow(number: 5, text: "Click Start and wait for buffer fill before playback checks.")
                }

                HelpSection(title: "Recommended Defaults") {
                    Bullet("Use Compatible mode unless you specifically need pass-through.")
                    Bullet("Use a buffer delay (15s to 30s) for better continuity on live sources.")
                    Bullet("Keep disk-backed buffering enabled for long sessions.")
                    Bullet("Use presets to avoid endpoint typos between sessions.")
                }

                HelpSection(title: "Troubleshooting") {
                    Bullet("No output: Validate transport fields and destination endpoint.")
                    Bullet("Frequent freezes: Increase buffer delay and use Compatible mode.")
                    Bullet("A/V drift: Use A/V sync offset in small increments.")
                    Bullet("Source issues: Try another live URL to rule out upstream instability.")
                }

                HelpSection(title: "CLI Guide") {
                    Text("Use the CLI for repeatable runs, remote operation, and scripted diagnostics. It runs the same core pipeline as the app.")
                        .foregroundStyle(.secondary)

                    Group {
                        Text("Install CLI Command")
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: "\"/Applications/Back Channel.app/Contents/Resources/bin/install-cli.sh\"")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        Text("Verify installation")
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: "backchannel --help")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Group {
                        Text("Start a Typical RTMP Session")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            verbatim: """
                            backchannel \\
                              --source-url \"https://www.youtube.com/watch?v=YOUR_ID\" \\
                              --format rtmp \\
                              --rtmp-url \"rtmp://127.0.0.1/live\" \\
                              --mode compatible \\
                              --buffer-seconds 15 \\
                              --disk-buffer true \\
                              --auto-start
                            """
                        )
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    }

                    Group {
                        Text("Capture Logs for Long Runs")
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: "backchannel ... --extended-logging true > ~/Downloads/backchannel-run.log 2>&1")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Bullet("Use GUI once to validate source and destination, then move repeat runs to CLI.")
                    Bullet("Use Compatible mode for the most predictable ingest behavior.")
                    Bullet("Use a buffer delay (15s to 30s) when source delivery is uneven.")
                    Bullet("Keep one log file per run for easier troubleshooting and comparison.")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 760, minHeight: 620)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

private struct Bullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    init(number: Int, text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
            Text(text)
        }
    }
}
