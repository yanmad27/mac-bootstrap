# Unified bootstrap and hand-off contract (frozen)

One script, one URL: `<origin>/install.sh`. It detects the OS, never opens a browser on the target, and has client modes that run on a Mac you already trust. This document is the contract the page, the README and the script all follow.

## 1. Modes

### Target mode (default)

```bash
curl -fsSL "<origin>/install.sh" | bash -s -- [flags]
```

Flags: `--dry-run`, `--skip-tailscale-up`, `--skip-gh-auth`, `--iterm2-shell-integration` (macOS only), `--no-wait`, `--reauth-tailscale`, `--reauth-gh`, `--set-git-identity`, `--target-user USER`, `--handoff-timeout SECONDS` (default 900), `-h|--help`.

Environment (back-compat, all optional, empty counts as unset): `TS_AUTHKEY`, `TS_TAGS`, `GH_TOKEN`, `TS_HOSTNAME`, `GIT_USER_NAME`, `GIT_USER_EMAIL`.

- A `tskey-client-` (OAuth) value in `TS_AUTHKEY` requires `TS_TAGS`. The script writes `<key>?ephemeral=false&preauthorized=true` INSIDE the 0600 key file passed as `--auth-key=file:<path>`; the query string is never appended to the flag and nothing secret is in argv.
- `TS_TAGS` (comma separated `tag:name`) is passed as `--advertise-tags`.
- Secrets are copied to non-exported variables and unset from the environment first, as before.

### Client modes (macOS only)

| Command | What it does |
|---|---|
| `install.sh --client-setup [--origin URL]` | Hidden prompt for the `tskey-client-` OAuth secret and the tag (default `tag:bootstrap`). Stores both in the login Keychain. Installs the helper `~/.local/bin/mac-bootstrap` (a saved copy of install.sh; sha256 printed; PATH hint if needed). |
| `mac-bootstrap handoff <user@host> [--port N]` | SSH push to a waiting target (section 4). |
| `mac-bootstrap bundle [--copy]` | Prints the paste bundle on stdout. `--copy` additionally pipes it to `pbcopy` (opt-in). Warns that the bundle contains the GitHub token. |

`--origin URL` is the one addition to the brief's surface: when `--client-setup` runs from `curl | bash`, the script cannot read its own source, so it downloads `<origin>/install.sh` to save the helper. `--origin` is required in that case (https only) and unnecessary when run from a saved file (the file is copied). Page command for client setup:

```bash
curl -fsSL "<origin>/install.sh" | bash -s -- --client-setup --origin "<origin>"
```

Keychain items (login keychain, account = `$USER`): service `mac-bootstrap.tailscale-oauth` (the OAuth secret) and `mac-bootstrap.tailscale-tag` (the tag). `--client-setup` stores nothing about GitHub.

## 2. Bundle

`MB1:` + base64 (one line, no wrapping) of `KEY=VALUE` lines. The LAST line must be `END=1` (a truncation guard); a bundle without it, with data after it, or with a wrong END value is rejected, and a bundle with only `END=1` is empty.

| Key | Rule |
|---|---|
| `TS_AUTHKEY` | must match `^tskey-auth-[A-Za-z0-9_-]+$` (an OAuth `tskey-client-` is rejected: it never leaves the client) |
| `TS_TAGS` | `tag:name[,tag:name...]`, names `[a-z][a-z0-9-]*` |
| `GH_TOKEN` | `^[A-Za-z0-9_]+$` |
| `GIT_USER_NAME` | no control characters, at most 200 bytes |
| `GIT_USER_EMAIL` | `local@domain`, no whitespace or `<>` |
| `END` | exactly `END=1`, last line, once |

Receiver rules: decoded size at most 8 KiB (encoded line at most 11000 bytes); reject CR, NUL, empty lines, duplicate keys and unknown keys; split at the FIRST `=`; never `eval` or `source`. Errors name the problem, never the value. A bundle is parsed from a file or variable only by the receiver's own loop.

Git identity on the client is read-only: `git config --global user.name/user.email`, else the GitHub noreply address from `gh api user` (`<id>+<login>@users.noreply.github.com`). No client git config is ever changed. Keep the pasted line under about 1000 characters (the macOS terminal line limit); `bundle` warns above that.

## 3. Inbox (receiver, on the target)

