#!/usr/bin/env bash
# mac-bootstrap iterm2-client.sh — writes an iTerm2 Dynamic Profile for SSH into a bootstrapped Mac.
#
#   curl -fsSL "<origin>/iterm2-client.sh" | bash -s -- --host <short-hostname> \
#       [--user <ssh-user>] [--badge <text>] [--shell-integration] [--dry-run] \
#       [--profiles-dir <dir>] [-h|--help]
#
# Writes <profiles-dir>/mac-bootstrap-<host>.json (default profiles-dir:
# ~/Library/Application Support/iTerm2/DynamicProfiles): one profile with a badge and
# Bound Hosts rules, so iTerm2 switches to it automatically while you are SSHed into <host>.
# iTerm2 needs shell integration on every machine taking part in automatic profile
# switching: on the remote (install.sh --iterm2-shell-integration) to report user@host,
# and on this client Mac to switch back after ssh exits. --shell-integration (opt-in)
# installs it here with the same idempotent logic as install.sh step 9.
# --host is the bootstrapped Mac's short hostname, exactly as install.sh step 10 prints it
# (`hostname -s` on that Mac). It is NOT the Tailscale/MagicDNS name or TS_HOSTNAME: iTerm2
# shell integration reports user@`hostname -f` of the remote (usually <LocalHostName>.local),
# which can differ from those. The rules match <host> and <host>.* (.local, .ts.net, ...).
# With --dry-run, stdout is exactly the JSON; all notes and the target path go to stderr.
#
# curl|bash hardening: the whole script is one `{ ... }` group whose closing brace is the
# last line, so a truncated download is a syntax error and nothing executes. Residual
# risks: an empty/failed download makes `bash` run nothing and exit 0 (the outer shell owns
# pipefail); the shell-integration file is an unpinned HTTPS download (its sha256 is printed).
{
set -euo pipefail

DRY_RUN=0
HOST=""
SSH_USER=""
BADGE=""
SHELL_INT=0
PROFILES_DIR=""
TMPF=""
TMPS=""

usage() {
  cat <<'EOF'
Usage: curl -fsSL <origin>/iterm2-client.sh | bash -s -- --host <short-hostname> [options]

Options:
  --host <short-name>    short hostname of the bootstrapped Mac, as printed by install.sh step 10
                         (`hostname -s` there); NOT its Tailscale/MagicDNS name or TS_HOSTNAME,
                         because iTerm2 shell integration reports `hostname -f` (required)
  --user <name>          SSH user; adds user@host Bound Hosts rules
  --badge <text>         badge text (default: the host)
  --shell-integration    also install iTerm2 shell integration on this Mac (idempotent)
  --profiles-dir <dir>   default: ~/Library/Application Support/iTerm2/DynamicProfiles
  --dry-run              print the JSON and target path; write nothing
  -h, --help             show this help
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -f ${TMPF:+"$TMPF"} ${TMPS:+"$TMPS"}; }

json_escape() {
  local s=$1 out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      \\) out+="\\\\" ;;
      '"') out+='\"' ;;
      *) out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

parse_args() {
  while (($#)); do
    case $1 in
      --host | --user | --badge | --profiles-dir)
        (($# >= 2)) || { printf 'missing value for %s\n' "$1" >&2; usage >&2; exit 2; }
        case $1 in
          --host) HOST=$2 ;;
          --user) SSH_USER=$2 ;;
          --badge) BADGE=$2 ;;
          --profiles-dir) PROFILES_DIR=$2 ;;
        esac
        shift
        ;;
      --shell-integration) SHELL_INT=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h | --help) usage; exit 0 ;;
      *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

