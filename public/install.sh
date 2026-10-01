#!/usr/bin/env bash
# mac-bootstrap install.sh — one script, one URL: bootstraps a Mac (or, later, a Linux box) for
# remote work over Tailscale, without ever opening a browser on the target.
#
#   Target (default):
#   curl -fsSL "<origin>/install.sh" | bash -s -- [--dry-run] [--skip-tailscale-up] \
#       [--skip-gh-auth] [--iterm2-shell-integration] [--no-wait] [--reauth-tailscale] \
#       [--reauth-gh] [--set-git-identity] [--target-user USER] [--handoff-timeout SECONDS] \
#       [-h|--help]
#   Client Mac (macOS only), see docs/handoff.md:
#   install.sh --client-setup [--origin URL]   store the Tailscale OAuth secret, install helper
#   mac-bootstrap handoff <user@host> [--port N]   push credentials to a waiting target over SSH
#   mac-bootstrap bundle [--copy]                  print the paste bundle (contains the gh token)
#
# Optional environment (target): TS_AUTHKEY, TS_TAGS, GH_TOKEN, TS_HOSTNAME, GIT_USER_NAME,
# GIT_USER_EMAIL. Empty values count as unset. Secrets are copied into non-exported variables
# and unset from the environment as the first action, so no child process inherits them
# (internal names are unset first, so a caller-exported TS_KEY/GH_TOK cannot stay exported).
# They never appear in argv, logs or `set -x` (xtrace is switched off at the top); the
# Tailscale key goes through a 0600 temp file (--auth-key=file:...), the GitHub token through
# stdin. An OAuth `tskey-client-` value in TS_AUTHKEY requires TS_TAGS; the query string
# (?ephemeral=false&preauthorized=true) is written INSIDE the key file.
#
# Test seam: MB_BREW_CANDIDATES (colon-separated brew paths) overrides Homebrew discovery.
# It is honoured only together with --dry-run and is inert otherwise. Client-mode test hooks
# (MB_TEST_*) are honoured only when MB_TEST=1 and use dummy values only; see docs/handoff.md.
#
# curl|bash hardening: the whole script is one `{ ... }` group whose closing brace is the
# last line, so bash must parse all of it before running anything; a truncated download is
# a syntax error and nothing executes. Residual risks this script cannot close:
#  - an empty or fully failed download makes `bash` read an empty script and exit 0
#    silently (the outer shell, not this script, owns pipefail for `curl | bash`);
#  - the Homebrew installer and the iTerm2 shell-integration files are downloaded over
#    HTTPS (TLS 1.2+) from their upstream HEAD/latest locations and are NOT pinned or
#    checksum-verified (accepted risk); the sha256 of the shell-integration file is
#    printed so you can compare it. Use --dry-run first if in doubt.
{
set -euo pipefail
set +x

readonly BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
readonly TS_SOCKET="/var/run/tailscaled.socket"
readonly TS_PLIST="/Library/LaunchDaemons/com.tailscale.tailscaled.plist"
readonly ITERM_SI_BASE="https://iterm2.com/shell_integration"
readonly API_DEFAULT="https://api.tailscale.com"
readonly KC_OAUTH="mac-bootstrap.tailscale-oauth"
readonly KC_TAG="mac-bootstrap.tailscale-tag"
readonly BUNDLE_MAX=8192
readonly BUNDLE_LINE_MAX=11000
readonly TOTAL=10
readonly CURL=(curl --proto '=https' --tlsv1.2 -fsSL)
readonly GH_ENV=(env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_HOST)
# Remote commands run by the client over SSH (plain sh, no `eval`, bundle on stdin).
readonly RC_PROBE="sh -c 'd=\"\$HOME/.cache/mac-bootstrap/inbox\"; test -d \"\$d\" && test ! -L \"\$d\" && test -e \"\$d/ready\" && test ! -e \"\$d/bundle\"'"
readonly RC_SEND="sh -c 'umask 077; d=\"\$HOME/.cache/mac-bootstrap/inbox\"; if test -L \"\$d\" || test ! -d \"\$d\" || test ! -e \"\$d/ready\"; then echo \"mac-bootstrap: the target is not waiting for a hand-off\" >&2; exit 3; fi; t=\"\$d/bundle.tmp.\$\$\"; head -c 11100 >\"\$t\"; n=\$(wc -c <\"\$t\" | tr -d \" \"); if test \"\$n\" -gt 11000; then rm -f \"\$t\"; echo \"mac-bootstrap: bundle too large\" >&2; exit 4; fi; if test -e \"\$d/ready\" && ln \"\$t\" \"\$d/bundle\" 2>/dev/null; then rm -f \"\$t\"; exit 0; fi; rm -f \"\$t\"; echo \"mac-bootstrap: a bundle was already delivered or the hand-off is closed\" >&2; exit 5'"

unset TS_KEY GH_TOK
MODE=target
DRY_RUN=0
SKIP_TS_UP=0
SKIP_GH_AUTH=0
ITERM_SI=0
NO_WAIT=0
REAUTH_TS=0
REAUTH_GH=0
SET_GIT=0
HANDOFF_TIMEOUT=900
TARGET_USER_ARG=""
TARGET_USER=""
TARGET_HOME=""
TARGET_UID=""
OS_KIND=""
CL_HOST=""
CL_PORT=22
CL_COPY=0
ORIGIN=""
TS_KEY=""
TS_TAGS_V=""
GH_TOK=""
TS_HOST=""
GIT_NAME=""
GIT_EMAIL=""
B_TS=""
B_TAGS=""
B_GH=""
B_NAME=""
B_EMAIL=""
BREW=""
BREWCMD=""
HAVE_BREW=0
PREFIX=""
TMPD=""
TSBIN=""
INBOX=""
CM_DIR=""
CM_SOCK=""
CHOME=""
API_BASE="$API_DEFAULT"
NEXT_STEPS=()

usage() {
  cat <<'EOF'
Usage: curl -fsSL <origin>/install.sh | bash -s -- [options]

Target options:
  --dry-run                    show every step and the exact commands; change nothing
  --skip-tailscale-up          do not run `tailscale up`
  --skip-gh-auth               do not authenticate gh
  --iterm2-shell-integration   install iTerm2 shell integration for the login shell (macOS)
  --no-wait                    never wait for a hand-off from your client Mac
  --reauth-tailscale           log in to Tailscale again even if already Running
  --reauth-gh                  log in to gh again even if already authenticated
  --set-git-identity           overwrite an existing global git identity
  --target-user USER           user who owns the gh/git config and the inbox (when root)
  --handoff-timeout SECONDS    how long to wait for a hand-off (default 900)
  -h, --help                   show this help

Environment (optional): TS_AUTHKEY, TS_TAGS, GH_TOKEN, TS_HOSTNAME, GIT_USER_NAME, GIT_USER_EMAIL

No browser is ever opened. Without a key or token the script waits for a hand-off from your
client Mac (SSH push) or a pasted bundle (press p).

Client Mac (macOS only), after `--client-setup` has installed ~/.local/bin/mac-bootstrap:
  install.sh --client-setup [--origin URL]
  mac-bootstrap handoff <user@host> [--port N]
  mac-bootstrap bundle [--copy]
EOF
}

say() { printf '%s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n[%s/%s] %s\n' "$1" "$TOTAL" "$2"; }
err() { printf '    error: %s\n' "$*" >&2; }

cleanup() {
  inbox_cleanup
  if [[ -n $CM_SOCK && -S $CM_SOCK ]]; then
    ssh -S "$CM_SOCK" -O exit x >/dev/null 2>&1 </dev/null || true
  fi
  if [[ -n $CM_DIR && -d $CM_DIR ]]; then
    rm -rf "$CM_DIR"
  fi
  if [[ -n $TMPD && -d $TMPD ]]; then
    rm -rf "$TMPD"
  fi
}

ensure_tmp() {
  if [[ -z $TMPD ]]; then
    TMPD=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/mac-bootstrap.XXXXXX")
  fi
}

dry() {
  printf '    DRY-RUN would run:'
  printf ' %q' "$@"
  printf '\n'
}

# run <cmd...>: execute, or print in dry-run. Children never read the script from stdin.
run() {
  if ((DRY_RUN)); then
    dry "$@"
  else
    "$@" </dev/null
  fi
}

have_tty() { ( : </dev/tty ) 2>/dev/null; }

test_mode() { [[ ${MB_TEST-} == 1 ]]; }

brew_formula() {
  [[ -n $BREW ]] || return 1
  [[ -n $("$BREW" list --formula --versions "$1" 2>/dev/null || true) ]]
}

brew_cask() {
  [[ -n $BREW ]] || return 1
  [[ -n $("$BREW" list --cask --versions "$1" 2>/dev/null || true) ]]
}

default_prefix() {
  if [[ $(uname -m) == arm64 ]]; then echo /opt/homebrew; else echo /usr/local; fi
}

find_brew() {
  local cands c
  if ((DRY_RUN)) && [[ -n ${MB_BREW_CANDIDATES+x} ]]; then
    cands=$MB_BREW_CANDIDATES
  else
    cands="$(default_prefix)/bin/brew:/opt/homebrew/bin/brew:/usr/local/bin/brew"
  fi
  BREW=""
  local IFS=:
  for c in $cands; do
    if [[ -n $c && -x $c ]]; then BREW=$c; return 0; fi
  done
  return 1
}

badopt() { printf 'unknown or misplaced option: %s\n' "$1" >&2; usage >&2; exit 2; }

need_val() { (($# >= 2)) && [[ -n $2 ]] || { printf 'option %s needs a value\n' "$1" >&2; exit 2; }; }

parse_args() {
  local re
  case ${1-} in
    --client-setup) MODE=client-setup; shift ;;
    handoff) MODE=handoff; shift ;;
    bundle) MODE=bundle; shift ;;
  esac
  while (($#)); do
    case $1 in
      -h | --help) usage; exit 0 ;;
      --dry-run | --skip-tailscale-up | --skip-gh-auth | --iterm2-shell-integration | \
        --no-wait | --reauth-tailscale | --reauth-gh | --set-git-identity)
        [[ $MODE == target ]] || badopt "$1"
        case $1 in
          --dry-run) DRY_RUN=1 ;;
          --skip-tailscale-up) SKIP_TS_UP=1 ;;
          --skip-gh-auth) SKIP_GH_AUTH=1 ;;
          --iterm2-shell-integration) ITERM_SI=1 ;;
          --no-wait) NO_WAIT=1 ;;
          --reauth-tailscale) REAUTH_TS=1 ;;
          --reauth-gh) REAUTH_GH=1 ;;
          --set-git-identity) SET_GIT=1 ;;
        esac
        ;;
      --target-user)
        [[ $MODE == target ]] || badopt "$1"
        need_val "$@"; TARGET_USER_ARG=$2; shift
        ;;
      --handoff-timeout)
        [[ $MODE == target ]] || badopt "$1"
        need_val "$@"; re='^[0-9]{1,6}$'
        if ! [[ $2 =~ $re ]] || (($2 < 1)); then printf -- '--handoff-timeout needs a number of seconds\n' >&2; exit 2; fi
        HANDOFF_TIMEOUT=$2; shift
        ;;
      --port)
        [[ $MODE == handoff ]] || badopt "$1"
        need_val "$@"; re='^[0-9]{1,5}$'
        if ! [[ $2 =~ $re ]] || (($2 < 1 || $2 > 65535)); then printf -- '--port needs a port number\n' >&2; exit 2; fi
        CL_PORT=$2; shift
        ;;
      --copy)
        [[ $MODE == bundle ]] || badopt "$1"
        CL_COPY=1
        ;;
      --origin)
        [[ $MODE == client-setup ]] || badopt "$1"
        need_val "$@"; ORIGIN=$2; shift
        ;;
      -*) badopt "$1" ;;
      *)
        if [[ $MODE == handoff && -z $CL_HOST ]]; then CL_HOST=$1; else badopt "$1"; fi
        ;;
    esac
    shift
  done
}

