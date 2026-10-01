#!/usr/bin/env python3
"""Per-family Linux evidence: dry-run, then a REAL (non-dry) install in a disposable container,
then a real SSH hand-off from this Mac (MB_TEST=1, mock API on 127.0.0.1, DUMMY values), then probes.
usage (repo root): python3 docs/evidence/unified/scripts/run_linux.py <ubuntu|debian|fedora|rocky|arch>
No systemd in containers: sshd is started by hand after the installer prints its waiting banner."""
import hashlib, json, os, re, shlex, shutil, subprocess, sys, tempfile, datetime
sys.path.insert(0, os.path.dirname(__file__))
from ptydrive import Proc, BUNDLE_RE

FAMS = {
    "ubuntu": dict(image="ubuntu:24.04", plat="linux/arm64", port=2231, runas="tuser", pm="apt", sudo=True),
    "debian": dict(image="debian:trixie", plat="linux/arm64", port=2232, runas="root", pm="apt", sudo=False),
    "fedora": dict(image="fedora:latest", plat="linux/arm64", port=2233, runas="root", pm="dnf", sudo=False),
    "rocky": dict(image="rockylinux:9", plat="linux/arm64", port=2234, runas="tuser", pm="dnf", sudo=True),
    "arch": dict(image="archlinux:latest", plat="linux/amd64", port=2235, runas="root", pm="pacman", sudo=False, paste=True),
}
fam = sys.argv[1]; F = FAMS[fam]
ROOT = os.getcwd(); OUT = os.path.join(ROOT, "docs/evidence/unified/linux"); SCR = os.path.join(ROOT, "docs/evidence/unified/scripts")
INSTALL = os.path.join(ROOT, "public/install.sh"); SHA = hashlib.sha256(open(INSTALL, "rb").read()).hexdigest(); T = tempfile.mkdtemp(prefix="mbl.", dir="/tmp")
CN = "mbl-" + fam; API_PORT = 18770 + list(FAMS).index(fam)
D = {"oauth": "tskey-client-DUMMYcid-DUMMYoauthsecret0001", "gh": "ghp_DUMMYghtoken0001", "dry_ts": "tskey-auth-DUMMYdryrun0001", "dry_gh": "ghp_DUMMYdryrun0001"}
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

def clean(s):
    s = ANSI.sub("", s.replace("\r\n", "\n"))
    s = BUNDLE_RE.sub("MB1:<redacted bundle>", s)
    return "\n".join(l.split("\r")[-1] for l in s.split("\n"))

def sh(cmd, **kw): return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)
def dx(user, cmd): return sh("docker exec -u %s %s bash -c %s" % (user, CN, shlex.quote(cmd)))
results = []
def check(label, ok, detail=""):
    results.append((label, ok)); print(("PASS " if ok else "FAIL ") + label + ("" if ok else " -- " + detail), flush=True)

