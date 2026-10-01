# Unified bootstrap: evidence index

Branch `feat/unified-bootstrap`. One `public/install.sh` (OS-detecting, browser-free), macOS client modes, Linux install (apt/dnf/pacman), the page and README. Contract: `docs/handoff.md` (sections 1-4 frozen, section 9 = Linux facts). All credentials in all evidence are DUMMY; no real Tailscale API call, OAuth client, auth key, tailnet join, Keychain read or `gh auth token` was made, and the installer's target mode was never run for real on the Mac. Network traffic beyond package repos: the dummy token sent to api.github.com by `gh auth login` in the Linux runs (HTTP 401, brief-authorised).

## What was verified where (frozen install.sh sha256 `4ffad9cb0fb1794da905338d5bf50c21dc07e2dfbb4b95d4251ef30fb88dfa10`)

Every current summary starts with that sha; evidence for earlier script versions is in `superseded/`. Item-by-item mapping of the review fixes: `review-fixes.md`.

| Area | Where | Result |
|---|---|---|
| Static checks (shellcheck 0.11.0, `bash -n` Homebrew bash 5.3 + macOS bash 3.2, iterm2-client.sh byte-identical) | `integration/static-checks.txt` | exit 0 |
| Mac target dry-run before (main) vs after; browser fallbacks gone; unchanged since checkpoint A | `mac/`, `integration/mac-dry-run*.txt` | diff explained in `scripts/README.md`; identical to A |
| Client modes + hand-off (real SSH Mac -> Linux container, mock API mint, paste, wrong fingerprint, changed host key, stale ready, not-consumed + key revocation, helper replace prompt, arg validation, hooks inert without `MB_TEST`, no secret in argv or `bash -x`) | `handoff/summary.txt` | 45/45 |
| Bundle validator incl. `END=1` truncation guard | `handoff/bundle-negatives-*.txt` | 34/34 under bash 3.2 and 5 |
| Shared core with stub tailscale/gh (key file, gh stdin, reruns, no-terminal behaviour) | `handoff/target-core-stub.txt` | pass |
| Linux real installs without systemd, 4 families native arm64 + real SSH hand-off | `linux/real-*.txt`, `linux/summary-*.txt` | 9/9 each |
| Linux installs in systemd-booted containers (tailscaled + ssh unit enabled/active by the installer, hand-off into it) | `linux/systemd-*.txt` | ubuntu 9/9, debian 9/9, rocky 8/8, fedora 7/7 (hand-off: CONTAINER LIMIT) |
| Linux negative tests, detection matrix, review items C2/C3/C4/C8/C9 | `linux/negative-tests.txt`, `linux/fixes-tests.txt` | 11/11, 16/16 |
| Page and README vs the final script surface | `integration/surface-check.txt` | 69/69 |
| Page checks on the merged tree (commands JS on/off, 14 Copy buttons, no external requests, overflow, reduced motion, contrast, word count vs base, fresh 1280 screenshot) | `integration/page-checks.txt`, `wordcount.txt`, `screenshot-*.png` | pass (index.html unchanged since the integration commit) |
| No dummy secret (raw or base64) or MB1 blob in any evidence file | `integration/grep-secrets.txt` | none found (positive control verified) |

## EMULATION / CONTAINER LIMITS

- **Arch** only exists as linux/amd64; its run (emulated, earlier script version, in `superseded/`) hit an EMULATION LIMIT (gh Go panic, sshd exits 255, no hand-off). Arch on the frozen script: UNTESTED; native amd64 and Arch arm64: UNTESTED.
- **Fedora in a systemd container**: sshd's PAM account check refuses every non-root login (CONTAINER LIMIT, `linux/systemd-fedora.txt` header); no hand-off into it.

## UNTESTED

- launchd/`brew services` start on a Mac.
- `tailscale up` and a real tailnet join; tailscaled in a joined state (the `file:` key file, query string and argv are only checked with a stub binary).
- systemd, tailscaled and sshd on a REAL host (they were exercised only in systemd-booted `--privileged` containers).
- Real gh auth (only a dummy token rejected with 401).
- The real login Keychain write/read and the real `gh auth token` / `gh api user` (the `security -i` command form is unexercised).
- A real Tailscale API mint (response shapes, the lowest accepted `expirySeconds`, the revoke endpoint); only the 127.0.0.1 mock ran.
- A real macOS target run including Remote Login detection and opening System Settings (the receiver ran on Linux and as functions on the Mac).
- Native amd64, Arch (arm64 and the frozen script), the Paseo daemon start, password SSH login.
- Review items verified by code only: C5 (sudo refresh), the macOS `open`-failure message, the Linux Stopped-state tag re-apply, S-P1's no-ED25519 branch, S-M3, S-L4.
- Also not run: Debian 12, Ubuntu 22.04, RHEL 8/10, CentOS Stream, Oracle Linux, derivatives; firewalld/ufw on a real host; the apt Node candidate decision inside `--dry-run`.

## Regenerate

`scripts/run-local-checks.sh`, `scripts/README.md` (checkpoint A harness), `linux/README.md`, `integration/surface-check.sh`, `scripts/grep-secrets.py`. The page checks use `page/check.js` and `page/wordcount.js` (the integration run used a copy of `check.js` with its `ROOT` pointed at the merged `public/`).
