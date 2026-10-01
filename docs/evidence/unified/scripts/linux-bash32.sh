#!/bin/bash
# Runs the Linux dry-run flow functions under THIS shell (macOS /bin/bash 3.2) with fake os-release files,
# to prove the Linux branch parses and runs on bash 3.2 too. Nothing is executed for real (DRY_RUN=1).
# usage: linux-bash32.sh <install.sh>
SRC=$1; echo "bash $BASH_VERSION"
tmp=$(mktemp); grep -v '^main "\$@"$' "$SRC" >"$tmp"
for fam in ubuntu debian fedora rocky arch; do
  ( # shellcheck disable=SC1090
    source "$tmp"; set +e
    case $fam in
      ubuntu) id=ubuntu; ver=24.04; code=noble; like="" ;; debian) id=debian; ver=13; code=trixie; like="" ;;
      fedora) id=fedora; ver=44; code=""; like="" ;; rocky) id=rocky; ver=9.3; code=""; like="rhel centos fedora" ;; arch) id=arch; ver=""; code=""; like="" ;;
    esac
    f=$(mktemp); printf 'ID=%s\nID_LIKE="%s"\nVERSION_ID="%s"\nVERSION_CODENAME=%s\nPRETTY_NAME="Fake %s"\n' "$id" "$like" "$ver" "$code" "$id" >"$f"
    DRY_RUN=1; OS_KIND=linux; TARGET_USER=$(id -un); TARGET_UID=$(id -u); TS_TAGS_V=tag:bootstrap; TS_KEY=tskey-auth-DUMMYb32; GH_TOK=ghp_DUMMYb32; export MB_OS_RELEASE=$f
    echo; echo "=================== $fam (bash $BASH_VERSION)"
    SUDO_CMD=(sudo); linux_detect; echo "detected: $OS_PRETTY / $LINUX_FAMILY"; linux_init
    step_linux_repos 2>&1 | grep -v '^$' | head -12; step_linux_tailscale | head -3; step_linux_services 2>&1 | head -8; step_linux_tools 2>&1 | head -6
    rm -f "$f" )
done
rm -f "$tmp"
