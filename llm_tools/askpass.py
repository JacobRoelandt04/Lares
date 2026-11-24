#!/usr/bin/python3 -IS
# sudo's askpass for the shell's own askers: the LLM module's tool jobs (round
# 20) and the system update's yay (auth stage 3). It lives in llm_tools/ because
# the LLM was first and every copy of that directory keeps it working. sudo runs
# this -- SUDO_ASKPASS -- when a password is needed, with its prompt as the one
# argument. It connects to the socket the shell serves for that run, sends one
# line -- {"v": 1, "pid": ..., "prompt": ...} -- and waits for one line back:
# the password, printed for sudo, or an empty line, which is the user's cancel.
#
# The shell checks the pid before it shows anything: it must descend from the
# run and its parent must be sudo running as root, so a command cannot open a
# password box by running this file itself. Exit 1 is "no password": sudo says
# so and gives up.
#
# Environment (the QS_ names win; the LLM_ names are the module's own and keep
# working):
#   LARES_ASKPASS_SOCKET / LLM_ASKPASS_SOCKET    the socket to ask on
#   LARES_ASKPASS_TIMEOUT / LLM_ASKPASS_TIMEOUT  seconds to wait in all (120)
#   LARES_ASKPASS_RETRY=1                        the server may not be there yet
#                                             or may go away and come back
#
# RETRY is for a run that OUTLIVES the shell serving it. The system update is
# detached (helpers/update-run.sh), so a shell reload or a crash happens in the
# middle of a sudo, and the next shell serves the SAME path. Without RETRY a
# missing or dying server is an immediate "no password" (the LLM's jobs live
# and die with the popup that serves them). With it, a refused or missing
# socket, and a connection that closes with NO line at all (the server died
# before answering; a cancel is an explicit empty line), are tried again every
# 250 ms until the timeout.
import json, os, socket, sys, time

prompt = sys.argv[1] if len(sys.argv) > 1 else "Password: "
path = os.environ.get("LARES_ASKPASS_SOCKET") or os.environ.get("LLM_ASKPASS_SOCKET", "")
try:
    wait = float(os.environ.get("LARES_ASKPASS_TIMEOUT") or os.environ.get("LLM_ASKPASS_TIMEOUT") or "120")
except ValueError:
    wait = 120.0
retry = os.environ.get("LARES_ASKPASS_RETRY", "") == "1"
if not path:
    sys.exit(1)

line = (json.dumps({"v": 1, "pid": os.getpid(), "prompt": prompt}) + "\n").encode()
deadline = time.monotonic() + wait


def ask():
    """One connection: the answer's bytes, or None when the server never answered."""
    left = deadline - time.monotonic()
    if left <= 0:
        raise TimeoutError
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(left)
        s.connect(path)
        s.sendall(line)
        buf = b""
        while not buf.endswith(b"\n"):
            s.settimeout(max(0.001, deadline - time.monotonic()))
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        return buf if buf.endswith(b"\n") else None
    finally:
        s.close()


buf = None
while True:
    try:
        buf = ask()
    except (FileNotFoundError, ConnectionRefusedError, ConnectionResetError, BrokenPipeError):
        buf = None
    except OSError:
        sys.exit(1)
    if buf is not None or not retry:
        break
    if time.monotonic() + 0.25 >= deadline:
        sys.exit(1)
    time.sleep(0.25)

secret = (buf or b"").rstrip(b"\r\n")
if not secret:
    sys.exit(1)
sys.stdout.buffer.write(secret + b"\n")
sys.stdout.flush()
