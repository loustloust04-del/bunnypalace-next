#!/bin/bash
# mac-only entry; all ownership, proof reuse, deadlines and load gates live in Python.
# Usage: mac-perf-run.sh run|aa|baseline|resume|analyze [arguments; see --help]
set -eu
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$HERE/mac-perf-run.py" "$@"
