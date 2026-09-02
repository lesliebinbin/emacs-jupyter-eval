#!/usr/bin/env python3
"""Expose Jupyter IOPub events to the receive-only browser frontend."""

import argparse
import json
import threading
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from queue import Empty
from urllib.parse import urlparse

from jupyter_client import BlockingKernelClient


class EventStore:
    def __init__(self, max_events):
        self.events = deque(maxlen=max_events)
        self.lock = threading.Lock()

    def append(self, event):
        with self.lock:
            self.events.append(event)

    def snapshot(self):
        with self.lock:
            return list(self.events)


def receive_iopub(client, events):
    while True:
        try:
            message = client.get_iopub_msg(timeout=0.25)
        except Empty:
            continue

        request_id = message["parent_header"].get("msg_id")
        content = message["content"]
        if message["msg_type"] == "execute_input":
            events.append(
                {
                    "type": "execution_started",
                    "requestId": request_id,
                    "code": content["code"],
                }
            )
        events.append(
            {
                "type": message["msg_type"],
                "requestId": request_id,
                "content": content,
            }
        )


def handler_for(events):
    class EventHandler(BaseHTTPRequestHandler):
        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.end_headers()

        def do_GET(self):
            if urlparse(self.path).path != "/jupyter-eval-events":
                self.send_error(404)
                return

            body = json.dumps({"events": events.snapshot()}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            print(format % args)

    return EventHandler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--connection-file", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8766, type=int)
    parser.add_argument("--max-events", default=1000, type=int)
    args = parser.parse_args()

    client = BlockingKernelClient()
    client.load_connection_file(args.connection_file)
    client.start_channels()
    events = EventStore(args.max_events)
    threading.Thread(target=receive_iopub, args=(client, events), daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), handler_for(events))
    print(f"Listening at http://{args.host}:{args.port}/jupyter-eval-events", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        client.stop_channels()


if __name__ == "__main__":
    main()
