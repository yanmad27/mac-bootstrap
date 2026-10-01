# Final acceptance evidence
- Commit: c6d9287604ae6533fcabae76211115275ab7d096 (main). Date: 2026-10-01.
- `screenshot-fullpage.png`: full-page render of `public/index.html` from a local `python3 -m http.server` on 127.0.0.1.
- `page-check.txt`: h2 order (manual, install, auth key, iTerm2, done), every command shown, 10/10 copy buttons match their clipboard, 0 external requests, `/install.sh` and `/iterm2-client.sh` HTTP 200 locally.
- `static-checks.txt`: HEAD sha, shellcheck 0.11.0 exit code, `bash -n` and `/bin/bash -n` exit codes for both scripts.
- `dry-run.txt`: install.sh dry runs (piped; fresh-Mac mock with empty HOME) showing [1/10]..[10/10] in order, plus the iterm2-client.sh dry run (stderr and stdout separate, stdout valid JSON); no DUMMY values leaked.
- `no-change.txt`: before/after snapshots around all dry runs (brew, services, tailscale state, gh auth exit, rc/git-config hashes, iTerm2 files): identical.
- `contract-check.txt`: every flag and env name in both `--help` outputs is present on the page; no hardcoded deployment domain.
- NOT proven: live Vercel headers/Content-Type/routing, real installs (no sudo, brew install, tailscale up or gh login was run), real iTerm2 profile loading, behaviour on a clean macOS or Intel Mac.
