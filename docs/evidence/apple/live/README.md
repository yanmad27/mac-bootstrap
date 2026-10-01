# Live evidence: Apple-clean page, production

- Commit: 2a1e1ade5c61dc7a954c75e3433aa04afe6994c6 (main, "Merge branch 'apple': Apple-clean restyle")
- Deployment: dpl_HF1wWMWjfNCejx5ERF96KVJMCVjv (https://mac-bootstrap-deam71q2v-yanmad27.vercel.app), READY, production, source git
- Alias checked: https://mac-bootstrap-seven.vercel.app
- Date: 2026-10-01

| File | Proves |
|---|---|
| deploy.txt | the production deployment for 2a1e1ad is READY, git-sourced, aliased |
| sha-compare.txt | live `/`, `/install.sh`, `/iterm2-client.sh` sha256 equal the repo files at 2a1e1ad (3/3 MATCH); the two scripts are unchanged since the previous live evidence |
| headers.txt | status, content-type, CSP (on `/`), nosniff, X-Frame-Options (`/install.sh` is served without a CSP header) |
| live-checks.txt | per viewport/scheme: visible illustration variant and aria-label, flow tiles, page heights, scrollWidth at 390, 11/11 copy buttons clipboard == displayed, 7/7 curl commands on the live origin, unique button labels, 0 external requests, 0 console/CSP errors |
| contract-check.txt | every flag and env var from both `--help` outputs appears in the live page text (0 missing) |
| live-{1280,390}-{light,dark}.png | full page, `<details>` collapsed, prefers-reduced-motion: reduce |
| live-first-1280x800-{light,dark}.png | first-screen crops |

Live heights (collapsed): 1280 = 5247px, 390 = 6756px (local run in ../heights.txt: 5220 / 6754; the small delta is not investigated).

Not proven: browsers other than Chromium (Safari, Firefox), VoiceOver / real screen-reader behavior, reveal-on-scroll motion (screenshots use reduced motion), expanded-`<details>` visuals.
