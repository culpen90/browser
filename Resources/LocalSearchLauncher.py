"""Start Browser's private SearXNG JSON service."""

import hmac
import json
import os
import secrets
import shutil
import signal
import threading
import time
from pathlib import Path
from socketserver import ThreadingMixIn
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, make_server


class LoopbackServer(ThreadingMixIn, WSGIServer):
    daemon_threads = True
    request_queue_size = 8

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(4)
        super().__init__(*args, **kwargs)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


class QuietHandler(WSGIRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *_args):
        pass


def watch_parent(parent_pid, directory):
    while os.getppid() == parent_pid:
        time.sleep(0.5)
    remove_state_and_exit(directory)


def remove_state_and_exit(directory):
    shutil.rmtree(directory, ignore_errors=True)
    os._exit(0)


def main():
    os.umask(0o077)
    directory = Path(os.environ["BROWSER_SEARCH_STATE"])
    token = os.environ.pop("BROWSER_SEARCH_TOKEN").encode("ascii")
    parent_pid = int(os.environ.pop("BROWSER_SEARCH_PARENT_PID"))
    engines = json.loads(os.environ.pop("BROWSER_SEARCH_ENGINES"))
    signal.signal(signal.SIGTERM, lambda *_args: remove_state_and_exit(directory))
    threading.Thread(target=watch_parent, args=(parent_pid, directory), daemon=True).start()

    with make_server("127.0.0.1", 0, None, LoopbackServer, QuietHandler) as server:
        host = f"127.0.0.1:{server.server_port}"
        settings = directory / "settings.json"
        settings.write_text(json.dumps({
            "use_default_settings": {"engines": {"keep_only": engines}},
            "general": {"debug": False, "enable_metrics": False, "instance_name": "Browser Search"},
            "server": {
                "base_url": f"http://{host}/",
                "secret_key": secrets.token_urlsafe(32),
                "limiter": False,
                "public_instance": False,
                "image_proxy": False,
            },
            "search": {"formats": ["json"], "autocomplete": "", "favicon_resolver": ""},
            "outgoing": {"request_timeout": 4.0, "max_request_timeout": 7.0},
            "engines": [{"name": name, "disabled": False} for name in engines],
        }), encoding="utf-8")
        os.environ["SEARXNG_SETTINGS_PATH"] = str(settings)

        from searx.webapp import app

        def private_app(environ, start_response):
            # Keep normal browsing, DNS rebinding, and other apps away from the query API.
            authorization = environ.get("HTTP_X_BROWSER_SEARCH_TOKEN", "").encode("latin-1")
            content_length = environ.get("CONTENT_LENGTH", "")
            if (environ.get("HTTP_HOST") != host
                    or "HTTP_ORIGIN" in environ
                    or environ["PATH_INFO"] != "/search"
                    or environ["REQUEST_METHOD"] != "POST"
                    or environ.get("QUERY_STRING")
                    or not environ.get("CONTENT_TYPE", "").startswith("application/x-www-form-urlencoded")
                    or not content_length.isdecimal()
                    or not 0 < int(content_length) <= 2_048
                    or not hmac.compare_digest(authorization, token)):
                start_response("403 Forbidden", [("Content-Type", "text/plain"), ("Content-Length", "0")])
                return [b""]
            return app(environ, start_response)

        server.set_app(private_app)
        staged = directory / "ready.tmp"
        staged.write_text(str(server.server_port), encoding="ascii")
        staged.replace(directory / "ready")
        server.serve_forever()


if __name__ == "__main__":
    main()
