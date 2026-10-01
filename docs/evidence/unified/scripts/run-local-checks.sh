#!/usr/bin/env bash
# Local (no container) checks on the frozen install.sh. Run at the repo root. Every output starts with the install.sh sha256.
set -u
SHA=$(shasum -a 256 public/install.sh | cut -d' ' -f1); H="install.sh sha256: $SHA"
S=docs/evidence/unified/scripts; HD=docs/evidence/unified/handoff; I=docs/evidence/unified/integration; L=docs/evidence/unified/linux
mkdir -p $I
{ echo "$H"; echo "# static checks (final tree)"; shellcheck --version | sed -n 2p; shellcheck -s bash public/*.sh; echo "shellcheck -s bash public/*.sh exit=$?";
  for sh in /opt/homebrew/bin/bash /bin/bash; do $sh --version | head -1; for f in public/install.sh public/iterm2-client.sh; do $sh -n $f; echo "$sh -n $f exit=$?"; done; done
  git diff --quiet main -- public/iterm2-client.sh && echo "iterm2-client.sh byte-identical to main: yes"
  echo "bash 3.2 construct audit (declare -A, mapfile, readarray, \${x,,}, [[ -v, &>>, |&):"; grep -nE 'declare -A|mapfile|readarray|\$\{[a-zA-Z_]+(,,|\^\^)|\[\[ -v |&>>|\|&' public/install.sh || echo "  none found"; } > $I/static-checks.txt 2>&1
{ echo "$H"; /bin/bash $S/bundle-negatives.sh public/install.sh; } > $HD/bundle-negatives-bash3.2.txt 2>&1
{ echo "$H"; /opt/homebrew/bin/bash $S/bundle-negatives.sh public/install.sh; } > $HD/bundle-negatives-bash5.txt 2>&1
{ echo "$H"; python3 - <<'PY'
import subprocess, os
r = subprocess.run(["/bin/bash", "docs/evidence/unified/scripts/target-core-stub.sh", "public/install.sh"], capture_output=True, text=True, start_new_session=True, env=dict(os.environ, USER="tester"))
print(r.stdout + r.stderr)
PY
} > $HD/target-core-stub.txt 2>&1
{ echo "$H"; /bin/bash $S/linux-bash32.sh public/install.sh 2>&1 | sed 's#/var/folders/[^ ]*#<tmp>#'; } > $L/bash32-linux-dry.txt
{ echo "$H"; echo "# Mac: bash public/install.sh --dry-run (final script)"; bash public/install.sh --dry-run 2>&1; echo "exit=$?"; } > $I/mac-dry-run.txt
{ echo "$H"; echo "diff vs checkpoint A mac/dry-run-after.txt (header lines ignored): $( diff <(sed 1,2d docs/evidence/unified/mac/dry-run-after.txt) <(sed 1,2d $I/mac-dry-run.txt) >/tmp/macdiff.txt && echo IDENTICAL || echo DIFFERENT )"; cat /tmp/macdiff.txt; } > $I/mac-dry-run-diff.txt
HH=$(mktemp -d); { echo "$H"; echo "# fresh-Mac mock (empty HOME, no brew)"; HOME=$HH MB_BREW_CANDIDATES=/nonexistent/brew bash public/install.sh --dry-run 2>&1 </dev/null; echo "exit=$?"; } > $I/mac-dry-run-fresh.txt; rm -rf $HH
{ echo "$H"; bash docs/evidence/unified/integration/surface-check.sh; } > $I/surface-check.txt 2>&1
grep -E 'pass=|FAIL' $I/surface-check.txt | tail -3; tail -1 $HD/bundle-negatives-bash3.2.txt; tail -1 $HD/bundle-negatives-bash5.txt; cat $I/mac-dry-run-diff.txt | head -3; grep -c . $HD/target-core-stub.txt; grep -n 'exit=' $I/static-checks.txt | head
