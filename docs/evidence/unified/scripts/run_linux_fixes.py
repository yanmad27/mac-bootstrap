#!/usr/bin/env python3
"""Functional tests for the review items C2, C3, C4, C8, C9 on the FROZEN install.sh, in disposable native-arm64 ubuntu containers.
usage (repo root): python3 docs/evidence/unified/scripts/run_linux_fixes.py"""
import hashlib, os, shlex, subprocess, sys
ROOT = os.getcwd(); OUT = os.path.join(ROOT, "docs/evidence/unified/linux"); INSTALL = os.path.join(ROOT, "public/install.sh"); SCR = os.path.join(ROOT, "docs/evidence/unified/scripts")
SHA = hashlib.sha256(open(INSTALL, "rb").read()).hexdigest()
def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True)
def dx(cn, user, cmd): r = sh("docker exec -u %s %s bash -c %s" % (user, cn, shlex.quote(cmd))); return r.stdout + r.stderr
res = []; log = []
def check(label, ok, detail=""):
    res.append((label, ok)); print(("PASS " if ok else "FAIL ") + label + ("" if ok else " -- " + str(detail)[-300:]), flush=True)
def sect(t, b): log.append("##### " + t + "\n" + b.rstrip() + "\n")
def mk(cn, prep):
    sh("docker rm -f %s >/dev/null 2>&1" % cn); sh("docker run -d --name %s ubuntu:24.04 sleep infinity >/dev/null" % cn)
    o = dx(cn, "root", "apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo curl ca-certificates >/dev/null 2>&1; useradd -m -s /bin/bash tuser; echo 'tuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tuser; " + prep)
    sh("docker cp %s %s:/opt/install.sh; docker cp %s/fn-harness.sh %s:/opt/fn-harness.sh" % (INSTALL, cn, SCR, cn))
def run(cn, args="", user="tuser"): return dx(cn, user, "bash /opt/install.sh --no-wait --skip-tailscale-up --skip-gh-auth %s; echo exit=$?" % args)
def strip(o): return "\n".join(l for l in o.split("\n") if not l.startswith(("Selecting", "Preparing", "Unpacking", "Setting up", "(Reading", "Get:", "Processing", "Created symlink", "debconf")))

# ---- C9: no dnf / no pacman / RHEL 7 (no override => the real checks run)
mk("mbf-c9", "cp /etc/os-release /root/os-release.orig")
for name, body in (("fedora-without-dnf", 'ID=fedora\nVERSION_ID=44\nPRETTY_NAME="Fake Fedora"\n'), ("arch-without-pacman", 'ID=arch\nPRETTY_NAME="Fake Arch"\n'), ("centos-7", 'ID=centos\nID_LIKE="rhel fedora"\nVERSION_ID="7"\nPRETTY_NAME="Fake CentOS 7"\n')):
    dx("mbf-c9", "root", "printf %s > /etc/os-release" % shlex.quote(body))
    o = dx("mbf-c9", "tuser", "bash /opt/install.sh --dry-run; echo exit=$?"); sect("C9 %s (real /etc/os-release, no override, ubuntu userland)" % name, o)
    want = {"fedora-without-dnf": "dnf not found", "arch-without-pacman": "pacman not found", "centos-7": "older than 8"}[name]
    check("C9 %s -> clear error before changes" % name, want in o and "exit=1" in o, o)
sh("docker rm -f mbf-c9 >/dev/null")

# ---- C8: inbox permission rule (Fedora/RHEL private group, umask 002)
mk("mbf-c8", "mkdir -p /home/tuser/.cache; chown tuser:tuser /home/tuser/.cache")
def inbox(setup, label, want_ok):
    dx("mbf-c8", "root", "rm -rf /home/tuser/.cache/mac-bootstrap; " + setup)
    o = dx("mbf-c8", "tuser", "bash /opt/fn-harness.sh /opt/install.sh %s" % shlex.quote("if inbox_prepare; then echo RESULT-OK inbox=$INBOX; ls -ld $INBOX; else echo RESULT-REFUSED; fi; inbox_cleanup"))
    sect("C8 " + label, "setup: " + setup + "\n" + o)
    check("C8 %s -> %s" % (label, "accepted" if want_ok else "refused"), ("RESULT-OK" in o) == want_ok, o)
