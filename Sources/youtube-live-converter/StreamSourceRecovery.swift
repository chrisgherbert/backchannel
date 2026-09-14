import Foundation

struct StreamSourceRecovery {
    enum Phase { case none, switching, trying, restored, failed, stopped }
    private(set) var usesYtDlp = false
    private(set) var phase: Phase = .none
    private(set) var sourceTool = "—"
    private(set) var cookiesLoaded = false
    private(set) var browserName: String?
    private(set) var failureTitle = ""
    private(set) var failureDetail = ""
    private(set) var fallbackError = ""

    var sourceToolLabel: String { sourceTool + (usesYtDlp && sourceTool == "yt-dlp" ? " · Fallback" : "") }
    var attemptDetail: String {
        browserName.map { "Using your \($0) browser session." } ?? "Using the current source authentication settings."
    }

    mutating func launched(tool: String, browser: String?) {
        sourceTool = tool
        browserName = browser
        cookiesLoaded = false
        if usesYtDlp { phase = .trying }
    }

    mutating func observe(message: String, source: String, sourceURL: String) -> Bool {
        let lower = message.lowercased()
        if source == "streamlink", lower.hasPrefix("browser cookies imported from ") {
            cookiesLoaded = true
        }
        guard source == "streamlink",
              let host = URL(string: sourceURL)?.host?.lowercased(),
              host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") else { return false }
        let authenticationRequired = lower.contains("login_required") ||
            lower.contains("youtube authentication required") ||
            lower.contains("sign in to confirm you’re not a bot") ||
            lower.contains("sign in to confirm you're not a bot")
        guard authenticationRequired || lower.contains("no playable streams found on this url") else { return false }
        // Keep explicit authentication evidence even if the generic CLI error follows it.
        if authenticationRequired || failureTitle.isEmpty {
            failureTitle = authenticationRequired
                ? (cookiesLoaded ? "YouTube rejected Streamlink authentication" : "YouTube requires authentication")
                : "Streamlink couldn’t open this source"
            failureDetail = authenticationRequired
                ? (cookiesLoaded ? "Browser cookies were loaded, but YouTube did not accept the request." : "YouTube did not accept Streamlink’s request and asked for sign-in.")
                : "Streamlink reported no playable streams. This response does not establish an authentication failure."
        }
        guard !usesYtDlp else { return false }
        usesYtDlp = true
        phase = .switching
        return true
    }

    mutating func outputStarted() {
        if phase == .trying { phase = .restored }
    }

    mutating func failed(message: String) {
        phase = .failed
        fallbackError = message
    }

    mutating func stopped() {
        if phase != .none { phase = .stopped }
    }

    static let ytDlpArguments = ["--no-playlist", "--format", "best"]
}
