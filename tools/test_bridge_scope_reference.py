#!/usr/bin/env python3
"""A Python mirror of BridgeScope (objekat/Shared/BridgeScope.swift), run against the case table
tools/fixtures/bridge_scope_cases.json. It proves the TABLE is right, on any machine (stdlib only);
tools/test_bridge_scope.swift then proves the Swift reads the same table the same way.

    python3 tools/test_bridge_scope_reference.py

The algorithm is the one of docs/plan_sidechain.md §5.5 / §5.10, written independently of the Swift
(ids are the table's short names here, UUIDs there). Exit 0 and "ALL PASS" if every case agrees."""
import json, os, sys

ROOT = "<root>"


class World:
    def __init__(self, nodes):
        self.nodes = nodes
        self.index = {}
        for n in nodes:
            self.index.setdefault(n["id"], n)

    def path(self, id_):
        chain = [id_]
        cur = self.index.get(id_)
        while cur is not None and cur.get("parent") in self.index:
            chain.append(cur["parent"])
            cur = self.index[cur["parent"]]
        return chain[::-1]

    def top(self, id_):
        return self.path(id_)[0]

    def stem_of(self, id_):
        return self.index[self.top(id_)].get("stem")

    def static_refusal(self, r):
        s = self.index.get(r["source"])
        if s is None:
            return "unknownSource"
        h = self.index.get(r["host"])
        if h is None:
            return "unknownHost"
        if s["id"] == h["id"]:
            return "selfSource"
        if s["kind"] == "main":
            return "mainSource"
        if s["kind"] == "aux":
            return "auxSource"
        in_tree = h["kind"] not in ("stem", "main")
        if s["kind"] == "stem":
            if in_tree and self.stem_of(h["id"]) == s["id"]:
                return "ancestorSource"
        elif in_tree and s["id"] in self.path(h["id"])[:-1]:
            return "ancestorSource"
        return None

    def data_graphs(self):
        graphs = {}
        root = Graph()
        top_level = [n for n in self.nodes if n["kind"] in ("object", "group", "aux") and n.get("parent") is None]
        stems = [n for n in self.nodes if n["kind"] == "stem"]
        for s in stems:
            root.touch(s["id"])
        for t in top_level:
            root.touch(t["id"])
        for s in stems:
            for t in top_level:
                if t.get("stem") == s["id"]:
                    root.add(s["id"], t["id"], 0)
                    if t["kind"] == "aux":
                        for o in top_level:
                            if o.get("stem") == s["id"] and o["kind"] != "aux":
                                root.add(t["id"], o["id"], 0)
        for t in top_level:
            st = t.get("stem")
            on_stem = st is not None and st in self.index and self.index[st]["kind"] == "stem"
            if t["kind"] == "aux" and not on_stem:
                for o in top_level:
                    if o["kind"] != "aux":
                        root.add(t["id"], o["id"], 0)
                for s in stems:
                    root.add(t["id"], s["id"], 0)
        graphs[ROOT] = root
        for c in self.nodes:
            if c["kind"] != "group":
                continue
            kids = [n for n in self.nodes if n.get("parent") == c["id"] and n["kind"] in ("object", "group", "aux")]
            if not kids:
                continue
            g = Graph()
            for k in kids:
                g.touch(k["id"])
            for a in kids:
                if a["kind"] == "aux":
                    for o in kids:
                        if o["kind"] != "aux":
                            g.add(a["id"], o["id"], 0)
            graphs[c["id"]] = g
        return graphs

    def key_edge(self, r):
        """(scope, unit, after) or None."""
        s, h = self.index[r["source"]], self.index[r["host"]]
        if h["kind"] == "main":
            return None
        if h["kind"] == "stem":
            if s["kind"] == "stem":
                return (ROOT, h["id"], s["id"])
            if self.stem_of(s["id"]) == h["id"]:
                return None
            return (ROOT, h["id"], self.top(s["id"]))
        if s["kind"] == "stem":
            return (ROOT, self.top(h["id"]), s["id"])
        ph, ps = self.path(h["id"]), self.path(s["id"])
        if ph[0] != ps[0]:
            return (ROOT, ph[0], ps[0])
        d = 0
        while d < len(ph) and d < len(ps) and ph[d] == ps[d]:
            d += 1
        if d >= len(ph) or d >= len(ps):
            return None
        return (ph[d - 1], ph[d], ps[d])


