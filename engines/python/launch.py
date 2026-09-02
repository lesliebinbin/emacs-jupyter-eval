#!/usr/bin/env python3
"""Jupyter Eval Python engine: launch kernels, list and register kernelspecs."""

import argparse
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

from jupyter_client.kernelspec import KernelSpecManager


class KernelLauncher:
    """Launch a Jupyter kernel and report its connection and pid files."""

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
            "pidFile": str(self.pid_file),
            "kernelId": self.kernel_id,
            "pid": process.pid,
        }


def register_kernelspec():
    """Register this engine's kernelspec for the current user."""
    from ipykernel.kernelspec import install

    install(
        user=True,
        kernel_name="jupyter-eval-python",
        display_name="Jupyter Eval (Python)",
    )


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    launch = commands.add_parser("launch")
    launch.add_argument("--kernel-id", required=True)
    launch.add_argument("--buffer-path", required=True)

    commands.add_parser("list")
    commands.add_parser("register")

    args = parser.parse_args()
    if args.command == "launch":
        print(
            json.dumps(KernelLauncher(args.kernel_id, args.buffer_path).launch()),
            flush=True,
        )
    elif args.command == "list":
        print(json.dumps(sorted(KernelSpecManager().get_all_specs())), flush=True)
    elif args.command == "register":
        register_kernelspec()


if __name__ == "__main__":
    main()
