# Unified page evidence

Candidate page: `public/index.html` at the commit that adds this directory. Served from `http://127.0.0.1:8878` (static server on `public/`), Playwright chromium.

- `checks-raw.txt`: JS-off and JS-on command checks, Copy test (clipboard read for all 14 buttons), external requests, overflow/overlap, reduced motion, word count, contrast (light and dark). Produced by `check.js`.
- `iterm-diff.txt`: iTerm2 commands, iTerm2 section and read-the-script paragraph vs base 33d3e07.
- `after-{1280,390}-{light,dark}.png` (full page), `after-first-*` (first viewport), `after-1280-light-nojs.png` (JS disabled).

Word budget: the earlier `docs/evidence/apple/wordcount.txt` script (`/tmp/wc/measure.js`) no longer exists, so its exact "code" split could not be reproduced. Same total method (`document.body.innerText`, details collapsed, light, reduced motion) gives visible words 617 (base 33d3e07) -> 585 (new), -32. Counting only visible `<pre>`/`<code>` text, non-code words fall 554 -> 518 (-36). The recorded non-code figure at base was 315 (limit 334); applying the same -36 gives about 279, inside the budget.
Notes: `--origin` is https-only in the script; on this http://127.0.0.1 server the page still builds the command from the serving origin as required. Static commands with no origin by design: c-policy, c-nc, c-bundle, c-read1, c-read2, c-unset (the printed `mac-bootstrap handoff user@IP` has no Copy button because it contains placeholders).
