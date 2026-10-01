#!/usr/bin/env python3
"""Proves no dummy secret value (raw, or base64 in any of the 3 alignments) and no MB1 bundle blob
appears in any evidence output. The sources that DEFINE the dummy values (scripts/*.py, *.sh) are
the only files excluded: they cannot exist without the constants. Run from the repo root."""
import base64, os, re, sys
VALUES = ["tskey-client-DUMMYcid-DUMMYoauthsecret0001", "ghp_DUMMYghtoken0001", "tskey-auth-DUMMYminted0001",
          "tskey-api-DUMMYaccess0001", "tskey-client-DUMMYHOOKcid-DUMMYHOOKsecret", "ghp_DUMMYHOOKtoken",
          "ghp_DUMMYSTUBgh0001", "tskey-client-DUMMYSTUBcid-DUMMYSTUBsecret", "tskey-auth-DUMMYenv0001", "ghp_DUMMYenvtoken01",
          "DUMMYoauthsecret", "DUMMYghtoken", "DUMMYminted", "DUMMYaccess", "DUMMYHOOK", "DUMMYSTUB", "DUMMYenv"]
def forms(v):
    out = {v}
    for off in range(3):
        b = base64.b64encode(("x" * off + v).encode()).decode().strip("=")
        out.add(b[4:-4] if len(b) > 12 else b)
    return out
files = []
for d, _, fs in os.walk("docs/evidence/unified"):
    for f in fs:
        p = os.path.join(d, f)
        if p.startswith("docs/evidence/unified/scripts/") and f.endswith((".py", ".sh")): continue
        if f in ("grep-secrets.txt",) or f.endswith(".png"): continue
        files.append(p)
bad = []
for p in sorted(files):
    t = open(p, errors="replace").read()
    for v in VALUES:
        for f in forms(v):
            if f in t: bad.append((p, v, f if f == v else "base64 form"))
    if re.search(r"MB1:[A-Za-z0-9+/=]{8,}", t): bad.append((p, "MB1 bundle blob", ""))
print("scanned %d files (%d dummy values x raw+base64 forms, plus MB1 blobs)" % (len(files), len(VALUES)))
for b in bad: print("LEAK", *b)
print("RESULT: %s" % ("no dummy secret in any evidence file" if not bad else "LEAKS FOUND"))
sys.exit(1 if bad else 0)
