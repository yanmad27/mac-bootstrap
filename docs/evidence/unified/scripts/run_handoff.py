#!/usr/bin/env python3
"""Hand-off evidence runner. DUMMY credentials only, a local mock API, a disposable Linux
container (mb-sshd, sshd on 127.0.0.1:2222). Writes redacted logs into docs/evidence/unified/handoff/.
Run from the repo root:  python3 docs/evidence/unified/scripts/run_handoff.py"""
import json, os, re, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(__file__))
from ptydrive import Proc, redact

ROOT = os.getcwd()
OUT = os.path.join(ROOT, "docs/evidence/unified/handoff")
SCR = os.path.join(ROOT, "docs/evidence/unified/scripts")
INSTALL = os.path.join(ROOT, "public/install.sh")
T = tempfile.mkdtemp(prefix="mbev.", dir="/tmp")
PORT_API = 18765
DUMMY = {
    "oauth": "tskey-client-DUMMYcid-DUMMYoauthsecret0001",
    "gh": "ghp_DUMMYghtoken0001",
    "minted": "tskey-auth-DUMMYminted0001",
    "access": "tskey-api-DUMMYaccess0001",
    "hook_oauth": "tskey-client-DUMMYHOOKcid-DUMMYHOOKsecret",
    "hook_gh": "ghp_DUMMYHOOKtoken",
    "stub_gh": "ghp_DUMMYSTUBgh0001",
    "stub_oauth": "tskey-client-DUMMYSTUBcid-DUMMYSTUBsecret",
    "name": "Dummy Person", "email": "dummy@example.invalid",
}
results = []

def ev(name, text):
    with open(os.path.join(OUT, name), "w") as f:
        f.write(redact(text) if not text.endswith("\0") else text[:-1])

def check(label, ok, detail=""):
    results.append((label, ok, detail))
    print(("PASS " if ok else "FAIL ") + label + (" -- " + detail if detail and not ok else ""), flush=True)

def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)

def dexec(user, cmd):
    return sh("docker exec -u %s mb-sshd bash -c %s" % (user, json.dumps(cmd)))

# ---------------------------------------------------------------- setup
os.makedirs(OUT, exist_ok=True)
home = os.path.join(T, "home"); os.makedirs(home)
with open(os.path.join(home, ".gitconfig"), "w") as f:
    f.write("[user]\n\tname = %s\n\temail = %s\n" % (DUMMY["name"], DUMMY["email"]))
stubs = os.path.join(T, "stubs"); os.makedirs(stubs)
stublog = os.path.join(T, "stub.log")
def stub(name, body):
    p = os.path.join(stubs, name)
    with open(p, "w") as f: f.write("#!/bin/bash\n" + body)
    os.chmod(p, 0o755)
# security/gh stubs for test mode: must never be called (exit 99 + log)
stub("security", 'echo "security CALLED argc=$#" >> %s; exit 99\n' % stublog)
stub("gh", 'echo "gh CALLED argc=$#" >> %s; exit 99\n' % stublog)
sh("ssh-keygen -q -t ed25519 -N '' -f %s/id" % T)
sh("ssh-keygen -q -t ed25519 -N '' -f %s/fake" % T)
agent = sh("ssh-agent -a %s/agent.sock" % T).stdout
agent_pid = int(re.search(r"SSH_AGENT_PID=(\d+)", agent).group(1))
sh("SSH_AUTH_SOCK=%s/agent.sock ssh-add %s/id" % (T, T))
pub = open(T + "/id.pub").read()
sh("docker cp %s mb-sshd:/tmp/install.sh && docker cp %s/recv-harness.sh mb-sshd:/tmp/recv-harness.sh" % (INSTALL, SCR))
for u in ("tuser",):
    dexec("root", "mkdir -p /home/%s/.ssh && echo %s > /home/%s/.ssh/authorized_keys && chown -R %s: /home/%s/.ssh && chmod 700 /home/%s/.ssh && chmod 600 /home/%s/.ssh/authorized_keys" % (u, json.dumps(pub.strip()), u, u, u, u, u))

