#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cross-project paste (tabs INC2) — copy in one tab, paste in ANOTHER.

What it is out to prove, beyond the commands answering: that `CrossProjectImport` never reads
or corrupts the TARGET tab's own state, even in the worst case the mission calls out by name —
two tabs sharing UUIDs (a "V1/V2" pair, born from `project.save_as` renaming a project in place
and the OLD path then reopened as its own, separate tab). Concretely:

  - a plugin's pasted parameter comes from the CLIPBOARD's frozen state, never from whatever the
    TARGET's own, same-numbered plugin happens to hold live (the exact `copiedPlugins`/
    `getPluginStateXML`/`update(id:)` pitfall the mission names);
  - the target's own object, AT THE SAME ID the source also happens to use, is completely
    UNTOUCHED by the paste;
  - a plugin link INSIDE the copied batch survives the trip, remapped onto a NEW, batch-only
    group;
  - a send to an aux OUTSIDE the copied batch is dropped rather than left dangling;
  - a stem assignment is forced back onto the Main;
  - a consolidated object becomes a brand-new definition;
  - the whole paste is ONE undo step.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay (ROOT is a scratch folder for the project fixtures; it need not exist yet)
    ./scenario_cross_paste.py /tmp/o.sock /tmp/trial_cross_paste

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

SOCK, ROOT = sys.argv[1], sys.argv[2]
BIP = os.path.join(HERE, "fixtures", "bip.wav")

SRC_JSON = os.path.join(ROOT, "src", "src.objekat.json")
SRC2_JSON = os.path.join(ROOT, "src", "src_v2.objekat.json")
for p in (SRC_JSON, SRC2_JSON):
    os.makedirs(os.path.dirname(p), exist_ok=True)

fails = []
total = 0


def check(label, ok, detail=""):
    global total
    total += 1
    print(("ok    " if ok else "FAIL  ") + label + ("" if ok else "   " + str(detail)))
    if not ok:
        fails.append(label)


def approx(a, b, eps=1e-3):
    return abs(a - b) < eps


