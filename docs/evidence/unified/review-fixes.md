# Review fixes: item -> fix -> evidence

Frozen `public/install.sh` sha256: `b914176ba7514835474d4f4a5d163d5b76736b742a7ebdc2377caeb8b4c27a17` (round 2; round 1 was `4ffad9cb…`, whose evidence was regenerated on this sha). Every current summary starts with this value. Paths are under `docs/evidence/unified/`. "code" = verified by reading the code plus ShellCheck/`bash -n`, no functional test (listed honestly).

| ID | Fix | Evidence |
|---|---|---|
| C1 | `ssh.socket` is used only when already enabled/active; otherwise `systemctl enable --now ssh`/`sshd`; a failed enable dies with a clear message; dry-run plan matches | `linux/systemd-debian.txt` (ssh.service enabled+active, ssh.socket untouched, no abort), `linux/systemd-ubuntu.txt` (socket-activated ssh keeps working), `systemd-rocky.txt` |
| C2 | NodeSource configured (list present) -> plan `nodesource`, install `nodejs` only | `linux/fixes-tests.txt` C2 (rerun after `apt-get remove nodejs`) |
| C3 | node < 20 -> explicit install/upgrade in step 2 (apt NodeSource, dnf module switch-to/enable), verified before the Tailscale step; unfixable node -> die before the join | `linux/fixes-tests.txt` C3 (distro node v18 preinstalled -> v22, upgrade printed before step 5) |
| C4 | npm resolved with `command -v`; no sudo when the prefix is writable, else `sudo env PATH=... <resolved npm>`; prefix named | `linux/fixes-tests.txt` C4 (plain `sudo npm` fails, new code succeeds; writable prefix without sudo) |
| C5 | `sudo_refresh` after the hand-off wait; non-interactive failure -> clear message | code only (needs an expiring sudo credential; not exercised) |
| C6 | no terminal -> behaves as `--no-wait`; documented in `docs/handoff.md` section 3 | `handoff/target-core-stub.txt` scenario 6b |
| C7 | `^[1-9][0-9]{0,5}$` timeout, port `^[1-9][0-9]{0,4}$` and <= 65535 | `handoff/17-arg-validation.txt` |
| C8 | group-write accepted only for the user's own private group; world-write and foreign groups refused; inbox stays 0700 | `linux/fixes-tests.txt` C8 (6 cases) |
| C9 | RHEL-family needs dnf and major >= 8; `dnf module` failure dies clearly; apt/pacman presence checked | `linux/fixes-tests.txt` C9 (no dnf, no pacman, CentOS 7) |
| C10 | dry-run without systemd exits 0 with a note; `ip` preferred on Linux; macOS `open` failure prints the manual path; Linux Stopped state re-applies known tags | `linux/dry-run-*.txt` (dry-run exit 0 + note), `linux/real-*.txt` (LAN IPs via `ip`); `open` failure and Stopped-tags: code only |
| S-M1 | `ready` = `<pid> <nonce>`; probe/send refuse a dead pid or wrong nonce (`kill -0`, `/proc`, `ps -p`); client waits <= 15 s for the receiver to take the bundle, else removes it and fails | `handoff/06-second-bundle.txt`, `handoff/15-stale-ready-client.txt`, `handoff/16-not-consumed-revoke-client.txt` |
| S-M2 | every inbox operation via `as_target` | code; root receiver with `--target-user`: `handoff/08-root-with-target-user-*.txt`, `linux/real-debian.txt`, `linux/real-fedora.txt` (root runs) |
| S-M3 | `umask 077` for b64dec output and the curl response files (scoped, so global npm/dnf installs keep normal modes) | code only (the temp dir is also 0700) |
| S-L1 | bundle must end with `END=1`; rejected if missing, duplicated, wrong or followed by data; docs section 2 updated; generator updated | `handoff/bundle-negatives-bash3.2.txt`, `-bash5.txt` (34 cases) |
| S-L2 | ssh gets `ProxyCommand=none ProxyJump=none PermitLocalCommand=no ClearAllForwardings=yes` (no `-F /dev/null`) | `handoff/13-argv-log.txt` (the exact ssh argv) |
| S-L3 | existing different helper -> both sha256 shown, default No; identical -> no prompt | `handoff/18-helper-replace.txt` |
| S-L4 | `INBOX` stays set until final cleanup (`INBOX_OPEN` flag instead) | code; cleanup trap: `handoff/04-wrong-fingerprint-receiver.txt` |
| S-L5 | failed delivery -> `DELETE /api/v2/tailnet/-/keys/{id}` with the bearer on stdin | `handoff/16-not-consumed-revoke-client.txt`, `handoff/16-mock-api-requests.jsonl` (DELETE recorded) |
| S-P1 | no readable ED25519 host key -> no hand-off lines, "use paste"; client prompt names the ED25519 SHA256 fingerprint | client text in `handoff/01-success-client.txt`; the no-key branch is code only |
| S-P2 | env-secret caveat added to `docs/handoff.md` section 8 | `docs/handoff.md` |
| S-P3 | `json_error` redacts `tskey-...`/`Bearer ...` runs | `handoff/19-json-error-redaction.txt` |
| S-P4 | Linux summary prints effective `PasswordAuthentication`/`PermitRootLogin` from `sshd -T` and warns when password login is on; nothing is changed | `linux/systemd-*.txt`, `linux/real-*.txt` (summary lines) |

