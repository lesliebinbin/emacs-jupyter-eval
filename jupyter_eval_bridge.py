#!/usr/bin/env python3
"""Jupyter kernel bridge for the jupyter-eval Emacs package."""

import argparse
import json
import sys
import threading

from jupyter_client import KernelManager


def emit(event):
    print(json.dumps(event), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel", required=True)
    args = parser.parse_args()
    manager = KernelManager(kernel_name=args.kernel)
    manager.start_kernel()
    client = manager.client()
    client.start_channels()
    request_ids = {}

    def receive_iopub():
        while True:
            try:
                message = client.get_iopub_msg(timeout=0.25)
            except Exception:
                continue
            parent_id = message["parent_header"].get("msg_id")
            event = {
                "type": message["msg_type"],
                "requestId": request_ids.get(parent_id),
                "content": message["content"],
            }
            emit(event)

    threading.Thread(target=receive_iopub, daemon=True).start()
    emit({"type": "ready", "kernel": args.kernel})
    try:
        for line in sys.stdin:
            request = json.loads(line)
            if request.get("type") != "execute":
                continue
            request_id = request["requestId"]
            message_id = client.execute(request["code"], allow_stdin=False)
            request_ids[message_id] = request_id
            emit({"type": "execution_started", "requestId": request_id,
                  "code": request["code"]})
    finally:
        client.stop_channels()
        manager.shutdown_kernel(now=True)


if __name__ == "__main__":
    main()
