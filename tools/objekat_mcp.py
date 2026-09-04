#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""An MCP server on top of OBJEKAT's command API.

Exposes every command of the app as an MCP tool, so that an assistant can drive
OBJEKAT knowing nothing of the socket or of the JSON-lines protocol.

WHAT MATTERS HERE: the tool list is **generated from `help`**, never hard-coded.
The app is the single source of truth on what it can do; a list copied out here
would diverge at the first command added, and nobody would notice before a tool
failed in production. Adding a command in the app is enough to expose it.

Usage (the stdio transport, as MCP clients expect):

    ./objekat_mcp.py                       # the default socket
    ./objekat_mcp.py --socket /tmp/o.sock  # or the OBJEKAT_SOCKET variable

Declaration on the MCP client side:

    {"mcpServers": {"objekat": {"command": "/path/to/tools/objekat_mcp.py"}}}

Prerequisite: the app is running with the API enabled (Settings ▸ Command API, or `--api`).
Standard library only, like `objekat_cli.py`.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError, DEFAULT_SOCKET

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "objekat", "version": "1.0.0"}


# -- translating the API's vocabulary into JSON Schema ----------------------

def schema_for(type_name):
    """`ParamSpec.type` → a JSON schema.

    The API's types are deliberately finer than JSON's (`uuid`, `int`): they are widened
    here rather than invented on the MCP side, and the original type is kept in the
    description so that the caller knows what is really expected.
    """
    if type_name.startswith("array<") and type_name.endswith(">"):
        return {"type": "array", "items": schema_for(type_name[6:-1])}
    return {
        "string": {"type": "string"},
        "uuid": {"type": "string"},
        "number": {"type": "number"},
        "int": {"type": "integer"},
        "bool": {"type": "boolean"},
        "object": {"type": "object"},
    }.get(type_name, {})


def tool_name(command):
    """`object.set_gain` → `object_set_gain`.

    MCP tool names do not allow the dot. The reverse correspondence is KEPT in a
    table (and not recomputed): guessing by replacing the `_`s with `.`s would be wrong
    from the first command that already holds a `_`, that is to say almost all of them.
    """
    return command.replace(".", "_")


def tool_from(command):
    """One entry of `help` → one MCP tool."""
    properties = {}
    required = []
    for spec in command.get("params", []):
        schema = dict(schema_for(spec.get("type", "")))
        doc = spec.get("doc", "")
        schema["description"] = "%s (%s)" % (doc, spec.get("type", "?")) if doc else spec.get("type", "")
        properties[spec["name"]] = schema
        if spec.get("required"):
            required.append(spec["name"])

    summary = command.get("summary", "")
    undo = command.get("undo")
    # The effect on undo is part of what a caller must know BEFORE calling: "none"
    # marks a read (or a gesture that cannot be undone), the other two a gesture that leaves an
    # entry on the stack. It is the information that tells an exploration from a modification.
    if undo == "none":
        summary += "  [no effect on undo]"
    elif undo:
        summary += "  [lays an undo entry]"

    return {
        "name": tool_name(command["name"]),
        "description": summary,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required,
        },
    }


# -- the server ------------------------------------------------------------

class MCPServer:

    def __init__(self, socket_path):
        self.socket_path = socket_path
        self.client = None
        self.tools = []
        self.by_tool_name = {}

    # -- connecting to the app --------------------------------------------

    def connect(self):
        """(Re)connects and regenerates the tool catalogue.

        The reconnection is LAZY and redone on every failure: the app can be relaunched
        mid-session (it often is, during development), and an MCP server that
        kept a dead connection would force the client to be restarted every time.
        """
        if self.client is not None:
            try:
                self.client.close()
            except Exception:
                pass
        self.client = ObjekatClient(self.socket_path).connect()
        catalogue = self.client.send("help")
        self.tools = [tool_from(c) for c in catalogue.get("commands", [])]
        self.by_tool_name = {tool_name(c["name"]): c["name"] for c in catalogue.get("commands", [])}

    def ensure_connected(self):
        if self.client is None:
            self.connect()

    def call(self, command, arguments):
        """Sends a command, with ONE reconnection attempt."""
        try:
            self.ensure_connected()
            return self.client.send(command, arguments)
        except (ConnectionError, OSError):
            self.connect()
            return self.client.send(command, arguments)

    # -- JSON-RPC ---------------------------------------------------------

    def handle(self, request):
        """Returns the response to send, or None for a notification."""
        method = request.get("method")
        request_id = request.get("id")
        params = request.get("params") or {}

        # A notification (no `id`) expects NOTHING: answering `notifications/initialized`
        # is a protocol error that some clients report noisily.
        if request_id is None:
            return None

        if method == "initialize":
            return self.ok(request_id, {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": SERVER_INFO,
            })

        if method == "ping":
            return self.ok(request_id, {})

        if method == "tools/list":
            try:
                self.connect()   # re-reads `help`: the app may have changed version in the meantime
            except (ConnectionError, OSError, FileNotFoundError) as error:
                return self.error(request_id, -32000, self.unreachable(error))
            return self.ok(request_id, {"tools": self.tools})

        if method == "tools/call":
            name = params.get("name", "")
            arguments = params.get("arguments") or {}
            try:
                self.ensure_connected()
            except (ConnectionError, OSError, FileNotFoundError) as error:
                return self.error(request_id, -32000, self.unreachable(error))
            command = self.by_tool_name.get(name)
            if command is None:
                return self.error(request_id, -32602, "unknown tool: %s" % name)
            try:
                result = self.call(command, arguments)
            except ObjekatError as failure:
                # A refused command is NOT a server failure: it is a result, which
                # the caller must be able to read (the error code is stable, see the contract's
                # documentation). Hence `isError` rather than a JSON-RPC error, which would mask it.
                # The error object is rebuilt instead of returning `str(failure)`: a caller
                # must be able to branch on `code` without having to take a sentence apart.
                payload = {"code": failure.code, "message": failure.message}
                if failure.details is not None:
                    payload["details"] = failure.details
                return self.ok(request_id, {
                    "content": [{"type": "text",
                                 "text": json.dumps(payload, ensure_ascii=False, indent=2)}],
                    "isError": True,
                })
            except (ConnectionError, OSError) as error:
                return self.error(request_id, -32000, self.unreachable(error))
            return self.ok(request_id, {
                "content": [{"type": "text",
                             "text": json.dumps(result, ensure_ascii=False, indent=2)}],
                "isError": False,
            })

        return self.error(request_id, -32601, "unknown method: %s" % method)

    def unreachable(self, error):
        return ("OBJEKAT unreachable on %s (%s). Is the app running with the API enabled "
                "— Settings ▸ Command API, or --api?" % (self.socket_path, error))

    @staticmethod
    def ok(request_id, result):
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    @staticmethod
    def error(request_id, code, message):
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}

    # -- the stdio loop ---------------------------------------------------

    def serve(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except json.JSONDecodeError:
                continue
            response = self.handle(request)
            if response is None:
                continue
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()


def main(argv):
    socket_path = os.environ.get("OBJEKAT_SOCKET") or DEFAULT_SOCKET
    if "--socket" in argv:
        index = argv.index("--socket")
        if index + 1 >= len(argv):
            sys.stderr.write("--socket expects a path\n")
            return 2
        socket_path = argv[index + 1]
    for token in argv:
        if token.startswith("--socket="):
            socket_path = token.split("=", 1)[1]
    if "--help" in argv or "-h" in argv:
        print(__doc__)
        return 0

    MCPServer(socket_path).serve()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
