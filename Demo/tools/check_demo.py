#!/usr/bin/env python3
"""Checks the demo content for broken references, bad dates and writing-rule slips.

    python3 -I Demo/tools/check_demo.py            # structure, references, dates, writing rules
    python3 -I Demo/tools/check_demo.py --network  # also requests every history URL, cookie-free

Exits non-zero if anything fails. Standard library only.
"""
import concurrent.futures
import datetime as dt
import json
import re
import sys
import urllib.request
from pathlib import Path

DEMO = Path(__file__).resolve().parent.parent
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
# En and em dashes, other Unicode dashes and minus, soft hyphen, middle dots and bullets used as separators.
BANNED = re.compile("[‐‑‒–—―−­·•‧・∙]")
DOC_SOURCES = {"google-docs", "google-sheets", "google-slides", "notion"}
KIND_OF_SOURCE = {"note": "note", "granola": "meeting", **{s: "doc" for s in DOC_SOURCES}}

errors = []


def fail(where, msg):
    errors.append(f"{where}: {msg}")


def parse_scalar(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def split_top(s):
    """Splits on commas that aren't inside quotes."""
    out, cur, q = [], "", None
    for c in s:
        if q:
            cur += c
            if c == q:
                q = None
        elif c in "\"'" and not cur.strip():
            q = c
            cur += c
        elif c == ",":
            out.append(cur)
            cur = ""
        else:
            cur += c
    if cur.strip():
        out.append(cur)
    return out


def parse_flow_map(s):
    m = {}
    for part in split_top(s.strip()[1:-1]):
        k, _, v = part.partition(":")
        m[k.strip()] = parse_scalar(v)
    return m


def front_matter(path):
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        fail(path.name, "no front matter")
        return {}, text
    end = text.find("\n---\n", 4)
    head, body = text[4:end], text[end + 5:]
    meta, key = {}, None
    for line in head.split("\n"):
        if not line.strip():
            continue
        if line.startswith("  - "):
            item = line[4:].strip()
            meta.setdefault(key, []).append(parse_flow_map(item) if item.startswith("{") else parse_scalar(item))
            continue
        key, _, v = line.partition(":")
        key, v = key.strip(), v.strip()
        if v.startswith("[") and v.endswith("]"):
            meta[key] = [parse_scalar(x) for x in split_top(v[1:-1])]
        elif v == "":
            meta[key] = []
        else:
            meta[key] = parse_scalar(v)
    return meta, body


def when(where, s):
    try:
        t = dt.datetime.fromisoformat(s)
        if t.tzinfo is None:
            fail(where, f"time without an offset: {s}")
        return t
    except (TypeError, ValueError):
        fail(where, f"not an ISO time: {s!r}")
        return None


def check_writing(where, text):
    for i, line in enumerate(text.split("\n"), 1):
        m = BANNED.search(line)
        if m:
            fail(where, f"line {i} has U+{ord(m.group()):04X}: {line.strip()[:80]}")


def main():
    spaces_doc = json.loads((DEMO / "spaces.json").read_text())
    history = json.loads((DEMO / "history.json").read_text())
    expected = json.loads((DEMO / "expected.json").read_text())
    anchor = dt.datetime.fromisoformat(spaces_doc["anchor"])
    if dt.datetime.fromisoformat(history["anchor"]) != anchor:
        fail("history.json", "anchor differs from spaces.json")
    space_ids = {s["id"] for s in spaces_doc["spaces"]}
    folder_space = {s["notesFolder"]: s["id"] for s in spaces_doc["spaces"]}

    content = {}  # id -> (kind, meta, path)
    stems = {}
    for path in sorted((DEMO / "notes").rglob("*.md")):
        meta, body = front_matter(path)
        where = str(path.relative_to(DEMO))
        for k in ("id", "title", "space", "created", "updated", "tags"):
            if k not in meta:
                fail(where, f"missing {k}")
        if folder_space.get(path.parent.name) != meta.get("space"):
            fail(where, f"space {meta.get('space')} doesn't match folder {path.parent.name}")
        if path.stem != meta.get("title"):
            fail(where, "file name and title differ")
        heading = next((l for l in body.split("\n") if l.strip()), "")
        if heading != f"# {meta.get('title')}":
            fail(where, "first line isn't a # heading with the title")
        c, u = when(where, meta.get("created")), when(where, meta.get("updated"))
        if c and u and not c <= u <= anchor:
            fail(where, "dates out of order or after the anchor")
        stems[path.stem] = meta.get("id")
        content[meta.get("id")] = ("note", meta, path, body)
        check_writing(where, path.read_text(encoding="utf-8"))

    for folder, kind in (("docs", "doc"), ("meetings", "meeting")):
        for path in sorted((DEMO / folder).glob("*.md")):
            meta, body = front_matter(path)
            where = str(path.relative_to(DEMO))
            need = ("id", "title", "source", "space", "created", "edited", "owner", "shared_with", "origin_url", "demo_url") if kind == "doc" \
                else ("id", "title", "source", "space", "date", "duration_min", "attendees", "demo_url")
            for k in need:
                if k not in meta:
                    fail(where, f"missing {k}")
            if path.stem != meta.get("id"):
                fail(where, "file name and id differ")
            if KIND_OF_SOURCE.get(meta.get("source")) != kind:
                fail(where, f"source {meta.get('source')} doesn't belong in {folder}/")
            if meta.get("demo_url") != f"demo://{meta.get('source')}/{meta.get('id')}":
                fail(where, "demo_url should be demo://<source>/<id>")
            heading = next((l for l in body.split("\n") if l.strip()), "")
            if not heading.startswith("# "):
                fail(where, "first line isn't a # heading")
            if kind == "doc":
                c, e = when(where, meta.get("created")), when(where, meta.get("edited"))
                if c and e and not c <= e <= anchor:
                    fail(where, "dates out of order or after the anchor")
            else:
                d = when(where, meta.get("date"))
                if d and d > anchor:
                    fail(where, "meeting after the anchor")
                if d and d.weekday() >= 5:
                    fail(where, f"meeting falls on a {d.strftime('%A')}")
                for a in meta.get("attendees", []):
                    if not isinstance(a, dict) or "name" not in a:
                        fail(where, f"attendee isn't a {{name, role}} map: {a}")
                if "## Action items" not in body or "## Transcript excerpt" not in body:
                    fail(where, "needs Action items and Transcript excerpt sections")
            if meta.get("id") in content:
                fail(where, f"duplicate id {meta.get('id')}")
            content[meta.get("id")] = (kind, meta, path, body)
            check_writing(where, path.read_text(encoding="utf-8"))

    for cid, (kind, meta, path, body) in content.items():
        if meta.get("space") not in space_ids:
            fail(str(path.relative_to(DEMO)), f"unknown space {meta.get('space')}")
        for link in re.findall(r"\[\[([^\]|#]+)", body):
            if link.strip() not in stems:
                fail(str(path.relative_to(DEMO)), f"wikilink to a missing note: [[{link}]]")

    # History
    start = anchor - dt.timedelta(days=43)
    pages = {}
    for p in history["pages"]:
        where = f"history.json {p['id']}"
        if p["id"] in pages or p["id"] in content:
            fail(where, "duplicate id")
        pages[p["id"]] = p
        if p["space"] not in space_ids:
            fail(where, f"unknown space {p['space']}")
        times = [when(where, v) for v in p["visits"]]
        if None in times:
            continue
        if times != sorted(times) or p["visitCount"] != len(times):
            fail(where, "visits unsorted or visitCount wrong")
        if p["firstVisit"] != p["visits"][0] or p["lastVisit"] != p["visits"][-1]:
            fail(where, "firstVisit or lastVisit doesn't match visits")
        if times[0] < start or times[-1] >= anchor:
            fail(where, "visit outside the six weeks before the anchor")
        if not p.get("excerpt"):
            fail(where, "no excerpt")
        if p.get("excerptSource") not in ("page", "written"):
            fail(where, "excerptSource should be page or written")
    for s in history["searches"]:
        if s["led_to"] and s["led_to"] not in pages:
            fail("history.json searches", f"led_to points nowhere: {s['led_to']}")
        when("history.json searches", s["at"])
    check_writing("history.json about", history["about"])

    every = {**{k: v[0] for k, v in content.items()}, **{k: "web" for k in pages}}

    # Spaces
    item_ids, placed = set(), {}

    def item(where, it):
        if it["id"] in item_ids:
            fail(where, f"duplicate item id {it['id']}")
        item_ids.add(it["id"])
        if every.get(it["ref"]) != it["kind"]:
            fail(where, f"{it['id']} points at {it['ref']}, which isn't a {it['kind']}")
        if it["ref"] in placed:
            fail(where, f"{it['ref']} is placed twice ({placed[it['ref']]} and {it['id']})")
        placed[it["ref"]] = it["id"]

    for it in spaces_doc["essentials"]:
        item("essentials", it)
    for s in spaces_doc["spaces"]:
        where = f"spaces.json {s['id']}"
        own = set()
        for it in s["pinned"] + s["tabs"] + [i for f in s["folders"] for i in f["items"]]:
            item(where, it)
            own.add(it["id"])
        splits = {}
        for sp in s["splits"]:
            item(where, sp["left"])
            item(where, sp["right"])
            own |= {sp["left"]["id"], sp["right"]["id"]}
            splits[sp["id"]] = sp
            if sp["focus"] not in ("left", "right") or not 0.2 <= sp["ratio"] <= 0.8:
                fail(where, f"split {sp['id']} has a bad focus or ratio")
        sel = s["selected"]
        if "split" in sel and sel["split"] not in splits:
            fail(where, "selected split doesn't exist")
        if "item" in sel and sel["item"] not in own:
            fail(where, "selected item isn't in this space")
        if not re.fullmatch(r"#[0-9A-F]{6}", s["color"]):
            fail(where, "colour should be #RRGGBB")
        check_writing(where, s["name"] + " " + " ".join(f["name"] for f in s["folders"]))
    f = spaces_doc["focus"]
    sp = next((x for s in spaces_doc["spaces"] if s["id"] == f["space"] for x in s["splits"] if x["id"] == f.get("split")), None)
    if spaces_doc["currentSpace"] != f["space"] or not sp or sp[f["pane"]]["id"] != f["item"]:
        fail("spaces.json focus", "doesn't match the current space's split and pane")
    check_writing("spaces.json about", spaces_doc["about"])

    # Expected
    for g in expected["nearDuplicateGroups"]:
        for r in g["items"] + [g["prefer"]]:
            if r not in every:
                fail(f"expected.json {g['id']}", f"unknown ref {r}")
    for d in expected["distractors"]:
        for r in d["items"]:
            if r not in every:
                fail("expected.json distractors", f"unknown ref {r}")
    case_ids = set()
    for c in expected["cases"]:
        where = f"expected.json {c['id']}"
        if c["id"] in case_ids:
            fail(where, "duplicate case id")
        case_ids.add(c["id"])
        ctx = c["context"]["ref"]
        if every.get(ctx) != c["context"]["kind"]:
            fail(where, f"context {ctx} isn't a {c['context']['kind']}")
        lists = {
            "must": [x["ref"] for x in c["must"]],
            "nice": [x["ref"] for x in c["nice"]],
            "acceptable": c["acceptable"],
            "shouldNotSurface": [x["ref"] for x in c["shouldNotSurface"]],
            "onScreen": c["onScreen"],
        }
        seen = {}
        for name, refs in lists.items():
            for r in refs:
                if r not in every:
                    fail(where, f"{name} has unknown ref {r}")
                if r == ctx:
                    fail(where, f"{name} lists the context itself")
                if r in seen:
                    fail(where, f"{r} is in both {seen[r]} and {name}")
                seen[r] = name
        for x in c["must"] + c["nice"]:
            sec = "docs" if every.get(x["ref"]) in ("note", "doc", "meeting") else "sites"
            if x["section"] != sec:
                fail(where, f"{x['ref']} belongs in {sec}, not {x['section']}")
        for sec in ("docs", "sites"):
            if sum(1 for x in c["must"] if x["section"] == sec) > 3:
                fail(where, f"more than 3 musts in {sec}")
        for group in c["atMostOneOf"]:
            for r in group:
                if r not in every:
                    fail(where, f"atMostOneOf has unknown ref {r}")
            if sum(1 for r in group if lists["must"].count(r)) > 1:
                fail(where, "two items of an atMostOneOf group are both musts")
        check_writing(where, c["description"] + " " + " ".join(x["why"] for x in c["must"] + c["nice"] + c["shouldNotSurface"]))

    for name in ("SCENARIOS.md", "SPEC.md"):
        p = DEMO / name
        if p.exists():
            check_writing(name, p.read_text(encoding="utf-8"))
        else:
            fail(name, "missing")

    if "--network" in sys.argv:
        def get(p):
            req = urllib.request.Request(p["url"], headers={"User-Agent": UA, "Accept": "text/html,application/xhtml+xml"})
            try:
                with urllib.request.urlopen(req, timeout=25) as r:
                    return p["id"], r.status, r.headers.get("Content-Type", "")
            except Exception as e:
                return p["id"], getattr(e, "code", 0), str(e)[:60]
        with concurrent.futures.ThreadPoolExecutor(10) as ex:
            for pid, status, ct in ex.map(get, history["pages"]):
                if status != 200 or "html" not in ct:
                    fail(f"history.json {pid}", f"doesn't load: {status} {ct}")

    kinds = {}
    for k, v in content.items():
        src = v[1].get("source", "note")
        kinds[src] = kinds.get(src, 0) + 1
    visits = sum(p["visitCount"] for p in history["pages"])
    print(f"notes {kinds.get('note', 0)}, google docs {kinds.get('google-docs', 0)}, sheets {kinds.get('google-sheets', 0)}, "
          f"slides {kinds.get('google-slides', 0)}, notion {kinds.get('notion', 0)}, meetings {kinds.get('granola', 0)}")
    print(f"history {len(pages)} pages, {visits} visits, {len(history['searches'])} searches")
    print(f"spaces {len(spaces_doc['spaces'])}, placed items {len(item_ids)}, expected cases {len(case_ids)}")
    if errors:
        print(f"\n{len(errors)} problems:")
        for e in errors:
            print("  " + e)
        return 1
    print("all checks pass" + (" (including network)" if "--network" in sys.argv else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
