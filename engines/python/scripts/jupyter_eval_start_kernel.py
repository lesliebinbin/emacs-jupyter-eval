#!/usr/bin/env python3
"""Start a named Jupyter kernel and print its connection details."""

import argparse
import json
from pathlib import Path

from jupyter_client import KernelManager


def connection_details(connection_file):
    with connection_file.open(encoding="utf-8") as file:
        connection = json.load(file)
    return {
        "connectionFile": str(connection_file),
        "ports": {
            name: connection[name]
            for name in ("shell_port", "iopub_port", "stdin_port", "control_port", "hb_port")
        },
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--connection-file", required=True, type=Path)
    args = parser.parse_args()

    connection_file = args.connection_file.expanduser().resolve()
    connection_file.parent.mkdir(parents=True, exist_ok=True)
    if connection_file.exists():
        connection_file.unlink()

    manager = KernelManager(
        kernel_name=args.kernel, connection_file=str(connection_file)
    )
    manager.start_kernel()
    details = connection_details(connection_file)
    details["pid"] = manager.provisioner.pid
    print(json.dumps(details), flush=True)


if __name__ == "__main__":
    main()