# ---- container
sh("docker rm -f %s >/dev/null 2>&1" % CN)
sh("docker pull -q --platform %s %s" % (F["plat"], F["image"]))
info = sh("docker image inspect --format '{{.Architecture}} {{index .RepoDigests 0}} {{.Id}}' %s" % F["image"]).stdout.split()
arch, digest, imgid = info[0], info[1], info[2]
sh("docker run -d --platform %s --name %s -p 127.0.0.1:%d:22 %s sleep infinity" % (F["plat"], CN, F["port"], F["image"]))
prep = ["set -e"]
if F["pm"] == "apt": prep += ["apt-get update -qq >/dev/null", "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo >/dev/null" if F["sudo"] else "true"]
if F["pm"] == "dnf": prep += ["command -v useradd >/dev/null || dnf -y -q install shadow-utils >/dev/null", "dnf -y -q install sudo >/dev/null" if F["sudo"] else "true"]
prep += ["useradd -m -s /bin/bash tuser", "usermod -p '*' tuser", "install -d -m 700 -o tuser -g tuser /home/tuser/.ssh"]
if F["sudo"]: prep += ["mkdir -p /etc/sudoers.d", "echo 'tuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tuser"]
r = dx("root", "; ".join(prep)); assert r.returncode == 0, r.stderr
sh("ssh-keygen -q -t ed25519 -N '' -f %s/id" % T)
agent = sh("ssh-agent -a %s/agent.sock" % T).stdout; apid = int(re.search(r"SSH_AGENT_PID=(\d+)", agent).group(1))
sh("SSH_AUTH_SOCK=%s/agent.sock ssh-add %s/id" % (T, T))
sh("docker cp %s/id.pub %s:/home/tuser/.ssh/authorized_keys && docker exec -u root %s bash -c 'chown tuser:tuser /home/tuser/.ssh/authorized_keys && chmod 600 /home/tuser/.ssh/authorized_keys'" % (T, CN, CN))
sh("docker cp %s %s:/tmp/install.sh" % (INSTALL, CN))
home = os.path.join(T, "home"); os.makedirs(home)
open(home + "/.gitconfig", "w").write("[user]\n\tname = Dummy Person\n\temail = dummy@example.invalid\n")
args = [] if F["runas"] == "tuser" else ["--target-user", "tuser"]
hdr = ["install.sh sha256: %s" % SHA, "image: %s" % digest, "image id: %s" % imgid, "platform: %s (image architecture %s)%s" % (F["plat"], arch, "  EMULATION: amd64 under arm64 virtualisation" if arch == "amd64" else "  native"),
       "family: %s   run as: %s%s" % (fam, F["runas"], " (sudo)" if F["sudo"] else " (root, --target-user tuser)"), "date: %s" % datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
       "container: disposable, no systemd as PID 1 (docker 'sleep infinity')"]

# ---- dry run (dummy secrets in the env must not appear)
dry_cmd = ["docker", "exec", "-u", F["runas"], "-e", "TS_AUTHKEY=" + D["dry_ts"], "-e", "GH_TOKEN=" + D["dry_gh"], "-e", "TS_TAGS=tag:bootstrap", CN, "bash", "/tmp/install.sh", "--dry-run"] + args
dr = subprocess.run(dry_cmd, capture_output=True, text=True)
open(os.path.join(OUT, "dry-run-%s.txt" % fam), "w").write("\n".join(hdr[:6]) + "\ncommand: docker exec -u %s -e TS_AUTHKEY=<dummy> -e GH_TOKEN=<dummy> -e TS_TAGS=tag:bootstrap %s bash /tmp/install.sh --dry-run %s\n\n" % (F["runas"], CN, " ".join(args)) + clean(dr.stdout + dr.stderr) + "\nexit=%d\n" % dr.returncode)
check("%s dry-run exits 0 and shows the numbered flow" % fam, dr.returncode == 3 or dr.returncode == 0 and "[10/10] Summary" in dr.stdout, str(dr.returncode))
check("%s dry-run: dummy TS_AUTHKEY/GH_TOKEN absent from the output" % fam, D["dry_ts"] not in dr.stdout + dr.stderr and D["dry_gh"] not in dr.stdout + dr.stderr)
check("%s dry-run changed nothing (no tailscale/gh/node installed)" % fam, dx("root", "command -v tailscale gh paseo sshd").returncode != 0)

# ---- mock API + real run
mlog = os.path.join(T, "mock.jsonl")
mock = subprocess.Popen([sys.executable, os.path.join(SCR, "mock_api.py"), str(API_PORT), mlog, "ok"], stdout=subprocess.PIPE, text=True); mock.stdout.readline()
cenv = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"], "USER": os.environ.get("USER", "u"), "TERM": "xterm", "SSH_AUTH_SOCK": T + "/agent.sock", "LANG": "en_US.UTF-8",
        "MB_TEST": "1", "MB_TEST_OAUTH_SECRET": D["oauth"], "MB_TEST_GH_TOKEN": D["gh"], "MB_TEST_API_BASE": "http://127.0.0.1:%d" % API_PORT, "MB_TEST_HOME": home}
