#!/usr/bin/env python3
"""Coordinate a Jupyter kernel, ZMQ clients, and the Vite output frontend."""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from queue import Empty
from urllib.parse import urlparse

from jupyter_client import BlockingKernelClient
from jupyter_client.kernelspec import KernelSpecManager


class KernelLauncher:
    def __init__(self, kernel_id, emacs_buffer_absolute_path):
        self.kernel_id = kernel_id
        self.emacs_buffer_absolute_path = Path(emacs_buffer_absolute_path).resolve()

    @property
    def connection_id(self):
        kernel_hash = hashlib.sha256(self.kernel_id.encode()).hexdigest()[:16]
        buffer_hash = hashlib.sha256(
            str(self.emacs_buffer_absolute_path).encode()
        ).hexdigest()[:16]
        return f"{kernel_hash}_{buffer_hash}_kernel.json"

    @property
    def connection_file(self):
        return Path.home() / self.connection_id

    @property
    def pid_file(self):
        return self.connection_file.with_suffix(".pid")

    def launch(self):
        if self.connection_file.exists():
            self.connection_file.unlink()
        if self.pid_file.exists():
            self.pid_file.unlink()

        kernel_spec = KernelSpecManager().get_kernel_spec(self.kernel_id)
        command = [
            argument.replace("{connection_file}", str(self.connection_file))
            for argument in kernel_spec.argv
        ]
        environment = os.environ.copy()
        environment.update(kernel_spec.env)
        process = subprocess.Popen(
            command,
            env=environment,
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        deadline = time.monotonic() + 10
        while not self.connection_file.exists():
            if process.poll() is not None:
                raise RuntimeError(
                    f"Kernel process exited with status {process.returncode}"
                )
            if time.monotonic() >= deadline:
                process.terminate()
                process.wait()
                raise TimeoutError(
                    f"Kernel did not create {self.connection_file} within 10 seconds"
                )
            time.sleep(0.05)

        self.pid_file.write_text(str(process.pid), encoding="ascii")
        return {
            "connectionFile": str(self.connection_file),
            "kernelId": self.kernel_id,
            "pid": process.pid,
        }


class ZMQPublisher:
    def __init__(self, connection_kernel_file):
        self.connection_kernel_file = Path(connection_kernel_file).expanduser()
        if not self.connection_kernel_file.is_file():
            raise FileNotFoundError(
                f"Kernel connection file is not ready: {self.connection_kernel_file}"
            )
        self.client = BlockingKernelClient()
        self.client.load_connection_file(self.connection_kernel_file)

    def start(self):
        self.client.start_channels(
            shell=True, iopub=False, stdin=False, hb=False, control=False
        )

    def stop(self):
        self.client.stop_channels()

    def publish(self, code):
        if not code:
            raise ValueError("Cannot publish an empty code cell")
        request_id = self.client.execute(code, allow_stdin=False)
        return {"requestId": request_id, "status": "submitted"}

    def launch(self):
        self.start()
        try:
            for line in sys.stdin:
                try:
                    request = json.loads(line)
                    result = self.publish(request["code"])
                except (KeyError, ValueError, RuntimeError) as error:
                    result = {"error": str(error)}
                print(json.dumps(result), flush=True)
        finally:
            self.stop()


class ZMQSubscriber:
    def __init__(self, connection_kernel_file, event_port):
        self.connection_kernel_file = Path(connection_kernel_file).expanduser()
        if not self.connection_kernel_file.is_file():
            raise FileNotFoundError(
                f"Kernel connection file is not ready: {self.connection_kernel_file}"
            )
        self.event_port = event_port
        self.events = deque(maxlen=1000)
        self.events_lock = threading.Lock()
        self.client = BlockingKernelClient()
        self.client.load_connection_file(self.connection_kernel_file)

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
        subscriber = self

        class EventHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                if urlparse(self.path).path != "/jupyter-eval-events":
                    self.send_error(404)
                    return
                body = json.dumps({"events": subscriber._snapshot()}).encode()
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
                {
                    "eventUrl": (
                        f"http://127.0.0.1:{self.event_port}/jupyter-eval-events"
                    )
                }
            ),
            flush=True,
        )
        try:
            server.serve_forever()
        finally:
            server.server_close()
            self.client.stop_channels()


class ViteLauncher:
    def __init__(self, kernel_id, event_port, vite_port=5173):
        self.kernel_id = kernel_id
        self.event_port = event_port
        self.vite_port = vite_port

    def launch(self):
        environment = os.environ.copy()
        environment["VITE_JUPYTER_EVAL_KERNEL_NAME"] = self.kernel_id
        environment["VITE_JUPYTER_EVAL_EVENTS_URL"] = (
            f"http://127.0.0.1:{self.event_port}/jupyter-eval-events"
        )
        subprocess.run(
            [
                "npm",
                "run",
                "dev",
                "--",
                "--host",
                "127.0.0.1",
                "--port",
                str(self.vite_port),
                "--strictPort",
            ],
            check=True,
            env=environment,
            cwd=Path(__file__).parent,
        )


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    launch = commands.add_parser("launch-kernel")
    launch.add_argument("--kernel-id", required=True)
    launch.add_argument("--buffer-path", required=True)

    publish = commands.add_parser("publish")
    publish.add_argument("--connection-file", required=True)
    publish.add_argument("--code")

    subscribe = commands.add_parser("subscribe")
    subscribe.add_argument("--connection-file", required=True)
    subscribe.add_argument("--event-port", required=True, type=int)

    vite = commands.add_parser("launch-vite")
    vite.add_argument("--kernel-id", required=True)
    vite.add_argument("--event-port", required=True, type=int)
    vite.add_argument("--vite-port", default=5173, type=int)

    args = parser.parse_args()
    if args.command == "launch-kernel":
        KernelLauncher(args.kernel_id, args.buffer_path).launch()
    elif args.command == "publish":
        publisher = ZMQPublisher(args.connection_file)
        if args.code is None:
            publisher.launch()
        else:
            publisher.start()
            try:
                print(json.dumps(publisher.publish(args.code)), flush=True)
            finally:
                publisher.stop()
    elif args.command == "subscribe":
        ZMQSubscriber(args.connection_file, args.event_port).launch()
    else:
        ViteLauncher(args.kernel_id, args.event_port, args.vite_port).launch()


if __name__ == "__main__":
    main()