with ObjekatClient(SOCK, timeout=180) as c:

    def cmd(cmd_name, **params):
        return c.send(cmd_name, params or None)

    def tabs():
        return cmd("tab.list")["tabs"]

    def active_tab_id():
        return cmd("app.info")["active_tab"]

    def objects_by_parent(parent_id):
        return [o for o in cmd("object.list")["objects"] if o.get("parent") == parent_id]

    def plugin_link_group(host, plugin_id):
        for pl in cmd("plugin.list", host=host)["plugins"]:
            if pl["id"] == plugin_id:
                return pl.get("link_group")
        return None

    # ── build the SOURCE project (a group with two linked plugins, an internal send to an ──
    #    aux inside it, a send to an aux OUTSIDE it (must be dropped), a stem assignment (must
    #    be forced back to the Main), and a standalone consolidated clip ──────────────────────
    cmd("project.new")
    oa = cmd("object.add", path=BIP, lane=0, start=0)["id"]
    ob = cmd("object.add", path=BIP, lane=1, start=0)["id"]

    p1 = cmd("plugin.add", host=oa, identifier="4bandEq")["plugin"]["id"]
    p1_params = cmd("plugin.get_params", plugin=p1)["params"]
    check("the built-in EQ answers with at least one parameter", len(p1_params) >= 1)
    lo, hi = p1_params[0]["min"], p1_params[0]["max"]
    V_ORIG = lo + (hi - lo) * 0.2
    cmd("plugin.set_param", plugin=p1, index=0, value=V_ORIG)

    # "from" is a Python keyword: passed positionally via **kwargs instead.
    linked = cmd("plugin.link", **{"from": oa, "plugin": p1, "to": ob})
    p2 = linked["plugins"][0]
    group_v1_link = plugin_link_group(oa, p1)
    check("the source plugin carries a link group", group_v1_link is not None)
    check("the linked copy shares that same group",
          plugin_link_group(ob, p2) == group_v1_link)

    aux_inside = cmd("aux.create", start=0, end=4, lane=2)["id"]
    cmd("send.set_level", id=oa, aux=aux_inside, db=-3)

    aux_outside = cmd("aux.create", start=0, end=4, lane=6)["id"]
    cmd("send.set_level", id=ob, aux=aux_outside, db=-5)

    stem_id = cmd("stem.add", name="TestStem")["id"]

    group_id = cmd("group.create", ids=[oa, ob, aux_inside])["id"]
    cmd("stem.assign", stem=stem_id, ids=[group_id])
    check("the group is on the test stem before the copy",
          cmd("object.get", id=group_id).get("stem") == stem_id)

    cmd("project.save_as", path=SRC_JSON)

    ids_before_consolidate = {o["id"] for o in cmd("object.list")["objects"]}
    oc_clip = cmd("object.add", path=BIP, lane=5, start=10)["id"]
    job = cmd("consolidate.make", id=oc_clip)["job_id"]
    # `consolidate.make` on a LONE clip wraps it in a fresh one-item group FIRST (synchronously),
    # and it is that WRAPPER's id — not the clip's own — that survives as the top-level
    # consolidated placement once the render lands (@see consolidateWrappingClip/finishConsolidate).
    # The wrapper starts COLLAPSED, so its child (`oc_clip`) is not even in `object.list` (it only
    # flattens what `laneEntries` shows) — the wrapper is simply the one new TOP-LEVEL id.
    oc = next(o["id"] for o in cmd("object.list")["objects"]
             if o["id"] not in ids_before_consolidate and o["id"] != oc_clip)
    cmd("job.wait", id=job, timeout_ms=30000)
    cmd("wait_idle", timeout_ms=10000)
    def_id = cmd("object.get", id=oc).get("definition")
    check("consolidating oc produced a definition", def_id is not None)
    cmd("project.save")  # persist the group/links/sends/stem/definition to SRC_JSON

    # ── the V1/V2 fork: rename the live tab (save_as, in place — tab count unchanged), then ──
    #    reopen the OLD path as a genuinely separate tab. Both now carry the SAME UUIDs for ──
    #    oa/ob/p1/p2/aux_inside/aux_outside/group_id/oc/def_id. ──────────────────────────────
    cmd("project.save_as", path=SRC2_JSON)
    tab_v2 = active_tab_id()  # the renamed tab: this is the PASTE TARGET from here on
    opened = cmd("tab.open", path=SRC_JSON)
    check("tab.open on the pre-rename path creates a genuinely separate tab",
          opened["already_open"] is False)
    tab_v1 = opened["id"]
    check("V1 is now active", active_tab_id() == tab_v1)
    check("V1 and V2 are two distinct tabs", tab_v1 != tab_v2 and len(tabs()) == 2)

    # ── copy, in V1 ──────────────────────────────────────────────────────────────────────────
    cmd("selection.set", ids=[group_id, oc])
    copied = cmd("clipboard.copy")
    check("the copy picked up both top-level entries", copied.get("copied") == 2)

    # ── switch to V2 (the target) and mutate ITS OWN plugin at the SAME id p1 BEFORE pasting: ─
    #    if the paste ever read the TARGET's live engine by this id (the pitfall the mission ──
    #    names), the pasted plugin would come back with V_TARGET instead of the frozen V_ORIG ──
    cmd("tab.select", id=tab_v2)
    check("V2 is active", active_tab_id() == tab_v2)
    V_TARGET = lo + (hi - lo) * 0.9
    cmd("plugin.set_param", plugin=p1, index=0, value=V_TARGET)

    objects_before = {o["id"] for o in cmd("object.list")["objects"]}

    # Land the paste far from the target's own content: V1 and V2 are IDENTICAL at this point
    # (the whole point of the fork), so pasting at the clipboard's own origin position would have
    # `resolveOverlaps` — correctly — overwrite the target's own, perfectly-overlapping material.
    # That would be an ordinary "paste on top of something" outcome, not a bug, but it would also
    # defeat this test's actual purpose (proving `plan()`/the apply step never touch what they
    # don't have to) — so the selection is aimed at empty ground instead.
    cmd("timesel.set", start=100, end=104, lane=20, lane_count=3)
    pasted = cmd("clipboard.paste")
    check("the paste reports exactly two new top-level ids", pasted.get("count") == 2)
    new_ids = pasted["ids"]
    check("no pasted id collides with anything the target already had",
          all(i not in objects_before for i in new_ids))

    all_objects = cmd("object.list")["objects"]
    new_group = next((o for o in all_objects if o["id"] in new_ids and o["kind"] == "group"), None)
    new_oc = next((o for o in all_objects if o["id"] in new_ids and o["id"] != (new_group or {}).get("id")), None)
    check("a new group and a new clip were both placed", new_group is not None and new_oc is not None)

    if new_group:
        cmd("group.expand", id=new_group["id"], expanded=True)
    children = objects_by_parent(new_group["id"]) if new_group else []
    check("the pasted group has exactly three children (oa, ob, the inside aux)", len(children) == 3)
    # `object.list` (unlike `object.get`) does not carry `plugins` — fetched per child instead.
    clip_children = [cmd("object.get", id=ch["id"]) for ch in children if ch["kind"] == "clip"]
    new_aux = next((o for o in children if o["kind"] == "aux"), None)
    new_oa = next((o for o in clip_children if o.get("plugins")), None)
    new_ob = next((o for o in clip_children if o["id"] != (new_oa or {}).get("id")), None)
    check("the three expected kinds are all there",
          new_oa is not None and new_ob is not None and new_aux is not None)

    # ── the plugin state travelled FROZEN, not read from the target's live instance ─────────
    if new_oa:
        new_p1 = new_oa["plugins"][0]["id"]
        check("a fresh plugin id was issued", new_p1 != p1)
        pasted_value = cmd("plugin.get_params", plugin=new_p1)["params"][0]["value"]
        check("the pasted plugin carries the SOURCE's frozen value, not the target's live one",
              approx(pasted_value, V_ORIG) and not approx(pasted_value, V_TARGET),
              "got %s (expected ~%s, source-live mutation was %s)" % (pasted_value, V_ORIG, V_TARGET))

    # ── the target's OWN object, at the SAME id the source also used, is untouched ──────────
    still_v_target = cmd("plugin.get_params", plugin=p1)["params"][0]["value"]
    check("the target's own plugin (same id as the source's) kept ITS OWN value: no corruption",
          approx(still_v_target, V_TARGET))
    target_group_after = cmd("object.get", id=group_id)
    check("the target's own group is still on its own stem, untouched",
          target_group_after.get("stem") == stem_id)

    # ── the internal link survived, remapped to a NEW group — never the source's own id ─────
    if new_oa and new_ob:
        new_p1_group = plugin_link_group(new_oa["id"], new_oa["plugins"][0]["id"])
        new_p2_group = plugin_link_group(new_ob["id"], new_ob["plugins"][0]["id"])
        check("the two pasted plugins are linked to EACH OTHER",
              new_p1_group is not None and new_p1_group == new_p2_group)
        check("...through a BRAND NEW group, never the source's own",
              new_p1_group != group_v1_link)

    # ── the internal send (to the aux INSIDE the batch) was remapped, not dropped ───────────
    if new_oa and new_aux:
        new_sends = new_oa.get("sends", [])
        check("the send to the INSIDE aux was remapped onto the pasted aux",
              any(s["aux"] == new_aux["id"] for s in new_sends))

    # ── the send to the aux OUTSIDE the batch was dropped entirely ──────────────────────────
    if new_ob:
        check("the send to the OUTSIDE aux was dropped, not left dangling",
              len(new_ob.get("sends", [])) == 0)

    # ── stems forced to the Main ─────────────────────────────────────────────────────────────
    check("the pasted group carries no stem (forced to the Main)",
          new_group is not None and "stem" not in new_group)
    for ch in children:
        check("pasted child '%s' carries no stem either" % ch["id"], "stem" not in ch)

    # ── the consolidated object became a NEW definition ─────────────────────────────────────
    if new_oc:
        new_def = new_oc.get("definition")
        check("the pasted consolidated object carries a definition", new_def is not None)
        check("...and it is a BRAND NEW one, never the source's", new_def != def_id)

    # ── ONE undo point for the whole paste ──────────────────────────────────────────────────
    cmd("edit.undo")
    after_undo = {o["id"] for o in cmd("object.list")["objects"]}
    check("a single undo removes the WHOLE pasted batch, nothing more, nothing less",
          after_undo == objects_before)
    still_target_untouched = cmd("plugin.get_params", plugin=p1)["params"][0]["value"]
    check("the target's own plugin is still exactly as the mutation left it, after the undo",
          approx(still_target_untouched, V_TARGET))

print("\n%d assertion(s), %s" % (total, "ALL PASS" if not fails else "%d FAILED: %s" % (len(fails), fails)))
sys.exit(1 if fails else 0)
