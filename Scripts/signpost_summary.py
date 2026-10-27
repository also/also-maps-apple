"""Summarize this app's signpost intervals from `xctrace export` of the
OSSignpostIntervals table: count and duration stats by category and name."""
import collections, statistics, sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
ids = {}

def val(e):
    if e.get("ref"):
        return ids.get(e.get("ref"))
    # Text for numbers, the formatted string for everything else.
    if e.tag in ("start-time", "duration", "event-time") or e.text and e.text.lstrip("-").isdigit():
        v = e.text
    else:
        v = e.get("fmt") or e.text
    if e.get("id"):
        ids[e.get("id")] = v
    return v

rows = []
cols = None
for e in root.iter():
    if e.tag == "schema" and cols is None:
        cols = [c.findtext("mnemonic") for c in e.findall("col")]
    elif e.tag == "row":
        rows.append({c: val(x) for c, x in zip(cols, list(e))})

mine = [r for r in rows if r.get("subsystem") == "com.ryanberdeen.MapVolume"]
by = collections.defaultdict(list)
for r in mine:
    by[(r["category"], r["name"])].append(int(r["duration"]) / 1e6)
print(f"{'category':<7}{'interval':<12}{'count':>6}{'total ms':>10}{'mean':>8}{'p50':>8}{'p95':>8}{'max':>8}")
for (cat, name), d in sorted(by.items(), key=lambda x: -sum(x[1])):
    d.sort()
    print(f"{cat:<7}{name:<12}{len(d):>6}{sum(d):>10.0f}{statistics.mean(d):>8.1f}{d[len(d)//2]:>8.1f}{d[max(0, int(len(d)*.95)-1)]:>8.1f}{d[-1]:>8.1f}")