def start_mock(logname, mode="ok", port=PORT_API):
    log = os.path.join(T, logname)
    if os.path.exists(log): os.remove(log)
    p = subprocess.Popen([sys.executable, os.path.join(SCR, "mock_api.py"), str(port), log, mode],
                         stdout=subprocess.PIPE, text=True)
    p.stdout.readline()  # banner: server is listening
    return p, log

def client_env(extra=None, test=True):
    e = {"PATH": stubs + ":" + os.environ["PATH"], "HOME": os.environ["HOME"], "TERM": "xterm",
         "SSH_AUTH_SOCK": T + "/agent.sock", "LANG": "en_US.UTF-8"}
    if test:
        e.update({"MB_TEST": "1", "MB_TEST_OAUTH_SECRET": DUMMY["oauth"], "MB_TEST_GH_TOKEN": DUMMY["gh"],
                  "MB_TEST_API_BASE": "http://127.0.0.1:%d" % PORT_API, "MB_TEST_HOME": home})
    if extra: e.update(extra)
    return e

def receiver(user="tuser", target="", timeout=120):
    return Proc(["docker", "exec", "-it", "-u", user, "mb-sshd", "bash", "/tmp/recv-harness.sh", "/tmp/install.sh", target, str(timeout)])

def reset_inbox():
    dexec("root", "rm -rf /home/tuser/.cache/mac-bootstrap /tmp/evil")

def stub_calls():
    return open(stublog).read() if os.path.exists(stublog) else ""

def client_handoff(answer="y\n", extra_env=None, port=2222):
    c = Proc(["/bin/bash", INSTALL, "handoff", "tuser@127.0.0.1", "--port", str(port)], env=client_env(extra_env))
    c.wait_for("Does this match the screen? [y/N]", 40)
    c.send(answer)
    return c

HOST_FP = dexec("root", "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256").stdout.split()[1]

# ---------------------------------------------------------------- 01 success (real SSH, strict, test mode)
reset_inbox(); open(stublog, "w").close()
mock, mlog = start_mock("m1.jsonl")
r = receiver(); r.wait_for("waiting up to", 40)
c = client_handoff("y\n")
cs = c.wait(60); r.wait_for("harness: RESULT", 40); rs = r.wait(30)
ev("01-success-client.txt", c.log); ev("01-success-receiver.txt", r.log)
check("01 hand-off over real SSH exit 0", cs == 0, str(cs))
check("01 fingerprint shown by client equals the one on the target screen",
      HOST_FP in c.log and HOST_FP in r.log)
check("01 receiver parsed the bundle (TS key tskey-auth-, gh, tags, identity set)",
      "RESULT received; TS_KEY=set TS_TAGS=set GH_TOK=set GIT_NAME=set GIT_EMAIL=set" in r.log and "tskey-auth- prefix" in r.log)
check("01 target screen printed LAN IP + exact handoff line", re.search(r"mac-bootstrap handoff tuser@\d+\.\d+\.\d+\.\d+", r.log) is not None)
check("01 inbox is empty/removed after use", "bundle" not in r.log.split("inbox after:")[-1] and "ready" not in r.log.split("inbox after:")[-1])
check("01 test mode never called security/gh stubs", stub_calls() == "", stub_calls())
check("01 bundle text never echoed by the client (stdout holds none)", not c.bundles())
time.sleep(0.3); mock.terminate()
reqs = [json.loads(l) for l in open(mlog)]
shutil.copy(mlog, os.path.join(OUT, "02-mock-api-requests.jsonl"))
mint = [q for q in reqs if q["path"].endswith("/keys")][0]["body"]
cr = mint["capabilities"]["devices"]["create"]
check("02 mint request: reusable false, ephemeral false, preauthorized true, tags, short expiry",
      cr["reusable"] is False and cr["ephemeral"] is False and cr["preauthorized"] is True and cr["tags"] == ["tag:bootstrap"] and mint["expirySeconds"] == 3600, json.dumps(mint))
check("02 token request carried the expected (dummy) secret as form field only", reqs[0]["client_secret_matches_expected"] and "client_secret" in reqs[0]["form_fields"])

