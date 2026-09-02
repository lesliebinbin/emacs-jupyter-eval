#!/usr/bin/env python3
"""Send one code submission to a running Jupyter kernel."""

import argparse
import json
import sys
from pathlib import Path

from jupyter_client import BlockingKernelClient


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--connection-file", required=True, type=Path)
    parser.add_argument("--code")
    args = parser.parse_args()

    code = args.code if args.code is not None else sys.stdin.read()
    if not code:
        raise ValueError("Provide code with --code or standard input")

    client = BlockingKernelClient()
    client.load_connection_file(args.connection_file.expanduser())
    client.start_channels()
    try:
        request_id = client.execute(code, allow_stdin=False)
    finally:
        client.stop_channels()

    print(json.dumps({"requestId": request_id}), flush=True)


if __name__ == "__main__":
    main()
