# Sources used (fetched 2026-10-01)

- Vercel, vercel.json reference (framework/buildCommand/installCommand/outputDirectory/headers; `framework: null` = "Other"): https://vercel.com/docs/project-configuration/vercel-json
- Vercel, project configuration overview: https://vercel.com/docs/project-configuration
- Vercel, creating a project from the dashboard (Add New… > Project, import Git repo): https://vercel.com/docs/projects/managing-projects
- Apple, Screen Sharing: https://support.apple.com/guide/mac-help/turn-screen-sharing-on-or-off-mh11848/mac
- Apple, Remote Login: https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac
- Tailscale: https://tailscale.com/kb/1085/auth-keys , https://tailscale.com/kb/1065/macos-variants (via docs/tailscale-auth-key.md)

# Reproduce

Untracked stubs `public/install.sh` and `public/iterm2-client.sh` were used for local viewing and are not committed.
`python3 -m http.server 48765 --bind 127.0.0.1 --directory public`, then a Playwright script (chromium) loaded the page,
clicked each Copy button and compared clipboard to the displayed text: see playwright-check.txt.
Not verified: vercel.json header application and the Vercel dashboard labels on a live deployment; Apple/Tailscale UI on a real Mac.
