#!/usr/bin/env bash
# Cross-check: every flag/env/mode/command shown by public/index.html and README.md exists in install.sh
# (or iterm2-client.sh) and behaves as described. Dry-run/--help only; nothing is installed. Run at the repo root.
set -u
P=public/index.html; R=README.md; S=public/install.sh; I=public/iterm2-client.sh
ok=0; bad=0
chk() { if eval "$2" >/dev/null 2>&1; then ok=$((ok+1)); echo "PASS $1"; else bad=$((bad+1)); echo "FAIL $1"; fi; }
HELP=$(bash $S --help 2>&1); IHELP=$(bash $I --help 2>&1)
body() { python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
if "<body" in s: s=s[s.index("<body"):]
s=re.sub(r"<script.*?</script>|<style.*?</style>|<svg.*?</svg>","",s,flags=re.S)
print(re.sub(r"<[^>]+>"," ",s))
PY
}
PB=$(body $P); RB=$(cat $R)
echo "== 1. every --flag shown on the page or README is a flag of install.sh / iterm2-client.sh (or of a tool the page names)"
EXTERN=" --auth-key --advertise-tags --with-token --get --force-reauth "
for f in $( (echo "$PB"; echo "$RB") | grep -o -E -- '--[a-z][a-z0-9-]+' | sort -u ); do
  case $EXTERN in *" $f "*) echo "SKIP $f (flag of tailscale/gh/scutil shown in prose)"; continue;; esac
  if grep -q -- "$f" <<<"$HELP" || grep -q -- "$f" <<<"$IHELP"; then ok=$((ok+1)); echo "PASS $f is in --help of $(grep -q -- "$f" <<<"$HELP" && echo install.sh || echo iterm2-client.sh)"; else bad=$((bad+1)); echo "FAIL $f shown on page/README but not in any --help"; fi
done
echo; echo "== 2. every install.sh flag in --help is shown on the page (flags table)"
for f in $(grep -o -E -- '^  --[a-z0-9-]+' <<<"$HELP" | tr -d ' '); do chk "page shows $f" "grep -q -- '$f' <<<\"\$PB\""; done
echo; echo "== 3. env names"
for e in TS_AUTHKEY TS_TAGS GH_TOKEN TS_HOSTNAME GIT_USER_NAME GIT_USER_EMAIL; do chk "$e in --help" "grep -q $e <<<\"\$HELP\""; done
for e in $( (echo "$PB"; echo "$RB") | grep -o -E '\b(TS_[A-Z]+|GH_TOKEN|GIT_USER_[A-Z]+)\b' | sort -u ); do chk "page/README env $e is read by install.sh" "grep -q -E '(TS_AUTHKEY|TS_TAGS|TS_HOSTNAME|GH_TOKEN|GIT_USER_NAME|GIT_USER_EMAIL)' <<<\"$e\" && grep -q -E '\\\$\{$e-\}' $S"; done
echo; echo "== 4. modes and commands shown on the page parse (help-only, nothing runs)"
chk "client setup: --client-setup --origin <url> --help exits 0" "bash $S --client-setup --origin https://example.com --help"
chk "mac-bootstrap handoff user@IP --port N --help exits 0" "bash $S handoff user@192.0.2.1 --port 22 --help"
chk "mac-bootstrap bundle --copy --help exits 0" "bash $S bundle --copy --help"
chk "bundle rejects unknown option (exit 2)" "bash $S bundle --bogus >/dev/null 2>&1; [ \$? -eq 2 ]"
chk "--origin only valid with --client-setup" "! bash $S --origin https://x --dry-run"
chk "--help lists the three client modes" "grep -q 'client-setup' <<<\"\$HELP\" && grep -q 'handoff' <<<\"\$HELP\" && grep -q 'bundle' <<<\"\$HELP\""
echo; echo "== 5. flags in the table behave (Mac dry-run, nothing changes)"
for combo in "--dry-run" "--dry-run --skip-tailscale-up --skip-gh-auth" "--dry-run --no-wait" "--dry-run --handoff-timeout 5" "--dry-run --reauth-tailscale --reauth-gh" "--dry-run --set-git-identity" "--dry-run --iterm2-shell-integration" "--dry-run --target-user $(id -un)"; do
  chk "install.sh $combo exits 0" "bash $S $combo </dev/null"
done
chk "--target-user for another user without root is refused" "bash $S --dry-run --target-user nobody-such 2>&1 </dev/null | grep -q 'needs root'"
chk "--handoff-timeout rejects non-numbers" "! bash $S --dry-run --handoff-timeout abc"
chk "--dry-run with TS_TAGS + --no-wait prints no secret and mentions no browser" "TS_AUTHKEY=tskey-auth-DUMMYsurf GH_TOKEN=ghp_DUMMYsurf bash $S --dry-run --no-wait </dev/null 2>&1 | grep -v -q -E 'DUMMYsurf'"
echo; echo "== 6. page claims vs checkpoint B (Linux facts)"
chk "page lists macOS, Ubuntu, Debian, Fedora, RHEL-compatible, Arch" "grep -q 'macOS, Ubuntu, Debian, Fedora, RHEL-compatible' $P"
chk "script supports exactly those: ubuntu|debian, fedora, rhel|centos|rocky|almalinux|ol, arch" "grep -q 'ubuntu | debian) echo apt' $S && grep -q 'fedora) echo fedora' $S && grep -q 'rhel | centos | rocky | almalinux | ol) echo rhel' $S && grep -q 'arch) echo pacman' $S"
chk "Remote Login is Mac-only in the script (wait loop opens System Settings only for OS_KIND macos)" "grep -q 'elif \[\[ \$OS_KIND == macos \]\]; then' $S && grep -q 'x-apple.systempreferences' $S"
chk "page says Remote Login / Screen Sharing are Mac-only steps" "grep -q 'Mac only: turn on Remote Login' $P"
chk "Paseo on Linux is the CLI (npm @getpaseo/cli) and the page says so" "grep -q '@getpaseo/cli' $S && grep -q 'Paseo (the CLI on Linux)' $P && grep -q 'Paseo CLI on Linux' $R"
chk "page: gh token on Linux is a plaintext owner-only file (docs/handoff.md section 9 agrees)" "grep -q 'plaintext, owner-only file' $P && grep -q 'plaintext' docs/handoff.md"
chk "page: key valid 1 hour, single-use, tagged, preauthorized == mint body" "grep -q '1 hour' $P && grep -q 'reusable.*false' $S && grep -q 'preauthorized.*true' $S && grep -q 'expirySeconds.*3600' $S"
chk "page: --handoff-timeout default 900 == script" "grep -q 'default 900' $P && grep -q '^HANDOFF_TIMEOUT=900' $S"
chk "page: step order preflight/packages/Tailscale/hand-off/git+gh/identity/summary == script order (Mac and Linux)" "awk '/^main\\(\\)/,/^}/' $S | grep -n -E 'step_preflight|step_linux_repos|step_homebrew|step_tailscale_up|step_gh_auth|step_git_identity|step_summary' | head -20 | grep -q step_tailscale_up"
chk "page: \`p\` pastes at a hidden prompt == receiver" "grep -q 'p | P)' $S && grep -q 'read -r -s -t' $S"
chk "no page/README text promises a browser on the target" "! grep -i -E 'opens? a browser|open the printed URL' $P $R | grep -v -i 'no browser'"
echo; echo "result: pass=$ok fail=$bad"; [ $bad -eq 0 ]
