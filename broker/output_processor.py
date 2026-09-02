"""Relay Jupyter kernel IOPub events to HTTP clients."""

import json
import threading
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from queue import Empty
from urllib.parse import urlparse

from jupyter_client import BlockingKernelClient


class OutputProcessor:
    def __init__(self, connection_file, event_port):
        self.connection_file = Path(connection_file).expanduser()
        if not self.connection_file.is_file():
            raise FileNotFoundError(
                f"Kernel connection file is not ready: {self.connection_file}"
            )
        self.event_port = event_port
        self.events = deque(maxlen=1000)
        self.events_lock = threading.Lock()
        self.client = BlockingKernelClient()
        self.client.load_connection_file(self.connection_file)

    def _append(self, event):
        with self.events_lock:
            self.events.append(event)

    def _snapshot(self):
        with self.events_lock:
            return list(self.events)

    def _listen_iopub(self):
        while True:
            try:
                message = self.client.get_iopub_msg(timeout=0.25)
            except Empty:
                continue
            message_type = message["msg_type"]
            request_id = message["parent_header"].get("msg_id")
            content = message["content"]
            if message_type == "execute_input":
                self._append(
                    {
                        "type": "execution_started",
                        "requestId": request_id,
                        "code": content["code"],
                    }
                )
            self._append(
                {"type": message_type, "requestId": request_id, "content": content}
            )

    def _handler(self):
        processor = self

        class EventHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                if urlparse(self.path).path != "/jupyter-eval-events":
                    self.send_error(404)
                    return
                body = json.dumps({"events": processor._snapshot()}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                print(format % args)

        return EventHandler

    def launch(self):
        self.client.start_channels(
            shell=False, iopub=True, stdin=False, hb=False, control=False
        )
        threading.Thread(target=self._listen_iopub, daemon=True).start()
        server = ThreadingHTTPServer(("127.0.0.1", self.event_port), self._handler())
        print(
            json.dumps(
                {"eventUrl": f"http://127.0.0.1:{self.event_port}/jupyter-eval-events"}
            ),
            flush=True,
        )
        try:
            server.serve_forever()
        finally:
            server.server_close()
            self.client.stop_channels()
