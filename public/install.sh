#!/usr/bin/env bash
# mac-bootstrap install.sh — bootstraps a Mac for remote work over Tailscale.
#
#   curl -fsSL "<origin>/install.sh" | bash -s -- [--dry-run] [--skip-tailscale-up] \
#       [--skip-gh-auth] [--iterm2-shell-integration] [-h|--help]
#
# Optional environment: TS_AUTHKEY, GH_TOKEN, TS_HOSTNAME, GIT_USER_NAME, GIT_USER_EMAIL.
# Secrets are copied into non-exported variables and unset from the environment as the
# first action, so no child process inherits them. They never appear in argv, logs or
# `set -x`; the Tailscale key goes through a 0600 temp file (--auth-key=file:...), the
# GitHub token through stdin.
#
# Test seam: MB_BREW_CANDIDATES (colon-separated brew paths) overrides Homebrew discovery.
# It is honoured only together with --dry-run and is inert otherwise.
#
# Residual curl|bash risks this script cannot close:
#  - an empty or fully failed download makes `bash` read an empty script and exit 0
#    silently (the outer shell, not this script, owns pipefail for `curl | bash`);
#  - a download truncated exactly before the trailing `main "$@"` line runs nothing,
#    and one truncated inside that line runs `main` without its arguments (flags lost,
#    defaults applied). Everything else is inside functions, so a truncation earlier
#    is a syntax error and nothing executes. Use --dry-run first if in doubt.
set -euo pipefail

readonly BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
readonly TS_SOCKET="/var/run/tailscaled.socket"
readonly TS_PLIST="/Library/LaunchDaemons/com.tailscale.tailscaled.plist"
readonly ITERM_SI_BASE="https://iterm2.com/shell_integration"
readonly TOTAL=10

DRY_RUN=0
SKIP_TS_UP=0
SKIP_GH_AUTH=0
ITERM_SI=0
TS_KEY=""
GH_TOK=""
TS_HOST=""
GIT_NAME=""
GIT_EMAIL=""
BREW=""
PREFIX=""
TMPD=""
TSBIN=""
NEXT_STEPS=()

usage() {
  cat <<'EOF'
Usage: curl -fsSL <origin>/install.sh | bash -s -- [options]

Options:
  --dry-run                    show every step and the exact commands; change nothing
  --skip-tailscale-up          do not run `tailscale up`
  --skip-gh-auth               do not authenticate gh
  --iterm2-shell-integration   install iTerm2 shell integration for the login shell
  -h, --help                   show this help

Environment (optional): TS_AUTHKEY, GH_TOKEN, TS_HOSTNAME, GIT_USER_NAME, GIT_USER_EMAIL
EOF
}

say() { printf '%s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n[%s/%s] %s\n' "$1" "$TOTAL" "$2"; }

cleanup() {
  if [[ -n $TMPD && -d $TMPD ]]; then
    rm -rf "$TMPD"
  fi
}

ensure_tmp() {
  if [[ -z $TMPD ]]; then
    umask 077
    TMPD=$(mktemp -d "${TMPDIR:-/tmp}/mac-bootstrap.XXXXXX")
  fi
}

# run <cmd...>: execute, or print in dry-run. Children never read the script from stdin.
run() {
  if ((DRY_RUN)); then
    printf '    DRY-RUN would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@" </dev/null
  fi
}

have_tty() { ( : </dev/tty ) 2>/dev/null; }

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

parse_args() {
  while (($#)); do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --skip-tailscale-up) SKIP_TS_UP=1 ;;
      --skip-gh-auth) SKIP_GH_AUTH=1 ;;
      --iterm2-shell-integration) ITERM_SI=1 ;;
      -h | --help) usage; exit 0 ;;
      *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

setstate() { if [[ -n $1 ]]; then echo set; else echo "not set"; fi; }

step_preflight() {
  step 1 "Preflight"
  [[ $(uname -s) == Darwin ]] || die "macOS only (found $(uname -s))"
  ((EUID != 0)) || die "do not run as root; the script calls sudo only where needed"
  command -v curl >/dev/null || die "curl not found"
  if [[ -n $TS_HOST && ! $TS_HOST =~ ^[A-Za-z0-9-]{1,63}$ ]]; then
    die "TS_HOSTNAME must match ^[A-Za-z0-9-]{1,63}\$"
  fi
  note "macOS $(sw_vers -productVersion 2>/dev/null || echo '?'), arch $(uname -m)"
  note "mode: $( ((DRY_RUN)) && echo dry-run || echo apply )"
  note "TS_AUTHKEY: $(setstate "$TS_KEY")"
  note "GH_TOKEN: $(setstate "$GH_TOK")"
  note "TS_HOSTNAME: $(setstate "$TS_HOST")"
  note "GIT_USER_NAME: $(setstate "$GIT_NAME")"
  note "GIT_USER_EMAIL: $(setstate "$GIT_EMAIL")"
  say "    done"
}

