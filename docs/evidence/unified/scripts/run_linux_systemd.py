#!/usr/bin/env python3
"""Real run of the final install.sh in a SYSTEMD-booted disposable container (native arm64, --privileged), with --skip-tailscale-up
so no auth key ever reaches Tailscale. No manual sshd: the installer must enable the ssh unit itself. Then a real SSH hand-off
from this Mac (MB_TEST=1, mock API 127.0.0.1, DUMMY values), probes and an idempotent rerun.
usage (repo root): python3 docs/evidence/unified/scripts/run_linux_systemd.py <ubuntu|debian|fedora|rocky>"""
import faulthandler, hashlib, json, os, re, shlex, shutil, subprocess, sys, tempfile, datetime
faulthandler.dump_traceback_later(1500, exit=True)  # fail fast with a traceback instead of hanging
sys.path.insert(0, os.path.dirname(__file__))
from ptydrive import Proc, BUNDLE_RE

SHA = hashlib.sha256(open(os.path.join(os.getcwd(), "public/install.sh"), "rb").read()).hexdigest()
FAMS = {
    "ubuntu": dict(image="ubuntu:24.04", port=2241, runas="tuser", sudo=True, pm="apt"),
    "debian": dict(image="debian:trixie", port=2242, runas="root", sudo=False, pm="apt"),
    "fedora": dict(image="fedora:latest", port=2243, runas="root", sudo=False, pm="dnf"),
    "rocky": dict(image="rockylinux:9", port=2244, runas="tuser", sudo=True, pm="dnf"),
}
fam = sys.argv[1]; F = FAMS[fam]
ROOT = os.getcwd(); OUT = os.path.join(ROOT, "docs/evidence/unified/linux"); SCR = os.path.join(ROOT, "docs/evidence/unified/scripts")
INSTALL = os.path.join(ROOT, "public/install.sh"); T = tempfile.mkdtemp(prefix="mbs.", dir="/tmp")
CN = "mbsd-" + fam; IMG = "mbsd-img-" + fam; API_PORT = 18780 + list(FAMS).index(fam)
D = {"oauth": "tskey-client-DUMMYcid-DUMMYoauthsecret0001", "gh": "ghp_DUMMYghtoken0001"}
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
def clean(s):
    s = ANSI.sub("", s.replace("\r\n", "\n")); s = BUNDLE_RE.sub("MB1:<redacted bundle>", s)
    return "\n".join(l.split("\r")[-1] for l in s.split("\n"))
def sh(cmd, **kw): return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)
def dx(user, cmd): return sh("docker exec -u %s %s bash -c %s" % (user, CN, shlex.quote(cmd)))
results = []
def check(label, ok, detail=""):
    results.append((label, ok)); print(("PASS " if ok else "FAIL ") + label + ("" if ok else " -- " + str(detail)[:300]), flush=True)

# ---- image: official base + systemd (+ sudo), users
if F["pm"] == "apt":
    pre = "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv dbus sudo iproute2 >/dev/null"
else:
    pre = "dnf -y -q install systemd sudo iproute shadow-utils >/dev/null"
fed = ""
df = ("FROM %s\nRUN %s && " % (F["image"], pre) + fed + "useradd -m -s /bin/bash tuser && usermod -p '*' tuser && install -d -m 700 -o tuser -g tuser /home/tuser/.ssh && %s\nSTOPSIGNAL SIGRTMIN+3\nCMD [\"/sbin/init\"]\n"
      % ("mkdir -p /etc/sudoers.d && echo 'tuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tuser" if F["sudo"] else "true"))
b = subprocess.run(["docker", "build", "-q", "-t", IMG, "-"], input=df, capture_output=True, text=True); assert b.returncode == 0, b.stderr
info = sh("docker image inspect --format '{{.Architecture}} {{index .RepoDigests 0}}' %s" % F["image"]).stdout.split()
sh("docker rm -f %s >/dev/null 2>&1" % CN)
r0 = sh("docker run -d --name %s --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -p 127.0.0.1:%d:22 %s /sbin/init" % (CN, F["port"], IMG)); assert r0.returncode == 0, r0.stderr
state = ""
for _try in range(20):  # systemd needs a moment before `docker exec systemctl` answers; each call blocks until boot finished
    state = sh("docker exec %s systemctl is-system-running --wait" % CN).stdout.strip()
    if state: break
