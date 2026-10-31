#!/usr/bin/env python3
"""What the desktops actually did -- read from exec.jsonl, no model involved.

THIS IS THE CONSUMER THE LOG EXISTS FOR. A log with no reader is a log nobody checks, and we
have one of those already: usage.log ran for 23 days and 12,158 rows before anyone asked it a
question it could answer.

Four questions, chosen as the ones that decide what gets built next:
  1. WHERE DOES DESKTOP TIME GO?          tool latency, waits, retries
  2. WHAT ACTUALLY FAILS?                 and is it perception, targeting, or contention
  3. HOW REPETITIVE IS THE WORK?          at TASK level and at SUBTASK level -- the second is
                                          the one a task-level view alone cannot see, and the
                                          reason `goal` had to be recorded at the time
  4. HOW OFTEN IS INTELLIGENCE NEEDED?    what share was already fully deterministic

Deliberately a script over a file, not a metrics platform. If the answers say a deterministic
sequence library is worth building, THAT is when something bigger earns its place.
"""
import json, sys, collections, os
from pathlib import Path

LOG = Path(os.environ.get("EXEC_LOG", Path.home() / ".fleet" / "desktops" / "exec.jsonl"))
rows = []
for line in LOG.read_text().splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except ValueError:
        continue          # a torn line from a concurrent append is not a reason to die

if not rows:
    print("no records yet -- agents need to run some desktop commands first"); sys.exit(0)

def pct(n, d): return (100.0 * n / d) if d else 0.0
def p(vals, q):
    if not vals: return 0
    v = sorted(vals); return v[min(len(v) - 1, int(len(v) * q))]

print("=" * 72)
print("DESKTOP EXECUTION REPORT   %d records   %s -> %s"
      % (len(rows), rows[0]["ts"][:16], rows[-1]["ts"][:16]))
print("=" * 72)

# ---- 1. where does the time go -------------------------------------------
print("\n1. WHERE DOES THE TIME GO")
by = collections.defaultdict(list)
for r in rows:
    by[r["cmd"]].append(r.get("work_ms") or 0)
total = sum(sum(v) for v in by.values())
print("   %-12s %6s %9s %8s %8s %8s" % ("cmd", "n", "total_s", "mean", "p50", "p90"))
for cmd, v in sorted(by.items(), key=lambda kv: -sum(kv[1]))[:14]:
    print("   %-12s %6d %9.1f %7dms %7dms %7dms"
          % (cmd, len(v), sum(v) / 1000.0, sum(v) / len(v), p(v, .5), p(v, .9)))
print("   %-12s %6d %9.1f   (settle/waiting excluded from work_ms)"
      % ("TOTAL", len(rows), total / 1000.0))

# ---- 2. what fails --------------------------------------------------------
print("\n2. WHAT ACTUALLY FAILS")
# Fold case: rows written before the vocabulary was normalised used CHANGED/
# NOCHANGE. A field with two spellings is a field you have to clean before you can count it.
oc = collections.Counter((r.get("outcome") or "?").lower() for r in rows)
for k, n in oc.most_common():
    print("   %-10s %5d  %5.1f%%" % (k, n, pct(n, len(rows))))
# rc is the load-bearing part: these codes mean specific, different things.
MEAN = {2: "read the page, nothing matched (targeting)",
        3: "could not read the page at all (perception)",
        4: "ambiguous -- refused rather than guess",
        6: "viewport unusable, coordinates would lie",
        75: "another agent holds the desktop (contention)",
        1: "general failure"}
rcs = collections.Counter(r["rc"] for r in rows if r.get("rc"))
if rcs:
    print("   failure codes:")
    for rc, n in rcs.most_common():
        print("     rc=%-3s %4d  %s" % (rc, n, MEAN.get(rc, "?")))

# ---- 3. repetition, at BOTH levels ---------------------------------------
print("\n3. HOW REPETITIVE IS THE WORK")
goals = collections.Counter(r["goal"] for r in rows if r.get("goal"))
print("   TASK level -- distinct goals: %d over %d labelled actions"
      % (len(goals), sum(goals.values())))
unlabelled = sum(1 for r in rows if not r.get("goal"))
if unlabelled:
    print("   ** %d of %d actions (%.0f%%) carry NO goal -- subtask repetition cannot be"
          % (unlabelled, len(rows), pct(unlabelled, len(rows))))
    print("      measured for those. Agents must run: desktop.sh goal \"<what you are doing>\"")
for g, n in goals.most_common(8):
    print("     %4dx  %s" % (n, g[:60]))

# SUBTASK level: sequences of SEMANTIC steps within one goal. `find -> click -> read` is the
# house style and means nothing; `activate button "Continue"` inside goal X, recurring, is a
# candidate for a deterministic sequence.
print("\n   SUBTASK level -- recurring semantic sequences within a goal:")
streams = collections.defaultdict(list)
for r in rows:
    if not r.get("goal"):
        continue
    step = r["cmd"]
    if r.get("target_role"):
        step += ":%s[%s]" % (r["target_role"], (r.get("target_name") or "")[:24])
    streams[(r["agent"], r["desktop"], r["goal"])].append(step)
found = False
for N in (3, 4):
    c = collections.Counter()
    for seq in streams.values():
        for i in range(len(seq) - N + 1):
            c[tuple(seq[i:i + N])] += 1
    rep = [(k, v) for k, v in c.items() if v > 1]
    if not rep:
        continue
    found = True
    print("     %d-step sequences seen more than once: %d" % (N, len(rep)))
    for k, v in sorted(rep, key=lambda kv: -kv[1])[:5]:
        print("       %3dx  %s" % (v, " -> ".join(k)[:88]))
if not found:
    print("     none yet -- needs more labelled runs. THIS IS THE NUMBER THAT DECIDES")
    print("     whether a deterministic skill library is worth building at all.")

# ---- 4. how much needed intelligence -------------------------------------
print("\n4. HOW OFTEN WAS INTELLIGENCE ACTUALLY NEEDED")
ds = collections.Counter(r.get("decision_source") or "?" for r in rows)
for k, n in ds.most_common():
    print("   %-15s %5d  %5.1f%%" % (k, n, pct(n, len(rows))))
det = ds.get("deterministic", 0)
print("   -> %.1f%% of actions needed no model at all." % pct(det, len(rows)))
print("      Any case for a faster decision model has to beat that baseline,")
print("      not the cost of the model it replaces.")
print()
