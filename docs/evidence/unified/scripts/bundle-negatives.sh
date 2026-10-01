#!/usr/bin/env bash
# Exercises bundle_parse (the receiver's validator) from install.sh with good and hostile bundles.
# DUMMY values only. usage: bundle-negatives.sh <install.sh>
set -u
SRC=$1
tmp=$(mktemp); grep -v '^main "\$@"$' "$SRC" >"$tmp"
# shellcheck disable=SC1090
source "$tmp"; rm -f "$tmp"; set +e
trap cleanup EXIT
echo "bash $BASH_VERSION"
rm -f /tmp/mb-pwned
pass=0; fail=0
enc() { printf 'MB1:%s' "$(base64 | tr -d '\n')"; }
try() { # name expect(0|1) ; bundle on stdin(arg $3)
  local name=$1 want=$2 b=$3 out rc
  out=$(bundle_parse "$b" 2>&1); rc=$?
  # error text must never contain the dummy secret values
  if [[ $out == *DUMMY* ]]; then echo "FAIL $name: error output leaked a value"; fail=$((fail+1)); return; fi
  if ((rc == want)); then pass=$((pass+1)); echo "PASS $name: rc=$rc ${out:+($out)}"; else fail=$((fail+1)); echo "FAIL $name: rc=$rc want=$want ${out}"; fi
}
GOOD='TS_AUTHKEY=tskey-auth-DUMMYminted0001
TS_TAGS=tag:bootstrap
GH_TOKEN=ghp_DUMMYghtoken0001
GIT_USER_NAME=Dummy Person
GIT_USER_EMAIL=dummy@example.invalid
END=1
'
try "valid bundle accepted" 0 "$(printf '%s' "$GOOD" | enc)"
try "valid, no trailing newline" 0 "$(printf '%s' "${GOOD%?}" | enc)"
try "S-L1 truncated bundle (END=1 marker missing) rejected" 1 "$(printf '%s' "${GOOD%END=1?}" | enc)"
try "S-L1 END=1 present but not last (data after END)" 1 "$(printf 'END=1\nTS_TAGS=tag:a\n' | enc)"
try "S-L1 END with a wrong value" 1 "$(printf 'TS_TAGS=tag:a\nEND=2\n' | enc)"
try "S-L1 END only (no data)" 1 "$(printf 'END=1\n' | enc)"
try "S-L1 duplicate END" 1 "$(printf 'TS_TAGS=tag:a\nEND=1\nEND=1\n' | enc)"
bundle_parse "$(printf 'GIT_USER_NAME=a=b\nEND=1\n' | enc)" && [[ $B_NAME == "a=b" ]] && { pass=$((pass+1)); echo "PASS split at the first '=': value 'a=b' kept whole"; } || { fail=$((fail+1)); echo "FAIL first-= split"; }
bundle_parse "$(printf '%s' "$GOOD" | enc)" && [[ -n $B_TS && -n $B_GH && $B_TAGS == tag:bootstrap && $B_NAME == "Dummy Person" && ${#B_EMAIL} -gt 5 ]] && { pass=$((pass+1)); echo "PASS good bundle fills all five variables (lengths ts=${#B_TS} gh=${#B_GH})"; } || { fail=$((fail+1)); echo "FAIL good bundle fields"; }
try "shell metacharacters are inert text (never eval/source)" 0 "$(printf 'GIT_USER_NAME=$(touch /tmp/mb-pwned)`touch /tmp/mb-pwned`\nEND=1\n' | enc)"
[[ ! -e /tmp/mb-pwned ]] && echo "PASS no command substitution happened (/tmp/mb-pwned absent)" || echo "FAIL command executed"
try "wrong prefix" 1 "XB1:AAAA"
try "no prefix" 1 "VFNfQVVUSEtFWT0x"
try "non-base64 characters" 1 "MB1:!!!!@@@@"
try "invalid base64 padding" 1 "MB1:A"
try "empty after prefix" 1 "MB1:"
try "oversized encoded line (> 11000)" 1 "$(head -c 9000 /dev/zero | tr '\0' 'a' | sed 's/^/GIT_USER_NAME=/' | enc)"
try "decoded size 8200 > 8 KiB (encoded < 11000)" 1 "$( { printf 'GIT_USER_NAME='; head -c 8190 /dev/zero | tr '\0' 'a'; printf '\n'; } | enc)"
try "duplicate key" 1 "$(printf 'TS_TAGS=tag:a\nTS_TAGS=tag:b\n' | enc)"
try "unknown key" 1 "$(printf 'TS_AUTHKEY=tskey-auth-DUMMYx\nEVIL=1\n' | enc)"
try "unknown key with a secret-looking name" 1 "$(printf 'ghp_DUMMYleak=1\n' | enc)"
try "CR in a value" 1 "$(printf 'GIT_USER_NAME=Dummy\rPerson\n' | enc)"
try "CRLF line endings" 1 "$(printf 'TS_TAGS=tag:bootstrap\r\n' | enc)"
try "NUL byte" 1 "$(printf 'GIT_USER_NAME=Dum\000my\n' | enc)"
try "empty line inside" 1 "$(printf 'TS_TAGS=tag:a\n\nGH_TOKEN=ghp_DUMMYx\n' | enc)"
try "line without '='" 1 "$(printf 'ghp_DUMMYtokenonly\n' | enc)"
try "OAuth tskey-client- in TS_AUTHKEY (never leaves the client)" 1 "$(printf 'TS_AUTHKEY=tskey-client-DUMMYcid-DUMMYsecret\n' | enc)"
try "TS_AUTHKEY not tskey-auth-" 1 "$(printf 'TS_AUTHKEY=tskey-api-DUMMYx\n' | enc)"
try "TS_AUTHKEY with query string" 1 "$(printf 'TS_AUTHKEY=tskey-auth-DUMMYx?ephemeral=true\n' | enc)"
try "bad tag (uppercase)" 1 "$(printf 'TS_TAGS=tag:Bad\n' | enc)"
try "bad GH_TOKEN characters" 1 "$(printf 'GH_TOKEN=ghp_DUMMY x\n' | enc)"
try "control character in git name" 1 "$(printf 'GIT_USER_NAME=Dum\001my\n' | enc)"
try "git name > 200" 1 "$(printf 'GIT_USER_NAME=%0300d\n' 0 | enc)"
try "bad email" 1 "$(printf 'GIT_USER_EMAIL=not-an-email\n' | enc)"
try "empty value for a key" 1 "$(printf 'GH_TOKEN=\n' | enc)"
echo "bundle_parse results: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
