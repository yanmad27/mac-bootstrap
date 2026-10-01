#!/usr/bin/env bash
# Function-level check of the shared core with STUB binaries (fake tailscale and gh in a temp dir,
# temp HOME). It never runs the installer for real and never touches the real tailscale/gh/brew.
# DUMMY values only. usage: target-core-stub.sh <install.sh>
set -u
SRC=$1
W=$(mktemp -d /tmp/mbcore.XXXXXX); export HOME=$W/home; mkdir -p "$HOME" "$W/opt/tailscale/bin" "$W/bin"
LOG=$W/calls.log; : >"$LOG"
cat >"$W/opt/tailscale/bin/tailscale" <<STUB
#!/bin/bash
echo "tailscale argv: \$*" >>$LOG
if [ "\$1" = status ]; then echo "{\"BackendState\":\"\${STUB_STATE:-NeedsLogin}\"}"; exit 0; fi
for a in "\$@"; do case \$a in --auth-key=file:*)
  f=\${a#--auth-key=file:}; c=\$(cat "\$f"); m=\$(stat -f %Lp "\$f")
  echo "  key file mode=\$m, \${#c} bytes, starts \${c:0:11}..." >>$LOG
  case \$c in *\\?*) echo "  key file query suffix (inside the file): ?\${c#*\\?}" >>$LOG;; *) echo "  key file has no query suffix" >>$LOG;; esac;; esac; done
STUB
cat >"$W/bin/gh" <<STUB
#!/bin/bash
echo "gh argv: \$*" >>$LOG
case "\$1 \$2" in
  "auth status") exit \${STUB_GH_RC:-1} ;;
  "auth login") t=\$(cat); echo "  gh login stdin: \${#t} bytes, prefix \${t:0:4}..." >>$LOG ;;
esac
exit 0
STUB
ln -s /usr/bin/git "$W/bin/git"; chmod +x "$W/opt/tailscale/bin/tailscale" "$W/bin/gh"
tmp=$(mktemp); grep -v '^main "\$@"$' "$SRC" >"$tmp"
# shellcheck disable=SC1090
source "$tmp"; rm -f "$tmp"; set +e
trap cleanup EXIT
echo "bash $BASH_VERSION  (stubs in $W, never the real tailscale/gh)"
HAVE_BREW=1; PREFIX=$W; TSBIN=$W/opt/tailscale/bin; BREWCMD=$W/bin/brew; OS_KIND=macos
TARGET_USER=$(id -un); TARGET_UID=$(id -u)
show() { sed 's/^/    | /' "$LOG"; : >"$LOG"; }
scn() { echo; echo "=== $*"; }
SKIP_GH_AUTH=1  # keeps maybe_handoff from waiting in the tailscale scenarios

scn "1. TS_AUTHKEY=tskey-auth-... + TS_TAGS (state NeedsLogin)"
TS_KEY=tskey-auth-DUMMYminted0001 TS_TAGS_V=tag:bootstrap; export STUB_STATE=NeedsLogin
step_tailscale_up; show
scn "2. OAuth TS_AUTHKEY=tskey-client-... + TS_TAGS: query string goes INSIDE the file, never argv"
TS_KEY=tskey-client-DUMMYcid-DUMMYoauthsecret0001 TS_TAGS_V=tag:bootstrap
step_tailscale_up; show
scn "3. OAuth key without TS_TAGS: preflight refuses"
( TS_KEY=tskey-client-DUMMYcid-DUMMYoauthsecret0001 TS_TAGS_V=""; step_preflight ) 2>&1 | grep -E 'error|OAuth' | sed 's/^/    | /'
scn "4. Running node, no --reauth-tailscale: key not used"
TS_KEY=tskey-auth-DUMMYminted0001 STUB_STATE=Running; step_tailscale_up; show
scn "5. Running node + --reauth-tailscale: up --force-reauth with the key file"
REAUTH_TS=1; TS_KEY=tskey-auth-DUMMYminted0001; step_tailscale_up; show; REAUTH_TS=0
scn "6. no key and --no-wait: no browser login, manual next step recorded"
TS_KEY=""; NO_WAIT=1; STUB_STATE=NeedsLogin; NEXT_STEPS=(); step_tailscale_up; show; printf '    | next: %s\n' "${NEXT_STEPS[@]}"; NO_WAIT=0

SKIP_GH_AUTH=0
scn "7. gh not authenticated (stub: auth status exits 1) + token: token via stdin, then setup-git"
GH_TOK=ghp_DUMMYghtoken0001; export STUB_GH_RC=1; step_gh_auth; show
scn "8. gh already authenticated (stub exits 0): login skipped, token unused"
GH_TOK=ghp_DUMMYghtoken0001; export STUB_GH_RC=0; step_gh_auth; show
scn "9. gh authenticated + --reauth-gh: login again via stdin"
REAUTH_GH=1; GH_TOK=ghp_DUMMYghtoken0001; step_gh_auth; show; REAUTH_GH=0
scn "10. gh not authenticated, no token, --no-wait: no --web, manual step recorded"
GH_TOK=""; export STUB_GH_RC=1; NO_WAIT=1; NEXT_STEPS=(); step_gh_auth; show; printf '    | next: %s\n' "${NEXT_STEPS[@]}"

scn "11. git identity: existing kept; overwritten only with --set-git-identity"
git config --global user.name "Existing Name"; git config --global user.email "existing@example.invalid"
GIT_NAME="Dummy Person" GIT_EMAIL="dummy@example.invalid"; step_git_identity
echo "    | after default run: name=[$(git config --global user.name)]"
SET_GIT=1; step_git_identity; echo "    | after --set-git-identity: name=[$(git config --global user.name)] email=[$(git config --global user.email)]"
rm -rf "$W"
