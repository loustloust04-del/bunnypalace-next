#!/bin/bash
# Same-package A/A is default; --abba selects two-package A1 B1 B2 A2.
# Usage: mac-perf-abba.sh [--abba] --app A.app --isolation-proof proof.json ...
set -eu
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MODE=aa
if [ "${1:-}" = --abba ]; then MODE=abba; shift; fi
exec python3 "$HERE/mac-perf-run.py" "$MODE" "$@"