class Graph:
    def __init__(self):
        self.order = []
        self.after = {}

    def touch(self, u):
        if u not in self.after:
            self.after[u] = []
            self.order.append(u)

    def add(self, u, v, w):
        self.touch(u)
        self.touch(v)
        self.after[u].append((v, w))

    def reaches(self, start, target):
        seen, stack = set(), [start]
        while stack:
            u = stack.pop()
            if u == target:
                return True
            if u in seen:
                continue
            seen.add(u)
            stack.extend(v for v, _ in self.after.get(u, []))
        return False

    def ranks(self):
        memo = {}

        def rank(u):
            if u not in memo:
                memo[u] = max([rank(v) + w for v, w in self.after.get(u, [])] or [0])
            return memo[u]

        for u in self.order:
            rank(u)
        return memo


def plan(nodes, routes):
    world = World(nodes)
    out = {"refused": {}, "rootRanks": {}, "auxRanks": {}, "innerRanks": {}, "stemRanks": {}, "readerRanks": {}, "taps": {}}
    ok = []
    for i, r in enumerate(routes):
        why = world.static_refusal(r)
        if why:
            out["refused"][str(i)] = why
        ok.append(why is None)
    graphs = world.data_graphs()
    data_only = world.data_graphs()      # a second, untouched copy of the data edges
    accepted = []
    for i, r in enumerate(routes):
        if not ok[i]:
            continue
        edge = world.key_edge(r)
        if edge is None:
            accepted.append(i)
            continue
        scope, unit, after = edge
        # A key edge the data graph already implies adds a rank and a gate for nothing.
        if data_only.get(scope) is not None and data_only[scope].reaches(unit, after):
            accepted.append(i)
            continue
        g = graphs.setdefault(scope, Graph())
        if g.reaches(after, unit):
            out["refused"][str(i)] = "cycle"
            continue
        g.add(unit, after, 1)
        accepted.append(i)
    ranks = {scope: g.ranks() for scope, g in graphs.items()}

    def rank(u, scope):
        return ranks.get(scope, {}).get(u, 0)

    for n in nodes:
        if n["kind"] in ("stem", "main"):
            continue
        if n.get("parent") is not None:
            r = rank(n["id"], n["parent"])
            if r > 0:
                out["innerRanks"][n["id"]] = r
        else:
            r = rank(n["id"], ROOT)
            if r > 0:
                out["auxRanks" if n["kind"] == "aux" else "rootRanks"][n["id"]] = r
    for i in accepted:
        r = routes[i]
        s, h = world.index[r["source"]], world.index[r["host"]]
        if s["kind"] == "stem":
            out["stemRanks"][s["id"]] = rank(s["id"], ROOT)
        if h["kind"] == "stem":
            out["stemRanks"][h["id"]] = rank(h["id"], ROOT)
        out["taps"][s["id"]] = rank(s["id"], ROOT) if s["kind"] == "stem" else -1
        if h["kind"] == "main":
            hr = 0
        elif h["kind"] == "stem":
            hr = rank(h["id"], ROOT)
        else:
            hr = rank(h["id"], h.get("parent") or ROOT)
        if hr > 0:
            out["readerRanks"][str(i)] = hr
    return out


def candidates(nodes, routes, host, replacing):
    base = list(routes)
    if replacing is not None and 0 <= replacing < len(base):
        del base[replacing]
    res = {}
    for n in nodes:
        if n["id"] == host:
            continue
        p = plan(nodes, base + [{"source": n["id"], "host": host, "consumer": {"kind": "sidechain", "id": "probe"}}])
        res[n["id"]] = p["refused"].get(str(len(base)))
    return res


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "fixtures", "bridge_scope_cases.json")) as f:
        table = json.load(f)
    total = failed = 0
    for c in table["cases"]:
        total += 1
        got = plan(c["nodes"], c["routes"])
        if got != c["expect"]:
            failed += 1
            print("FAIL  " + c["name"])
            for k in c["expect"]:
                if got[k] != c["expect"][k]:
                    print("      %s: expected %r, got %r" % (k, c["expect"][k], got[k]))
        else:
            print("ok    " + c["name"])
        for q in c.get("candidates", []):
            total += 1
            g = candidates(c["nodes"], c["routes"], q["host"], q["replacing"])
            if g != q["expect"]:
                failed += 1
                print("FAIL  %s / candidates for %s (replacing %s): expected %r, got %r" % (c["name"], q["host"], q["replacing"], q["expect"], g))
            else:
                print("ok    %s / candidates for %s (replacing %s)" % (c["name"], q["host"], q["replacing"]))
    print("\n%d checks, %d failed" % (total, failed))
    print("ALL PASS" if failed == 0 else "FAILED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