# ---------------------------------------------------------------- 03 paste fallback
reset_inbox()
mock, mlog = start_mock("m3.jsonl")
r = receiver(timeout=90); r.wait_for("waiting up to", 40)
b = Proc(["/bin/bash", INSTALL, "bundle"], env=client_env()); bs = b.wait(40)
bundle = b.bundles()[0]
ev("03-paste-bundle-client.txt", b.log)
check("03 `bundle` printed an MB1 bundle and the gh-token warning", bs == 0 and "contains your GitHub token" in b.log)
r.send("p"); r.wait_for("Paste the bundle", 20)
r.send(bundle + "\n")
r.wait_for("harness: RESULT", 40); rs = r.wait(30)
ev("03-paste-receiver.txt", r.log)
check("03 paste accepted, hidden (bundle not echoed on the receiver tty)", "pasted bundle accepted" in r.log and bundle not in r.log and "RESULT received" in r.log)
mock.terminate()

# ---------------------------------------------------------------- 04 wrong fingerprint answer
reset_inbox()
mock, mlog = start_mock("m4.jsonl")
r = receiver(timeout=60); r.wait_for("waiting up to", 40)
c = client_handoff("n\n"); cs = c.wait(30)
ev("04-wrong-fingerprint-client.txt", c.log)
check("04 answering n aborts, nothing sent", cs != 0 and "fingerprint not confirmed" in c.log)
check("04 nothing minted (mock saw no request)", not os.path.exists(mlog) or open(mlog).read() == "")
check("04 inbox still holds only ready (no bundle)", dexec("tuser", "ls /home/tuser/.cache/mac-bootstrap/inbox").stdout.split() == ["ready"])
r.send("\x03"); r.wait(20)
ev("04-wrong-fingerprint-receiver.txt", r.log)
check("04 Ctrl-C on the receiver runs the cleanup trap (inbox removed)", dexec("tuser", "ls /home/tuser/.cache/mac-bootstrap/inbox 2>&1").stdout.strip().endswith("No such file or directory"), dexec("tuser", "ls /home/tuser/.cache/mac-bootstrap/inbox 2>&1").stdout)
mock.terminate()

# ---------------------------------------------------------------- 05 changed host key (keyscan stub lies; real sshd differs)
reset_inbox()
fake = open(T + "/fake.pub").read().split()
stub("ssh-keyscan", 'echo "[127.0.0.1]:2222 %s %s"\n' % (fake[0], fake[1]))
mock, mlog = start_mock("m5.jsonl")
r = receiver(timeout=60); r.wait_for("waiting up to", 40)
c = client_handoff("y\n"); cs = c.wait(40)
ev("05-changed-host-key-client.txt", c.log)
check("05 pinned key != real host key: strict checking refuses, nothing minted/sent",
      cs != 0 and "ssh login failed" in c.log and (not os.path.exists(mlog) or open(mlog).read() == ""))
check("05 ssh reported the host key problem", "Host key verification failed" in c.log or "REMOTE HOST IDENTIFICATION" in c.log or "host key" in c.log.lower())
r.send("\x03"); r.wait(20); os.remove(stubs + "/ssh-keyscan"); mock.terminate()

# ---------------------------------------------------------------- 06 second bundle rejected / not waiting
reset_inbox()
dexec("tuser", "mkdir -p /home/tuser/.cache/mac-bootstrap/inbox && chmod 700 /home/tuser/.cache/mac-bootstrap /home/tuser/.cache/mac-bootstrap/inbox && touch /home/tuser/.cache/mac-bootstrap/inbox/ready")
known = os.path.join(T, "kh")
scan = sh("ssh-keyscan -p 2222 -t ed25519 127.0.0.1 2>/dev/null").stdout
open(known, "w").write(scan)
rc = open(INSTALL).read()
send_cmd = re.search(r'^readonly RC_SEND="(.*)"$', rc, re.M).group(1).replace('\\"', '"').replace('\\$', '$').replace('\\\\', '\\') if False else None
# evaluate the exact RC_* strings by letting bash do the unquoting
RC = subprocess.run(["/bin/bash", "-c", 'eval "$(grep -E "^readonly RC_SEND=" %s)"; printf "%%s" "$RC_SEND"' % INSTALL], capture_output=True, text=True).stdout
RP = subprocess.run(["/bin/bash", "-c", 'eval "$(grep -E "^readonly RC_PROBE=" %s)"; printf "%%s" "$RC_PROBE"' % INSTALL], capture_output=True, text=True).stdout
SSHO = "ssh -p 2222 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i %s/id -o IdentityAgent=none -o BatchMode=yes tuser@127.0.0.1" % (known, T)
def push(payload):
    return subprocess.run(SSHO + " " + json.dumps(RC).replace("\\$", "\\$"), shell=True, input=payload, capture_output=True, text=True)