setstate() { if [[ -n $1 ]]; then echo set; else echo "not set"; fi; }

# ---------------------------------------------------------------------------------------
# Shared core: OS, target user, bundle, hand-off receiver
# ---------------------------------------------------------------------------------------

detect_os() {
  case $(uname -s) in
    Darwin) OS_KIND=macos ;;
    Linux) OS_KIND=linux ;;
    *) die "macOS or Linux only (found $(uname -s))" ;;
  esac
}

# Who owns the gh/git config and the inbox. Root is refused unless a user is named.
target_resolve() {
  local me u re='^[A-Za-z_][A-Za-z0-9._-]*$'
  me=$(id -un)
  if ((EUID != 0)); then
    if [[ -n $TARGET_USER_ARG && $TARGET_USER_ARG != "$me" ]]; then
      die "--target-user $TARGET_USER_ARG needs root; run this as $TARGET_USER_ARG instead"
    fi
    TARGET_USER=$me
    TARGET_HOME=$HOME
  else
    if [[ $OS_KIND == macos ]]; then
      die "do not run as root; the script calls sudo only where needed"
    fi
    u=${TARGET_USER_ARG:-${SUDO_USER-}}
    if [[ -z $u || $u == root ]]; then
      die "running as root: name the user who owns the gh/git config and the inbox with --target-user USER (or run through sudo from that user)"
    fi
    [[ $u =~ $re ]] || die "invalid --target-user"
    id -u "$u" >/dev/null 2>&1 || die "no such user: $u"
    TARGET_USER=$u
    TARGET_HOME=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
    [[ -n $TARGET_HOME && -d $TARGET_HOME ]] || die "cannot find the home directory of $u"
  fi
  TARGET_UID=$(id -u "$TARGET_USER")
}

# Run a command as the target user (identity when root; plain exec otherwise).
as_target() {
  if ((EUID == 0)) && [[ $TARGET_USER != root ]]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    else
      sudo -n -u "$TARGET_USER" -H -- env HOME="$TARGET_HOME" "$@"
    fi
  else
    "$@"
  fi
}

owner_mode() {
  if [[ $(uname -s) == Darwin ]]; then stat -f '%u %Lp' "$1"; else stat -c '%u %a' "$1"; fi
}

b64dec() { # $1 in-file, $2 out-file
  base64 -d <"$1" >"$2" 2>/dev/null || base64 -D <"$1" >"$2" 2>/dev/null
}

bundle_clear() { B_TS=""; B_TAGS=""; B_GH=""; B_NAME=""; B_EMAIL=""; }
bundle_fail() { err "bundle rejected: $1"; rm -f "$TMPD/bundle.dec" "$TMPD/bundle.b64"; bundle_clear; }