- Path `$TARGET_HOME/.cache/mac-bootstrap/inbox`, mode 0700, owned by the target user. The receiver verifies that `.cache`, `mac-bootstrap` and `inbox` are real directories (not symlinks), owned by the target user, and not group/world writable.
- The receiver writes a `ready` marker containing `<receiver pid> <random nonce>`. The SSH-side commands (the only things the client runs) refuse a `ready` whose pid is not alive (`kill -0`, or `/proc/<pid>` / `ps -p` when the receiver runs as root), so a marker left by a killed receiver or a reboot is never trusted. The probe prints the nonce; the send command must present the same nonce. It writes `bundle.tmp.<pid>` under `umask 077` and links it to `bundle` only if `ready` still matches and `bundle` does not exist (an atomic no-clobber `ln`, then removes the temp). After sending, the client waits up to 15 s (same SSH connection) for the receiver to take `bundle`; if it is not taken the client removes it, revokes the minted key by id (`DELETE /api/v2/tailnet/-/keys/{id}`) and reports failure.
- Every filesystem operation on inbox paths runs as the target user, so a root receiver never follows user-controlled paths. The inbox directory is 0700; its parents must be real directories owned by the user, not world-writable, and group-writable only when the directory's group is the user's own private group (Fedora/RHEL `umask 002`).
- Wait loop: polls for `bundle` once a second while `read -t 1 -s -n 1 </dev/tty` watches for `p`. `p` switches to a hidden paste prompt (strictly sequential, never two readers). Empty paste goes back to waiting. Timeout `--handoff-timeout` (default 900 s); after a timeout the run continues without credentials and lists the manual steps. `--no-wait` skips the wait entirely. With no terminal (`/dev/tty` unavailable) the installer does not wait either: it behaves as `--no-wait` and lists the manual next steps (clarification of the earlier Mac behaviour "no terminal -> skip").
- Single use: on read the receiver removes `ready`, validates, then deletes `bundle`. A second bundle is refused by the SSH side (no `ready`).
- Cleanup trap on EXIT, INT, TERM removes `ready`, `bundle`, `bundle.tmp.*` and the empty inbox.
- When the wait is needed: Tailscale not Running (or `--reauth-tailscale`) with no key, or gh not authenticated (or `--reauth-gh`) with no token, in a non-skipped step. Values already in the environment win over bundle values.

Target screen (printed once SSH is reachable): LAN IPs, a `.local` name only if it resolves, the ED25519 host-key fingerprint (`/etc/ssh/ssh_host_ed25519_key.pub`), and the exact `mac-bootstrap handoff user@IP` lines, plus the `p` paste hint.

## 4. Client hand-off

1. `ssh-keyscan -t ed25519` the target; show the SHA256 fingerprint; ask `Does this match the screen? [y/N]` on `/dev/tty`. Only `y` continues.
2. Write ONLY that key to a temporary known_hosts; connect with `-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<tmp> -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519`. Never `StrictHostKeyChecking=no`.
3. One authenticated connection (OpenSSH control master). Probe that the target inbox is `ready` BEFORE anything is minted.
4. Collect the gh token (`gh auth token --hostname github.com`) and the identity. Mint the Tailscale key (section 5).
5. Send the bundle over the SSH session's stdin, never argv. Close the master. Temp files are removed on exit.

Access matrix: normal sudo user: password SSH; cloud user: an existing key; root-only machine: refused unless `--target-user` or `SUDO_USER` names the user who owns the gh/git config and the inbox (the SSH login must still be that user for the inbox to be found); no SSH login: paste. The script never enables password or root login. On macOS the target must have Remote Login on (detected with a local TCP 22 probe; if off the script opens System Settings > General > Sharing and waits). Screen Sharing is an optional manual next step.

## 5. Mint (client only)

OAuth secret from the Keychain (`tskey-client-...`) -> `POST <api>/api/v2/oauth/token` (form: `grant_type=client_credentials`, `client_secret`, a dummy `client_id`; the id is carried inside the secret) -> bearer token -> `POST <api>/api/v2/tailnet/-/keys` with

```json
{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["tag:bootstrap"]}}},"expirySeconds":3600,"description":"mac-bootstrap handoff"}
```

Single use, non-ephemeral, preauthorized, tagged, 1 hour. Only the returned `tskey-auth-` key is bundled. Secrets reach curl through `-K -` on stdin, never argv. The OAuth secret never leaves the Mac. The lower bound of `expirySeconds` accepted by the real API is UNCONFIRMED (no real call is allowed in this work).

## 6. Reruns

Tailscale already Running: skip unless `--reauth-tailscale`. gh already authenticated: keep unless `--reauth-gh`. A global git identity that already exists: keep unless `--set-git-identity`.