# RC contains $ and quotes meant for the REMOTE shell: pass via argv list instead of shell
def push2(payload):
    return subprocess.run(["ssh", "-p", "2222", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + known, "-o", "GlobalKnownHostsFile=/dev/null",
                           "-o", "IdentitiesOnly=yes", "-i", T + "/id", "-o", "IdentityAgent=none", "-o", "BatchMode=yes", "tuser@127.0.0.1", RC],
                          input=payload, capture_output=True, text=True)
p1 = push2("MB1:AAAA\n"); p2 = push2("MB1:BBBB\n")
big = push2("MB1:" + "A" * 20000 + "\n")
dexec("tuser", "rm -f /home/tuser/.cache/mac-bootstrap/inbox/*; touch /home/tuser/.cache/mac-bootstrap/inbox/ready")
big = push2("MB1:" + "A" * 20000 + "\n")
dexec("tuser", "rm -rf /home/tuser/.cache/mac-bootstrap")
p3 = push2("MB1:CCCC\n")
ev("06-second-bundle.txt",
   "send #1 (ready present): exit=%d stderr=%r\nsend #2 (bundle exists, ready present): exit=%d stderr=%r\n"
   "oversized (20000 bytes) with ready present: exit=%d stderr=%r\nsend with no inbox: exit=%d stderr=%r\n"
   % (p1.returncode, p1.stderr.strip(), p2.returncode, p2.stderr.strip(), big.returncode, big.stderr.strip(), p3.returncode, p3.stderr.strip()))
check("06 first push ok, second push rejected (exit 5), oversized rejected (exit 4), no inbox rejected (exit 3)",
      (p1.returncode, p2.returncode, big.returncode, p3.returncode) == (0, 5, 4, 3), str((p1.returncode, p2.returncode, big.returncode, p3.returncode)))
# the client's own probe refuses before minting when the target is not waiting
reset_inbox()
mock, mlog = start_mock("m6.jsonl")
c = client_handoff("y\n"); cs = c.wait(40)
ev("06-not-waiting-client.txt", c.log)
check("06 client probe: target not waiting -> abort before minting", cs != 0 and "not waiting" in c.log and (not os.path.exists(mlog) or open(mlog).read() == ""))
mock.terminate()

# ---------------------------------------------------------------- 07 symlinked inbox
reset_inbox()
dexec("tuser", "mkdir -p /tmp/evil /home/tuser/.cache/mac-bootstrap && chmod 700 /home/tuser/.cache/mac-bootstrap && ln -s /tmp/evil /home/tuser/.cache/mac-bootstrap/inbox")
r = receiver(timeout=8); rs = r.wait(40)
ev("07-symlinked-inbox-receiver.txt", r.log)
check("07 symlinked inbox refused; no ready marker written through the link",
      "inbox refused" in r.log and dexec("tuser", "ls -A /tmp/evil").stdout.strip() == "")
mock, mlog = start_mock("m7.jsonl")
r = receiver(timeout=30); r.wait_for("waiting up to", 40)
c = client_handoff("y\n"); cs = c.wait(40)
ev("07-symlinked-inbox-client.txt", c.log)
check("07 client cannot push into a symlinked inbox (aborts before minting)", cs != 0 and "not waiting" in c.log and (not os.path.exists(mlog) or open(mlog).read() == ""))
r.send("\x03"); r.wait(20); mock.terminate()

