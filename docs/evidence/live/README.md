# Live deployment evidence

- Production URL: https://mac-bootstrap-seven.vercel.app (also https://mac-bootstrap-yanmad27.vercel.app)
- Vercel project: `mac-bootstrap`, account `yanmad27` (Hobby)
- Deployments of commit `aab511a` (public/ and vercel.json identical to `bd92c8d`):
  - CLI `vercel deploy --prod`: `dpl_B3YGxa8hn7Z9D5zJi2m37wZzxf86`
  - Git auto-deploy from the push: `dpl_EMcStDrUDX9qEEr5VFJCaybfcZM2` (githubCommitSha `aab511a0fb290f1311aa330b21d74cb0c6ca8d4f`, source `git`)
- Git connect: `yanmad27/mac-bootstrap is already connected to your project.` (`vercel link` connected it on project creation, no browser step)
- Date: 2026-10-01
- Files: `deploy.txt`, `headers.txt`, `sha-compare.txt`, `dry-run-live.txt`, `screenshot-live.png`, `page-commands.txt`

Results: `/`, `/install.sh`, `/iterm2-client.sh` return 200 publicly; the scripts are `text/plain; charset=utf-8` with `nosniff`; live sha256 of all three files equals the repo; live `--dry-run` (dummy secrets, exit 0) shows [1/10]..[10/10]; every command on the page starts with the production URL.

Not proven: Deployment Protection state of per-deployment URLs (not tested; only the alias was checked); a real install; behaviour in a browser other than headless Chromium; anything beyond the checks above.

## Git auto-deploy proof

Pushing the evidence commit `48d9253` to origin main created production deployment `dpl_EAZKKrPKqiA5NsTVxPvH5jyPvkGw` (source `git`, githubCommitSha `48d925301552e84f287dc9dd46fd6b01e090a743`, READY). Afterwards `curl -sI https://mac-bootstrap-seven.vercel.app/install.sh` returned `HTTP/2 200`, `content-type: text/plain; charset=utf-8`, `x-content-type-options: nosniff`.
