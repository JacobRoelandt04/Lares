#!/usr/bin/env python3
# A stand-in for tools/aerial/aerial-helper (contract docs/contracts/aerial.md section 3) for the service's probe: it speaks the
# helper's JSON lines on stdout / stdin and touches NOTHING of the machine.
#
#   aerial_helper_stub.py --log <file> --control <file> [--scenario <file>] [--silent <cmd,cmd>]
#
#   --scenario  a JSON file: { "start": [ <messages emitted right after hello> ], "replies": { "<cmd>" | "<cmd>:<action>": {ok, error, data} },
#               "on": { "<cmd>" | "<cmd>:<action>": [ <messages emitted after that command> ] } }
#   --control   a file the probe APPENDS lines to; each line is a message to emit now (`{"t": ...}`), or {"ctl": "reply", "key": k, "reply": r}
#               to change a reply, or {"ctl": "exit"} to die.
#   --log       every command received is appended, one JSON line each.
#   --silent    commands that get no reply (a timeout test).
# A reply table entry may carry "before": [messages emitted just before its reply].
# Every command that carries an `id` is answered `{"t":"reply","id":..,"ok":true,...}` unless the scenario says otherwise. It exits on stdin EOF.
import json, os, select, sys, time

def arg(name, default=""):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default

LOG, CTL = arg("--log"), arg("--control")
scn = json.load(open(arg("--scenario"))) if arg("--scenario") else {}
replies = dict(scn.get("replies", {}))
on = scn.get("on", {})
silent = set(filter(None, arg("--silent").split(",")))

def emit(o):
    sys.stdout.write(json.dumps(o, separators=(",", ":")) + "\n")
    sys.stdout.flush()

def key_of(m):
    return m["cmd"] + ":" + str(m.get("action")) if m.get("action") else m["cmd"]

emit({"t": "hello", "v": 1, "pid": os.getpid()})
for m in scn.get("start", []):
    emit(m)

ctl_off = os.path.getsize(CTL) if CTL and os.path.exists(CTL) else 0     # a restarted helper does not replay the probe's past
buf = b""
fd = sys.stdin.fileno()
while True:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            m = json.loads(line)
            if LOG:
                with open(LOG, "a") as f:
                    f.write(json.dumps(m, sort_keys=True) + "\n")
            k = key_of(m)
            if "id" in m and m["cmd"] not in silent and k not in silent:
                rep = replies.get(k, replies.get(m["cmd"], {}))
                for out in rep.get("before", []):       # events the real helper emits BEFORE the reply (a pad's testing / answer)
                    if "sleep" in out:                   # { "sleep": ms }: a pause between two (the answer is not in the same turn as the `testing`)
                        time.sleep(out["sleep"] / 1000.0)
                    else:
                        emit(dict(out, id=m.get("pad")) if out.get("id") == "$pad" else out)    # "$pad": the pad this command asked for
                emit({"t": "reply", "id": m["id"], "ok": rep.get("ok", True), "error": rep.get("error"), "data": rep.get("data")})
            for out in on.get(k, on.get(m["cmd"], [])):
                emit(out)
    if CTL and os.path.exists(CTL):
        with open(CTL, "rb") as f:
            f.seek(ctl_off)
            data = f.read()
        if data and data.endswith(b"\n"):
            ctl_off += len(data)
            for line in data.decode().splitlines():
                if not line.strip():
                    continue
                m = json.loads(line)
                if m.get("ctl") == "reply":
                    replies[m["key"]] = m["reply"]
                elif m.get("ctl") == "exit":
                    sys.exit(3)
                else:
                    emit(m)
