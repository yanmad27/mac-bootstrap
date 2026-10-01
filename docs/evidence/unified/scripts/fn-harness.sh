#!/usr/bin/env bash
# Sources install.sh without its final `main "$@"` and evals a snippet in that environment (function-level tests).
# usage: fn-harness.sh <install.sh> '<snippet>'
SRC=$1; SNIP=$2
tmp=$(mktemp); grep -v '^main "\$@"$' "$SRC" >"$tmp"
# shellcheck disable=SC1090
source "$tmp"; rm -f "$tmp"; set +e
trap cleanup EXIT
OS_KIND=${OS_KIND:-linux}; TARGET_USER=$(id -un); TARGET_UID=$(id -u); TARGET_HOME=$HOME
eval "$SNIP"