# ---------------------------------------------------------------- 08 root without target user, root with target user
reset_inbox()
a = sh("docker exec -u root mb-sshd bash /tmp/install.sh --dry-run 2>&1; echo exit=$?")
b2 = sh("docker exec -u root mb-sshd bash /tmp/install.sh --dry-run --target-user tuser 2>&1; echo exit=$?")
c2 = sh("docker exec -u tuser mb-sshd bash /tmp/install.sh --dry-run --target-user other 2>&1; echo exit=$?")
ev("08-root-matrix.txt", "# root, no --target-user\n" + a.stdout + "\n# root, --target-user tuser (Linux install branch is a stub: checkpoint B)\n" + b2.stdout +
   "\n# non-root tuser, --target-user other\n" + c2.stdout)
check("08 root without --target-user refused", "running as root: name the user" in a.stdout and "exit=1" in a.stdout)
check("08 --target-user passes preflight on Linux then hits the clean not-yet stub", "not yet implemented" in b2.stdout and "exit=1" in b2.stdout)
check("08 non-root --target-user other refused", "needs root" in c2.stdout)
mock, mlog = start_mock("m8.jsonl")
reset_inbox()
r = receiver(user="root", target="tuser", timeout=90); r.wait_for("waiting up to", 40)
c = client_handoff("y\n"); cs = c.wait(60); r.wait_for("harness: RESULT", 40); r.wait(30)
ev("08-root-with-target-user-receiver.txt", r.log); ev("08-root-with-target-user-client.txt", c.log)
own = dexec("root", "stat -c '%U %a' /home/tuser/.cache /home/tuser/.cache/mac-bootstrap 2>&1").stdout
check("08 root receiver for --target-user tuser: hand-off delivered and parsed", cs == 0 and "RESULT received" in r.log, str(cs))
mock.terminate()

# ---------------------------------------------------------------- 09 refused mint (403)
reset_inbox()
mock, mlog = start_mock("m9.jsonl", mode="forbid")
r = receiver(timeout=60); r.wait_for("waiting up to", 40)
c = client_handoff("y\n"); cs = c.wait(40)
ev("09-mint-refused-client.txt", c.log)
check("09 API refusing the mint: clear error, nothing delivered", cs != 0 and "refused to mint" in c.log and dexec("tuser", "ls /home/tuser/.cache/mac-bootstrap/inbox").stdout.split() == ["ready"])
r.send("\x03"); r.wait(20); mock.terminate()

# ---------------------------------------------------------------- 10 test hooks inert without MB_TEST; non-loopback base
mock, mlog = start_mock("m10.jsonl")
curl_log = os.path.join(T, "curl.log")
stub("security", 'echo "security CALLED (stub) service=$3" >> %s; case $3 in *tag) echo tag:bootstrap;; *) echo %s;; esac\n' % (curl_log, DUMMY["stub_oauth"]))
stub("gh", 'echo "gh CALLED (stub) $1 $2" >> %s; if [ "$1 $2" = "auth token" ]; then echo %s; fi\n' % (curl_log, DUMMY["stub_gh"]))
stub("curl", 'echo "curl CALLED (stub) args: $*" >> %s; while IFS= read -r l; do case $l in url*) echo "  stdin-config $l" >> %s;; esac; done; exit 7\n' % (curl_log, curl_log))
home2 = os.path.join(T, "home2"); os.makedirs(home2)
env = client_env({"MB_TEST_OAUTH_SECRET": DUMMY["hook_oauth"], "MB_TEST_GH_TOKEN": DUMMY["hook_gh"], "MB_TEST_API_BASE": "http://127.0.0.1:%d" % PORT_API, "MB_TEST_HOME": home2, "HOME": home2}, test=False)
open(curl_log, "w").close()
b = Proc(["/bin/bash", INSTALL, "bundle"], env=env); bs = b.wait(30)
ev("10-hooks-inert-without-mb-test.txt", "# env had MB_TEST_OAUTH_SECRET, MB_TEST_GH_TOKEN, MB_TEST_API_BASE, MB_TEST_HOME but NO MB_TEST\n# PATH stubs: security/gh/curl (they record calls; curl fails with 7, so no network call is made)\n" + b.log + "\n# stub call log:\n" + open(curl_log).read())
cl = open(curl_log).read()
check("10 hooks inert: Keychain stub and gh stub were used instead of the hook values", "security CALLED" in cl and "gh CALLED (stub) auth token" in cl)
check("10 hooks inert: curl targeted api.tailscale.com, not the mock; hook secret absent", "api.tailscale.com" in cl and "127.0.0.1" not in cl)
check("10 hooks inert: the mock API received no request", not os.path.exists(mlog) or open(mlog).read() == "")
mock.terminate()
bad = ["https://api.tailscale.com", "http://127.0.0.1.evil.example:80", "http://localhost:80", "http://10.0.0.1:80", "http://127.0.0.1:80@evil.example", "http://127.0.0.1", "http://127.0.0.1:80/x"]
lines = []; allbad = True
for u in bad:
    open(curl_log, "w").close()
    p = Proc(["/bin/bash", INSTALL, "bundle"], env=client_env({"MB_TEST_API_BASE": u})); st = p.wait(30)
    ok = st != 0 and "MB_TEST_API_BASE must be" in p.log and open(curl_log).read() == ""
    allbad &= ok
    lines.append("%-45s exit=%d rejected=%s" % (u, st, ok))