validate() {
  [[ -n $HOST ]] || { printf -- '--host is required\n' >&2; usage >&2; exit 2; }
  [[ $HOST =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ && $HOST != *..* && ! $HOST =~ (^|\.)[^.]{64,}(\.|$) ]] ||
    { printf 'invalid --host (allowed: letters, digits, dots, hyphens)\n' >&2; exit 2; }
  if [[ -n $SSH_USER && ! $SSH_USER =~ ^[A-Za-z_][A-Za-z0-9._-]{0,31}$ ]]; then
    printf 'invalid --user (allowed: letters, digits, . _ -; max 32)\n' >&2
    exit 2
  fi
  if [[ -z $BADGE ]]; then
    BADGE=$HOST
    if ((${#BADGE} > 64)); then BADGE=${HOST%%.*}; fi
  fi
  if ((${#BADGE} > 64)) || [[ $BADGE =~ [[:cntrl:]] ]]; then
    printf 'invalid --badge (max 64 chars, no control characters)\n' >&2
    exit 2
  fi
}

guid_for() {
  local h
  h=$(printf 'mac-bootstrap:%s' "$1" | shasum -a 256 | cut -c1-32 | tr 'a-f' 'A-F')
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

build_json() {
  local short=${HOST%%.*} guid hosts=() h out="" sep=""
  guid=$(guid_for "$HOST")
  hosts+=("$short" "$short.*")
  [[ $HOST == "$short" ]] || hosts+=("$HOST")
  if [[ -n $SSH_USER ]]; then
    hosts+=("$SSH_USER@$short" "$SSH_USER@$short.*")
    [[ $HOST == "$short" ]] || hosts+=("$SSH_USER@$HOST")
  fi
  for h in "${hosts[@]}"; do
    out+="$sep\"$(json_escape "$h")\""
    sep=", "
  done
  printf '{\n  "Profiles": [\n    {\n'
  printf '      "Name": "mac-bootstrap: %s",\n' "$(json_escape "$HOST")"
  printf '      "Guid": "%s",\n' "$guid"
  printf '      "Dynamic Profile Parent Name": "Default",\n'
  printf '      "Badge Text": "%s",\n' "$(json_escape "$BADGE")"
  printf '      "Bound Hosts": [%s]\n' "$out"
  printf '    }\n  ]\n}\n'
}

profile_filename() {
  local base="mac-bootstrap-$HOST"
  if ((${#base} > 100)); then
    base="mac-bootstrap-${HOST:0:60}-$(printf 'mac-bootstrap:%s' "$HOST" | shasum -a 256 | cut -c1-8)"
  fi
  printf '%s.json' "$base"
}

install_shell_integration() {
  local sh rc file url line sum
  sh=$(basename "${SHELL:-/bin/zsh}")
  case $sh in
    zsh) rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bash_profile" ;;
    *)
      printf "shell integration: unsupported login shell '%s' -> skipped (see https://iterm2.com/documentation-shell-integration.html)\n" "$sh"
      return 0
      ;;
  esac
  file="$HOME/.iterm2_shell_integration.$sh"
  url="https://iterm2.com/shell_integration/$sh"
  line="test -e \"\${HOME}/.iterm2_shell_integration.$sh\" && source \"\${HOME}/.iterm2_shell_integration.$sh\" # mac-bootstrap iterm2"
  if [[ -s $file ]]; then
    printf 'shell integration: ~/.iterm2_shell_integration.%s already present -> skip download (sha256 %s)\n' "$sh" "$(shasum -a 256 <"$file" | cut -d' ' -f1)"
  elif ((DRY_RUN)); then
    printf 'DRY-RUN would run: curl --proto =https --tlsv1.2 -fsSL %s -o ~/.iterm2_shell_integration.%s\n' "$url" "$sh"
  else
    TMPS=$(umask 077; mktemp "${TMPDIR:-/tmp}/mb-si.XXXXXX")
    curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$TMPS"
    [[ -s $TMPS ]] || die "empty iTerm2 shell integration download"
    sum=$(shasum -a 256 <"$TMPS" | cut -d' ' -f1)
    mv "$TMPS" "$file"
    TMPS=""
    printf 'shell integration: installed ~/.iterm2_shell_integration.%s, sha256 %s (unpinned download)\n' "$sh" "$sum"
  fi
  if [[ -f $rc ]] && grep -qF "# mac-bootstrap iterm2" "$rc"; then
    printf 'shell integration: source line already in ~%s -> skip\n' "${rc#"$HOME"}"
  elif ((DRY_RUN)); then
    printf 'DRY-RUN would append to ~%s: %s\n' "${rc#"$HOME"}" "$line"
  else
    { [[ -s $rc ]] && printf '\n'; printf '%s\n' "$line"; } >>"$rc"
    printf 'shell integration: appended source line to ~%s (open a new tab)\n' "${rc#"$HOME"}"
  fi
}

main() {
  trap cleanup EXIT
  parse_args "$@"
  validate
  PROFILES_DIR=${PROFILES_DIR:-$HOME/Library/Application Support/iTerm2/DynamicProfiles}
  local target shown json
  target="$PROFILES_DIR/$(profile_filename)"
  shown="~${target#"$HOME"}"; [[ $target == "$HOME"/* ]] || shown=$target
  json=$(build_json)
  if ((DRY_RUN)); then
    printf 'DRY-RUN: would write %s\n' "$shown" >&2
    printf '%s\n' "$json"
  else
    mkdir -p "$PROFILES_DIR"
    TMPF=$(umask 077; mktemp "$PROFILES_DIR/../.mac-bootstrap.XXXXXX")
    printf '%s\n' "$json" >"$TMPF"
    chmod 644 "$TMPF"
    mv -f "$TMPF" "$target"
    TMPF=""
    printf 'wrote %s\n' "$shown"
  fi
  if ((SHELL_INT)); then
    if ((DRY_RUN)); then install_shell_integration >&2; else install_shell_integration; fi
  else
    printf 'note: automatic profile switching also needs iTerm2 shell integration on this Mac (rerun with --shell-integration) and on %s.\n' "$HOST" >&2
  fi
}

main "$@"
}