## 7. Test hooks (dummy values only)

Honoured ONLY when `MB_TEST=1`; otherwise inert (they are never read).

| Hook | Effect |
|---|---|
| `MB_TEST_OAUTH_SECRET` | replaces the Keychain read (`--client-setup` then skips the Keychain write) |
| `MB_TEST_GH_TOKEN` | replaces `gh auth token` |
| `MB_TEST_API_BASE` | must match `^http://127\.0\.0\.1:[0-9]+$`; replaces `https://api.tailscale.com` |
| `MB_TEST_HOME` | replaces HOME for the helper install and the client's git config read |

In test mode the real Keychain and the real `gh` are never invoked and `gh api user` is skipped. `--origin` may be `http://127.0.0.1:PORT` only in test mode. A non-loopback `MB_TEST_API_BASE` is a fatal error.

## 8. Threat model and revocation

| Asset | Exposure | Mitigation / revoke |
|---|---|---|
| OAuth client secret (Keychain on the client) | Whoever reads it can mint keys for the tag | Create it with only the `auth_keys` (write) scope and only the one tag. Rotate: delete and recreate the client in the admin console, rerun `--client-setup`. It never leaves the Mac. |
| GitHub token (`gh auth token`, explicit consent) | The client's token is shared with the target: broad scopes, the same token on two machines. It travels in the bundle (SSH, or your clipboard/scrollback when pasted). Revoking it logs the client Mac out too. Linux stores it as plaintext 0600 `~/.config/gh/hosts.yml` when no keyring exists. | `gh auth logout` on either machine, or revoke the OAuth app authorization at github.com/settings/applications; then `gh auth login` again on the client. |
| Minted Tailscale key | Single use, 1 hour. Only valid until used or expired. | Revoke it in the admin console (Settings > Keys). Revoking does not remove a node already registered; remove the machine in the admin console. |
| SSH host key (trust on first use) | A network attacker could present their own key | The client shows the fingerprint and you compare it with the target screen; only that key is trusted, strict checking, never `StrictHostKeyChecking=no`. Pasting avoids the network. |
| Inbox / bundle on the target | Plain file for a moment | 0700 dir owned by the target user, 0600 file, removed on read and by the exit trap; stale `ready` markers (dead pid) are refused. |
| Secrets passed through the environment (`TS_AUTHKEY`, `GH_TOKEN`) | They stay in the process environment block of the installer (readable by the same user and root) and in shell history if typed inline | Prefer the hand-off. The script copies them to non-exported variables and unsets them first, but cannot scrub the parent shell's history or the original environment block. |
| Failed delivery | A minted key that was not used | The client revokes it by id when the delivery fails or is not taken within 15 s, or when it is interrupted (INT/TERM). A bundle that the receiver TAKES but then rejects (for example a validation failure on the target) is NOT revoked: the unused single-use key stays valid for up to 1 hour, so revoke it in the admin console if you care. |

Known limits of the hand-off (PARTIAL / ACCEPTED-RISK, from the final review round):

- **PID reuse (N1, PARTIAL):** the `ready` marker proves a live pid and a matching nonce, not that the pid is still the receiver. A reused pid is bounded by the client's 15 s wait for the bundle to be taken, after which the bundle is removed and the minted key revoked.
- **hidepid `/proc` with a root receiver (N4/R3, ACCEPTED-RISK):** if `/proc` is mounted with `hidepid` and the receiver runs as root, the target user cannot see its pid, so the probe fails closed ("not waiting"). Use paste (`p`).
- **Hand-off while the target is at the `p` prompt (R5, ACCEPTED-RISK):** the receiver reads sequentially; a bundle pushed while the paste prompt is open waits until the prompt returns, and the client's 15 s wait may expire first, which removes the bundle and revokes the key. It fails safely; retry.
- **`~/.ssh/config` is kept on purpose (L2, ACCEPTED-RISK):** the client does not use `-F /dev/null`, so key-based hosts keep their `IdentityFile`/`User`; proxies, local commands and forwarding are switched off on the command line (`ProxyCommand=none`, `ProxyJump=none`, `PermitLocalCommand=no`, `ClearAllForwardings=yes`).
- **Helper download (L3, ACCEPTED-RISK):** `--client-setup --origin` fetches the helper in a second download over the same TLS origin as the piped script; a first install has no replace prompt (nothing to replace), later ones show both sha256 values and ask.
- **Interrupted client leaves the bundle (UNRESOLVED-LOW, NI-2):** after a client interrupt the minted key is revoked, but the bundle (which contains the gh token) can stay in the target's 0700 inbox until the waiting receiver takes it or exits (the exit trap removes it). Only the target user and root can read it.
- **`pacman --disable-sandbox` in containers:** when a container is detected (`/.dockerenv` or `/run/.containerenv`) the script runs pacman with `--disable-sandbox`, because pacman's sandbox fails inside containers. Real hosts are unaffected.
- **Older helpers (contract):** the receiver requires the `END=1` line, so a `mac-bootstrap` helper older than this version produces bundles that are rejected; re-run `--client-setup`.
- **Stopped Tailscale node on Linux (UNTESTED):** a rerun in the `Stopped` state runs plain `tailscale up --timeout=120s` (prefs persist) and sets the operator with `tailscale set --operator=<user>`; no real `up` was run.

