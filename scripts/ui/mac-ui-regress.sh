#!/bin/bash
# 只转发参数；门控、隔离、自持进程和收尾由 Python 统一负责。
set -eu
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$HERE/mac-ui-regress.py" "$@"