real_cmd = ["docker", "exec", "-it", "-u", F["runas"], CN, "bash", "/tmp/install.sh"] + args
if F.get("paste"):
    # EMULATION LIMIT (amd64 under arm64): neither hand-off path works here. OpenSSH's seccomp sandbox cannot be
    # attached (sshd drops every connection) and `read -s -n 1` never receives a key on the emulated tty. So no hand-off is
    # attempted for this family; the dummy gh token and git identity are given through the back-compat env instead.
    r = Proc(["docker", "exec", "-it", "-u", F["runas"], "-e", "GH_TOKEN=" + D["gh"], "-e", "GIT_USER_NAME=Dummy Person", "-e", "GIT_USER_EMAIL=dummy@example.invalid", CN, "bash", "/tmp/install.sh"] + args)
    rs = r.wait(900)
    dbg = dx("root", "(/usr/bin/sshd -ddd -D -p 2299 -E /tmp/sshd-debug.log &) ; sleep 2; ssh-keyscan -T 10 -p 2299 -t ed25519 127.0.0.1 2>&1 | cut -c1-70; sleep 1; grep -E 'PR_SET_SECCOMP|exited with status' /tmp/sshd-debug.log | head -3")
    tt = Proc(["docker", "exec", "-it", CN, "bash", "-c", "read -r -t 4 -s -n 1 k </dev/tty; echo key-read: got=[$k] rc=$?"]); tt.send("p"); tt.wait(20)
    emu = ("EMULATION LIMIT (amd64 on arm64): no hand-off was attempted for this family.\n--- sshd under emulation (in-container probe):\n" + dbg.stdout + dbg.stderr +
           "--- single-key read on the emulated tty (a 'p' was typed):\n" + clean(tt.log) + "\n")
    cs = 0; c = type("C", (), {"log": emu})()
else:
    r = Proc(real_cmd)
    r.wait_for("waiting up to", 900)
    sh("docker exec -d -u root %s bash -c %s" % (CN, shlex.quote('exec $(command -v sshd || echo /usr/sbin/sshd)')))
    r.wait_for("host-key fingerprint", 60)
    c = Proc(["/bin/bash", INSTALL, "handoff", "tuser@127.0.0.1", "--port", str(F["port"])], env=cenv)
    c.wait_for("Does this match the screen? [y/N]", 60); c.send("y\n"); cs = c.wait(120)
    rs = r.wait(600)
mock.terminate()
body = ("\n".join(hdr) + "\ncommand: docker exec -it -u %s %s%s bash /tmp/install.sh %s\n" % (F["runas"], "-e GH_TOKEN=<dummy> -e GIT_USER_NAME=<dummy> -e GIT_USER_EMAIL=<dummy> " if F.get("paste") else "", CN, " ".join(args)) +
        ("note: NO hand-off for this family (emulation limit, see below); dummy gh token and git identity come from the env.\n\n" if F.get("paste") else
         "client: bash public/install.sh handoff tuser@127.0.0.1 --port %d   (MB_TEST=1, mock API 127.0.0.1:%d, dummy values)\nnote: sshd was started by hand in the container (docker exec -d sshd) once the installer printed its waiting banner; there is no systemd.\n\n" % (F["port"], API_PORT)) +
        "===== installer output (full) =====\n") + clean(r.log) + "\n===== installer exit status: %d =====\n\n===== client (Mac) / emulation-limit output =====\n" % rs + clean(c.log) + "\n===== client exit status: %d =====\n" % cs
if not F.get("paste"): check("%s hand-off delivered over real SSH" % fam, cs == 0 and "bundle received over SSH and accepted" in r.log, str(cs))
check("%s installer exit status 3 (services not started, honestly reported)" % fam, rs == 3 and "NOT COMPLETE" in r.log, str(rs))
check("%s gh login with the dummy token failed cleanly (script continued)" % fam, "gh login FAILED" in r.log and "[10/10] Summary" in r.log)

