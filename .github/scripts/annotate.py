"""Turns the end of a failed build log into error annotations, so the reason
shows on the run's summary page (and through the API) without opening logs.

    python3 .github/scripts/annotate.py LOGFILE [TITLE]
"""
import re, sys

path = sys.argv[1]
title = sys.argv[2] if len(sys.argv) > 2 else "Build output"
try:
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    sys.exit(0)

ansi = re.compile(r"\x1b\[[0-9;]*m")
lines = [ansi.sub("", l) for l in lines]
hot = re.compile(r"error|exception|failed|what went wrong|unresolved|cannot find|not found|undefined|isn't defined|expected", re.I)

keep = []
for i, l in enumerate(lines):
    if hot.search(l):
        keep.extend(range(max(0, i - 2), min(len(lines), i + 6)))
keep = sorted(set(keep))[-400:]
picked = [lines[i] for i in keep] if keep else []
tail = lines[-80:]

def emit(chunk, t):
    msg = "\n".join(chunk).replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print(f"::error title={t}::{msg}")

blocks, cur, size = [], [], 0
for l in picked:
    l = l[:400]
    if size + len(l) > 3500 and cur:
        blocks.append(cur); cur, size = [], 0
    cur.append(l); size += len(l) + 1
if cur:
    blocks.append(cur)
for n, b in enumerate(blocks[:7], 1):
    emit(b, f"{title} (errors {n})")
emit([l[:300] for l in tail][-40:], f"{title} (last lines)")