persist_shellenv() {
  local line="eval \"\$(${BREW:-$(default_prefix)/bin/brew} shellenv)\""
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
      note "DRY-RUN would run: sudo -v   (reason: cache credentials for the Homebrew installer)"
      note "DRY-RUN would run: curl -fsSL $BREW_INSTALL_URL -o <temp>/brew-install.sh"
      note "DRY-RUN would run: env NONINTERACTIVE=1 /bin/bash <temp>/brew-install.sh"
    else
      have_tty || die "Homebrew install needs a terminal for the sudo password"
      sudo -v
      ensure_tmp
      curl -fsSL "$BREW_INSTALL_URL" -o "$TMPD/brew-install.sh"
      NONINTERACTIVE=1 /bin/bash "$TMPD/brew-install.sh" </dev/null
      find_brew || die "Homebrew installer finished but brew was not found"
      say "    done"
    fi
  fi
  if [[ -n $BREW ]]; then
    eval "$("$BREW" shellenv)"
    PREFIX=$("$BREW" --prefix)
  else
    PREFIX=/nonexistent-homebrew-prefix
  fi
  persist_shellenv
  TSBIN="$PREFIX/opt/tailscale/bin"
}

socket_up() { [[ -n $BREW && -S $TS_SOCKET ]]; }

step_tailscale_formula() {
  step 3 "Tailscale formula"
  if [[ -d /Applications/Tailscale.app ]] || brew_cask tailscale-app; then
    die "Tailscale GUI app (tailscale-app) is installed; the formula conflicts with it. Remove it first, or use the app instead"
  fi
  if brew_formula tailscale; then
    say "    already present -> skip"
  else
    run "${BREW:-brew}" install tailscale
    ((DRY_RUN)) || say "    done"
  fi
}

step_tailscaled() {
  step 4 "tailscaled system daemon"
  if socket_up; then
    say "    already present (socket $TS_SOCKET) -> skip"
    return
  fi
  note "sudo needed: tailscaled runs as root (LaunchDaemon)"
  local i
  if [[ -n $BREW && -e $TS_PLIST ]]; then
    note "reusing existing $TS_PLIST"
    run sudo launchctl load -w "$TS_PLIST"
  else
    run sudo "${BREW:-brew}" services start tailscale
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
  if [[ -x $TSBIN/tailscale ]] && socket_up; then
    s=$("$TSBIN/tailscale" status --json 2>/dev/null | plutil -extract BackendState raw -o - - 2>/dev/null || true)
  fi
  echo "${s:-NoState}"
}

step_tailscale_up() {
  step 5 "tailscale up"
  if ((SKIP_TS_UP)); then
    say "    skipped (--skip-tailscale-up)"
    NEXT_STEPS+=("Run: $TSBIN/tailscale up")
    return
  fi
  local state ts_cmd=("$TSBIN/tailscale") extra=() keyfile
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
      say "    already present (Running) -> skip login; key not used"
      if [[ -n $TS_HOST ]]; then
        run "${ts_cmd[@]}" set --hostname="$TS_HOST"
      fi
      ;;
    Stopped)
      run "${ts_cmd[@]}" up --timeout=120s ${extra[@]+"${extra[@]}"}
      ((DRY_RUN)) || say "    done"
      ;;
    *)
      if [[ -n $TS_KEY ]]; then
        if ((DRY_RUN)); then
          note "DRY-RUN would write the key to a 0600 temp file (umask 077), never to argv"
          keyfile="/tmp/mac-bootstrap.XXXXXX/tskey"
        else
          ensure_tmp
          keyfile="$TMPD/tskey"
          (umask 077; printf '%s' "$TS_KEY" >"$keyfile")
          TS_KEY=""
        fi
        run "${ts_cmd[@]}" up "--auth-key=file:$keyfile" --timeout=120s ${extra[@]+"${extra[@]}"}
        if ((DRY_RUN)); then
          note "DRY-RUN would delete the key file right after"
        else
          rm -f "$keyfile"
          say "    done"
        fi
      else
        note "no TS_AUTHKEY: interactive login; open the printed URL in a browser"
        if ((DRY_RUN)); then
          run "${ts_cmd[@]}" up --timeout=300s ${extra[@]+"${extra[@]}"}
        else
          "${ts_cmd[@]}" up --timeout=300s ${extra[@]+"${extra[@]}"} </dev/null
          say "    done"
        fi
      fi
      ;;
  esac
}

