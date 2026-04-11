#!/usr/bin/env bash
# discord-reaction-pulse — interval calculator (pure)
#
# Usage:
#   ./interval.sh <progress> [base_interval_sec] [min_interval_sec] [curve]
#
# Prints a single integer (rounded seconds) on stdout. Reads no files,
# writes no files. Safe to call from anywhere.
#
# Formula:
#   p        = clamp(progress / 100, 0, 1)
#   interval = min + (base - min) * (1 - p) ** curve
#
# Defaults: base=300, min=15, curve=1.8

set -eu

progress="${1:-0}"
base="${2:-300}"
min="${3:-15}"
curve="${4:-1.8}"

# Hand the work to awk so we don't depend on `bc` or shell floating point.
awk -v p="$progress" -v base="$base" -v mn="$min" -v c="$curve" '
BEGIN {
    if (p == "" || p ~ /[^0-9.\-]/) p = 0
    if (base == "" || base ~ /[^0-9.\-]/) base = 300
    if (mn == "" || mn ~ /[^0-9.\-]/) mn = 15
    if (c == "" || c ~ /[^0-9.\-]/) c = 1.8

    # Numeric coercion
    p = p + 0; base = base + 0; mn = mn + 0; c = c + 0

    if (p < 0)   p = 0
    if (p > 100) p = 100
    if (base < mn) {            # swap if user inverted them
        tmp = base; base = mn; mn = tmp
    }
    if (mn < 0) mn = 0
    if (c < 0)  c = 0

    pn = p / 100.0
    span = base - mn

    # POSIX awk has no ** operator, so we compute (1-pn)^c via exp/log,
    # carefully handling the pn=0 and pn=1 endpoints (log(0) is undefined).
    if (pn >= 1) {
        factor = 0
    } else if (pn <= 0) {
        factor = 1
    } else {
        factor = exp(c * log(1 - pn))
    }

    interval = mn + span * factor

    # Round to nearest integer
    rounded = int(interval + 0.5)
    if (rounded < mn) rounded = int(mn + 0.5)
    if (rounded < 1)  rounded = 1
    print rounded
}
'
