#!/usr/bin/env python3
"""Jupyter Eval broker: bridge code requests and kernel events over ZMQ/HTTP."""

import argparse
import json

from input_processor import InputProcessor
from output_processor import OutputProcessor


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    input_command = commands.add_parser("input")
    input_command.add_argument("--connection-file", required=True)
    input_command.add_argument("--code")

    output_command = commands.add_parser("output")
    output_command.add_argument("--connection-file", required=True)
    output_command.add_argument("--event-port", required=True, type=int)
    output_command.add_argument("--allowed-origin", required=True)

    args = parser.parse_args()
    if args.command == "input":
        processor = InputProcessor(args.connection_file)
        if args.code is None:
            processor.launch()
        else:
            processor.start()
            try:
                print(json.dumps(processor.publish(args.code)), flush=True)
            finally:
                processor.stop()
    elif args.command == "output":
        OutputProcessor(
            args.connection_file, args.event_port, args.allowed_origin
        ).launch()


if __name__ == "__main__":
    main()
