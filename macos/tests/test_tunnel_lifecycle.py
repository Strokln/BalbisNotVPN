"""Own-process failure tests only; never modify networksetup, DNS, routes or VPN."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

APP = Path(__file__).resolve().parents[1] / "build/Balbis.app"

def ports():
    sockets = []
    try:
        for _ in range(3):
            s = socket.socket(); s.bind(("127.0.0.1", 0)); sockets.append(s)
        return [s.getsockname()[1] for s in sockets]
    finally:
        for s in sockets: s.close()

def children(pid):
    output = subprocess.run(["/usr/bin/pgrep", "-P", str(pid)], capture_output=True, text=True).stdout
    return {int(p) for p in output.split() if int(p) != pid}

def exists(pid):
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False

class SessionLifecycle(unittest.TestCase):
    def run_case(self, event):
        with tempfile.TemporaryDirectory() as root:
            dpi, socks, http = ports()
            root = Path(root)
            rules = root / "foreign.txt"; rules.write_text("openai.com\n")
            config = root / "session.json"
            config.write_text(json.dumps(dict(resources=str(APP / "Contents/Resources"), dpiPort=dpi, socksPort=socks,
                httpPort=http, strategy=0, sessionID="local-lifecycle-test", region="EU", domainsFile=str(rules))))
            helper = subprocess.Popen([str(APP / "Contents/MacOS/Balbis"), "--tunnel-session", str(config)],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            owned = set()
            try:
                for _ in range(100):
                    owned |= children(helper.pid)
                    if len(owned) >= 3: break
                    self.assertIsNone(helper.poll(), "supervisor failed before children started")
                    time.sleep(.02)
                self.assertEqual(len(owned), 3, "expected tpws, Opera and router")
                if event == "eof": helper.stdin.close()
                elif event == "signal": helper.send_signal(signal.SIGTERM)
                elif event == "child":
                    # Kill only one of this helper's recorded children, never by process name.
                    os.kill(sorted(owned)[-1], signal.SIGTERM)
                helper.wait(timeout=6)
                self.assertFalse(any(exists(pid) for pid in owned), "session left orphaned children")
            finally:
                if helper.stdin and not helper.stdin.closed: helper.stdin.close()
                if helper.poll() is None:
                    helper.terminate()
                    try: helper.wait(timeout=6)
                    except subprocess.TimeoutExpired: helper.kill(); helper.wait()
                for pid in owned:
                    if exists(pid): os.kill(pid, signal.SIGKILL)
    def test_parent_eof_stops_all_children(self): self.run_case("eof")
    def test_supervisor_sigterm_stops_all_children(self): self.run_case("signal")
    def test_child_failure_stops_session(self): self.run_case("child")

if __name__ == "__main__": unittest.main()
