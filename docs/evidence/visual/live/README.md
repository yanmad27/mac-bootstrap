# Live evidence: visual-first page

- Site: https://mac-bootstrap-seven.vercel.app
- Commit: c782f7a727a0ca837ae05dc00b830994dcef6ec0 (main)
- Deployment ID: dpl_B5MFjdohE1QVLxnkirbMJ1p2nhEh (production, READY, source git)
- Checked: 2026-10-01 (read-only; Chromium via Playwright, curl, vercel ls/inspect/api)

| File | Proves |
|---|---|
| deploy.txt | The production deployment built from c782f7a is READY and aliased to the site |
| sha-compare.txt | Live `/`, `/install.sh`, `/iterm2-client.sh` are byte-identical to the repo files at c782f7a; the two scripts equal the earlier docs/evidence/live hashes |
| headers.txt | Status 200, content types, CSP, nosniff, X-Frame-Options on `/` and `/install.sh` |
| live-1280-{light,dark}.png, live-390-{light,dark}.png | Full-page live render, `<details>` collapsed |
| live-checks.txt | Both diagrams visible per viewport (aria-labels), page heights, copy buttons clipboard == displayed text, curl URLs on the live origin, 0 external requests, 0 console/CSP errors, no overflow at 390px, unique button labels |
| contract-check.txt | Every flag and env var from both scripts' `--help` appears in the live page text (0 missing) |

Not proven: non-Chromium browsers (Safari, Firefox), VoiceOver / real screen-reader behavior, real clipboard on macOS Safari.
Note: the page has 13 `<details>` (repo and live agree), not 17.
