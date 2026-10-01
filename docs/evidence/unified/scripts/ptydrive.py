#!/usr/bin/env python3
"""Tiny pty process driver for the evidence runs (event-driven, no sleeps-as-polling).
Proc(argv, env).wait_for(text), .send(text), .wait() -> exit code. .log holds the raw output;
redact() removes any MB1 bundle and ANSI codes before anything is written to evidence."""
import os, pty, re, select, signal, threading, time

BUNDLE_RE = re.compile(r"MB1:[A-Za-z0-9+/=]{8,}")
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\r")

def redact(s):
    return BUNDLE_RE.sub("MB1:<redacted bundle>", ANSI.sub("", s))

class Proc:
    def __init__(self, argv, env=None, cwd=None):
        self.log = ""; self.cond = threading.Condition(); self.status = None
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if cwd: os.chdir(cwd)
            os.execvpe(argv[0], argv, env if env is not None else os.environ)
        self.t = threading.Thread(target=self._pump, daemon=True); self.t.start()

    def _pump(self):
        while True:
            try: d = os.read(self.fd, 4096)
            except OSError: d = b""
            if not d: break
            with self.cond:
                self.log += d.decode("utf-8", "replace"); self.cond.notify_all()
        _, st = os.waitpid(self.pid, 0)
        with self.cond:
            self.status = os.waitstatus_to_exitcode(st); self.cond.notify_all()

    def wait_for(self, text, timeout=60, since=0):
        end = time.time() + timeout
        with self.cond:
            while text not in self.log[since:]:
                left = end - time.time()
                if left <= 0 or self.status is not None and text not in self.log[since:]:
                    raise TimeoutError("waiting for %r; tail: %r" % (text, redact(self.log[-300:])))
                self.cond.wait(left)
            return self.log.index(text, since) + len(text)

    def send(self, text): os.write(self.fd, text.encode())

    def wait(self, timeout=60):
        end = time.time() + timeout
        with self.cond:
            while self.status is None:
                left = end - time.time()
                if left <= 0:
                    os.kill(self.pid, signal.SIGKILL); raise TimeoutError("process did not exit")
                self.cond.wait(left)
            return self.status

    def bundles(self): return BUNDLE_RE.findall(re.sub(ANSI, "", self.log))
