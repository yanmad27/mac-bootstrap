#!/usr/bin/env bash
# Exercises the real receiver functions of install.sh standalone (the Linux install is a stub).
# usage: recv-harness.sh <install.sh> <target-user-or-empty> <timeout>
# The harness deletes only the final `main "$@"` line, sources the rest, and calls wait_for_handoff.
set -u
SRC=$1; TU=${2:-}; TMO=${3:-30}
tmp=$(mktemp); grep -v '^main "\$@"$' "$SRC" >"$tmp"
# shellcheck disable=SC1090
source "$tmp"; rm -f "$tmp"
set +e
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
OS_KIND=linux; TARGET_USER_ARG=$TU; HANDOFF_TIMEOUT=$TMO
target_resolve
echo "harness: target user=$TARGET_USER uid=$TARGET_UID home=$TARGET_HOME euid=$EUID"
if wait_for_handoff; then
  echo "harness: RESULT received; TS_KEY=$(setstate "$B_TS$TS_KEY") TS_TAGS=$(setstate "$TS_TAGS_V") GH_TOK=$(setstate "$GH_TOK") GIT_NAME=$(setstate "$GIT_NAME") GIT_EMAIL=$(setstate "$GIT_EMAIL")"
  echo "harness: lengths ts=${#TS_KEY} gh=${#GH_TOK} tags=$TS_TAGS_V"
  case $TS_KEY in tskey-auth-*) echo "harness: ts key has tskey-auth- prefix" ;; esac
else
  echo "harness: RESULT none"
fi
inbox_cleanup
ls -la "$TARGET_HOME/.cache/mac-bootstrap/inbox" 2>&1 | sed 's/^/harness: inbox after: /'
