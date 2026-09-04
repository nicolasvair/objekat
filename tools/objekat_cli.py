#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A minimal client for OBJEKAT's command API.

Standard library only, no dependency: this file must stay copyable as it is
into any Python 3 environment.

The protocol is JSON-lines over a UNIX socket: one JSON request per line, one JSON
response per line. This script is as much the usage documentation as it is the tool.

    # what the app can do (the API describes itself)
    ./objekat_cli.py help

    # transport
    ./objekat_cli.py transport.play
    ./objekat_cli.py transport.seek --seconds 12.5
    ./objekat_cli.py transport.state

    # editing
    ./objekat_cli.py object.add --path ~/sounds/kick.wav --lane 2 --start 4
    ./objekat_cli.py object.list
    ./objekat_cli.py object.set_gain --ids UUID1 --ids UUID2 --db -6

    # a batch: one single undo, one single rebuild of the graph
    ./objekat_cli.py --batch session.jsonl

    # measurement
    ./objekat_cli.py perf.census

Exit codes: 0 = success, 1 = the command failed (the `error` field is printed on
stderr), 2 = incorrect usage, 3 = cannot connect.
"""

import argparse
import json
import os
import socket
import sys

DEFAULT_SOCKET = os.path.expanduser(
    "~/Library/Application Support/Objekat/objekat.sock"
)


class ObjekatError(Exception):
    """An error returned by the app: carries the stable code and the message."""

    def __init__(self, payload):
        self.code = payload.get("code", "unknown")
        self.message = payload.get("message", "")
        self.details = payload.get("details")
        super().__init__("%s: %s" % (self.code, self.message))


class ObjekatClient:
    """One connection, one JSON-lines stream. Usable as a context manager."""

    def __init__(self, socket_path=DEFAULT_SOCKET, timeout=120.0):
        self.socket_path = socket_path
        self.timeout = timeout
        self._sock = None
        self._buffer = b""
        self._next_id = 0

    # -- life cycle ------------------------------------------------------

    def connect(self):
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(self.timeout)
        self._sock.connect(self.socket_path)
        return self

    def close(self):
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def __enter__(self):
        return self.connect()

    def __exit__(self, *_):
        self.close()

    # -- exchanges -------------------------------------------------------

    def send(self, cmd, params=None):
        """Sends a command and returns its `result`. Raises ObjekatError if the app refuses."""
        self._next_id += 1
        request = {"id": self._next_id, "cmd": cmd}
        if params:
            request["params"] = params
        payload = json.dumps(request, ensure_ascii=False).encode("utf-8") + b"\n"
        self._sock.sendall(payload)

        response = json.loads(self._read_line())
        if not response.get("ok"):
            raise ObjekatError(response.get("error") or {})
        return response.get("result")

    def _read_line(self):
        # The response may arrive in several packets, and several responses may arrive
        # in the same one: we accumulate and split on the newline.
        while b"\n" not in self._buffer:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed by the application")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        return line.decode("utf-8")


# -- converting the command-line arguments --------------------------------


def coerce(text):
    """`--lane 2` has to arrive as an integer, not a string. JSON is tried first, falling back
    on the raw string — which lets paths, UUIDs and names through."""
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return text


def parse_params(tokens):
    """Turns `--key value --key value2 --flag` into a dictionary.

    A repeated key becomes a list: that is what `ids` wants, being an array.
    A key with no value means `true` (flags of the `--relative` kind).
    """
    params = {}
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if not token.startswith("--"):
            raise SystemExit("unexpected argument: %s (expected --key value)" % token)
        key = token[2:].replace("-", "_")
        if index + 1 < len(tokens) and not tokens[index + 1].startswith("--"):
            value = coerce(tokens[index + 1])
            index += 2
        else:
            value = True
            index += 1
        if key in params:
            existing = params[key]
            params[key] = existing + [value] if isinstance(existing, list) else [existing, value]
        else:
            params[key] = value
    # `ids` is always an array on the app side; passing a single id stays convenient to write.
    for key in ("ids", "commands"):
        if key in params and not isinstance(params[key], list):
            params[key] = [params[key]]
    return params


# -- execution modes ------------------------------------------------------


def run_single(client, cmd, tokens, compact):
    result = client.send(cmd, parse_params(tokens))
    dump(result, compact)


def run_batch(client, path, compact):
    """Replays a .jsonl file: one command per line, `#` for comments.

    The lines are sent one by one (and not inside a `batch` command): the file stays
    readable as a session, each response is printed as it comes, and a failure says
    exactly which line it happened on.

    `{DIR}` is replaced by the folder of the file being replayed. The app is a windowed
    program: its current folder is "/", so a relative path would mean nothing there. Without this
    token, every shareable scenario would have to hard-code an absolute path — hence a personal
    one, hence not committable.
    """
    base = os.path.dirname(os.path.abspath(path))
    with open(path, "r", encoding="utf-8") as handle:
        for number, raw in enumerate(handle, start=1):
            line = raw.strip().replace("{DIR}", base)
            if not line or line.startswith("#"):
                continue
            try:
                request = json.loads(line)
            except ValueError as error:
                raise SystemExit("line %d: invalid JSON (%s)" % (number, error))
            cmd = request.get("cmd")
            if not cmd:
                raise SystemExit("line %d: missing \"cmd\" field" % number)
            try:
                result = client.send(cmd, request.get("params"))
            except ObjekatError as error:
                sys.stderr.write("line %d: %s\n" % (number, error))
                raise
            dump({"line": number, "cmd": cmd, "result": result}, compact)


def dump(value, compact):
    if compact:
        print(json.dumps(value, ensure_ascii=False))
    else:
        print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))


def main(argv):
    parser = argparse.ArgumentParser(
        prog="objekat_cli.py",
        description="Drives OBJEKAT through its command socket.",
        epilog="The command's parameters are passed as --key value.",
    )
    parser.add_argument("command", nargs="?", help="the command name (e.g. transport.play)")
    parser.add_argument("--socket", default=DEFAULT_SOCKET, help="path of the UNIX socket")
    parser.add_argument("--batch", metavar="FILE.jsonl", help="replay a file of commands")
    parser.add_argument("--compact", action="store_true", help="output on a single line")
    parser.add_argument("--timeout", type=float, default=120.0, help="socket timeout in seconds")
    known, rest = parser.parse_known_args(argv)

    if not known.command and not known.batch:
        parser.print_help()
        return 2

    try:
        client = ObjekatClient(known.socket, timeout=known.timeout).connect()
    except (FileNotFoundError, ConnectionRefusedError, OSError) as error:
        sys.stderr.write(
            "cannot connect on %s: %s\n"
            "Is the API enabled? (Settings ▸ Command API, or launch with --api)\n"
            % (known.socket, error)
        )
        return 3

    try:
        if known.batch:
            run_batch(client, known.batch, known.compact)
        else:
            run_single(client, known.command, rest, known.compact)
    except ObjekatError as error:
        sys.stderr.write("%s\n" % error)
        if error.details:
            sys.stderr.write(json.dumps(error.details, ensure_ascii=False, indent=2) + "\n")
        return 1
    except ConnectionError as error:
        sys.stderr.write("%s\n" % error)
        return 3
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
