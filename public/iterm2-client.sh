#!/usr/bin/env bash
# mac-bootstrap iterm2-client.sh — writes an iTerm2 Dynamic Profile for SSH into a bootstrapped Mac.
#
#   curl -fsSL "<origin>/iterm2-client.sh" | bash -s -- --host <tailscale-hostname> \
#       [--user <ssh-user>] [--badge <text>] [--dry-run] [--profiles-dir <dir>] [-h|--help]
#
# Writes <profiles-dir>/mac-bootstrap-<host>.json (default profiles-dir:
# ~/Library/Application Support/iTerm2/DynamicProfiles): one profile with a badge and
# Bound Hosts rules, so iTerm2 switches to it automatically while you are SSHed into <host>.
# Automatic profile switching needs iTerm2 shell integration on the remote machine
# (install.sh --iterm2-shell-integration there), per the iTerm2 documentation.
#
# Residual curl|bash risk: an empty/failed download makes `bash` run nothing and exit 0
# (the outer shell owns pipefail); a download cut inside the final `main "$@"` line runs
# main without arguments, which fails on the missing --host. Everything else is inside
# functions, so an earlier truncation is a syntax error and nothing executes.
set -euo pipefail

DRY_RUN=0
HOST=""
SSH_USER=""
BADGE=""
PROFILES_DIR=""
TMPF=""

usage() {
  cat <<'EOF'
Usage: curl -fsSL <origin>/iterm2-client.sh | bash -s -- --host <tailscale-hostname> [options]

Options:
  --host <name>          Tailscale hostname or MagicDNS name of the bootstrapped Mac (required)
  --user <name>          SSH user; adds user@host Bound Hosts rules
  --badge <text>         badge text (default: the host)
  --profiles-dir <dir>   default: ~/Library/Application Support/iTerm2/DynamicProfiles
  --dry-run              print the JSON and target path; write nothing
  -h, --help             show this help
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n $TMPF ]]; then rm -f "$TMPF"; fi; }

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
      --dry-run) DRY_RUN=1 ;;
      -h | --help) usage; exit 0 ;;
      *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

validate() {
  [[ -n $HOST ]] || { printf -- '--host is required\n' >&2; usage >&2; exit 2; }
  [[ $HOST =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ && $HOST != *..* ]] ||
    { printf 'invalid --host (allowed: letters, digits, dots, hyphens)\n' >&2; exit 2; }
  if [[ -n $SSH_USER && ! $SSH_USER =~ ^[A-Za-z_][A-Za-z0-9._-]{0,31}$ ]]; then
    printf 'invalid --user (allowed: letters, digits, . _ -; max 32)\n' >&2
    exit 2
  fi
  BADGE=${BADGE:-$HOST}
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
  hosts+=("$short" "$short.*.ts.net")
  [[ $HOST == "$short" ]] || hosts+=("$HOST")
  if [[ -n $SSH_USER ]]; then
    hosts+=("$SSH_USER@$short" "$SSH_USER@$short.*.ts.net")
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

main() {
  trap cleanup EXIT
  parse_args "$@"
  validate
  PROFILES_DIR=${PROFILES_DIR:-$HOME/Library/Application Support/iTerm2/DynamicProfiles}
  local target="$PROFILES_DIR/mac-bootstrap-$HOST.json" shown json
  shown="~${target#"$HOME"}"; [[ $target == "$HOME"/* ]] || shown=$target
  json=$(build_json)
  if ((DRY_RUN)); then
    printf 'DRY-RUN: would write %s\n%s\n' "$shown" "$json"
    return 0
  fi
  mkdir -p "$PROFILES_DIR"
  umask 077
  TMPF=$(mktemp "$PROFILES_DIR/../.mac-bootstrap.XXXXXX")
  printf '%s\n' "$json" >"$TMPF"
  chmod 644 "$TMPF"
  mv -f "$TMPF" "$target"
  TMPF=""
  printf 'wrote %s\n' "$shown"
  printf 'iTerm2 picks it up automatically. Profile switching needs shell integration on %s.\n' "$HOST"
}

main "$@"