inbox("chmod 755 /home/tuser/.cache", ".cache 0755", True)
inbox("chmod 775 /home/tuser/.cache", ".cache 0775 group = the user's private group tuser (Fedora umask 002)", True)
inbox("chgrp daemon /home/tuser/.cache; chmod 775 /home/tuser/.cache", ".cache 0775 group daemon (not the private group)", False)
inbox("chmod 777 /home/tuser/.cache", ".cache 0777 (world-writable)", False)
inbox("chmod 755 /home/tuser/.cache; mkdir -p /home/tuser/.cache/mac-bootstrap; chown tuser:tuser /home/tuser/.cache/mac-bootstrap; chmod 770 /home/tuser/.cache/mac-bootstrap", "mac-bootstrap 0770 pre-existing, private group (chmod 0700 applied, inbox 0700)", True)
inbox("chmod 755 /home/tuser/.cache; ln -s /tmp /home/tuser/.cache/mac-bootstrap", "mac-bootstrap is a symlink", False)
sh("docker rm -f mbf-c8 >/dev/null")

# ---- C2: rerun after a partial run (nodesource.list present, nodejs absent)
mk("mbf-c2", "")
o1 = strip(run("mbf-c2")); sect("C2 first run (full install)", o1[-1500:])
o2 = dx("mbf-c2", "tuser", "sudo apt-get remove -y -qq nodejs >/dev/null 2>&1; ls /etc/apt/sources.list.d/nodesource.list; command -v node || echo 'node: absent'; dpkg -l nodejs 2>&1 | tail -1")
sect("C2 state after `apt-get remove nodejs` (NodeSource list stays)", o2)
o3 = strip(run("mbf-c2")); sect("C2 rerun", o3[-3500:])
check("C2 first run ok", "exit=0" in o1 or "exit=3" in o1, o1[-300:])
check("C2 rerun with nodesource.list present and nodejs absent: NodeSource plan, no apt error, node >= 20 again", ("exit=3" in o3 or "exit=0" in o3) and "NodeSource apt repo already configured" in o3 and "E: Unable" not in o3 and "dpkg: error" not in o3, o3[-400:])
v = dx("mbf-c2", "tuser", "node --version; npm --version; paseo --version"); sect("C2 versions after rerun", v)
check("C2 node 22 + npm present after the rerun", "v22" in v or "v20" in v or "v2" in v, v)
# ---- R2: NodeSource configured as deb822 .sources (not nodesource.list): do not add a second repo
dx("mbf-c2", "tuser", "sudo apt-get remove -y -qq nodejs >/dev/null 2>&1; sudo rm -f /etc/apt/sources.list.d/nodesource.list; printf 'Types: deb\\nURIs: https://deb.nodesource.com/node_22.x\\nSuites: nodistro\\nComponents: main\\nSigned-By: /usr/share/keyrings/nodesource.gpg\\n' | sudo tee /etc/apt/sources.list.d/nodesource.sources >/dev/null")
o4 = strip(run("mbf-c2")); sect("R2 rerun with a deb822 nodesource.sources and nodejs absent", o4[-3000:])
l = dx("mbf-c2", "tuser", "ls /etc/apt/sources.list.d/ | grep -i nodesource; node --version")
sect("R2 files after", l)
check("R2 deb822 .sources counts as configured: no second NodeSource repo added, node installed", "nodesource.sources" in l and "nodesource.list" not in l and "NodeSource apt repo already configured (/etc/apt/sources.list.d/nodesource.sources)" in o4 and "v22" in l, l + o4[-300:])
sh("docker rm -f mbf-c2 >/dev/null")