step_tools() {
  step 6 "git, gh, paseo"
  local f missing=()
  for f in git gh; do
    if brew_formula "$f"; then note "$f: already present -> skip"; else missing+=("$f"); fi
  done
  if ((${#missing[@]})); then
    run "${BREW:-brew}" install "${missing[@]}"
  fi
  if brew_cask paseo; then
    note "paseo: already present -> skip"
  else
    run "${BREW:-brew}" install --cask paseo
  fi
  if ((DRY_RUN)); then return; fi
  say "    done"
}

gh_clean() {
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN "$PREFIX/bin/gh" "$@"
}

step_gh_auth() {
  step 7 "gh auth"
  if ((SKIP_GH_AUTH)); then
    say "    skipped (--skip-gh-auth)"
    NEXT_STEPS+=("Run: gh auth login && gh auth setup-git")
    return
  fi
  local gh="$PREFIX/bin/gh" authed=0
  if [[ -x $gh ]] && gh_clean auth status >/dev/null 2>&1; then authed=1; fi
  if ((authed)); then
    say "    already present (stored credentials) -> skip login"
  elif [[ -n $GH_TOK ]]; then
    if ((DRY_RUN)); then
      note "DRY-RUN would run: printf <GH_TOKEN, masked> | env -u GH_TOKEN -u GITHUB_TOKEN gh auth login --with-token"
    else
      printf '%s' "$GH_TOK" | gh_clean auth login --with-token
      GH_TOK=""
      authed=1
      say "    done"
    fi
  elif have_tty; then
    if ((DRY_RUN)); then
      note "DRY-RUN would run: gh auth login --hostname github.com --git-protocol https --web  (stdin from /dev/tty)"
    else
      gh_clean auth login --hostname github.com --git-protocol https --web </dev/tty >/dev/tty
      authed=1
      say "    done"
    fi
  else
    say "    no GH_TOKEN and no terminal -> skip"
    NEXT_STEPS+=("Run: gh auth login && gh auth setup-git")
    return
  fi
  if ((authed || DRY_RUN)); then
    if ((DRY_RUN)); then
      note "DRY-RUN would run: gh auth setup-git"
    else
      gh_clean auth setup-git
    fi
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
    [[ -x $git ]] && cur=$("$git" config --global --get "${keys[i]}" 2>/dev/null || true)
    if [[ -n $cur ]]; then
      note "${keys[i]}: already present -> skip (never overwritten)"
    elif ((DRY_RUN)); then
      note "DRY-RUN would run: git config --global ${keys[i]} ${vals[i]}"
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
  local sh rc file url line
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
  elif ((DRY_RUN)); then
    note "DRY-RUN would run: curl -fsSL $url -o ~/.iterm2_shell_integration.$sh"
  else
    ensure_tmp
    curl -fsSL "$url" -o "$TMPD/si"
    [[ -s $TMPD/si ]] || die "empty iTerm2 shell integration download"
    mv "$TMPD/si" "$file"
  fi
  if [[ -f $rc ]] && grep -qF "# mac-bootstrap iterm2" "$rc"; then
    note "source line already in ~${rc#"$HOME"} -> skip"
  elif ((DRY_RUN)); then
    note "DRY-RUN would append to ~${rc#"$HOME"}: $line"
  else
    { [[ -s $rc ]] && printf '\n'; printf '%s\n' "$line"; } >>"$rc"
    note "appended source line to ~${rc#"$HOME"}"
  fi
  NEXT_STEPS+=("Open a new terminal tab so iTerm2 shell integration loads (also install it on the Mac you ssh into for automatic profile switching)")
}

step_summary() {
  step 10 "Summary"
  local ip="" name=""
  if ((DRY_RUN)); then
    note "DRY-RUN: would show the Tailscale IP and MagicDNS name here (nothing changed)"
    note "then: ssh <user>@<host>"
  elif [[ -x $TSBIN/tailscale ]]; then
    ip=$("$TSBIN/tailscale" ip -4 2>/dev/null | head -n1 || true)
    name=$("$TSBIN/tailscale" status --json 2>/dev/null | plutil -extract Self.DNSName raw -o - - 2>/dev/null || true)
    name=${name%.}
    note "Tailscale IP: ${ip:-unavailable}"
    note "MagicDNS name: ${name:-unavailable}"
    if [[ -n $name ]]; then note "connect: ssh $USER@$name"; fi
  fi
  NEXT_STEPS+=("Enable Remote Login: System Settings > General > Sharing > Remote Login (needs the macOS UI)")
  say "    still manual:"
  local s
  for s in ${NEXT_STEPS[@]+"${NEXT_STEPS[@]}"}; do say "      - $s"; done
}

main() {
  TS_KEY=${TS_AUTHKEY-}
  GH_TOK=${GH_TOKEN-}
  unset TS_AUTHKEY GH_TOKEN
  TS_HOST=${TS_HOSTNAME-}
  GIT_NAME=${GIT_USER_NAME-}
  GIT_EMAIL=${GIT_USER_EMAIL-}
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  parse_args "$@"
  step_preflight
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
