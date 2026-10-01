# mac-bootstrap

Bootstraps a Mac for remote access over Tailscale: Screen Sharing and Remote Login are switched on by hand (Apple's supported UI), then one `curl | bash` command installs Homebrew, Tailscale (system daemon), git, gh and Paseo. An optional step sets up iTerm2 on both Macs.

- `public/index.html`: the walkthrough page (static, no framework, no external requests). Every command on it is built from the address it is served from.
- `public/install.sh`: run on the Mac being bootstrapped.
- `public/iterm2-client.sh`: run on the client Mac you SSH from.
- `vercel.json`: no build; serves `public/`; scripts as `text/plain; charset=utf-8` with `nosniff` and revalidating cache; security headers on every path, and a CSP on `/` and `/index.html`.
- `docs/tailscale-auth-key.md`: research behind the auth-key section (not served).

## One-time Vercel import

No CLI needed; everything is in the dashboard. Source: [Managing projects](https://vercel.com/docs/projects/managing-projects).

1. On the Vercel [dashboard](https://vercel.com/dashboard), pick the right team, click **Add New…** then **Project**.
2. Under *Import Git Repository*, connect GitHub if asked, and import **yanmad27/mac-bootstrap** (grant the Vercel GitHub app access to that repository if prompted).
3. On the configure screen leave **Root Directory** at the repository root. **Framework Preset**, **Build Command**, **Install Command** and **Output Directory** are overridden by `vercel.json` (`framework: null` = "Other", no build or install command, `outputDirectory: "public"`), so you do not need to change them. The settings screen may show them as overridden. Do not add environment variables.
4. Click **Deploy**. Every later push to the production branch (`main`) redeploys; the repository's default branch is the production branch unless you change it in Settings.

Key names verified against [vercel.json reference](https://vercel.com/docs/project-configuration/vercel-json) (`framework`, `buildCommand`, `installCommand`, `outputDirectory`, `headers`; "To select 'Other' as the Framework Preset, use `null`").

## Live checks (pending: no Vercel deployment exists yet)

After the first deploy, with `<url>` the production URL (for example `https://<project>.vercel.app`):

```sh
curl -sI <url>/install.sh | grep -i -E '^(HTTP|content-type|x-content-type-options|cache-control)'
# expect: 200, content-type: text/plain; charset=utf-8, x-content-type-options: nosniff
curl -fsSL <url>/install.sh | bash -s -- --dry-run
curl -sI <url>/iterm2-client.sh | grep -i content-type
```

Then open `<url>/` and confirm the commands show `<url>`'s own address and the Copy buttons work. Until this is done, the plain-text content type on Vercel is unverified; only a local static server was used (which does not apply `vercel.json`).

## Security notes

- The page never asks for or stores secrets. Secrets go through a hidden `read` into non-exported shell variables and are handed only to `bash`; see the page and `install.sh`.
- Pipe-to-shell trusts this site and your Vercel project. The page links the script URLs so you can read them first, and recommends `--dry-run`.