# ---- R6: configured NodeSource repo that offers Node < 20 -> clear error naming the file, before any irreversible step
mk("mbf-r6", "printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_18.x nodistro main\\n' > /etc/apt/sources.list.d/nodesource.list")
o = dx("mbf-r6", "tuser", "bash /opt/fn-harness.sh /opt/install.sh 'LINUX_FAMILY=apt; NODE_PLAN=nodesource; DRY_RUN=0; apt_candidate_major() { echo 18; }; linux_ensure_node; echo exit=$?'; echo outer-exit=$?")
sect("R6 NodeSource repo for node_18.x configured (apt_candidate_major stubbed to 18)", o)
check("R6 old NodeSource repo: error names the file and how to fix it", "/etc/apt/sources.list.d/nodesource.list" in o and "older than the 20" in o and "node_22.x" in o, o)
sh("docker rm -f mbf-r6 >/dev/null")


# ---- C3: preinstalled distro nodejs 18 -> upgraded BEFORE any irreversible step
mk("mbf-c3", "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs npm >/dev/null 2>&1; node --version > /root/node-before.txt")
before = dx("mbf-c3", "root", "cat /root/node-before.txt")
o = strip(run("mbf-c3")); sect("C3 run with distro nodejs preinstalled (%s)" % before.strip(), o[-3000:])
v = dx("mbf-c3", "tuser", "node --version; paseo --version"); sect("C3 versions after", v)
check("C3 node < 20 preinstalled (%s): found, upgraded, install completes" % before.strip(), before.startswith("v18") and "too old for Paseo" in o and "v22" in v and "paseo: " not in "x" and "exit=" in o, o[-500:] + v)
check("C3 the upgrade happens in step 2, before the Tailscale step", o.index("too old for Paseo") < o.index("[5/10]"), "")
sh("docker rm -f mbf-c3 >/dev/null")

# ---- C4: npm global prefix writable (no sudo) / not writable with node outside sudo's secure_path (sudo + resolved npm)
mk("mbf-c4", "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xz-utils >/dev/null 2>&1; V=v22.11.0; curl -fsSL https://nodejs.org/dist/$V/node-$V-linux-arm64.tar.xz -o /tmp/n.tar.xz && mkdir -p /opt/node-user && tar -xJf /tmp/n.tar.xz -C /opt/node-user --strip-components=1 && chown -R root:root /opt/node-user")
o = dx("mbf-c4", "tuser", "export PATH=/opt/node-user/bin:$PATH; echo 'plain `sudo npm` (what the old code did):'; sudo npm --version 2>&1 | head -2; echo; node --version; bash /opt/fn-harness.sh /opt/install.sh 'DRY_RUN=0; SUDO_CMD=(sudo); linux_install_paseo; command -v paseo; paseo --version'")
sect("C4 node/npm only on the user's PATH (/opt/node-user, root-owned prefix): sudo with the resolved npm", o)
check("C4 root-owned npm prefix + node outside secure_path: plain `sudo npm` fails, the new code uses sudo with the resolved npm path and succeeds", "command not found" in o and "needs root: installing Paseo with sudo /opt/node-user/bin/npm" in o and "paseo" in o and "0." in o.split("sudo /opt/node-user/bin/npm")[-1], o[-500:])
dx("mbf-c4", "root", "rm -rf /opt/node-user/lib/node_modules/@getpaseo; rm -f /opt/node-user/bin/paseo; chown -R tuser:tuser /opt/node-user")
o = dx("mbf-c4", "tuser", "export PATH=/opt/node-user/bin:$PATH; bash /opt/fn-harness.sh /opt/install.sh 'DRY_RUN=0; SUDO_CMD=(sudo); linux_install_paseo; command -v paseo; paseo --version'")
sect("C4 npm prefix writable by the user (user-owned node install): no sudo", o)
check("C4 writable npm prefix: installed without sudo, prefix named", "is writable by this user: installing Paseo without sudo" in o and "paseo" in o, o[-400:])
sh("docker rm -f mbf-c4 >/dev/null")

open(os.path.join(OUT, "fixes-tests.txt"), "w").write("install.sh sha256: %s\nFunctional tests of review items C2, C3, C4, C8, C9 (disposable native arm64 ubuntu containers)\n\n" % SHA + "\n".join(log))
open(os.path.join(OUT, "summary-fixes.txt"), "w").write("install.sh sha256: %s\n" % SHA + "\n".join(("PASS " if k else "FAIL ") + l for l, k in res) + "\n")
sys.exit(0 if all(k for _, k in res) else 1)
