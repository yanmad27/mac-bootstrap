# Tailscale on macOS (Homebrew `tailscale` formula): non-interactive auth key login

> Update (unified bootstrap): `install.sh` no longer uses an interactive login (the `tailscale up` URL, section 5 `else` branch) and never opens a browser on the target. Without a key it waits for a hand-off from your client Mac; the key there is minted per hand-off from an OAuth client (section 7). Sections 1-4 still describe how the key is consumed.

Scope: the Homebrew formula `tailscale` (open-source `tailscaled` + `tailscale` CLI), **not** the App Store / standalone GUI app.
Source pin: every source link below is tagged `v1.102.4`, the version installed on the research Mac (`brew info` offered 1.102.5 as the stable; the code paths cited are unchanged in design, but 1.102.5 was not diffed: UNCONFIRMED for that patch release).
Method: official docs and source reading, plus read-only commands on the research Mac. Nothing was started, stopped, or changed. Identifying values (hostname, IPs, tailnet, account) are redacted or omitted.

Legend: **CONFIRMED** = stated in a linked official source. **UNCONFIRMED** = not found in an official source, or only inferred.

## 0. Short answer

Yes. `tailscale up --auth-key=file:/path` logs the node in without a browser, with the key never in argv. `TS_AUTHKEY` is **not** read by `tailscale` or `tailscaled` (only by `containerboot`), so install.sh must translate the env var into a `file:` key file itself.

## 1. Can it be non-interactive? Flag, file/stdin, env vars