pid1 = dx("root", "cat /proc/1/comm").stdout.strip()
sh("ssh-keygen -q -t ed25519 -N '' -f %s/id" % T)
agent = sh("ssh-agent -a %s/agent.sock" % T).stdout; apid = int(re.search(r"SSH_AGENT_PID=(\d+)", agent).group(1))
sh("SSH_AUTH_SOCK=%s/agent.sock ssh-add %s/id" % (T, T))
sh("docker cp %s/id.pub %s:/home/tuser/.ssh/authorized_keys && docker exec -u root %s bash -c 'chown tuser:tuser /home/tuser/.ssh/authorized_keys && chmod 600 /home/tuser/.ssh/authorized_keys'" % (T, CN, CN))
sh("docker cp %s %s:/opt/install.sh" % (INSTALL, CN))
home = os.path.join(T, "home"); os.makedirs(home)
open(home + "/.gitconfig", "w").write("[user]\n\tname = Dummy Person\n\temail = dummy@example.invalid\n")
args = ["--skip-tailscale-up"] + ([] if F["runas"] == "tuser" else ["--target-user", "tuser"])
hdr = ["image: %s" % info[1], "platform: linux/arm64 (image architecture %s) native, --privileged systemd container" % info[0], "family: %s   run as: %s%s" % (fam, F["runas"], " (sudo)" if F["sudo"] else " (root, --target-user tuser)"),
       "date: %s" % datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "PID 1: %s   systemctl is-system-running: %s" % (pid1, state),
       "%s" % ("CONTAINER LIMIT: in this docker/colima Fedora 44 systemd container sshd refuses every non-root login after the key is accepted (PAM account check: pam_acct_mgmt = 9, reproduced with a freshly created user and with a password set), so NO hand-off into it is possible; this run uses --no-wait with the dummy GH_TOKEN / git identity from the env instead. The hand-off receiver itself was exercised on Fedora in linux/real-fedora.txt (no systemd)." if fam == "fedora" else "(hand-off over real SSH into the installer-enabled ssh unit)"),
       "NOTE: --skip-tailscale-up was used, so no auth key was sent to Tailscale's control server; `tailscale up` / a real join is UNTESTED."]
check("%s container booted systemd as PID 1" % fam, pid1 == "systemd" and state in ("running", "degraded"), (pid1, state))

mlog = os.path.join(T, "mock.jsonl")
mock = subprocess.Popen([sys.executable, os.path.join(SCR, "mock_api.py"), str(API_PORT), mlog, "ok"], stdout=subprocess.PIPE, text=True); mock.stdout.readline()
cenv = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"], "USER": os.environ.get("USER", "u"), "TERM": "xterm", "SSH_AUTH_SOCK": T + "/agent.sock", "LANG": "en_US.UTF-8",
        "MB_TEST": "1", "MB_TEST_OAUTH_SECRET": D["oauth"], "MB_TEST_GH_TOKEN": D["gh"], "MB_TEST_API_BASE": "http://127.0.0.1:%d" % API_PORT, "MB_TEST_HOME": home}
if fam == "fedora":
    args = args + ["--no-wait"]
    r = Proc(["docker", "exec", "-it", "-u", F["runas"], "-e", "GH_TOKEN=" + D["gh"], "-e", "GIT_USER_NAME=Dummy Person", "-e", "GIT_USER_EMAIL=dummy@example.invalid", CN, "bash", "/opt/install.sh"] + args)
    rs = r.wait(600); mock.terminate()
    cs = 0; c = type("C", (), {"log": "(no hand-off for this family: CONTAINER LIMIT, see header)\n"})()
else:
    r = Proc(["docker", "exec", "-it", "-u", F["runas"], CN, "bash", "/opt/install.sh"] + args)
    r.wait_for("waiting up to", 900)
    r.wait_for("ED25519 SHA256 host-key fingerprint", 60)   # printed because the INSTALLER's own ssh unit is listening: no manual sshd
    c = Proc(["/bin/bash", INSTALL, "handoff", "tuser@127.0.0.1", "--port", str(F["port"])], env=cenv)
    c.wait_for("Does this match the screen? [y/N]", 60); c.send("y\n"); cs = c.wait(120)
    if cs != 0: print("client failed (exit %s):\n%s" % (cs, clean(c.log)[-1500:]), flush=True)
    rs = r.wait(600); mock.terminate()
