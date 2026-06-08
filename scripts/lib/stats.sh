#!/usr/bin/env bash
# Statistical helpers shared by the benchmark modules.
#
# All numeric samples are reduced to a JSON summary object with
# count/min/median/mean/p95/p99/max/stddev so the thesis can report
# distributions rather than single means.

# stats_json: read whitespace/newline separated numbers from stdin, echo a
# compact JSON summary object. Non-numeric tokens are ignored. Empty input
# yields {"count":0}.
stats_json() {
    local _prog
    _prog="$(cat <<'PY'
import sys, json, math

vals = []
for tok in sys.stdin.read().split():
    try:
        vals.append(float(tok))
    except ValueError:
        continue

if not vals:
    print(json.dumps({"count": 0}))
    sys.exit(0)

vals.sort()
n = len(vals)

def pct(p):
    if n == 1:
        return vals[0]
    k = (n - 1) * (p / 100.0)
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return vals[int(k)]
    return vals[lo] * (hi - k) + vals[hi] * (k - lo)

mean = sum(vals) / n
var = sum((x - mean) ** 2 for x in vals) / n
median = pct(50)

def r(x):
    return round(x, 3)

print(json.dumps({
    "count": n,
    "min": r(vals[0]),
    "median": r(median),
    "mean": r(mean),
    "p95": r(pct(95)),
    "p99": r(pct(99)),
    "max": r(vals[-1]),
    "stddev": r(math.sqrt(var)),
}))
PY
)"
    python3 -c "$_prog"
}

# now_ms: current epoch time in milliseconds.
now_ms() {
    date +%s%3N
}
