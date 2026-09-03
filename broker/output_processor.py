"""Relay Jupyter kernel IOPub events to HTTP clients."""

import base64
import json
import threading
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from queue import Empty
from urllib.parse import urlparse

from jupyter_client import BlockingKernelClient


class OutputProcessor:
    def __init__(self, connection_file, event_port, allowed_origin):
        self.connection_file = Path(connection_file).expanduser()
        if not self.connection_file.is_file():
            raise FileNotFoundError(
                f"Kernel connection file is not ready: {self.connection_file}"
            )
        self.event_port = event_port
        self.allowed_origin = allowed_origin
        self.events = deque(maxlen=1000)
        self.events_condition = threading.Condition()
        self.event_sequence = 0
        self.shell_lock = threading.Lock()
        self.client = BlockingKernelClient()
        self.client.load_connection_file(self.connection_file)

    def _append(self, event):
        with self.events_condition:
            self.event_sequence += 1
            self.events.append((self.event_sequence, event))
            self.events_condition.notify_all()

    def _snapshot(self):
        with self.events_condition:
            return [event for _, event in self.events]

    def _events_after(self, sequence):
        with self.events_condition:
            return [(event_id, event) for event_id, event in self.events if event_id > sequence]

    def _wait_for_events(self, sequence, timeout=15):
        with self.events_condition:
            if self.event_sequence <= sequence:
                self.events_condition.wait(timeout)
            return self.event_sequence > sequence

    @staticmethod
    def _encoded_buffers(message):
        return [
            base64.b64encode(bytes(buffer)).decode("ascii")
            for buffer in message.get("buffers", [])
        ]

    def publish_comm(self, request):
        message_type = request.get("type")
        if message_type not in {"comm_open", "comm_msg", "comm_close"}:
            raise ValueError(f"Unsupported comm message type: {message_type}")

        comm_id = request.get("comm_id")
        message_id = request.get("message_id")
        data = request.get("data", {})
        metadata = request.get("metadata", {})
        encoded_buffers = request.get("buffers", [])
        if not isinstance(comm_id, str) or not comm_id:
            raise ValueError("comm_id must be a non-empty string")
        if not isinstance(message_id, str) or not message_id:
            raise ValueError("message_id must be a non-empty string")
        if not isinstance(data, dict) or not isinstance(metadata, dict):
            raise ValueError("comm data and metadata must be JSON objects")
        if not isinstance(encoded_buffers, list) or not all(
            isinstance(buffer, str) for buffer in encoded_buffers
        ):
            raise ValueError("comm buffers must be base64 strings")

        content = {"comm_id": comm_id, "data": data}
        if message_type == "comm_open":
            target_name = request.get("target_name")
            if not isinstance(target_name, str) or not target_name:
                raise ValueError("target_name is required for comm_open")
            content["target_name"] = target_name

        try:
            buffers = [base64.b64decode(buffer, validate=True) for buffer in encoded_buffers]
        except ValueError as error:
            raise ValueError("comm buffers must contain valid base64") from error

        with self.shell_lock:
            header = self.client.session.msg_header(message_type)
            header["msg_id"] = message_id
            message = self.client.session.msg(
                message_type, content=content, metadata=metadata, header=header
            )
            message["buffers"] = buffers
            self.client.shell_channel.send(message)
        return message["header"]["msg_id"]

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
            event = {
                "type": message_type,
                "requestId": request_id,
                "content": content,
                "header": {
                    "msg_id": message["header"].get("msg_id"),
                    "msg_type": message_type,
                },
                "parent_header": {
                    "msg_id": request_id,
                },
                "metadata": message["metadata"],
            }
            buffers = self._encoded_buffers(message)
            if buffers:
                event["buffers"] = buffers
            self._append(event)

    def _handler(self):
        processor = self

        class EventHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _origin_allowed(self):
                origin = self.headers.get("Origin")
                if origin is None or origin == processor.allowed_origin:
                    return True
                self.send_error(403, "Origin is not allowed")
                return False

            def _cors_header(self):
                self.send_header(
                    "Access-Control-Allow-Origin", processor.allowed_origin
                )
                self.send_header("Vary", "Origin")

            def do_GET(self):
                if not self._origin_allowed():
                    return
                path = urlparse(self.path).path
                if path == "/jupyter-eval-events":
                    self._send_snapshot()
                elif path == "/jupyter-eval-events/stream":
                    self._send_stream()
                else:
                    self.send_error(404)

            def _send_snapshot(self):
                body = json.dumps({"events": processor._snapshot()}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self._cors_header()
                self.end_headers()
                self.wfile.write(body)

            def _send_stream(self):
                try:
                    sequence = int(self.headers.get("Last-Event-ID", "0"))
                except ValueError:
                    sequence = 0
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self._cors_header()
                self.end_headers()

                try:
                    while True:
                        pending = processor._events_after(sequence)
                        if not pending:
                            processor._wait_for_events(sequence)
                            pending = processor._events_after(sequence)
                        if not pending:
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
                            continue
                        for event_id, event in pending:
                            body = json.dumps(event, separators=(",", ":"))
                            payload = f"id: {event_id}\ndata: {body}\n\n".encode()
                            self.wfile.write(payload)
                            sequence = event_id
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return

            def do_POST(self):
                if urlparse(self.path).path != "/jupyter-eval-comm":
                    self.send_error(404)
                    return
                if not self._origin_allowed():
                    return
                try:
                    if self.headers.get("Content-Type") != "application/json":
                        raise ValueError("Content-Type must be application/json")
                    content_length = int(self.headers.get("Content-Length", "0"))
                    if content_length <= 0 or content_length > 10 * 1024 * 1024:
                        raise ValueError("Invalid comm request size")
                    request = json.loads(self.rfile.read(content_length))
                    if not isinstance(request, dict):
                        raise ValueError("Comm request must be a JSON object")
                    message_id = processor.publish_comm(request)
                except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as error:
                    self.send_error(400, str(error))
                    return

                body = json.dumps({"messageId": message_id}).encode()
                self.send_response(202)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self._cors_header()
                self.end_headers()
                self.wfile.write(body)

            def do_OPTIONS(self):
                if urlparse(self.path).path != "/jupyter-eval-comm":
                    self.send_error(404)
                    return
                if not self._origin_allowed():
                    return
                self.send_response(204)
                self._cors_header()
                self.send_header("Access-Control-Allow-Headers", "Content-Type")
                self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
                self.end_headers()

            def log_message(self, format, *args):
                print(format % args)

        return EventHandler

    def launch(self):
        self.client.start_channels(
            shell=True, iopub=True, stdin=False, hb=False, control=False
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
