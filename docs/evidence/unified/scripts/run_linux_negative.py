#!/usr/bin/env python3
"""Linux negative tests + distro detection matrix (disposable containers, nothing installed).
usage (repo root): python3 docs/evidence/unified/scripts/run_linux_negative.py"""
import os, shlex, subprocess, sys
ROOT = os.getcwd(); OUT = os.path.join(ROOT, "docs/evidence/unified/linux"); INSTALL = os.path.join(ROOT, "public/install.sh")
def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True)
def dx(cn, user, cmd, env=()):
    e = "".join("-e %s " % shlex.quote(x) for x in env)
    r = sh("docker exec -u %s %s%s bash -c %s" % (user, e, cn, shlex.quote(cmd))); return r.stdout + r.stderr
res = []; log = []
def check(label, ok):
    res.append((label, ok)); print(("PASS " if ok else "FAIL ") + label, flush=True)
def sect(t, body): log.append("##### " + t + "\n" + body.rstrip() + "\n")

def mk(cn, image, prep):
    sh("docker rm -f %s >/dev/null 2>&1" % cn); sh("docker run -d --name %s %s sleep infinity >/dev/null" % (cn, image))
    sh("docker exec %s sh -c %s" % (cn, shlex.quote(prep))); sh("docker cp %s %s:/tmp/install.sh" % (INSTALL, cn))

# ---- ubuntu container WITHOUT sudo: non-root without sudo, override inertness
U = "mbn-ubuntu"; mk(U, "ubuntu:24.04", "useradd -m -s /bin/bash tuser; printf 'ID=alpine\\nPRETTY_NAME=\"Fake Alpine\"\\nVERSION_ID=3.20\\n' > /tmp/fake-os-release; chmod 644 /tmp/fake-os-release; command -v sudo || echo 'sudo: not installed'")
before = dx(U, "root", "dpkg -l | wc -l")
o1 = dx(U, "tuser", "bash /tmp/install.sh; echo exit=$?")
sect("1. non-root user without sudo (real run, no flags): refused before any change", o1)
check("non-root without sudo: clear error, exit 1, before changes", "sudo is not installed" in o1 and "exit=1" in o1 and "Package repositories" not in o1)
o2 = dx(U, "tuser", "MB_OS_RELEASE=/tmp/fake-os-release bash /tmp/install.sh; echo exit=$?")
sect("2. MB_OS_RELEASE=<fake alpine> WITHOUT --dry-run and WITHOUT MB_TEST: override must be INERT (the real Ubuntu os-release is used)", o2)
check("os-release override without --dry-run is inert (Ubuntu still detected, override not announced)", "detected: Ubuntu" in o2 and "test override" not in o2 and "unsupported" not in o2)
o3 = dx(U, "tuser", "MB_OS_RELEASE=/tmp/fake-os-release bash /tmp/install.sh --dry-run; echo exit=$?")
sect("3. same override WITH --dry-run: honoured (unsupported distro error)", o3)
check("override honoured with --dry-run", "test override" in o3 and "unsupported Linux distribution 'alpine'" in o3)
o4 = dx(U, "tuser", "MB_TEST=1 MB_OS_RELEASE=/tmp/fake-os-release bash /tmp/install.sh; echo exit=$?")
sect("4. same override with MB_TEST=1 (non-dry): honoured", o4)
check("override honoured with MB_TEST=1", "test override" in o4 and "unsupported Linux distribution 'alpine'" in o4 and "exit=1" in o4)
o5 = dx(U, "root", "bash /tmp/install.sh --dry-run; echo exit=$?")
sect("5. root without --target-user (Linux)", o5)
check("root without --target-user refused", "name the user who owns" in o5 and "exit=1" in o5)
o6 = dx(U, "tuser", "MB_OS_RELEASE=/nonexistent bash /tmp/install.sh --dry-run; echo exit=$?")
sect("6. override pointing at a missing file (dry-run)", o6)
check("missing os-release (override path) -> clear error", "is missing or unreadable" in o6 and "exit=1" in o6)
after = dx(U, "root", "dpkg -l | wc -l")
check("none of the refusals changed the package set", before.strip() == after.strip())