# bundle_parse <MB1:...>: validate and load into B_*. Errors never include values.
bundle_parse() {
  local raw=$1 re line key val seen=" " size tmp
  bundle_clear
  if ((${#raw} > BUNDLE_LINE_MAX)); then err "bundle rejected: too large"; return 1; fi
  re='^MB1:[A-Za-z0-9+/]+={0,2}$'
  if ! [[ $raw =~ $re ]]; then err "bundle rejected: not an MB1 bundle"; return 1; fi
  ensure_tmp
  tmp="$TMPD/bundle"
  (umask 077; printf '%s' "${raw#MB1:}" >"$tmp.b64")
  if ! b64dec "$tmp.b64" "$tmp.dec"; then
    bundle_fail "not valid base64"; return 1
  fi
  rm -f "$tmp.b64"
  size=$(wc -c <"$tmp.dec" | tr -d ' ')
  if ((size < 1 || size > BUNDLE_MAX)); then bundle_fail "decoded size out of range"; return 1; fi
  if (($(LC_ALL=C tr -d '\000' <"$tmp.dec" | wc -c) != size)); then bundle_fail "NUL byte"; return 1; fi
  if (($(LC_ALL=C tr -d '\r' <"$tmp.dec" | wc -c) != size)); then bundle_fail "carriage return"; return 1; fi
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ -z $line ]]; then bundle_fail "empty line"; return 1; fi
    if [[ $line != *=* ]]; then bundle_fail "line without '='"; return 1; fi
    key=${line%%=*}
    val=${line#*=}
    case $key in
      TS_AUTHKEY | TS_TAGS | GH_TOKEN | GIT_USER_NAME | GIT_USER_EMAIL) ;;
      *) bundle_fail "unknown key"; return 1 ;;
    esac
    case $seen in
      *" $key "*) bundle_fail "duplicate key $key"; return 1 ;;
    esac
    seen="$seen$key "
    case $key in
      TS_AUTHKEY) re='^tskey-auth-[A-Za-z0-9_-]+$'; [[ $val =~ $re ]] && B_TS=$val ;;
      TS_TAGS) re='^tag:[a-z][a-z0-9-]*(,tag:[a-z][a-z0-9-]*)*$'; [[ $val =~ $re ]] && B_TAGS=$val ;;
      GH_TOKEN) re='^[A-Za-z0-9_]+$'; [[ $val =~ $re ]] && B_GH=$val ;;
      GIT_USER_NAME) if [[ -n $val && ${#val} -le 200 && $val != *[[:cntrl:]]* ]]; then B_NAME=$val; fi ;;
      GIT_USER_EMAIL) re='^[^[:space:]<>@]+@[^[:space:]<>@]+$'; [[ $val =~ $re && $val != *[[:cntrl:]]* ]] && B_EMAIL=$val ;;
    esac
    # a value that failed its pattern leaves the B_ variable empty: reject
    case $key in
      TS_AUTHKEY) [[ -n $B_TS ]] || { bundle_fail "bad TS_AUTHKEY (must be a tskey-auth- key)"; return 1; } ;;
      TS_TAGS) [[ -n $B_TAGS ]] || { bundle_fail "bad TS_TAGS"; return 1; } ;;
      GH_TOKEN) [[ -n $B_GH ]] || { bundle_fail "bad GH_TOKEN"; return 1; } ;;
      GIT_USER_NAME) [[ -n $B_NAME ]] || { bundle_fail "bad GIT_USER_NAME"; return 1; } ;;
      GIT_USER_EMAIL) [[ -n $B_EMAIL ]] || { bundle_fail "bad GIT_USER_EMAIL"; return 1; } ;;
    esac
  done <"$tmp.dec"
  rm -f "$tmp.dec"
  if [[ $seen == " " ]]; then err "bundle rejected: empty"; return 1; fi
  return 0
}

# Environment values win; the bundle only fills what is empty.
bundle_apply() {
  if [[ -z $TS_KEY ]]; then TS_KEY=$B_TS; fi
  if [[ -z $TS_TAGS_V ]]; then TS_TAGS_V=$B_TAGS; fi
  if [[ -z $GH_TOK ]]; then GH_TOK=$B_GH; fi
  if [[ -z $GIT_NAME ]]; then GIT_NAME=$B_NAME; fi
  if [[ -z $GIT_EMAIL ]]; then GIT_EMAIL=$B_EMAIL; fi
  bundle_clear
}

