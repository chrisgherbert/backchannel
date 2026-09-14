"""Run with the managed Python runtime (yt-dlp and Streamlink installed).

Uses synthetic cookies only; never reads browser data or requests a stream.
"""
from pathlib import Path
import subprocess
import sys
import textwrap
import unittest


SOURCE = (Path(__file__).resolve().parents[2] /
          "Sources/youtube-live-converter/StreamlinkBrowserCookies.swift").read_text()
BOOTSTRAP = textwrap.dedent(SOURCE.split('static let bootstrap = #"""\n', 1)[1].split('\n    """#', 1)[0])
PRELUDE = """
import http.cookiejar
import time
import sys
import requests
import yt_dlp.cookies
import streamlink_cli.main as cli
jar = yt_dlp.cookies.YoutubeDLCookieJar()
"""


class BrowserCookieTests(unittest.TestCase):
    def run_bootstrap(self, fixture, browser="brave"):
        code = PRELUDE + textwrap.dedent(fixture) + "\n" + BOOTSTRAP
        return subprocess.run(
            [sys.executable, "-c", code, browser, "--no-config",
             "--can-handle-url-no-redirect", "https://www.youtube.com/watch?v=HAQ1fCqy84E"],
            capture_output=True, text=True, timeout=15,
        )

    def test_real_cli_preserves_session_cookies_and_domain_scope(self):
        for browser in ["chrome", "brave", "safari", "firefox", "edge"]:
            with self.subTest(browser=browser):
                result = self.run_bootstrap("""
                    expected_browser = sys.argv[1]
                    for name, expires in [('session_fixture', None), ('expired_fixture', int(time.time()) - 10)]:
                        jar.set_cookie(http.cookiejar.Cookie(0, name, 'synthetic-test-value', None, False,
                            '.youtube.com', True, True, '/', True, True, expires, expires is None,
                            None, None, {}, False))
                    def extract(browser, logger):
                        assert browser == expected_browser
                        return jar
                    yt_dlp.cookies.extract_cookies_from_browser = extract
                    def check_session(parser):
                        session = cli.streamlink.http
                        assert session.cookies.get('session_fixture') == 'synthetic-test-value'
                        assert session.cookies.get('expired_fixture') is None
                        request = requests.Request('GET', 'https://www.youtube.com/')
                        assert 'session_fixture=' in session.prepare_request(request).headers['Cookie']
                        other = requests.Request('GET', 'https://example.org/')
                        assert 'Cookie' not in session.prepare_request(other).headers
                        return 0
                    cli.run = check_session
                    """, browser)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Browser cookies imported from " + browser.capitalize(), result.stderr)
                self.assertNotIn("synthetic-test-value", result.stdout + result.stderr)

    def test_permission_failure_is_actionable_and_does_not_start_streamlink(self):
        result = self.run_bootstrap("""
            def extract(browser, logger):
                raise PermissionError('private browser path or data')
            yt_dlp.cookies.extract_cookies_from_browser = extract
            cli.main = lambda: sys.exit(99)
            """)
        self.assertEqual(result.returncode, 77)
        self.assertIn("Browser cookie import failed", result.stderr)
        self.assertIn("Full Disk Access", result.stderr)
        self.assertNotIn("private browser path or data", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_empty_browser_jar_does_not_silently_stream_anonymously(self):
        result = self.run_bootstrap("""
            yt_dlp.cookies.extract_cookies_from_browser = lambda browser, logger: jar
            cli.main = lambda: sys.exit(99)
            """)
        self.assertEqual(result.returncode, 77)
        self.assertIn("No cookies were available", result.stderr)

    def test_authentication_response_is_reported_without_reading_browser_when_disabled(self):
        result = self.run_bootstrap("""
            def extract(*args, **kwargs):
                raise AssertionError('Browser import must be disabled')
            yt_dlp.cookies.extract_cookies_from_browser = extract
            def check_response_hooks(parser):
                response = requests.Response()
                response.status_code = 200
                response.url = 'https://www.youtube.com/youtubei/v1/player'
                response._content = b'{"playabilityStatus":{"status":"LOGIN_REQUIRED"}}'
                hooks = cli.streamlink.http.hooks['response']
                assert hooks
                for hook in hooks:
                    assert hook(response) is response
                response._content = b'{"playabilityStatus":{"status":"UNPLAYABLE"}}'
                for hook in hooks:
                    hook(response)
                return 0
            cli.run = check_response_hooks
            """, browser="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count('YouTube authentication required'), 1)
        self.assertNotIn('cookies imported', result.stderr)


if __name__ == "__main__":
    unittest.main()