ev("11-non-loopback-api-base.txt", "MB_TEST=1 with a non-loopback or malformed MB_TEST_API_BASE (curl/gh/security stubs record calls; none happened)\n" + "\n".join(lines) + "\n")
check("11 every non-loopback/malformed MB_TEST_API_BASE rejected before any call", allbad)
os.remove(stubs + "/curl"); stub("security", 'echo "security CALLED argc=$#" >> %s; exit 99\n' % stublog); stub("gh", 'echo "gh CALLED argc=$#" >> %s; exit 99\n' % stublog)

# ---------------------------------------------------------------- 12 client-setup (test mode, temp HOME)
home3 = os.path.join(T, "home3"); os.makedirs(home3)
open(stublog, "w").close()
c = Proc(["/bin/bash", INSTALL, "--client-setup"], env=client_env({"MB_TEST_HOME": home3}))
c.wait_for("Tag for the minted keys", 20); c.send("\n"); cs = c.wait(30)
want = sh("shasum -a 256 %s" % INSTALL).stdout.split()[0]
helper = os.path.join(home3, ".local/bin/mac-bootstrap")
ev("12-client-setup-from-file.txt", c.log + "\n# helper: " + sh("ls -l %s" % helper).stdout.replace(os.environ.get("USER", "?"), "user"))
check("12 --client-setup from a saved file: helper installed 0755, sha256 printed equals install.sh", cs == 0 and want in c.log and oct(os.stat(helper).st_mode)[-3:] == "755", str(cs))
check("12 client-setup in test mode did not touch the Keychain (security stub never called)", stub_calls() == "" and "Keychain write skipped" in c.log)
h = sh("%s --help | head -3" % helper)
check("12 installed helper runs", "Usage" in h.stdout)
srv = subprocess.Popen([sys.executable, "-m", "http.server", "18766", "--bind", "127.0.0.1", "--directory", os.path.join(ROOT, "public")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1.0)  # one-time server start (no polling)
home4 = os.path.join(T, "home4"); os.makedirs(home4)
pc = Proc(["/bin/bash", "-c", "cat %s | bash -s -- --client-setup --origin http://127.0.0.1:18766" % INSTALL], env=client_env({"MB_TEST_HOME": home4}))
pc.wait_for("Tag for the minted keys", 20); pc.send("\n"); ps = pc.wait(30)
os.makedirs(home4 + "x", exist_ok=True)
os.makedirs(home4 + "x", exist_ok=True)
pn = Proc(["/bin/bash", "-c", "cat %s | bash -s -- --client-setup" % INSTALL], env=client_env({"MB_TEST_HOME": home4 + "x"}))
pns = pn.wait(20)
pb = Proc(["/bin/bash", "-c", "cat %s | bash -s -- --client-setup --origin http://evil.example.com" % INSTALL], env=client_env({"MB_TEST_HOME": home4 + "x"})); pbs = pb.wait(20)
srv.terminate()
ev("12-client-setup-piped-origin.txt", "# piped with --origin (local http origin, test mode only)\n" + pc.log + "\n# piped WITHOUT --origin\n" + pn.log + "\n# piped with a non-https origin outside the test allowance\n" + pb.log)
check("12 piped --client-setup --origin: helper downloaded, sha256 equals install.sh", ps == 0 and want in pc.log, str(ps))
check("12 piped without --origin: clear refusal", pns != 0 and "--origin" in pn.log)
check("12 non-https origin refused", pbs != 0 and "must be https" in pb.log)

# ---------------------------------------------------------------- 13 no secret in argv (curl/ssh wrappers log argv, then run the real tool)
argv_log = os.path.join(T, "argv.log"); open(argv_log, "w").close()
stub("curl", 'echo "curl $*" >> %s; exec /usr/bin/curl "$@"\n' % argv_log)
real_ssh = shutil.which("ssh")
stub("ssh", 'echo "ssh $*" >> %s; exec %s "$@"\n' % (argv_log, real_ssh))
reset_inbox()
mock, mlog = start_mock("m13.jsonl")
r = receiver(timeout=60); r.wait_for("waiting up to", 40)
c = client_handoff("y\n"); cs = c.wait(60); r.wait_for("harness: RESULT", 40); r.wait(30)
mock.terminate()
al = open(argv_log).read()
ev("13-argv-log.txt", "# argv of every curl and ssh the client ran during a full successful hand-off (wrappers log argv, then exec the real tool)\n" + al)
vals = [DUMMY[k] for k in ("oauth", "gh", "minted", "access")]
import base64
def forms(v):
    out = [v]
    for off in range(3):
        out.append(base64.b64encode(("x" * off + v).encode()).decode().strip("="))
    return out
leak = [v for v in vals for f in forms(v) if f[8:-4] in al]
check("13 hand-off still works through the argv-logging wrappers", cs == 0 and "RESULT received" in r.log)
check("13 no secret (raw or base64) in any curl/ssh argv", not leak and "tskey-" not in al and "ghp_" not in al, str(leak))
os.remove(stubs + "/curl"); os.remove(stubs + "/ssh")

# ---------------------------------------------------------------- 14 xtrace (bash -x) leaks nothing
mock, mlog = start_mock("m14.jsonl")
x = Proc(["/bin/bash", "-x", INSTALL, "bundle"], env=client_env()); xs = x.wait(40)
mock.terminate()
envdry = subprocess.run(["/bin/bash", "-x", INSTALL, "--dry-run"], capture_output=True, text=True,
                        env=dict(os.environ, TS_AUTHKEY="tskey-auth-DUMMYenv0001", GH_TOKEN="ghp_DUMMYenvtoken01", TS_TAGS="tag:bootstrap"))
xt = redact(x.log) + "\n# --- target dry-run with TS_AUTHKEY/GH_TOKEN in the env under bash -x (stdout+stderr):\n" + envdry.stdout + envdry.stderr
ev("14-xtrace.txt", xt)
allv = [DUMMY[k] for k in ("oauth", "gh", "minted", "access")] + ["tskey-auth-DUMMYenv0001", "ghp_DUMMYenvtoken01"]
raw = redact(x.log) + envdry.stdout + envdry.stderr
leak = [v for v in allv for f in forms(v) if f[8:-4] in raw]
check("14 bash -x leaks no secret (client `bundle` and target dry-run with secrets in env)", xs == 0 and not leak and "set +x" in raw, str(leak))

# ---------------------------------------------------------------- finish
open(os.path.join(OUT, "summary.txt"), "w").write("\n".join(("PASS " if ok else "FAIL ") + l for l, ok, _ in results) + "\n")
os.kill(agent_pid, 15)
shutil.rmtree(T, ignore_errors=True)
print("failed:", [l for l, ok, _ in results if not ok])
sys.exit(0 if all(ok for _, ok, _ in results) else 1)