Tailnet policy needed once (OpenSSH on TCP 22, not Tailscale SSH):

```json
{
  "tagOwners": { "tag:bootstrap": ["autogroup:admin"] },
  "grants": [{ "src": ["autogroup:member"], "dst": ["tag:bootstrap"], "ip": ["tcp:22"] }]
}
```

## 9. Linux target facts (not part of the frozen contract, sections 1-4 are unchanged)

Same single script and flags; the Linux branch is chosen by `uname -s`. Detected from `/etc/os-release` (parsed, never sourced): Ubuntu/Debian (apt, also ID_LIKE), Fedora (dnf), RHEL-compatibles `rhel|centos|rocky|almalinux|ol` (dnf), Arch (pacman, also ID_LIKE). Anything else (including Amazon Linux, Alpine, SUSE) stops with an "unsupported" error before any change. `MB_OS_RELEASE=<path>` replaces the os-release path ONLY with `--dry-run` or `MB_TEST=1` and is ignored otherwise.

| Step | Ubuntu/Debian | Fedora | RHEL-compatible | Arch |
|---|---|---|---|---|
| Tailscale | signed apt repo (keyring + list from pkgs.tailscale.com per distro/codename) | `fedora/tailscale.repo` | `centos/<major>/tailscale.repo` | `tailscale` |
| gh | signed apt repo (cli.github.com keyring) | distro `gh` | `gh-cli.repo` | `github-cli` |
| Node >= 20 (Paseo) | distro `nodejs npm` if the candidate is >= 20, else NodeSource `node_22.x` apt repo with its signing key (never `setup_22.x`) | distro | `dnf module enable nodejs:22` on 8/9 | `nodejs npm` |
| SSH server | `openssh-server`; unit `ssh` (`ssh.socket` too where it exists) | `openssh-server`, `sshd` | same | `openssh`, `sshd` |

Paseo is `npm install -g @getpaseo/cli` (latest, version printed); only the CLI, its daemon is never started. Repo keys/files are HTTPS downloads, sanity-checked and not pinned (their sha256 is printed). The installer never enables password or root login and never opens a firewall port: firewalld state is checked and reported (with the command to allow `ssh`), ufw state is only reported.

Privileges: root runs the system steps directly; a normal user needs sudo (otherwise a clear error before any change). As root, gh and git run as the `--target-user` / `SUDO_USER` user. gh stores its token in `~/.config/gh/hosts.yml` (plaintext, mode 0600) when no keyring is available, as on a headless server.

No systemd as PID 1 (`/run/systemd/system` absent, e.g. a container): packages are installed, `tailscaled`/`sshd` are NOT enabled or started, `tailscale up` is skipped, and the summary and the exit status say so: exit 3 (`NOT COMPLETE`). A failed gh login (rejected token, no network) is reported without aborting and exits 4. A hand-off in such a container needs sshd started by hand (or paste, `p`).

Updates after review (section 9 facts): the SSH unit is `ssh.socket` only when it is already enabled or active (Ubuntu); otherwise `systemctl enable --now ssh` (apt) or `sshd`, and a failed enable stops with a clear error. Node >= 20 with npm is installed or upgraded in step 2, before the Tailscale join (NodeSource when its repo is configured or the distro candidate is older than 20; `dnf module switch-to/enable nodejs:22` on RHEL 8/9). Paseo is installed without sudo when npm's global prefix is writable, otherwise with `sudo env PATH=... <resolved npm>`. A RHEL-family system must have dnf and major version >= 8. A dry-run without systemd exits 0 and says a real run would exit 3. The Linux summary reports the effective `PasswordAuthentication`/`PermitRootLogin` from `sshd -T` and warns when password login is on (it never changes the configuration).