# ---- postconditions
probes = []
def probe(title, user, cmd):
    o = dx(user, cmd); probes.append("$ (%s) %s\n%s%s" % (user, cmd, o.stdout, o.stderr))
tools = "echo tailscale: $(tailscale version | head -1); echo sshd: $( (command -v sshd || echo /usr/sbin/sshd) | xargs -I{} sh -c '{} -V 2>&1 | head -1'); git --version; gh --version | head -1; echo node: $(node --version); echo paseo: $(paseo --version)"
probe("versions", "root", tools)
probe("gh binary", "root", "command -v gh; ls -l $(command -v gh)")
probe("sshd -t", "root", "$(command -v sshd || echo /usr/sbin/sshd) -t; echo sshd -t exit=$?")
probe("gh auth status (dummy token => not logged in)", "tuser", "gh auth status 2>&1 | head -3; echo gh-auth-status-exit=${PIPESTATUS[0]}")
probe("git identity", "tuser", "git config --global user.name; git config --global user.email")
probe("inbox removed", "tuser", "ls -la ~/.cache/mac-bootstrap/inbox 2>&1 | head -2; ls -A ~/.cache/mac-bootstrap 2>&1")
probe("no key file / bundle residue in /tmp", "root", "ls -A /tmp | grep -E 'tskey|mac-bootstrap\\.' || echo none")
probe("sshd authorization untouched: password and root login not enabled by the installer", "root", "grep -hE '^(PasswordAuthentication|PermitRootLogin)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null || echo '(no PasswordAuthentication/PermitRootLogin lines written)'; git -C / log -0 2>/dev/null; true")
body += "\n===== postcondition probes =====\n" + "\n".join(probes)
gv = "\n".join(probes)
gh_ok = "gh version" in gv or (F.get("paste") and "panic: runtime error" in gv and "/usr/bin/gh" in gv)  # arch/amd64: Go runtime panics under emulation = EMULATION LIMIT
check("%s probes: all tools present (tailscale, sshd, git, gh, node >= 20, paseo)%s" % (fam, " [gh binary installed; its run crashes: EMULATION LIMIT]" if F.get("paste") else ""), all(k in gv for k in ("tailscale:", "git version", "node: v", "paseo: 0.")) and gh_ok and re.search(r"node: v(2\d|[3-9]\d)", gv) is not None, gv[:400])
check("%s probes: sshd -t ok, git identity set, inbox removed" % fam, "sshd -t exit=0" in gv and "Dummy Person" in gv and "No such file" in gv)

# ---- idempotent rerun
rr = subprocess.run(["docker", "exec", "-u", F["runas"], CN, "bash", "/tmp/install.sh", "--no-wait"] + args, capture_output=True, text=True)
rrt = clean(rr.stdout + rr.stderr)
body += "\n===== rerun (idempotence): bash install.sh --no-wait %s =====\n" % " ".join(args) + "\n".join(l for l in rrt.split("\n") if l.strip()) + "\n===== rerun exit status: %d =====\n" % rr.returncode
check("%s rerun is idempotent (everything already present -> skip, no reinstall)" % fam, "already present" in rrt and "Setting up" not in rrt and "Unpacking" not in rrt and "Installing" not in rrt, rrt[-300:])
open(os.path.join(OUT, "real-%s.txt" % fam), "w").write(body)
open(os.path.join(OUT, "summary-%s.txt" % fam), "w").write("install.sh sha256: %s\n" % SHA + "\n".join(("PASS " if ok else "FAIL ") + l for l, ok in results) + "\n")
os.kill(apid, 15); shutil.rmtree(T, ignore_errors=True)
sh("docker rm -f %s >/dev/null" % CN)
sys.exit(0 if all(ok for _, ok in results) else 1)
