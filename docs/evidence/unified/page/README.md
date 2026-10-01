# Unified page evidence

Candidate page: `public/index.html` at the commit that adds this directory. Served from `http://127.0.0.1:8878` (static server on `public/`), Playwright chromium.

- `checks-raw.txt`: JS-off and JS-on command checks, Copy test (clipboard read for all 14 buttons), external requests, overflow/overlap, reduced motion, word count, contrast (light and dark). Produced by `check.js`.
- `iterm-diff.txt`: iTerm2 commands, iTerm2 section and read-the-script paragraph vs base 33d3e07.
- `after-{1280,390}-{light,dark}.png` (full page), `after-first-*` (first viewport), `after-1280-light-nojs.png` (JS disabled).

Word budget: `wordcount.js` (committed) is the measure; its output is `wordcount.txt`. Same method on the base page (`git show 00590e9:public/index.html`) and on this one: `document.body.innerText`, details collapsed, light, reduced motion, 1280 and 390. Base: visible 617, non-code 554. New: visible 600, non-code 533 (-17 visible, -21 non-code). The limit of 334 from `docs/evidence/apple/wordcount.txt` cannot be applied to this method: that run's "code" count (302 of 617 visible) came from `/tmp/wc/measure.js`, which no longer exists and was not reproducible, and the base page already scores 554 here. The reproducible claim is therefore "no growth against the base": visible and non-code words both fall. If the recorded offset (visible - 302) were constant, new non-code would be about 298 (<= 334), but that is an inference, not a measurement. `checks-raw.txt` repeats a coarser word count from an earlier method; `wordcount.txt` is authoritative.
Unverified label wording: "Access controls", "Settings > OAuth clients" and "Trust credentials" (newer consoles) in step 1 are not checked against the live Tailscale console; the page links only the console root https://login.tailscale.com/admin.
Notes: `--origin` is https-only in the script; on this http://127.0.0.1 server the page still builds the command from the serving origin as required. Static commands with no origin by design: c-policy, c-nc, c-bundle, c-read1, c-read2, c-unset (the printed `mac-bootstrap handoff user@IP` has no Copy button because it contains placeholders).
