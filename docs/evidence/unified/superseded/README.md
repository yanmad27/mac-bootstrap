# Superseded evidence

These files were produced for EARLIER versions of `public/install.sh` (checkpoint A `1b463e6`, checkpoint B `bb00b9c`, integration `00bb099`), not for the frozen final script, whose sha256 is at the top of every current summary (see `../README.md`). They are kept only for history and must not be read as evidence for the final script.

- `real-arch.txt`, `dry-run-arch.txt`, `summary-arch.txt`: the Arch run (linux/amd64 under arm64 emulation; EMULATION LIMIT: gh Go panic, sshd exits 255, no hand-off) at the checkpoint-B script. Per the revised brief no further emulated runs were made, so Arch is covered only by this older run (UNTESTED on the final script).
- `static-checks.txt` (from `scripts/` and from `linux/`), `mac-dry-run-after-B.txt`, `mac-dry-run-diff-vs-A.txt`: replaced by `../integration/static-checks.txt`, `../integration/mac-dry-run.txt`, `../integration/mac-dry-run-diff.txt`.

Round-1 evidence on sha `4ffad9cb…` was regenerated in place on the round-2 sha (`b914176b…`) rather than kept; the commit history holds it.
