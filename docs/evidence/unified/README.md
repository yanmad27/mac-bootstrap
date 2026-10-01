# Unified bootstrap: evidence index

Branch `feat/unified-bootstrap`. One `public/install.sh` (OS-detecting, browser-free), macOS client modes, Linux install (apt/dnf/pacman), the page and README. Contract: `docs/handoff.md` (sections 1-4 frozen, section 9 = Linux facts). All credentials in all evidence are DUMMY; no real Tailscale API call, OAuth client, auth key, tailnet join, Keychain read or `gh auth token` was made, and the installer's target mode was never run for real on the Mac. Network traffic beyond package repos: the dummy token sent to api.github.com by `gh auth login` in the Linux runs (HTTP 401, brief-authorised).

## What was verified where

| Area | Where | Result |
|---|---|---|
| Static checks (shellcheck 0.11.0, `bash -n` Homebrew bash 5.3 + macOS bash 3.2, iterm2-client.sh byte-identical) | `integration/static-checks.txt` (final tree), `scripts/static-checks.txt` (A), `linux/static-checks.txt` (B) | exit 0 |
| Mac target dry-run, before vs after the rewrite; browser fallbacks gone | `mac/` (`dry-run-before/after`, `-fresh-` variants) | diff explained in `scripts/README.md` |
| Mac dry-run unchanged since checkpoint A | `linux/mac-dry-run-diff-vs-A.txt`, `integration/mac-dry-run-diff.txt` | identical |
| Client modes + hand-off: real SSH Mac -> Linux container, mock API mint request, paste fallback, 39 checks incl. wrong fingerprint, changed host key, second/oversized bundle, symlinked inbox, root matrix, hooks inert without `MB_TEST`, non-loopback API base, no secret in argv or `bash -x` | `handoff/` (`summary.txt`, `01-` to `14-`, `bundle-negatives-*.txt`, `target-core-stub.txt`) | 39/39, 29/29 |
| Linux install, real non-dry runs per family (image@digest, platform, full output, exit status, real SSH hand-off, postcondition probes, idempotent rerun) | `linux/real-<ubuntu,debian,fedora,rocky>.txt` | native arm64: pass (exit 3 = no systemd, reported honestly) |
| Linux dry-runs for 5 families (dummy secrets proven absent), negative tests (unsupported distro, missing os-release, override inert, non-root without sudo), detection matrix | `linux/dry-run-*.txt`, `linux/negative-tests.txt`, `linux/summary-*.txt` | pass |
| Arch | `linux/real-arch.txt`, `linux/summary-arch.txt` | EMULATION LIMIT, see below; one recorded FAIL kept |
| Page and README vs the final script surface (every flag, env, mode and command) | `integration/surface-check.txt` | 69/69 |
| Page checks on the merged tree: commands with JS on/off, 14 Copy buttons, no external requests, overflow, reduced motion, contrast (46 pairs >= 4.5), word count vs base (visible 617 -> 604, non-code 554 -> 537), fresh 1280 light screenshot | `integration/page-checks.txt`, `integration/wordcount.txt`, `integration/screenshot-*.png`; the earlier page-peer run is in `page/` | pass |
| No dummy secret (raw or base64) or MB1 blob in any evidence file | `integration/grep-secrets.txt` (script `scripts/grep-secrets.py`, positive control verified) | none found |

Containers were not re-run for the integration: `public/install.sh` is identical to checkpoint B (`bb00b9c`).

## EMULATION LIMIT (Arch)

Arch only exists as `linux/amd64` and ran under arm64 emulation. `gh` dies with a Go runtime panic there, sshd exits 255 (OpenSSH's seccomp sandbox cannot attach) and a single-key `read` never receives a key on the emulated tty. So for Arch there was NO hand-off (SSH or paste), and the "all tools present" probe in `linux/summary-arch.txt` is a FAIL kept as recorded (the gh package is installed; it cannot run). These are emulation artifacts, not install.sh defects; native amd64 and Arch arm64 are UNTESTED.

## UNTESTED

- systemd/launchd service start: `systemctl enable --now tailscaled/ssh/ssh.socket/sshd` under a real init; the macOS `brew services` / LaunchDaemon start.
- tailscaled running and a real `tailscale up` / tailnet join (the `file:` key file, query string and argv are only checked with a stub binary).
- sshd under a real init.
- Real gh auth (only a dummy token rejected with 401 was run).
- The real login Keychain write/read and the real `gh auth token` / `gh api user` (the `security -i` command form is unexercised).
- A real Tailscale API mint (response shapes, the lowest accepted `expirySeconds`, the OAuth endpoint details); only the 127.0.0.1 mock ran.
- A real macOS target run, including Remote Login detection and opening System Settings; the macOS receiver ran only as functions and in dry-run.
- Native amd64; Arch arm64.
- The Paseo daemon start (only the CLI is installed on Linux; the Mac cask is not started by the script).
- Password SSH login (key auth only in the tests).
- Also not run: Debian 12, Ubuntu 22.04, RHEL 8/10, CentOS Stream, Oracle Linux, Arch/Ubuntu derivatives (mapped by the detection matrix, not installed); firewalld/ufw on a real host; the apt Node candidate decision inside `--dry-run`.

## Regenerate

`scripts/README.md` (checkpoint A harness), `linux/README.md` (checkpoint B), `integration/surface-check.sh`, `scripts/grep-secrets.py`. The page checks use `page/check.js` and `page/wordcount.js` (the integration run used a copy of `check.js` with its `ROOT` pointed at the merged `public/`).
