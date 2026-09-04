#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""An example third-party script for OBJEKAT.

Shows the complete contract, and nothing more:
  • the app supplies the socket path through the OBJEKAT_SOCKET variable;
  • the script runs in ITS OWN process — so it cannot bring the engine down;
  • it connects, works, writes its result, and exits.

To be copied into ~/Library/Application Support/Objekat/Plugins/<your-script>/ .
"""

import json
import os
import socket
import subprocess
import sys

SOCK = os.environ.get("OBJEKAT_SOCKET")
HERE = os.environ.get("OBJEKAT_PLUGIN_DIR") or os.path.dirname(os.path.abspath(__file__))


class Objekat:
    """A minimal JSON-lines client — deliberately copied out rather than imported: a third-party
    script must depend only on the socket, not on the layout of OBJEKAT's repository."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(60)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 0

    def send(self, cmd, params=None):
        self.next_id += 1
        request = {"id": self.next_id, "cmd": cmd}
        if params:
            request["params"] = params
        self.sock.sendall(json.dumps(request).encode("utf-8") + b"\n")
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed by the application")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        response = json.loads(line)
        if not response.get("ok"):
            raise RuntimeError(response.get("error"))
        return response["result"]


def main():
    if not SOCK:
        sys.stderr.write("OBJEKAT_SOCKET missing: run this script from the Scripts menu.\n")
        return 2

    detail = "--detail" in sys.argv
    app = Objekat(SOCK)

    info = app.send("app.info")
    census = app.send("perf.census")
    stems = app.send("stem.list")

    lines = ["REPORT — %s" % info.get("project_name", "?"), ""]
    lines.append("File      : %s" % (info.get("project_path") or "never saved"))
    lines.append("Modified  : %s" % ("yes" if info.get("dirty") else "no"))
    lines.append("")
    counts = census["objects"]
    lines.append("Objects   : %d (%s)" % (
        census["objects_total"],
        ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items()) if n)))
    lines.append("Buses     : %d" % census["stems"])
    lines.append("Plugins   : %d (+%d parallel blocks)" % (census["plugins"], census["racks"]))
    lines.append("Sends     : %d" % census["sends"])
    lines.append("MIDI notes: %d" % census["midi_notes"])
    lines.append("Shared    : %d definitions, %d instances"
                 % (census["shared_definitions"], census["shared_placements"]))
    lines.append("")
    for stem in stems["stems"]:
        lines.append("  bus “%s” — %+.1f dB%s%s"
                     % (stem["name"], stem["gain_db"],
                        ", muted" if stem["muted"] else "",
                        "" if stem["route_to_main"] else ", detached from the Main"))

    if detail:
        lines.append("")
        lines.append("OBJECTS")
        for obj in app.send("object.list")["objects"]:
            lines.append("  %-6s lane %-3d %7.2f s → %6.2f s  %+.1f dB  %s"
                         % (obj["kind"], obj["display_lane"], obj["start"],
                            obj["start"] + obj["duration"], obj["volume_db"], obj["name"]))

    path = os.path.join(HERE, "report.txt")
    with open(path, "w", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")
    # The script has no interface: it shows its result by having the system open it.
    subprocess.run(["open", path], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