# Directory is real (not a symlink), owned by the target user, not group/world writable.
inbox_check_dir() {
  local d=$1 om m
  if [[ -L $d || ! -d $d ]]; then return 1; fi
  om=$(owner_mode "$d") || return 1
  m=${om#* }
  if [[ ${om%% *} != "$TARGET_UID" ]]; then return 1; fi
  if (((8#$m & 8#022) != 0)); then return 1; fi
  return 0
}

inbox_prepare() {
  local base="$TARGET_HOME/.cache" d
  INBOX=""
  for d in "$base" "$base/mac-bootstrap" "$base/mac-bootstrap/inbox"; do
    if [[ -e $d || -L $d ]]; then
      if ! inbox_check_dir "$d"; then
        err "inbox refused: $d is not a plain directory owned by $TARGET_USER (symlink or loose permissions)"
        return 1
      fi
    elif ! as_target mkdir -m 0700 "$d"; then
      err "inbox refused: cannot create $d"
      return 1
    fi
  done
  as_target chmod 0700 "$base/mac-bootstrap" "$base/mac-bootstrap/inbox" || return 1
  INBOX="$base/mac-bootstrap/inbox"
  rm -f "$INBOX/bundle" "$INBOX"/bundle.tmp.* 2>/dev/null || true
  # shellcheck disable=SC2016
  as_target sh -c 'umask 077; : >"$1"' sh "$INBOX/ready" || { INBOX=""; return 1; }
  return 0
}

inbox_cleanup() {
  if [[ -n $INBOX ]]; then
    rm -f "$INBOX/ready" "$INBOX/bundle" "$INBOX"/bundle.tmp.* 2>/dev/null || true
    rmdir "$INBOX" 2>/dev/null || true
    INBOX=""
  fi
}

ssh_listening() { ( exec 3<>/dev/tcp/127.0.0.1/22 ) 2>/dev/null; }

lan_ips() {
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '$1=="inet" && $2 !~ /^127\./ && $2 !~ /^169\.254\./ {print $2}'
  elif command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'
  fi
}

local_name() {
  local n=""
  if [[ $OS_KIND == macos ]]; then
    n=$(scutil --get LocalHostName 2>/dev/null || true)
  fi
  if [[ -z $n ]]; then n=$(hostname -s 2>/dev/null || true); fi
  [[ -n $n ]] || return 1
  if [[ $OS_KIND == macos ]]; then
    dscacheutil -q host -a name "$n.local" 2>/dev/null | grep -q '^ip_address' || return 1
  else
    getent hosts "$n.local" >/dev/null 2>&1 || return 1
  fi
  printf '%s.local' "$n"
}

target_screen() {
  local fp="" ip ln
  if [[ -r /etc/ssh/ssh_host_ed25519_key.pub ]]; then
    fp=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 2>/dev/null | awk '{print $2}' || true)
  fi
  note "SSH is reachable on this machine. From your client Mac, run one of:"
  while IFS= read -r ip; do
    [[ -n $ip ]] && note "  mac-bootstrap handoff $TARGET_USER@$ip"
  done < <(lan_ips)
  if ln=$(local_name); then note "  mac-bootstrap handoff $TARGET_USER@$ln"; fi
  note "ED25519 host-key fingerprint (it must match what the client shows): ${fp:-unavailable (no ED25519 host key found)}"
}

# Wait for a bundle: SSH push into the inbox, or `p` for a hidden paste. Returns 0 if a bundle
# was received and loaded into the credential variables.
wait_for_handoff() {
  local deadline k rc shown=0 tty=0 line left pasted=0
  have_tty && tty=1
  if inbox_prepare; then
    :
  else
    note "SSH hand-off is unavailable on this machine; paste is still possible"
  fi
  if ssh_listening; then
    if [[ -n $INBOX ]]; then target_screen; fi
    shown=1
  elif [[ $OS_KIND == macos ]]; then
    note "Remote Login is off. Opening System Settings > General > Sharing: turn on Remote Login (or press p to paste a bundle instead)"
    open "x-apple.systempreferences:com.apple.Sharing-Settings.extension" >/dev/null 2>&1 || true
  else
    note "no SSH server is listening on port 22 here; press p to paste a bundle"
  fi
  if ((tty)); then note "press p to paste a bundle instead (client: mac-bootstrap bundle)"; fi
  note "waiting up to ${HANDOFF_TIMEOUT}s for a hand-off (Ctrl-C to stop)"
  deadline=$((SECONDS + HANDOFF_TIMEOUT))
  while ((SECONDS < deadline)); do
    if [[ -n $INBOX && -e $INBOX/bundle ]]; then
      if take_inbox_bundle; then bundle_apply; return 0; fi
      note "SSH hand-off is closed for this run; press p to paste, or run the installer again"
      INBOX=""
    fi
    if ((!shown)) && ssh_listening; then
      if [[ -n $INBOX ]]; then target_screen; fi
      shown=1
    fi
    if ((tty)); then
      rc=0
      read -r -t 1 -s -n 1 k 2>/dev/null </dev/tty || rc=$?
      if ((rc == 0)); then
        case $k in
          p | P)
            left=$((deadline - SECONDS))
            if paste_bundle "$left"; then pasted=1; break; fi
            ;;
        esac
      elif ((rc < 128)); then
        sleep 1
      fi
    else
      sleep 1
    fi
  done
  if ((pasted)); then bundle_apply; return 0; fi
  note "no hand-off received (timeout)"
  return 1
}

take_inbox_bundle() {
  local f="$INBOX/bundle" om size content rc
  rm -f "$INBOX/ready"
  if [[ -L $f || ! -f $f ]]; then err "bundle refused: not a regular file"; rm -f "$f"; return 1; fi
  om=$(owner_mode "$f") || { rm -f "$f"; return 1; }
  if [[ ${om%% *} != "$TARGET_UID" ]] || (((8#${om#* } & 8#077) != 0)); then
    err "bundle refused: wrong owner or loose permissions"; rm -f "$f"; return 1
  fi
  size=$(wc -c <"$f" | tr -d ' ')
  if ((size < 1 || size > BUNDLE_LINE_MAX + 1)); then err "bundle refused: size out of range"; rm -f "$f"; return 1; fi
  if (($(LC_ALL=C tr -d 'A-Za-z0-9+/=:\n' <"$f" | wc -c) != 0)); then err "bundle refused: unexpected characters"; rm -f "$f"; return 1; fi
  content=$(cat "$f")
  rc=0
  bundle_parse "$content" || rc=$?
  content=""
  rm -f "$f"
  if ((rc != 0)); then return 1; fi
  note "bundle received over SSH and accepted"
  return 0
}

paste_bundle() {
  local line="" left=$1
  printf '    Paste the bundle (input hidden), then Enter; empty line cancels: ' >/dev/tty
  IFS= read -r -s -t "$left" line </dev/tty || true
  printf '\n' >/dev/tty
  line=${line%$'\r'}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  if [[ -z $line ]]; then return 1; fi
  if ! bundle_parse "$line"; then line=""; return 1; fi
  line=""
  if [[ -n $INBOX ]]; then rm -f "$INBOX/ready"; fi
  note "pasted bundle accepted"
  return 0
}

# Called at the start of step 5: wait for credentials only if something needs them.
maybe_handoff() {
  local st need_ts=0 need_gh=0 why=""
  if ((!SKIP_TS_UP)) && [[ -z $TS_KEY ]]; then
    st=$(ts_state)
    case $st in
      Running | Stopped) if ((REAUTH_TS)); then need_ts=1; fi ;;
      *) need_ts=1 ;;
    esac
  fi
  if ((!SKIP_GH_AUTH)) && [[ -z $GH_TOK ]]; then
    if ((REAUTH_GH)) || ! gh_authed; then need_gh=1; fi
  fi
  if ((!need_ts && !need_gh)); then return 0; fi
  if ((need_ts)); then why="a Tailscale key"; fi
  if ((need_gh)); then why="${why:+$why and }a GitHub token"; fi
  if ((NO_WAIT)); then
    note "needs $why: --no-wait, not waiting for a hand-off"
    return 0
  fi
  if ((DRY_RUN)); then
    note "needs $why: DRY-RUN would wait up to ${HANDOFF_TIMEOUT}s for a hand-off:"
    note "  create ~/.cache/mac-bootstrap/inbox (0700), write a ready marker, print this machine's IPs and SSH host-key fingerprint,"
    note "  accept ONE bundle pushed over SSH by 'mac-bootstrap handoff' from your client Mac, or pasted (press p); no browser is opened"
    return 0
  fi
  note "needs $why: waiting for a hand-off from your client Mac"
  if wait_for_handoff; then
    note "hand-off received: Tailscale key $(setstate "$TS_KEY"), GitHub token $(setstate "$GH_TOK"), git identity $(setstate "$GIT_NAME$GIT_EMAIL")"
  fi
  inbox_cleanup
}

# ---------------------------------------------------------------------------------------
# Client modes (macOS): setup, bundle, handoff
# ---------------------------------------------------------------------------------------

client_guard() {
  [[ $(uname -s) == Darwin ]] || die "this mode runs on the client Mac (macOS only)"
  ((EUID != 0)) || die "run the client modes as your normal user, not root"
  CHOME=$HOME
  API_BASE=$API_DEFAULT
  if test_mode; then
    local re='^http://127\.0\.0\.1:[0-9]+$'
    printf 'TEST MODE (MB_TEST=1): dummy values only; the real Keychain and gh are never read\n' >&2
    if [[ -n ${MB_TEST_HOME-} ]]; then
      [[ -d $MB_TEST_HOME ]] || die "MB_TEST_HOME is not a directory"
      CHOME=$MB_TEST_HOME
    fi
    if [[ -n ${MB_TEST_API_BASE-} ]]; then
      [[ $MB_TEST_API_BASE =~ $re ]] || die "MB_TEST_API_BASE must be http://127.0.0.1:PORT"
      API_BASE=$MB_TEST_API_BASE
    fi
  fi
}

kc_get() { security find-generic-password -s "$1" -a "$USER" -w 2>/dev/null; }

# The secret reaches `security` on stdin (interactive mode), never argv. Values are validated.
kc_put() { printf 'add-generic-password -U -s %s -a %s -w %s\n' "$1" "$USER" "$2" | security -i >/dev/null 2>&1; }

client_setup() {
  local secret="" tag="" re ans sum dest src proto
  client_guard
  re='^[A-Za-z0-9._-]+$'
  [[ $USER =~ $re ]] || die "unsupported user name for the Keychain item"
  src=${BASH_SOURCE[0]-}
  proto=https
  if ! [[ -n $src && -f $src && -r $src ]]; then
    src=""
    [[ -n $ORIGIN ]] || die "this was run from a pipe, so the script cannot copy itself: add --origin \"<origin>\" (or save install.sh and run it from the file)"
    re='^https://[A-Za-z0-9.-]+(:[0-9]+)?$'
    if test_mode && [[ $ORIGIN =~ ^http://127\.0\.0\.1:[0-9]+$ ]]; then
      proto=http
    elif ! [[ $ORIGIN =~ $re ]]; then
      die "--origin must be https://host[:port]"
    fi
  fi
  if test_mode; then
    secret=${MB_TEST_OAUTH_SECRET-}
    [[ -n $secret ]] || die "test mode: MB_TEST_OAUTH_SECRET is required"
  else
    have_tty || die "needs a terminal for the hidden secret prompt"
    printf 'Tailscale OAuth client secret (tskey-client-..., input hidden): ' >/dev/tty
    IFS= read -r -s secret </dev/tty || true
    printf '\n' >/dev/tty
  fi
  re='^tskey-client-[A-Za-z0-9_-]+$'
  [[ $secret =~ $re ]] || die "that is not a tskey-client- OAuth secret"
  tag="tag:bootstrap"
  if have_tty; then
    printf 'Tag for the minted keys [tag:bootstrap]: ' >/dev/tty
    IFS= read -r ans </dev/tty || true
    if [[ -n $ans ]]; then tag=$ans; fi
  fi
  re='^tag:[a-z][a-z0-9-]*(,tag:[a-z][a-z0-9-]*)*$'
  [[ $tag =~ $re ]] || die "invalid tag (use tag:name, comma separated)"
  if test_mode; then
    say "test mode: Keychain write skipped"
  else
    kc_put "$KC_OAUTH" "$secret" || die "could not store the secret in the login Keychain"
    kc_put "$KC_TAG" "$tag" || die "could not store the tag in the login Keychain"
    say "stored in the login Keychain: service $KC_OAUTH (secret), $KC_TAG (tag $tag)"
  fi
  secret=""
  # helper copy
  ensure_tmp
  dest="$CHOME/.local/bin/mac-bootstrap"
  if [[ -n $src ]]; then
    cp "$src" "$TMPD/helper"
  else
    curl --proto "=$proto" --tlsv1.2 -fsSL --max-time 60 "$ORIGIN/install.sh" -o "$TMPD/helper" </dev/null || die "could not download $ORIGIN/install.sh"
  fi
  if [[ $(head -n1 "$TMPD/helper") != '#!/usr/bin/env bash' || $(tail -n1 "$TMPD/helper") != '}' ]] || ! grep -q 'mac-bootstrap install.sh' "$TMPD/helper"; then
    die "the helper copy does not look like install.sh; refusing to install it"
  fi
  sum=$(shasum -a 256 <"$TMPD/helper" | cut -d' ' -f1)
  mkdir -p "$CHOME/.local/bin"
  chmod 0755 "$TMPD/helper"
  mv "$TMPD/helper" "$dest"
  say "installed $dest"
  say "sha256 $sum"
  case ":$PATH:" in
    *":$CHOME/.local/bin:"*) ;;
    *) say "add it to your PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"   (put that line in ~/.zprofile)" ;;
  esac
  say "next: mac-bootstrap handoff <user@host>   (or: mac-bootstrap bundle)"
}

# Reads the stored OAuth secret and tag. Sets CL_SECRET, CL_TAG (non-exported).
client_credentials() {
  local re
  CL_SECRET=""
  CL_TAG=""
  if test_mode; then
    CL_SECRET=${MB_TEST_OAUTH_SECRET-}
    [[ -n $CL_SECRET ]] || die "test mode: MB_TEST_OAUTH_SECRET is required"
    CL_TAG="tag:bootstrap"
  else
    CL_SECRET=$(kc_get "$KC_OAUTH") || die "no OAuth secret in the Keychain: run install.sh --client-setup first"
    CL_TAG=$(kc_get "$KC_TAG") || CL_TAG="tag:bootstrap"
  fi
  re='^tskey-client-[A-Za-z0-9_-]+$'
  [[ $CL_SECRET =~ $re ]] || die "the stored OAuth secret is malformed; run --client-setup again"
  re='^tag:[a-z][a-z0-9-]*(,tag:[a-z][a-z0-9-]*)*$'
  [[ $CL_TAG =~ $re ]] || die "the stored tag is malformed; run --client-setup again"
}

gh_token_get() {
  local re='^[A-Za-z0-9_]+$'
  CL_GH=""
  if test_mode; then
    CL_GH=${MB_TEST_GH_TOKEN-}
    [[ -n $CL_GH ]] || die "test mode: MB_TEST_GH_TOKEN is required"
  else
    command -v gh >/dev/null 2>&1 || die "gh not found: brew install gh && gh auth login"
    CL_GH=$("${GH_ENV[@]}" gh auth token --hostname github.com 2>/dev/null </dev/null) || die "gh is not logged in on this Mac: run gh auth login"
  fi
  [[ $CL_GH =~ $re ]] || die "unexpected gh token format"
}

# Read-only: never changes any git config.
git_identity_get() {
  local n="" e=""
  if test_mode; then
    n=$(env HOME="$CHOME" XDG_CONFIG_HOME="$CHOME/.config" git config --global --get user.name 2>/dev/null || true)
    e=$(env HOME="$CHOME" XDG_CONFIG_HOME="$CHOME/.config" git config --global --get user.email 2>/dev/null || true)
  else
    n=$(git config --global --get user.name 2>/dev/null || true)
    e=$(git config --global --get user.email 2>/dev/null || true)
    if [[ -z $n ]]; then n=$("${GH_ENV[@]}" gh api user --jq '.name // .login' 2>/dev/null </dev/null || true); fi
    if [[ -z $e ]]; then e=$("${GH_ENV[@]}" gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null </dev/null || true); fi
  fi
  if [[ $n == *[[:cntrl:]]* ]] || ((${#n} > 200)); then n=""; fi
  if [[ $e == *[[:cntrl:]]* || $e == *[[:space:]]* ]]; then e=""; fi
  CL_NAME=$n
  CL_EMAIL=$e
}

json_error() { # $1 file: print a sanitized API message
  local m="" re="^[A-Za-z0-9 .,:_'/-]{1,200}\$"
  m=$(plutil -extract message raw -o - "$1" 2>/dev/null || true)
  if [[ $m =~ $re ]]; then printf '%s' "$m"; fi
}

# mint_key: OAuth secret -> token -> single-use, preauthorized, non-ephemeral, tagged, 1h key.
# Secrets and the bearer token reach curl through its stdin config (-K -), never argv.
mint_key() {
  local proto tok http tags="" t re body
  local IFS_SAVE=$IFS
  MINTED=""
  ensure_tmp
  proto=${API_BASE%%:*}
  http=$(printf '%s\n' \
    "url = \"$API_BASE/api/v2/oauth/token\"" \
    'data = "grant_type=client_credentials"' \
    'data = "client_id=mac-bootstrap"' \
    "data = \"client_secret=$CL_SECRET\"" |
    curl --proto "=$proto" --tlsv1.2 -sS --connect-timeout 10 --max-time 30 -K - -o "$TMPD/tok.json" -w '%{http_code}') || { rm -f "$TMPD/tok.json"; die "could not reach the Tailscale API"; }
  if [[ $http != 200 ]]; then
    err "Tailscale API rejected the OAuth login (HTTP $http) $(json_error "$TMPD/tok.json")"
    rm -f "$TMPD/tok.json"
    exit 1
  fi
  tok=$(plutil -extract access_token raw -o - "$TMPD/tok.json" 2>/dev/null || true)
  rm -f "$TMPD/tok.json"
  re='^[A-Za-z0-9_.-]+$'
  [[ $tok =~ $re ]] || die "the Tailscale API returned no usable access token"
  IFS=,
  for t in $CL_TAG; do tags="${tags:+$tags,}\"$t\""; done
  IFS=$IFS_SAVE
  body="{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[$tags]}}},\"expirySeconds\":3600,\"description\":\"mac-bootstrap handoff\"}"
  (umask 077; printf '%s' "$body" >"$TMPD/mint-body.json")
  http=$(printf '%s\n' \
    "url = \"$API_BASE/api/v2/tailnet/-/keys\"" \
    "header = \"Authorization: Bearer $tok\"" \
    'header = "Content-Type: application/json"' |
    curl --proto "=$proto" --tlsv1.2 -sS --connect-timeout 10 --max-time 30 -K - --data-binary "@$TMPD/mint-body.json" -o "$TMPD/key.json" -w '%{http_code}') || { rm -f "$TMPD/key.json" "$TMPD/mint-body.json"; die "could not reach the Tailscale API"; }
  tok=""
  rm -f "$TMPD/mint-body.json"
  if [[ $http != 200 ]]; then
    err "Tailscale API refused to mint the key (HTTP $http) $(json_error "$TMPD/key.json")"
    err "check the OAuth client scope (auth_keys) and that it owns $CL_TAG"
    rm -f "$TMPD/key.json"
    exit 1
  fi
  MINTED=$(plutil -extract key raw -o - "$TMPD/key.json" 2>/dev/null || true)
  rm -f "$TMPD/key.json"
  re='^tskey-auth-[A-Za-z0-9_-]+$'
  [[ $MINTED =~ $re ]] || die "the Tailscale API returned no usable auth key"
}

# Builds BUNDLE (MB1:...). Requires CL_* from the helpers above.
build_bundle() {
  BUNDLE=$({
    printf 'TS_AUTHKEY=%s\n' "$MINTED"
    printf 'TS_TAGS=%s\n' "$CL_TAG"
    printf 'GH_TOKEN=%s\n' "$CL_GH"
    if [[ -n $CL_NAME ]]; then printf 'GIT_USER_NAME=%s\n' "$CL_NAME"; fi
    if [[ -n $CL_EMAIL ]]; then printf 'GIT_USER_EMAIL=%s\n' "$CL_EMAIL"; fi
  } | base64 | tr -d '\n')
  BUNDLE="MB1:$BUNDLE"
  MINTED=""
}

client_collect() {
  client_credentials
  gh_token_get
  git_identity_get
  mint_key
  CL_SECRET=""
  build_bundle
  CL_GH=""
}

cmd_bundle() {
  client_guard
  client_collect
  printf 'WARNING: this bundle contains your GitHub token and a one-hour, single-use Tailscale key.\n' >&2
  printf '         Paste it only into the target'"'"'s prompt; do not share, save or commit it.\n' >&2
  if ((${#BUNDLE} > 1000)); then
    printf 'note: the bundle is %s characters; a macOS terminal line may truncate above ~1000. Prefer: mac-bootstrap handoff.\n' "${#BUNDLE}" >&2
  fi
  printf '%s\n' "$BUNDLE"
  if ((CL_COPY)); then
    if test_mode; then
      printf 'test mode: pbcopy skipped\n' >&2
    else
      printf '%s' "$BUNDLE" | pbcopy
      printf 'copied to the clipboard (clear it after use)\n' >&2
    fi
  fi
  BUNDLE=""
}

cmd_handoff() {
  local user host re scan fp ans kc rc
  client_guard
  [[ -n $CL_HOST ]] || die "usage: mac-bootstrap handoff <user@host> [--port N]"
  re='^[A-Za-z0-9._][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.:%_-]*$'
  [[ $CL_HOST =~ $re ]] || die "expected user@host (letters, digits, . _ - only)"
  user=${CL_HOST%%@*}
  host=${CL_HOST#*@}
  for kc in ssh ssh-keyscan ssh-keygen; do command -v "$kc" >/dev/null 2>&1 || die "$kc not found"; done
  have_tty || die "needs a terminal to confirm the host-key fingerprint"
  ensure_tmp
  scan=$(ssh-keyscan -T 10 -p "$CL_PORT" -t ed25519 -- "$host" 2>/dev/null | grep -v '^#' || true)
  re='^[^ ]+ ssh-ed25519 [A-Za-z0-9+/=]+$'
  if [[ -z $scan || $scan == *$'\n'* ]] || ! [[ $scan =~ $re ]]; then
    die "could not read an ED25519 host key from $host port $CL_PORT (is Remote Login/sshd on? or use: mac-bootstrap bundle)"
  fi
  fp=$(printf '%s\n' "$scan" | ssh-keygen -lf - -E sha256 2>/dev/null | awk '{print $2}')
  [[ -n $fp ]] || die "could not compute the host-key fingerprint"
  say "Host key of $host (ED25519): $fp"
  printf 'Does this match the screen? [y/N] ' >/dev/tty
  IFS= read -r ans </dev/tty || true
  case $ans in
    y | Y | yes | YES) ;;
    *) die "fingerprint not confirmed; nothing was sent" ;;
  esac
  (umask 077; printf '%s\n' "$scan" >"$TMPD/known_hosts")
  CM_DIR=$(umask 077; mktemp -d /tmp/mbcm.XXXXXX)
  CM_SOCK="$CM_DIR/cm"
  local opts=(-p "$CL_PORT" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$TMPD/known_hosts"
    -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 -o HashKnownHosts=no
    -o ClearAllForwardings=yes -o ForwardAgent=no -o "ControlPath=$CM_SOCK")
  say "Connecting to $CL_HOST (host key pinned, strict checking)"
  ssh "${opts[@]}" -MNf -- "$CL_HOST" </dev/null || die "ssh login failed (nothing was minted or sent)"
  rc=0
  ssh "${opts[@]}" -- "$CL_HOST" "$RC_PROBE" </dev/null || rc=$?
  if ((rc != 0)); then
    die "the target is not waiting for a hand-off for $user (start the installer there first; nothing was minted)"
  fi
  client_collect
  rc=0
  printf '%s\n' "$BUNDLE" | ssh "${opts[@]}" -- "$CL_HOST" "$RC_SEND" || rc=$?
  BUNDLE=""
  if ((rc != 0)); then
    die "the target refused the bundle (exit $rc). The minted key is single-use and expires in one hour; revoke it in the Tailscale admin console if you like"
  fi
  say "Hand-off delivered to $CL_HOST. The target takes it from here; watch its screen."
}

# ---------------------------------------------------------------------------------------
# Target: macOS install path
# ---------------------------------------------------------------------------------------

step_preflight() {
  local re
  step 1 "Preflight"
  command -v curl >/dev/null || die "curl not found"
  if [[ -n $TS_HOST && ! $TS_HOST =~ ^[A-Za-z0-9-]{1,63}$ ]]; then
    die "TS_HOSTNAME must match ^[A-Za-z0-9-]{1,63}\$"
  fi
  if [[ -n $TS_TAGS_V ]]; then
    re='^tag:[a-z][a-z0-9-]*(,tag:[a-z][a-z0-9-]*)*$'
    [[ $TS_TAGS_V =~ $re ]] || die "TS_TAGS must look like tag:name[,tag:name]"
  fi
  case $TS_KEY in
    tskey-client-*)
      [[ -n $TS_TAGS_V ]] || die "an OAuth TS_AUTHKEY (tskey-client-) needs TS_TAGS (e.g. tag:bootstrap)"
      ;;
  esac
  if ((ITERM_SI)) && [[ $OS_KIND != macos ]]; then
    note "--iterm2-shell-integration is macOS only: ignored"
    ITERM_SI=0
  fi
  if [[ $OS_KIND == macos ]]; then
    note "macOS $(sw_vers -productVersion 2>/dev/null || echo '?'), arch $(uname -m)"
  else
    note "Linux, arch $(uname -m), target user $TARGET_USER"
  fi
  note "mode: $( ((DRY_RUN)) && echo dry-run || echo apply )"
  note "TS_AUTHKEY: $(setstate "$TS_KEY")"
  note "TS_TAGS: $(setstate "$TS_TAGS_V")"
  note "GH_TOKEN: $(setstate "$GH_TOK")"
  note "TS_HOSTNAME: $(setstate "$TS_HOST")"
  note "GIT_USER_NAME: $(setstate "$GIT_NAME")"
  note "GIT_USER_EMAIL: $(setstate "$GIT_EMAIL")"
  say "    done"
}

# Linux install branch: checkpoint B.
linux_install() {
  die "the Linux install is not yet implemented in this install.sh"
}

persist_shellenv() {
  local line="eval \"\$($BREWCMD shellenv)\""
  local rc="$HOME/.zprofile"
  if [[ -f $rc ]] && grep -qF -- "$line" "$rc"; then
    note "shellenv already in ~/.zprofile -> skip"
  elif ((DRY_RUN)); then
    note "DRY-RUN would append to ~/.zprofile: $line"
  else
    { [[ -s $rc ]] && printf '\n'; printf '# Homebrew (mac-bootstrap)\n%s\n' "$line"; } >>"$rc"
    note "appended Homebrew shellenv to ~/.zprofile"
  fi
}

step_homebrew() {
  step 2 "Homebrew"
  if find_brew; then
    say "    already present -> skip ($BREW)"
  else
    note "Homebrew's installer needs sudo (it will ask for your password on the terminal)"
    if ((DRY_RUN)); then
      note "sudo needed: cache credentials for the Homebrew installer (installer runs with NONINTERACTIVE=1)"
      dry sudo -v
      dry "${CURL[@]}" "$BREW_INSTALL_URL" -o /tmp/mac-bootstrap.XXXXXX/brew-install.sh
      dry env NONINTERACTIVE=1 /bin/bash /tmp/mac-bootstrap.XXXXXX/brew-install.sh
    else
      have_tty || die "Homebrew install needs a terminal for the sudo password"
      sudo -v
      ensure_tmp
      "${CURL[@]}" "$BREW_INSTALL_URL" -o "$TMPD/brew-install.sh"
      NONINTERACTIVE=1 /bin/bash "$TMPD/brew-install.sh" </dev/null
      find_brew || die "Homebrew installer finished but brew was not found"
      say "    done"
    fi
  fi
  if [[ -n $BREW ]]; then
    HAVE_BREW=1
    eval "$("$BREW" shellenv)"
    PREFIX=$("$BREW" --prefix)
    BREWCMD=$BREW
  else
    PREFIX=$(default_prefix)
    BREWCMD="$PREFIX/bin/brew"
  fi
  persist_shellenv
  TSBIN="$PREFIX/opt/tailscale/bin"
}

step_tailscale_formula() {
  step 3 "Tailscale formula"
  if [[ -d /Applications/Tailscale.app ]] || brew_cask tailscale-app; then
    die "Tailscale GUI app (tailscale-app) is installed; the formula conflicts with it. Remove it first, or use the app instead"
  fi
  if brew_formula tailscale; then
    say "    already present -> skip"
  else
    run "$BREWCMD" install tailscale
    ((DRY_RUN)) || say "    done"
  fi
}

socket_up() { ((HAVE_BREW)) && [[ -S $TS_SOCKET ]]; }
plist_present() { ((HAVE_BREW)) && [[ -e $TS_PLIST ]]; }

daemon_program() {
  local b=""
  if [[ -r $TS_PLIST ]]; then
    b=$(plutil -extract ProgramArguments.0 raw -o - "$TS_PLIST" 2>/dev/null || true)
  fi
  if [[ -z $b ]]; then
    b=$(launchctl print system/com.tailscale.tailscaled 2>/dev/null | sed -n 's/^[[:space:]]*program = //p' | head -n1 || true)
  fi
  printf '%s' "$b"
}

check_existing_daemon() {
  local b
  b=$(daemon_program)
  case $b in
    "$PREFIX/opt/tailscale/bin/tailscaled" | "$PREFIX/bin/tailscaled" | "$PREFIX/Cellar/tailscale/"*)
      note "existing com.tailscale.tailscaled runs the Homebrew binary -> ok"
      ;;
    *)
      note "WARNING: an existing com.tailscale.tailscaled LaunchDaemon runs ${b:-an unknown binary (could not read it without sudo)}"
      note "         it is not Homebrew's opt/tailscale/bin/tailscaled, so it will not follow 'brew upgrade'"
      note "         and can drift from the brew tailscale client (version mismatch)."
      note "         I will not start a second daemon next to it and will not remove it. To switch to the"
      note "         Homebrew-managed daemon, run: sudo tailscaled uninstall-system-daemon, then re-run this script."
      ;;
  esac
}

step_tailscaled() {
  step 4 "tailscaled system daemon"
  if plist_present; then check_existing_daemon; fi
  if socket_up; then
    say "    already present (socket $TS_SOCKET) -> skip"
    return
  fi
  note "sudo needed: tailscaled runs as root (LaunchDaemon)"
  local i
  if plist_present; then
    note "reusing existing $TS_PLIST (no second daemon is started)"
    run sudo launchctl load -w "$TS_PLIST"
  else
    run sudo "$BREWCMD" services start tailscale
  fi
  if ((DRY_RUN)); then return; fi
  for i in $(seq 1 30); do
    [[ -S $TS_SOCKET ]] && break
    sleep 1
  done
  [[ -S $TS_SOCKET ]] || die "tailscaled socket did not appear at $TS_SOCKET"
  say "    done"
}

ts_state() {
  local s=""
  if ((HAVE_BREW)) && [[ -x $TSBIN/tailscale ]] && socket_up; then
    s=$("$TSBIN/tailscale" status --json 2>/dev/null | plutil -extract BackendState raw -o - - 2>/dev/null || true)
  fi
  echo "${s:-NoState}"
}

gh_authed() {
  local gh="$PREFIX/bin/gh"
  if ((HAVE_BREW)) && [[ -x $gh ]] && "${GH_ENV[@]}" "$gh" auth status --active --hostname github.com >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

step_tailscale_up() {
  step 5 "tailscale up"
  maybe_handoff
  if ((SKIP_TS_UP)); then
    say "    skipped (--skip-tailscale-up)"
    NEXT_STEPS+=("Run: $TSBIN/tailscale up   (prints a login URL; the installer itself never opens a browser)")
    return
  fi
  local state ts_cmd=("$TSBIN/tailscale") extra=() keyfile content want_up=0 force=()
  state=$(ts_state)
  note "BackendState: $state"
  if ! id -Gn | grep -qw admin; then
    ts_cmd=(sudo "$TSBIN/tailscale")
    extra+=(--operator="$USER")
    note "sudo needed: user is not in the admin group"
  fi
  [[ -z $TS_HOST ]] || extra+=(--hostname="$TS_HOST")
  case $state in
    Running)
      if ((REAUTH_TS)); then
        want_up=1
      else
        say "    already present (Running) -> skip login; key not used"
        if [[ -n $TS_HOST ]]; then
          run "${ts_cmd[@]}" set --hostname="$TS_HOST"
        fi
      fi
      ;;
    Stopped)
      if ((REAUTH_TS)); then
        want_up=1
      else
        run "${ts_cmd[@]}" up --timeout=120s ${extra[@]+"${extra[@]}"}
        ((DRY_RUN)) || say "    done"
      fi
      ;;
    *) want_up=1 ;;
  esac
  if ((want_up)); then
    if ((REAUTH_TS)); then force=(--force-reauth); fi
    [[ -z $TS_TAGS_V ]] || extra+=(--advertise-tags="$TS_TAGS_V")
    if [[ -n $TS_KEY ]] || ((DRY_RUN)); then
      if ((DRY_RUN)); then
        if [[ -z $TS_KEY ]]; then note "no key yet: this is what would run once a hand-off delivers one"; fi
        note "DRY-RUN would write the key to a 0600 temp file (umask 077 in a subshell), never to argv"
        keyfile="/tmp/mac-bootstrap.XXXXXX/tskey"
      else
        ensure_tmp
        keyfile="$TMPD/tskey"
        content=$TS_KEY
        case $TS_KEY in
          tskey-client-*) content="$TS_KEY?ephemeral=false&preauthorized=true" ;;
        esac
        (umask 077; printf '%s' "$content" >"$keyfile")
        content=""
        TS_KEY=""
      fi
      run "${ts_cmd[@]}" up ${force[@]+"${force[@]}"} "--auth-key=file:$keyfile" --timeout=120s ${extra[@]+"${extra[@]}"}
      if ((DRY_RUN)); then
        note "DRY-RUN would delete the key file right after"
      else
        rm -f "$keyfile"
        say "    done"
      fi
    else
      say "    no key available (no TS_AUTHKEY, no hand-off): skipped"
      NEXT_STEPS+=("Join Tailscale: run 'mac-bootstrap handoff $USER@<this-mac-ip>' from your client Mac while this installer waits (re-run it), or re-run with TS_AUTHKEY=... ; no browser login is used")
    fi
  fi
}

step_tools() {
  step 6 "git, gh, paseo"
  local f missing=()
  for f in git gh; do
    if brew_formula "$f"; then note "$f: already present -> skip"; else missing+=("$f"); fi
  done
  if ((${#missing[@]})); then
    run "$BREWCMD" install "${missing[@]}"
  fi
  if brew_cask paseo; then
    note "paseo: already present -> skip"
  else
    run "$BREWCMD" install --cask paseo
  fi
  if ((DRY_RUN)); then return; fi
  say "    done"
}

step_gh_auth() {
  step 7 "gh auth"
  if ((SKIP_GH_AUTH)); then
    say "    skipped (--skip-gh-auth)"
    NEXT_STEPS+=("Run: gh auth login --hostname github.com && gh auth setup-git --hostname github.com")
    return
  fi
  local gh="$PREFIX/bin/gh" authed=0
  if gh_authed; then
    authed=1
  fi
  if ((authed && !REAUTH_GH)); then
    say "    already present (stored credentials for github.com) -> skip login"
  elif [[ -n $GH_TOK ]]; then
    if ((DRY_RUN)); then
      printf '    DRY-RUN would run: printf %%s <GH_TOKEN masked> |'
      printf ' %q' "${GH_ENV[@]}" "$gh" auth login --hostname github.com --with-token
      printf '\n'
    else
      printf '%s' "$GH_TOK" | "${GH_ENV[@]}" "$gh" auth login --hostname github.com --with-token
      GH_TOK=""
      authed=1
      say "    done"
    fi
  elif ((DRY_RUN)); then
    note "no GH_TOKEN yet: with a hand-off this would run: printf %s <GH_TOKEN masked> | gh auth login --hostname github.com --with-token"
    authed=1
  else
    say "    no GH_TOKEN and no hand-off -> skip (no browser login is used)"
    NEXT_STEPS+=("Run: gh auth login --hostname github.com && gh auth setup-git --hostname github.com")
    return
  fi
  if ((DRY_RUN)); then
    dry "${GH_ENV[@]}" "$gh" auth setup-git --hostname github.com
  elif ((authed)); then
    "${GH_ENV[@]}" "$gh" auth setup-git --hostname github.com
  fi
}

step_git_identity() {
  step 8 "git identity"
  if [[ -z $GIT_NAME && -z $GIT_EMAIL ]]; then
    say "    skipped (GIT_USER_NAME / GIT_USER_EMAIL not set)"
    NEXT_STEPS+=("Set your git identity: git config --global user.name ... && git config --global user.email ...")
    return
  fi
  local git="$PREFIX/bin/git" cur
  local keys=(user.name user.email) vals=("$GIT_NAME" "$GIT_EMAIL") i
  for i in 0 1; do
    [[ -n ${vals[i]} ]] || continue
    cur=""
    if ((HAVE_BREW)) && [[ -x $git ]]; then
      cur=$("$git" config --global --get "${keys[i]}" 2>/dev/null || true)
    fi
    if [[ -n $cur ]] && ((!SET_GIT)); then
      note "${keys[i]}: already present -> skip (use --set-git-identity to overwrite)"
    elif ((DRY_RUN)); then
      dry "$git" config --global "${keys[i]}" "${vals[i]}"
    else
      "$git" config --global "${keys[i]}" "${vals[i]}"
      note "${keys[i]}: set"
    fi
  done
}

step_iterm2() {
  step 9 "iTerm2 shell integration"
  if ((!ITERM_SI)); then
    say "    skipped (needs --iterm2-shell-integration)"
    return
  fi
  local sh rc file url line sum
  sh=$(basename "${SHELL:-/bin/zsh}")
  case $sh in
    zsh) rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bash_profile" ;;
    *)
      say "    unsupported login shell '$sh' -> skip (see https://iterm2.com/documentation-shell-integration.html)"
      NEXT_STEPS+=("Install iTerm2 shell integration manually for $sh")
      return
      ;;
  esac
  file="$HOME/.iterm2_shell_integration.$sh"
  url="$ITERM_SI_BASE/$sh"
  line="test -e \"\${HOME}/.iterm2_shell_integration.$sh\" && source \"\${HOME}/.iterm2_shell_integration.$sh\" # mac-bootstrap iterm2"
  if [[ -s $file ]]; then
    note "iterm2_shell_integration.$sh in home: already present -> skip download"
    note "sha256 of installed file: $(shasum -a 256 <"$file" | cut -d' ' -f1)"
  elif ((DRY_RUN)); then
    dry "${CURL[@]}" "$url" -o "$file"
  else
    ensure_tmp
    "${CURL[@]}" "$url" -o "$TMPD/si"
    [[ -s $TMPD/si ]] || die "empty iTerm2 shell integration download"
    sum=$(shasum -a 256 <"$TMPD/si" | cut -d' ' -f1)
    mv "$TMPD/si" "$file"
    note "installed ~/.iterm2_shell_integration.$sh, sha256 $sum (unpinned download)"
  fi
  if [[ -f $rc ]] && grep -qF "# mac-bootstrap iterm2" "$rc"; then
    note "source line already in ~${rc#"$HOME"} -> skip"
  elif ((DRY_RUN)); then
    note "DRY-RUN would append to ~${rc#"$HOME"}: $line"
  else
    { [[ -s $rc ]] && printf '\n'; printf '%s\n' "$line"; } >>"$rc"
    note "appended source line to ~${rc#"$HOME"}"
  fi
  NEXT_STEPS+=("Open a new terminal tab so iTerm2 shell integration loads")
}

step_summary() {
  step 10 "Summary"
  local ip="" name="" short fqdn
  if ((DRY_RUN)); then
    note "DRY-RUN: would show the Tailscale IP and MagicDNS name here (nothing changed)"
    note "then: ssh <user>@<host>"
    short="<this-mac-short-name>"
    fqdn="<this-mac-fqdn>"
  else
    if [[ -x $TSBIN/tailscale ]]; then
      ip=$("$TSBIN/tailscale" ip -4 2>/dev/null | head -n1 || true)
      name=$("$TSBIN/tailscale" status --json 2>/dev/null | plutil -extract Self.DNSName raw -o - - 2>/dev/null || true)
      name=${name%.}
      note "Tailscale IP: ${ip:-unavailable}"
      note "MagicDNS name: ${name:-unavailable}"
      if [[ -n $name ]]; then note "connect: ssh $USER@$name"; fi
    fi
    short=$(hostname -s 2>/dev/null || echo unknown)
    fqdn=$(hostname -f 2>/dev/null || echo unknown)
  fi
  note "--host value for the client: $short (this Mac's 'hostname -s'); iTerm2 shell integration reports 'hostname -f' = $fqdn, which is independent of the Tailscale name and TS_HOSTNAME"
  note "on the Mac you ssh from, for automatic profile switching:"
  note "  curl -fsSL \"<origin>/iterm2-client.sh\" | bash -s -- --host $short --user <ssh-user> --shell-integration"
  note "start Paseo: open -a Paseo (desktop app), or run the paseo CLI the cask links"
  if ssh_listening; then
    note "Remote Login: on"
  else
    NEXT_STEPS+=("Enable Remote Login: System Settings > General > Sharing > Remote Login (needs the macOS UI)")
  fi
  NEXT_STEPS+=("Optional: Screen Sharing: System Settings > General > Sharing > Screen Sharing (needs the macOS UI)")
  say "    still manual:"
  local s
  for s in ${NEXT_STEPS[@]+"${NEXT_STEPS[@]}"}; do say "      - $s"; done
}

main() {
  USER=${USER:-$(id -un)}
  unset TS_KEY GH_TOK
  TS_KEY=${TS_AUTHKEY-}
  GH_TOK=${GH_TOKEN-}
  unset TS_AUTHKEY GH_TOKEN
  export -n TS_KEY GH_TOK
  TS_TAGS_V=${TS_TAGS-}
  TS_HOST=${TS_HOSTNAME-}
  GIT_NAME=${GIT_USER_NAME-}
  GIT_EMAIL=${GIT_USER_EMAIL-}
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  parse_args "$@"
  case $MODE in
    client-setup) client_setup; return ;;
    handoff) cmd_handoff; return ;;
    bundle) cmd_bundle; return ;;
  esac
  detect_os
  target_resolve
  step_preflight
  if [[ $OS_KIND == linux ]]; then
    linux_install
  fi
  step_homebrew
  step_tailscale_formula
  step_tailscaled
  step_tailscale_up
  step_tools
  step_gh_auth
  step_git_identity
  step_iterm2
  step_summary
}

main "$@"
}