New systemd evidence (native arm64, `--privileged`, `--skip-tailscale-up`, so no key ever reached Tailscale): `linux/systemd-{ubuntu,debian,rocky}.txt` with the real SSH hand-off into the installer-enabled ssh unit; `linux/systemd-fedora.txt` with a CONTAINER LIMIT (see header: sshd refuses every non-root login after the key is accepted, PAM account check `pam_acct_mgmt = 9`; run with `--no-wait` and env secrets instead).

## Round 2 (final repair round): item -> fix -> evidence

| ID | Fix | Evidence |
|---|---|---|
| R1/N3 | the probe prints `MBNONCE=<hex>`; the client takes the LAST matching line (CR stripped); no match fails closed | `handoff/20-chatty-bashrc-client.txt` (a `~/.bashrc` that prints a banner, digits and a fake `MBNONCE=ffff` before the real line: hand-off still succeeds); no-match case: `handoff/06-second-bundle.txt`, `15-stale-ready-client.txt` |
| R2 | NodeSource is not added whenever `apt_nodesource_configured` (any `nodesource.com` line in `sources.list` or `sources.list.d`, deb822 `.sources` included); the message names the files | `linux/fixes-tests.txt` R2 (deb822 `.sources` + nodejs absent: no second repo, node installed) |
| R6 | configured NodeSource repo offering Node < 20 -> error naming the file and the fix (before any install) | `linux/fixes-tests.txt` R6 (candidate stubbed to 18 with a `node_18.x` list file) |
| C10 Stopped | Linux Stopped: plain `tailscale up --timeout=120s`, then `tailscale set --operator=<user>` (and hostname) separately; marked UNTESTED | `handoff/target-core-stub.txt` scenario 6c (stub tailscale argv); no real `up` ran |
| C10 macOS text | first message reads "System Settings (or System Preferences) > Sharing > Remote Login" | code only (macOS Remote Login path not run; the page text already matches) |
| N2/R4 | after the bundle disappears the client says "Bundle taken by the receiver on <host>; check the target's screen for the result." | `handoff/01-success-client.txt` + check 01 in `handoff/summary.txt` |
| N5 | client trap (EXIT/INT/TERM) revokes a minted key whose delivery was not confirmed, bearer via `-K -` | `handoff/21-interrupt-revoke-client.txt`, `handoff/21-mock-api-requests.jsonl` (DELETE recorded after Ctrl-C) |
| P1 | no ED25519 fingerprint -> `ready` removed and the SSH hand-off closed, message says so | `handoff/22-no-fingerprint-receiver.txt`, `22-no-fingerprint-client.txt` (client refuses before minting) |

Documented in `docs/handoff.md` section 8 (PARTIAL / ACCEPTED-RISK, with reasons): N1 pid reuse (bounded by the 15 s consume wait + revoke, PARTIAL); N4/R3 hidepid `/proc` with a root receiver fails closed, use paste (ACCEPTED-RISK); R5 hand-off while the target is at the `p` prompt fails safely (ACCEPTED-RISK); L2 `~/.ssh/config` kept on purpose, minus proxies/forwarding (ACCEPTED-RISK); L3 helper is a second download over the same TLS origin, first install has no prompt (ACCEPTED-RISK); `END=1` means older helpers are rejected (contract note).