| Question | Answer | Evidence |
|---|---|---|
| Yes/no | **Yes** | `tailscale up --auth-key` is the documented non-interactive login ([CLI docs](https://tailscale.com/kb/1080/cli), [auth keys](https://tailscale.com/kb/1085/auth-keys)); with a key, the CLI suppresses the interactive auth URL ([up.go:524-530](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L524-L530)) |
| Flag name | `--auth-key` today. `--authkey` was the old spelling: present in v1.20.0 ([up.go:100](https://github.com/tailscale/tailscale/blob/v1.20.0/cmd/tailscale/cli/up.go#L100)), already `--auth-key` in v1.34.0 ([up.go:101](https://github.com/tailscale/tailscale/blob/v1.34.0/cmd/tailscale/cli/up.go#L101)). v1.102.4 defines only `--auth-key` ([up.go:102](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L102)). Use `--auth-key`. | as linked |
| Read from a file | **Yes**: a value starting with `file:` is a path; the CLI reads it and trims whitespace ([up.go:211-219](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L211-L219), `getAuthKey` [up.go:247-249](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L247-L249)). The file is read by the **`tailscale up` process** (the client), so it must be readable by the user running `tailscale up`, not by the daemon. | as linked |
| Minimum version for `file:` | Present in [v1.16.0](https://github.com/tailscale/tailscale/blob/v1.16.0/cmd/tailscale/cli/up.go) and absent in [v1.14.0](https://github.com/tailscale/tailscale/blob/v1.14.0/cmd/tailscale/cli/up.go) (grep for `file:`). Exact first release in between (v1.15.x) was not checked: UNCONFIRMED. Irrelevant in practice: brew installs 1.102.x, and the `--auth-key` spelling needs >= a release between v1.20 and v1.34 (not bisected). | linked tags |
| stdin | **No dedicated stdin option** in `tailscale up --help` or source. `--auth-key=file:/dev/stdin` would follow from `os.ReadFile` but is UNCONFIRMED (not documented, not tested: testing would change state), and is hostile to `curl \| bash` where stdin is the script. Use a `0600` temp file. | [up.go:211-219](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L211-L219) |
| Env vars | `TS_AUTHKEY` (also `TS_AUTH_KEY`) and `TS_HOSTNAME` are read by **`containerboot`** only ([settings.go:96,101](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/containerboot/settings.go#L96-L101)). No `TS_AUTHKEY` read in `tailscale up` ([up.go](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go)) or `tailscaled` ([tailscaled.go](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscaled/tailscaled.go)); `tailscaled` takes no auth key ([tailscaled docs](https://tailscale.com/kb/1278/tailscaled) do not mention one). Absence-by-grep of those two files; whole-repo absence is UNCONFIRMED. `tailscale` does read `TS_*` knobs via `envknob`, none of them an auth key. | as linked |
| Other options | `--client-id/--client-secret` (OAuth) and `--id-token` (workload identity federation) exist in 1.102.4 ([up.go:104-106](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L104-L106)); out of scope here. | |

Read-only on the research Mac:

```text
$ tailscale version
1.102.4
  tailscale commit: bbcd7d1fc2054b9189ebc1531acf74bd880ca0c8
  long version: 1.102.4-tbbcd7d1fc
  go version: go1.27.1
$ tailscale up --help | grep -A1 -e '--auth-key'
  --auth-key value
    	node authorization key; if it begins with "file:", then it's a path to a file containing the authkey
```

Note: an automated summary of the [CLI page](https://tailscale.com/kb/1080/cli) suggested `--auth-key` can reference environment variables; the CLI help and source above show no env expansion, so treat it as **not supported** (the page text itself was not verified verbatim: UNCONFIRMED).

## 2. Key types and recommendation

Per [Auth keys](https://tailscale.com/kb/1085/auth-keys):

- **Reusable** (many devices) vs **one-off** (usable once; one-off keys are revoked automatically after use).
- **Ephemeral**: the device is removed from the tailnet automatically after it goes offline.
- **Pre-approved**: skips manual device approval, when device approval is enabled on the tailnet.
- **Tagged**: devices that use the key get the tags; key expiry for tagged devices is disabled by default.
- **Expiry**: the *auth key* expires after 1-90 days (default 90) and only limits when it can be used to register; the *node key* of the registered device expires after 180 days by default and is a separate clock. Revoking a key does not deauthorize nodes already registered with it.

Recommendation for a personal Mac you reach remotely long-term: **one-off, non-ephemeral, pre-approved; tag optional**.

- One-off: the key dies after first use, so a leaked copy in shell scrollback/clipboard is worthless afterwards. Set the shortest auth-key expiry that fits (1 day).
- Non-ephemeral: an ephemeral node is deleted from the tailnet when it goes offline ([auth keys](https://tailscale.com/kb/1085/auth-keys)), so every sleep/shutdown/long network outage risks losing the machine's identity, IP and ACL/tag bindings, which defeats long-term remote access.
- Pre-approved: needed only if the tailnet has device approval on; otherwise the node sits in `NeedsMachineAuth` (the state exists: [backend.go:28-34](https://github.com/tailscale/tailscale/blob/v1.102.4/ipn/backend.go#L28-L34)) and the script would hang.
- Tag: optional. A tag removes node-key expiry (the 180-day default would otherwise force re-login on an untagged, user-owned device) but the device then stops being owned by your user and is governed by ACL `tagOwners`. For an unattended always-reachable Mac this is the usual choice **if** your ACLs are set up for tags; if you keep user-owned identity, calendar a node-key re-auth every 180 days or disable expiry per machine in the admin console (UNCONFIRMED as to exact UI steps; admin action, not exercised).

## 3. Passing the key without argv/history exposure (given the transport contract)

Facts:

- Argv is visible to all local users via `ps`. So `--auth-key=<secret>` is forbidden. `--auth-key=file:<path>` puts only the **path** in argv ([up.go:211-219](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L211-L219) shows the contents are read in-process).
- Env-var passing to a child is not available: `tailscale up` ignores `TS_AUTHKEY` (section 1). Also env of a same-uid/root process is readable by the owner/root, and a copy would exist in every child, so the contract's immediate `unset` is right.
- `sudo` by default sets `env_reset`: commands run with a new, minimal environment and variables are not inherited ([sudoers(5)](https://www.sudo.ws/docs/man/sudoers.man/), `env_reset`; verified in the local `man sudoers`). A non-exported variable would not cross `sudo` anyway; do not use `sudo -E` or `env_keep` workarounds.
- The key is handed from `tailscale up` to `tailscaled` over the local unix socket (not argv): see [up.go `getAuthKey`](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L247-L249) feeding the IPN options. (Transport detail not traced end-to-end: UNCONFIRMED beyond "not argv, not env".)
- Shell builtins (`printf`, here-strings, redirections) do not create an argv visible to `ps`; an external `echo` would. `mktemp` with default perms creates mode `0600`; `umask 077` makes that explicit.

Recommended sequence (bash, run after the script has done `TS_KEY=${TS_AUTHKEY-}; unset TS_AUTHKEY`):

```bash
if [ -n "${TS_KEY:-}" ]; then
  umask 077
  KEYFILE=$(mktemp "${TMPDIR:-/tmp}/tskey.XXXXXX")
  trap 'rm -f "$KEYFILE"' EXIT INT TERM HUP
  printf '%s' "$TS_KEY" > "$KEYFILE"
  unset TS_KEY
  "${TS[@]}" up --auth-key="file:$KEYFILE" --timeout=120s "${UP_EXTRA[@]}"
  rm -f "$KEYFILE"
fi
```

Where `TS` is `(tailscale)` or `(sudo tailscale)` (section 4). If `sudo` is used, root reads the user-owned `0600` file; fine. The file exists only for the duration of `up`; for a one-off key it is already spent afterwards.

## 4. macOS caveats for the open-source `tailscaled` from Homebrew

Source of truth for variant behavior: [Tailscale on macOS variants](https://tailscale.com/kb/1065/macos-variants).

### 4.1 Running it as a system daemon: use `sudo brew services start tailscale`

- `tailscaled` refuses to run unprivileged on darwin unless userspace-networking: "tailscaled requires root" ([tailscaled.go:280-283](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscaled/tailscaled.go#L280-L283)). Root is therefore required (the sudo password prompt is the only human step; see 4.6).
- The formula defines a `service` block (`run opt_bin/"tailscaled"`, `require_root true`, `keep_alive true`, log in `var/log/tailscaled.log`) and its caveat says `sudo brew services start tailscale` ([formula](https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/t/tailscale.rb); read via `brew cat tailscale` on the research Mac, tag v1.102.4). With `sudo`, brew operates on `/Library/LaunchDaemons` (started at boot); without, on `~/Library/LaunchAgents` (login only, so a user agent cannot run tailscaled as root) ([brew manpage, services](https://docs.brew.sh/Manpage#services-subcommand)). Plist label/name `homebrew.mxcl.tailscale` ([Homebrew service.rb:92](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/service.rb#L92), unpinned `main`; the file is `/Library/LaunchDaemons/homebrew.mxcl.tailscale.plist` by construction, not observed on disk: UNCONFIRMED as an observed path).
- Alternative: `sudo tailscaled install-system-daemon`. Writes `/Library/LaunchDaemons/com.tailscale.tailscaled.plist` (label `com.tailscale.tailscaled`, `RunAtLoad` only, **no `KeepAlive`**) running `/usr/local/bin/tailscaled`, and **copies** the binary there unless it is already the same file ([install_darwin.go:23-49,114-143](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscaled/install_darwin.go)). A Homebrew install lives under `/opt/homebrew`, so the copy is a separate file that does **not** follow `brew upgrade` (it goes stale; verified on the research Mac below).
- Why `brew services` is preferred: the daemon tracks the brewed binary through upgrades, restarts on crash (`keep_alive`), and is the path the formula itself documents; the `install-system-daemon` copy goes stale and the two labels are independent, so running both gives two daemons fighting for the socket/utun. If `com.tailscale.tailscaled` is already installed (as on the research Mac), do not also start the brew service.
- Observed on the research Mac (read-only):

```text
$ brew services list | grep -i tailscale
tailscale   none
$ ls /Library/LaunchDaemons | grep -i -E 'tailscale|homebrew'
com.tailscale.tailscaled.plist
$ ls -l /usr/local/bin/tailscaled /opt/homebrew/bin/tailscaled
-rwxr-xr-x@ 1 root  wheel  22828402 ... /usr/local/bin/tailscaled          (regular file: a copy)
lrwxr-xr-x@ 1 <user> admin  42 ... /opt/homebrew/bin/tailscaled -> ../Cellar/tailscale/1.102.4/bin/tailscaled
$ brew info tailscale   (caveat)
  tailscaled (shadowed by /usr/local/bin/tailscaled)
```

  i.e. this Mac was set up with `install-system-daemon`, and the `/usr/local/bin` copy shadows brew's binary in `PATH`. install.sh must therefore call `"$(brew --prefix)/opt/tailscale/bin/tailscale"` by absolute path, not rely on `PATH`.
- State and socket (defaults, no flags passed by either launcher): socket `/var/run/tailscaled.socket` ([paths.go:28-29](https://github.com/tailscale/tailscale/blob/v1.102.4/paths/paths.go#L28-L29)); state `/Library/Tailscale/tailscaled.state` ([paths_unix.go:32-33](https://github.com/tailscale/tailscale/blob/v1.102.4/paths/paths_unix.go#L32-L33); dir created by [tailscaled.go:296-308](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscaled/tailscaled.go#L296-L308)). `/Library/Tailscale` is not readable by a normal user (`Permission denied` on the research Mac), so do not try to inspect it.

### 4.2 `sudo` for `tailscale up`, or `--operator`?

The socket is mode `0666` on darwin and access is decided from peer credentials ([unixsocket.go socketPermissionsForOS](https://github.com/tailscale/tailscale/blob/v1.102.4/safesocket/unixsocket.go#L83-L89); [ipnauth.go:166-215](https://github.com/tailscale/tailscale/blob/v1.102.4/ipn/ipnauth/ipnauth.go#L166-L215)): root has write access; the daemon's own uid; the configured operator (`--operator`, "Unix username to allow to operate on tailscaled without sudo", [up.go:124](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L124)); and, on darwin, **any member of the `admin` group** (`isLocalAdmin`, `adminGroup = "admin"`). Everyone else is read-only.

Decision: the interactive user of a personal Mac is almost always in `admin`, so `tailscale up` can run **without sudo** and then needs no `--operator`. To be robust, install.sh checks `id -Gn | grep -qw admin`: if yes, `TS=(tailscale)`; otherwise `TS=(sudo tailscale)` and pass `--operator="$USER"` so later `tailscale` calls by that user work without sudo. This is from source; it was not exercised here (would require state changes): UNCONFIRMED at runtime.

### 4.3 DNS / features vs the GUI app

Open-source variant ([macOS variants](https://tailscale.com/kb/1065/macos-variants)): uses the kernel `utun` interface, no system/network extension, no GUI ("all functionality must be managed from the command line"). Supported: MagicDNS, Tailscale SSH server and client, advertising as exit node, services. Not supported/limited: Taildrop incomplete, cannot **use** exit nodes (only advertise), no MDM, not manageable from macOS VPN settings, no automatic updates, no configuration reports. Described as "only recommended for unattended installs managed by experienced macOS system administrators."

### 4.4 Conflict with the GUI app

The formula declares `conflicts_with cask: "tailscale-app"` ([formula](https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/t/tailscale.rb)), and the KB warns against running multiple variants at once ([macOS variants](https://tailscale.com/kb/1065/macos-variants)). install.sh must stop with a clear message if `/Applications/Tailscale.app` exists or the `tailscale-app` cask is installed; do not try to remove it.

### 4.5 UI approval / reboot

The open-source variant uses `utun`, not a system extension or network extension ([macOS variants](https://tailscale.com/kb/1065/macos-variants)), and `tailscale up --help` / source contain no macOS approval step. No official doc mentions a reboot requirement or a System Settings approval for this variant. Conclusion: none expected (**UNCONFIRMED by direct test**: starting the service here is forbidden). The only interactive step is the `sudo` password prompt. Reopen condition (UI step/reboot required) is therefore **not triggered by any evidence found**.

### 4.6 Idempotent re-run

`tailscale status --json` returns `BackendState` ([up.go:264-285 doc comment](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L264-L285); values `NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running` per [backend.go:28-48](https://github.com/tailscale/tailscale/blob/v1.102.4/ipn/backend.go#L28-L48)). macOS ships `plutil`, which extracts it without `jq`; checked locally:

```text
$ echo '{"BackendState":"NeedsLogin"}' | plutil -extract BackendState raw -o - -
NeedsLogin
$ tailscale status --json | plutil -extract BackendState raw -o - -     # research Mac, redacted other fields
Running
```

Behavior of `tailscale up` ([up.go:465-470](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L465-L470)): when already `Running` and no `--force-reauth`, no `--auth-key`, and no control-URL/tag change, it only edits prefs ("justEdit"). **Passing `--auth-key` while Running defeats this path** (it re-registers), which would burn a one-off key, so install.sh skips `up` when `Running`. When flags differ from the saved prefs, `up` refuses: "changing settings via 'tailscale up' requires mentioning all non-default flags. To proceed, either re-run your command with --reset or ..." ([up.go:978-980](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L978-L980)); `--reset` resets unspecified settings to defaults ([`tailscale up --help`](https://tailscale.com/kb/1080/cli)). Avoid both: use `tailscale set` for pref tweaks, never `--reset` in an idempotent script.

`--timeout` ("maximum amount of time to wait for tailscaled to enter a Running state; default (0s) blocks forever", [up.go:134](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go#L134)): always pass one, so a bad/expired key fails instead of hanging.

### 4.7 `--hostname` and the already-Running decision

`--hostname` ("hostname to use instead of the one provided by the OS") exists on `up` ([up.go](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/up.go)) and on `tailscale set` ([set.go:84,155](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscale/cli/set.go#L84)), which changes only that preference without restating all flags ([CLI docs](https://tailscale.com/kb/1080/cli)).

**Decision: when `BackendState` is `Running` and `TS_HOSTNAME` is supplied, run `tailscale set --hostname="$TS_HOSTNAME"`** (supported, idempotent: setting the same value is a no-op for the user; touches no key, no login, no other flag). An explicit skip would silently ignore a user-supplied value on re-run; `up --hostname` is unsuitable (it triggers the "mention all flags" error). When not Running, pass `--hostname` to `up`. A hostname is an argv value, not a secret, so it is safe on the command line. It is passed unchanged, so validate `TS_HOSTNAME` against `^[A-Za-z0-9-]{1,63}$` first.

## 5. Recommended install.sh sequence

```bash
# 0. first lines of the script (secret transport contract)
TS_KEY=${TS_AUTHKEY-}; unset TS_AUTHKEY
TS_HOST=${TS_HOSTNAME-}

# 1. refuse the GUI app / cask conflict
if [ -d /Applications/Tailscale.app ] || brew list --cask tailscale-app >/dev/null 2>&1; then
  echo "Tailscale GUI app present; remove it first" >&2; exit 1
fi

# 2. install, absolute paths (PATH may be shadowed by /usr/local/bin/tailscaled)
brew list --formula tailscale >/dev/null 2>&1 || brew install tailscale
TSBIN="$(brew --prefix)/opt/tailscale/bin"
TS=("$TSBIN/tailscale"); id -Gn | grep -qw admin || TS=(sudo "$TSBIN/tailscale")

# 3. system daemon: reuse an existing one, else brew service (root, LaunchDaemon, keep_alive)
if ! [ -S /var/run/tailscaled.socket ]; then
  if [ -e /Library/LaunchDaemons/com.tailscale.tailscaled.plist ]; then
    sudo launchctl load -w /Library/LaunchDaemons/com.tailscale.tailscaled.plist
  else
    sudo brew services start tailscale
  fi
  for _ in $(seq 1 30); do [ -S /var/run/tailscaled.socket ] && break; sleep 1; done
fi
[ -S /var/run/tailscaled.socket ] || { echo "tailscaled socket did not appear" >&2; exit 1; }

# 4. state check (no key involved)
STATE=$("$TSBIN/tailscale" status --json 2>/dev/null | plutil -extract BackendState raw -o - - 2>/dev/null || echo NoState)
UP_EXTRA=(); if [ -n "$TS_HOST" ]; then UP_EXTRA+=(--hostname="$TS_HOST"); fi

case "$STATE" in
  Running)
    echo "tailscale already Running; skipping login (key not used)"
    if [ -n "$TS_HOST" ]; then "${TS[@]}" set --hostname="$TS_HOST"; fi
    ;;
  Stopped)
    "${TS[@]}" up --timeout=120s "${UP_EXTRA[@]}"
    ;;
  *)
    if [ -n "$TS_KEY" ]; then
      umask 077
      KEYFILE=$(mktemp "${TMPDIR:-/tmp}/tskey.XXXXXX")
      trap 'rm -f "$KEYFILE"' EXIT INT TERM HUP
      printf '%s' "$TS_KEY" > "$KEYFILE"; unset TS_KEY
      "${TS[@]}" up --auth-key="file:$KEYFILE" --timeout=120s "${UP_EXTRA[@]}"
      rm -f "$KEYFILE"
    else
      "${TS[@]}" up --timeout=300s "${UP_EXTRA[@]}"    # prints the login URL
    fi
    ;;
esac
```

Notes for the implementer:

- No variant puts the key in argv: only `file:<path>` appears on the command line; `printf` is a builtin; the key variable is never exported; `sudo` is never given the key (and `env_reset` would drop it).
- `launchctl load -w` of the pre-existing `com.tailscale.tailscaled` plist mirrors what the daemon's own installer does ([install_darwin.go:138-143](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/tailscaled/install_darwin.go)); this branch is only for Macs that already used `install-system-daemon` and is untested here (UNCONFIRMED at runtime).
- `NeedsMachineAuth` falls in the `*` branch: `up` with a key will wait until `--timeout`; with a pre-approved key this state should not occur (section 2).
- A `brew upgrade tailscale` keeps `brew services` working; a restart (`sudo brew services restart tailscale`) is needed to run the new binary (standard launchd behavior, not tailscale-specific).

## 6. Limits of this research

- No daemon start, login, or `tailscale set` was performed (forbidden), so the runtime behavior of 4.2, 4.5 and the launchd branch in section 5 is source-derived, not observed.
- Source pinned to v1.102.4; the latest brew stable at the time was 1.102.5, not diffed.
- Admin-console UI steps for key creation and node-key expiry were not exercised.

## 7. OAuth client and the minted hand-off key (unified bootstrap)

Source reading of Tailscale 1.102.5 (not re-run against a live tailnet here). Contract: [handoff.md](handoff.md).

Facts used:

- `tailscale up --auth-key=file:<path>` reads the WHOLE file. A query string belongs INSIDE the file (`tskey-client-...?ephemeral=false&preauthorized=true`), never appended to the flag (that would make the flag a different path).
- An OAuth client secret (`tskey-client-...`) can itself be given as the auth key, but the defaults are `ephemeral=true` and `preauthorized=false`, so a non-ephemeral, preauthorized node needs the explicit query, and `--advertise-tags` is mandatory (OAuth keys only create tagged nodes). `install.sh` does this when `TS_AUTHKEY` holds a `tskey-client-` value and `TS_TAGS` is set; the query goes into the 0600 key file.
- Tagged nodes have no key expiry by default.
- Nothing on a node can mint keys; minting needs an API credential, so it happens on the client Mac.

Hand-off key minting (client Mac only, `mac-bootstrap handoff` / `bundle`):

1. The OAuth secret is read from the login Keychain (service `mac-bootstrap.tailscale-oauth`, tag in `mac-bootstrap.tailscale-tag`) and sent only to the Tailscale API: `POST /api/v2/oauth/token` (client-credentials form; the client id is embedded in the secret).
2. With the bearer token: `POST /api/v2/tailnet/-/keys`, body `{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["tag:bootstrap"]}}},"expirySeconds":3600,"description":"mac-bootstrap handoff"}`.
3. Only the returned `tskey-auth-` key travels to the target. It is single use (`reusable:false`), preauthorized, non-ephemeral (the node must survive sleep and outages), tagged, and valid for one hour. The secret and token reach `curl` through its stdin config, never argv.

Create the OAuth client once in the admin console (Settings > OAuth clients): scope `auth_keys` (write) only, tag `tag:bootstrap` only. Policy needed once:

```json
{
  "tagOwners": { "tag:bootstrap": ["autogroup:admin"] },
  "grants": [{ "src": ["autogroup:member"], "dst": ["tag:bootstrap"], "ip": ["tcp:22"] }]
}
```

(OpenSSH on TCP 22, not Tailscale SSH.) Rotate by deleting the client and re-running `--client-setup`; revoke a minted key in Settings > Keys (an already registered node stays until removed).

UNCONFIRMED (no real API call was allowed): the lowest `expirySeconds` the real API accepts (3600 is used), and the exact JSON of the live responses; the client reads `access_token` and `key` and fails closed with the API's message otherwise.

