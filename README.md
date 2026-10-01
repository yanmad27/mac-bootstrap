# mac-bootstrap

Bootstraps a Mac or Linux machine (Ubuntu/Debian, Fedora/RHEL, Arch) for remote access over Tailscale, with no browser ever opening on the new machine. One command installs Tailscale, git, gh and the rest (Homebrew and Paseo on a Mac). An optional step sets up iTerm2 on both Macs.

How it works (the frozen contract is [docs/handoff.md](docs/handoff.md)):

1. **Once, on your Mac.** In the Tailscale admin console add `tagOwners` for `tag:bootstrap` plus a grant to TCP 22, and create an OAuth client with only the Auth Keys (write) scope and that tag. Then run `curl -fsSL "<origin>/install.sh" | bash -s -- --client-setup --origin "<origin>"`, which stores the OAuth secret in your Keychain and installs the `mac-bootstrap` helper.
2. **On each new machine.** Run `curl -fsSL "<origin>/install.sh" | bash` and type the sudo password (on a Mac, turn on Remote Login when System Settings opens; Screen Sharing is optional, by hand).
3. **Hand-off.** On your Mac run the printed `mac-bootstrap handoff user@IP`, check the fingerprint matches the new machine's screen, and type its password. The new machine joins your tailnet (tagged, single-use key minted on your Mac; the OAuth secret never leaves it), logs `gh` in and gets your git identity. Fallback: `mac-bootstrap bundle --copy` on your Mac, then press `p` on the new machine and paste.

The hand-off copies your Mac's existing `gh` login (`gh auth token`) to the new machine: broad scopes, the same token on both, revoking it logs your Mac out too, and on Linux it is a plaintext owner-only file.

- `public/index.html`: the walkthrough page (static, no framework, no external requests). Every command on it is built from the address it is served from.
- `public/install.sh`: the one script, for new machines and the client modes on your Mac.
- `public/iterm2-client.sh`: run on the client Mac you SSH from.
- `vercel.json`: no build; serves `public/`; scripts as `text/plain; charset=utf-8` with `nosniff` and revalidating cache; security headers on every path, and a CSP on `/` and `/index.html`.
- `docs/tailscale-auth-key.md`: research on Tailscale auth keys (not served).
- `docs/handoff.md`: the unified bootstrap and hand-off contract (not served).

## One-time Vercel import

This step has been completed for this repo (Vercel project `mac-bootstrap`); it is kept here for forks.

No CLI needed; everything is in the dashboard. Source: [Managing projects](https://vercel.com/docs/projects/managing-projects).

1. On the Vercel [dashboard](https://vercel.com/dashboard), pick the right team, click **Add New…** then **Project**.
2. Under *Import Git Repository*, connect GitHub if asked, and import **yanmad27/mac-bootstrap** (grant the Vercel GitHub app access to that repository if prompted).
3. On the configure screen leave **Root Directory** at the repository root. **Framework Preset**, **Build Command**, **Install Command** and **Output Directory** are overridden by `vercel.json` (`framework: null` = "Other", no build or install command, `outputDirectory: "public"`), so you do not need to change them. The settings screen may show them as overridden. Do not add environment variables.
4. Click **Deploy**. Every later push to the production branch (`main`) redeploys; the repository's default branch is the production branch unless you change it in Settings.

Key names verified against [vercel.json reference](https://vercel.com/docs/project-configuration/vercel-json) (`framework`, `buildCommand`, `installCommand`, `outputDirectory`, `headers`; "To select 'Other' as the Framework Preset, use `null`").

## Live site

Production URL: https://mac-bootstrap-seven.vercel.app (alias https://mac-bootstrap-yanmad27.vercel.app). Pushes to main auto-deploy to production.

Verified 2026-10-01 ([evidence](docs/evidence/live/README.md)):

```sh
curl -sI https://mac-bootstrap-seven.vercel.app/install.sh | grep -i -E '^(HTTP|content-type|x-content-type-options|cache-control)'
# expect: 200, content-type: text/plain; charset=utf-8, x-content-type-options: nosniff
curl -fsSL https://mac-bootstrap-seven.vercel.app/install.sh | bash -s -- --dry-run
curl -sI https://mac-bootstrap-seven.vercel.app/iterm2-client.sh | grep -i content-type
```

Open https://mac-bootstrap-seven.vercel.app/ to confirm the commands show the correct URL and Copy buttons work.

## Security notes

- The page never asks for or stores secrets. The advanced env variant (`TS_AUTHKEY`, `GH_TOKEN`; a `tskey-client-` value also needs `TS_TAGS`) goes through a hidden `read` into non-exported shell variables and is handed only to `bash`; see the page and `install.sh`.
- Pipe-to-shell trusts this site and your Vercel project. The page links the script URLs so you can read them first, and recommends `--dry-run`.

## Page checks

Evidence for the unified page is in [docs/evidence/unified/page/](docs/evidence/unified/page/): screenshots (1280/390, light/dark, JS off), a Copy-button clipboard test, the commands check (origin with JS on, `<your-site>` with JS off), contrast and reduced-motion results, the word count, and the iTerm2 diff. `check.js` there reproduces them (`npm i playwright`, serve `public/` on 127.0.0.1:8878, `node check.js <outdir>`).
