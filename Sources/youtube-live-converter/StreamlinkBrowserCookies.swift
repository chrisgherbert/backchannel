import Foundation

enum StreamlinkBrowserCookies {
    static func arguments(browser: BrowserCookiesSource?, streamArguments: [String]) -> [String] {
        ["-c", bootstrap, browser?.ytDLPValue ?? ""] + streamArguments
    }

    // Run inside the managed Python runtime, which contains both yt-dlp and
    // Streamlink. Seed the CLI's session with the imported cookie jar in memory.
    // Using a cookie file would lose session cookies in Streamlink's file loader.
    // No cookie values enter argv, logs, or a persistent export file.
    // This adapts the CLI's session constructor; run the managed-runtime
    // integration tests when updating Streamlink.
    static let bootstrap = #"""
    import contextlib
    import importlib
    import signal
    import sys
    from urllib.parse import urlparse

    browser = sys.argv[1]
    stream_args = sys.argv[2:]

    def fail(message):
        print("error: Browser cookie import failed. " + message, file=sys.stderr, flush=True)
        raise SystemExit(77)

    class QuietLogger:
        def debug(self, *args, **kwargs): pass
        def info(self, *args, **kwargs): pass
        def warning(self, *args, **kwargs): pass
        def error(self, *args, **kwargs): pass

    signal.signal(signal.SIGTERM, signal.default_int_handler)
    try:
        from yt_dlp.cookies import extract_cookies_from_browser
        cli = importlib.import_module("streamlink_cli.main")
        cookies = None
        if browser:
            with contextlib.redirect_stdout(sys.stderr):
                cookies = extract_cookies_from_browser(browser, logger=QuietLogger())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception:
        fail("Open the selected browser and sign in to the source site. Allow browser cookie or Keychain access if macOS asks; Safari may require Full Disk Access. Then start again.")

    if cookies is not None:
        cookies.clear_expired_cookies()
        if not len(cookies):
            fail("No cookies were available. Open the selected browser, visit the source site, and check cookie access permissions before starting again.")

    def report_authentication(response, *args, **kwargs):
        url = urlparse(response.url)
        if url.hostname != "www.youtube.com" or url.path != "/youtubei/v1/player":
            return response
        try:
            status = response.json().get("playabilityStatus", {}).get("status")
        except (ValueError, AttributeError):
            return response
        if status == "LOGIN_REQUIRED":
            print("error: YouTube authentication required (LOGIN_REQUIRED).", file=sys.stderr, flush=True)
        return response

    try:
        class BrowserCookieSession(cli.Streamlink):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                self.http.hooks.setdefault("response", []).append(report_authentication)
                if cookies is not None:
                    self.http.cookies.update(cookies)
                    print("Browser cookies imported from " + browser.capitalize() + " and attached to Streamlink.", file=sys.stderr, flush=True)
        cli.Streamlink = BrowserCookieSession
    except Exception:
        fail("Update managed support in Settings > Tools to use browser cookies for streaming.")

    sys.argv = ["streamlink"] + stream_args
    cli.main()
    """#
}