body = "install.sh sha256: %s\n" % SHA + "\n".join(hdr) + "\ncommand: docker exec -it -u %s %s bash /opt/install.sh %s\nclient: %s\n\n===== installer output (full) =====\n" % (F["runas"], CN, " ".join(args), "none (container limit)" if fam == "fedora" else "bash public/install.sh handoff tuser@127.0.0.1 --port %d (MB_TEST=1, mock API, dummy values)" % F["port"])
body += clean(r.log) + "\n===== installer exit status: %d =====\n\n===== client (Mac) output =====\n" % rs + clean(c.log) + "\n===== client exit status: %d =====\n" % cs
if fam != "fedora": check("%s hand-off delivered over real SSH into the installer's own ssh unit (no manual sshd)" % fam, cs == 0 and "bundle received over SSH and accepted" in r.log, (cs,))
check("%s gh login with the dummy token failed cleanly; honest exit 4 (not complete)" % fam, rs == 4 and "gh login FAILED" in r.log and "NOT COMPLETE: gh login failed" in r.log, rs)
check("%s installer reported tailscaled and the ssh unit enabled and active" % fam, re.search(r"systemd: tailscaled active \(enabled\)", r.log) is not None and re.search(r"ssh(d|\.socket)? active \(enabled\)", r.log) is not None, clean(r.log)[-600:])
check("%s sshd -T report printed (effective PasswordAuthentication/PermitRootLogin)" % fam, "sshd effective settings: PasswordAuthentication" in r.log)

probes = []
def probe(cmd, user="root"):
    o = dx(user, cmd); probes.append("$ (%s) %s\n%s%s" % (user, cmd, o.stdout, o.stderr))
sshu = "ssh" if F["pm"] == "apt" else "sshd"
probe("for u in tailscaled %s ssh.socket; do printf '%%s: active=%%s enabled=%%s\\n' $u $(systemctl is-active $u 2>&1) $(systemctl is-enabled $u 2>&1); done" % sshu)
probe("ss -ltn | grep -E ':22 ' || echo 'NO-LISTENER'")
probe("tailscale version | head -1; tailscale status 2>&1 | head -2; echo '(tailscaled answers; not joined: --skip-tailscale-up)'")
probe("echo sshd: $( $(command -v sshd || echo /usr/sbin/sshd) -V 2>&1 | head -1); git --version; gh --version | head -1; echo node: $(node --version); echo paseo: $(paseo --version)")
probe("$(command -v sshd || echo /usr/sbin/sshd) -t; echo sshd -t exit=$?; $(command -v sshd || echo /usr/sbin/sshd) -T | grep -E '^(passwordauthentication|permitrootlogin) '")
probe("gh auth status 2>&1 | head -2; echo gh-auth-status-exit=${PIPESTATUS[0]}", "tuser")
probe("git config --global user.name; git config --global user.email", "tuser")
probe("ls -la ~/.cache/mac-bootstrap/inbox 2>&1 | head -2", "tuser")
gv = "\n".join(probes); body += "\n===== postcondition probes =====\n" + gv
ok_units = ("tailscaled: active=active enabled=enabled" in gv) and (("%s: active=active enabled=enabled" % sshu) in gv or "ssh.socket: active=active enabled=enabled" in gv)
check("%s probes: tailscaled and the ssh unit (or ssh.socket) enabled and active; port 22 listening" % fam, ok_units and "\nNO-LISTENER\n" not in gv, gv[:500])
if fam == "debian": check("debian C1: ssh.service holds port 22 and ssh.socket was NOT touched (no abort)", "ssh: active=active enabled=enabled" in gv, gv[:400])
if fam == "ubuntu": check("ubuntu C1: socket-activated ssh keeps working (ssh.socket active+enabled)", "ssh.socket: active=active enabled=enabled" in gv, gv[:400])
check("%s probes: tools, sshd -t, git identity set, inbox removed" % fam, all(k in gv for k in ("git version", "gh version", "node: v", "paseo: 0.", "sshd -t exit=0", "Dummy Person", "No such file")), gv[:400])

rr = subprocess.run(["docker", "exec", "-u", F["runas"], CN, "bash", "/opt/install.sh"] + (args if "--no-wait" in args else ["--no-wait"] + args), capture_output=True, text=True)
rrt = clean(rr.stdout + rr.stderr)
body += "\n===== rerun (idempotence): bash install.sh --no-wait %s =====\n" % " ".join(a_ for a_ in args if a_ != "--no-wait") + "\n".join(l for l in rrt.split("\n") if l.strip()) + "\n===== rerun exit status: %d =====\n" % rr.returncode
check("%s rerun is idempotent (all present -> skip; units already active)" % fam, "already present" in rrt and "Unpacking" not in rrt and "Setting up" not in rrt and "Installing" not in rrt, rrt[-400:])
open(os.path.join(OUT, "systemd-%s.txt" % fam), "w").write(body)
open(os.path.join(OUT, "summary-systemd-%s.txt" % fam), "w").write("install.sh sha256: %s\n" % SHA + "\n".join(("PASS " if k else "FAIL ") + l for l, k in results) + "\n")
os.kill(apid, 15); shutil.rmtree(T, ignore_errors=True)
sh("docker rm -f %s >/dev/null; docker rmi -f %s >/dev/null 2>&1" % (CN, IMG))
sys.exit(0 if all(k for _, k in results) else 1)