# ---- missing /etc/os-release for real
M = "mbn-noosrel"; mk(M, "ubuntu:24.04", "useradd -m -s /bin/bash tuser; rm -f /etc/os-release /usr/lib/os-release")
o7 = dx(M, "root", "bash /tmp/install.sh --target-user tuser; echo exit=$?")
sect("7. /etc/os-release and /usr/lib/os-release removed (real run, root + --target-user)", o7)
check("really missing os-release -> clear error before changes", "is missing or unreadable" in o7 and "exit=1" in o7 and "Package repositories" not in o7)

# ---- unsupported distro for real (Alpine)
A = "mbn-alpine"; mk(A, "alpine:3.20", "apk add --no-cache bash >/dev/null 2>&1; adduser -D tuser")
pa = dx(A, "root", "apk info | wc -l")
o8 = dx(A, "root", "bash /tmp/install.sh --target-user tuser; echo exit=$?")
sect("8. Alpine (real run, root + --target-user)", o8)
check("unsupported distro (alpine): clear error, exit 1, before changes", "unsupported Linux distribution 'alpine'" in o8 and "exit=1" in o8 and "Package repositories" not in o8)
check("alpine package set unchanged", pa.strip() == dx(A, "root", "apk info | wc -l").strip())

# ---- detection matrix (dry-run on the ubuntu container with fake os-release files)
rows = [("ubuntu", "", "24.04", "noble"), ("debian", "", "13", "trixie"), ("linuxmint", "ubuntu debian", "22", ""), ("fedora", "", "44", ""), ("rocky", "rhel centos fedora", "9.3", ""),
        ("almalinux", "rhel centos fedora", "9.4", ""), ("centos", "rhel fedora", "9", ""), ("rhel", "fedora", "10.0", ""), ("ol", "fedora", "9.4", ""), ("arch", "", "", ""),
        ("manjaro", "arch", "", ""), ("amzn", "fedora", "2023", ""), ("alpine", "", "3.20", ""), ("opensuse-leap", "suse opensuse", "15.6", "")]
mat = []
for i, l, v, c in rows:
    body = "ID=%s\nID_LIKE=\"%s\"\nVERSION_ID=\"%s\"\nVERSION_CODENAME=%s\nUBUNTU_CODENAME=noble\nPRETTY_NAME=\"Fake %s\"\n" % (i, l, v, c, i)
    dx(U, "root", "printf %s > /tmp/os-%s; chmod 644 /tmp/os-%s" % (shlex.quote(body), i, i))
    out = dx(U, "root", "MB_OS_RELEASE=/tmp/os-%s bash /tmp/install.sh --dry-run --target-user tuser 2>&1 | grep -E 'family|unsupported|Linux \\(' | head -2" % i)
    mat.append("ID=%-14s ID_LIKE=%-22s -> %s" % (i, l or "-", out.strip().replace("\n", " | ").replace("    ", "")))
sect("9. distro detection matrix (dry-run with fake os-release files)", "\n".join(mat))
ok = lambda i, fam: any(m.startswith("ID=%-14s" % i) and fam in m for m in mat)
check("matrix: ubuntu/debian/mint -> apt, fedora -> fedora, rocky/alma/centos/rhel/ol -> rhel, arch/manjaro -> pacman; amzn/alpine/suse unsupported",
      all(ok(i, "apt family") for i in ("ubuntu", "debian", "linuxmint")) and ok("fedora", "fedora family") and all(ok(i, "rhel family") for i in ("rocky", "almalinux", "centos", "rhel", "ol"))
      and all(ok(i, "pacman family") for i in ("arch", "manjaro")) and all(ok(i, "unsupported") for i in ("amzn", "alpine", "opensuse-leap")))
for c in (U, M, A): sh("docker rm -f %s >/dev/null" % c)
open(os.path.join(OUT, "negative-tests.txt"), "w").write("Linux negative tests (disposable containers, nothing installed)\n\n" + "\n".join(log))
open(os.path.join(OUT, "summary-negative.txt"), "w").write("\n".join(("PASS " if k else "FAIL ") + l for l, k in res) + "\n")
sys.exit(0 if all(k for _, k in res) else 1)
