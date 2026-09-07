import base64
import json
import threading
import unittest
from collections import deque
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from output_processor import OutputProcessor


class FakeSession:
    def msg_header(self, message_type):
        return {"msg_id": "generated", "msg_type": message_type}

    def msg(self, message_type, content, metadata, header):
        return {
            "header": header,
            "parent_header": {},
            "metadata": metadata,
            "content": content,
            "msg_type": message_type,
        }


class FakeShellChannel:
    def __init__(self):
        self.messages = []

    def send(self, message):
        self.messages.append(message)


class FakeClient:
    def __init__(self):
        self.session = FakeSession()
        self.shell_channel = FakeShellChannel()


def processor_without_kernel():
    processor = OutputProcessor.__new__(OutputProcessor)
    processor.events = deque(maxlen=1000)
    processor.events_condition = threading.Condition()
    processor.event_sequence = 0
    processor.shell_lock = threading.Lock()
    processor.allowed_origin = "http://127.0.0.1:5173"
    processor.session_id = "session-one"
    processor.generation = "generation-one"
    processor.interactive_capability = "secret-one"
    processor.client = FakeClient()
    return processor


class OutputProcessorTest(unittest.TestCase):
    def test_events_have_monotonic_ids_and_snapshot_stays_compatible(self):
        processor = processor_without_kernel()

        processor._append({"type": "first"})
        processor._append({"type": "second"})

        self.assertEqual(
            processor._snapshot(),
            [{"type": "first"}, {"type": "second"}],
        )
        self.assertEqual(
            processor._events_after(1),
            [(2, {"type": "second"})],
        )

    def test_publish_comm_sends_message_with_binary_buffers(self):
        processor = processor_without_kernel()
        encoded = base64.b64encode(b"\x00widget").decode("ascii")

        message_id = processor.publish_comm(
            {
                "type": "comm_msg",
                "message_id": "browser-message",
                "comm_id": "widget-model",
                "data": {"method": "update"},
                "metadata": {"version": "2.0.0"},
                "buffers": [encoded],
            }
        )

        self.assertEqual(message_id, "browser-message")
        message = processor.client.shell_channel.messages[0]
        self.assertEqual(message["header"]["msg_id"], "browser-message")
        self.assertEqual(message["content"]["comm_id"], "widget-model")
        self.assertEqual(message["buffers"], [b"\x00widget"])

    def test_comm_open_requires_target_name(self):
        processor = processor_without_kernel()

        with self.assertRaisesRegex(ValueError, "target_name"):
            processor.publish_comm(
                {
                    "type": "comm_open",
                    "message_id": "browser-message",
                    "comm_id": "widget-model",
                }
            )

    def test_http_routes_reject_an_untrusted_browser_origin(self):
        processor = processor_without_kernel()
        server = ThreadingHTTPServer(("127.0.0.1", 0), processor._handler())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/jupyter-eval-events"

        try:
            request = Request(url, headers={"Origin": "https://attacker.example"})
            with self.assertRaises(HTTPError) as context:
                urlopen(request, timeout=2)
            self.assertEqual(context.exception.code, 403)

            request = Request(
                url,
                headers={"Origin": processor.allowed_origin},
            )
            with urlopen(request, timeout=2) as response:
                self.assertEqual(
                    response.headers["Access-Control-Allow-Origin"],
                    processor.allowed_origin,
                )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_health_exposes_identity_without_capability(self):
        processor = processor_without_kernel()
        server = ThreadingHTTPServer(("127.0.0.1", 0), processor._handler())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/jupyter-eval-health"

        try:
            with urlopen(url, timeout=2) as response:
                health = json.load(response)
            self.assertEqual(health["sessionId"], "session-one")
            self.assertEqual(health["generation"], "generation-one")
            self.assertEqual(health["status"], "running")
            self.assertNotIn("capability", health)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_comm_route_requires_the_session_capability(self):
        processor = processor_without_kernel()
        server = ThreadingHTTPServer(("127.0.0.1", 0), processor._handler())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/jupyter-eval-comm"
        body = json.dumps(
            {
                "type": "comm_msg",
                "message_id": "browser-message",
                "comm_id": "widget-model",
                "data": {"method": "update"},
                "metadata": {},
                "buffers": [],
            }
        ).encode()

        try:
            unauthorized = Request(
                url,
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "Origin": processor.allowed_origin,
                },
                method="POST",
            )
            with self.assertRaises(HTTPError) as context:
                urlopen(unauthorized, timeout=2)
            self.assertEqual(context.exception.code, 403)
            self.assertEqual(processor.client.shell_channel.messages, [])

            wrong_session = Request(
                url,
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "Origin": processor.allowed_origin,
                    "X-Jupyter-Eval-Capability": "secret-two",
                },
                method="POST",
            )
            with self.assertRaises(HTTPError) as context:
                urlopen(wrong_session, timeout=2)
            self.assertEqual(context.exception.code, 403)

            authorized = Request(
                url,
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "Origin": processor.allowed_origin,
                    "X-Jupyter-Eval-Capability": "secret-one",
                },
                method="POST",
            )
            with urlopen(authorized, timeout=2) as response:
                self.assertEqual(response.status, 202)
            self.assertEqual(
                processor.client.shell_channel.messages[0]["header"]["msg_id"],
                "browser-message",
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
