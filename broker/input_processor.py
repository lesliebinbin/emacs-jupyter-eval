"""Accept code requests and publish them to a Jupyter kernel over ZMQ."""

import json
import sys
from pathlib import Path
from queue import Empty

from jupyter_client import BlockingKernelClient


class InputProcessor:
    def __init__(self, connection_file):
        self.connection_file = Path(connection_file).expanduser()
        if not self.connection_file.is_file():
            raise FileNotFoundError(
                f"Kernel connection file is not ready: {self.connection_file}"
            )
        self.client = BlockingKernelClient()
        self.client.load_connection_file(self.connection_file)

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
        # Wait for the shell reply so the request is guaranteed to be
        # delivered before the channel closes: closing with linger=0
        # would otherwise discard the still-queued request.
        try:
            self.client.get_shell_msg(timeout=30)
        except Empty:
            pass
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
