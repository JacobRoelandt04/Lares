#!/usr/bin/env python3
"""A stand-in for ollama that plays the spoken-ask scenarios (tools/dev/llm_voice_probe.sh).

    python3 -u tools/dev/llm_voice_stub.py <log.jsonl>

Binds 127.0.0.1 on a free port and prints `LISTEN <port>` once it is up. Every request is one JSON line in <log.jsonl>:
{"at": <epoch ms>, "method", "path", "body": <the parsed JSON body or null>}. Nothing else is served or reached.

ONE MODEL, `stub:voice`, that can call tools (/api/show says `tools`, /api/tags does not -- as the real server's /api/tags
does not either), so a turn that offers tools before /api/show has landed offers none.

THE SCENARIOS are chosen by words in the LAST user message and played by how many tool results follow it:
    explain   two sentences of prose, no tool (before `commit`: "explain what a commit is" is prose)
    commit    run_command `git log -1 --format=%h`, then the hash it saw, alone in a code block
    touch     run_command `touch notes.txt`, then a sentence
    todo      search_files TODO in ".", then a sentence
    readme    read_file (head) README.md, then web_search, then a sentence
    ssh       run_command `cat ~/.ssh/id_ed25519`, then a sentence
    pipeline  run_command `git log --oneline | head -1`, then a sentence
    typed     a code block saying whether the request carried tools ("TOOLS=yes" / "TOOLS=no")
/api/ps lists the model while it is loaded (any chat request loads it; keep_alive 0 evicts it).
A non-streaming request with `format` is a title (`{"title": "Stub title", "category": "code"}`); one with no messages is a
load. Every stream is NDJSON, ollama's shape: a content or tool-call frame, then a done frame.
"""
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "stub:voice"
MODELS = (MODEL, "stub:spoken")           # the second one answers the same; nothing but llm.jsonc's voice.model names it
LOCK = threading.Lock()
LOG = [None]
# Whether the model is "in memory": any chat request loads it, one with keep_alive 0 (the service's unload) evicts it, and /api/ps says
# which -- what LlmMachine and the service's residency read to know the card may go.
LOADED = [False]


def record(method, path, body):
    with LOCK:
        LOG[0].write(json.dumps({"at": int(time.time() * 1000), "method": method, "path": path, "body": body}) + "\n")
        LOG[0].flush()


def last_user_and_tools(messages):
    last = -1
    for i, m in enumerate(messages):
        if m.get("role") == "user":
            last = i
    if last < 0:
        return "", []
    return str(messages[last].get("content", "")), [m for m in messages[last + 1:] if m.get("role") == "tool"]


def say(text):
    return [{"message": {"role": "assistant", "content": text}}]


def call(name, args):
    return [{"message": {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": name, "arguments": args}}]}}]


def play(body):
    q, tools = last_user_and_tools(body.get("messages") or [])
    n = len(tools)
    ql = q.lower()
    if "typed" in ql:
        return say("```\nTOOLS=" + ("yes" if body.get("tools") else "no") + "\n```")
    if "explain" in ql:
        return say("A commit is a snapshot of the project. It records who changed what, and why.")
    if "commit" in ql:
        if n == 0:
            return call("run_command", {"command": "git log -1 --format=%h"})
        m = re.search(r"\b[0-9a-f]{7,12}\b", str(tools[-1].get("content", "")))
        return say("```\n" + (m.group(0) if m else "NO-HASH") + "\n```")
    if "touch" in ql:
        return call("run_command", {"command": "touch notes.txt"}) if n == 0 else say("I did not create the file.")
    if "todo" in ql:
        return call("search_files", {"pattern": "TODO", "path": "."}) if n == 0 else say("I found the notes.")
    if "readme" in ql:
        if n == 0:
            return call("read_file", {"action": "head", "path": "README.md"})
        if n == 1:
            return call("web_search", {"query": "stub project readme"})
        return say("I read the readme but did not search the web.")
    if "ssh" in ql:
        return call("run_command", {"command": "cat ~/.ssh/id_ed25519"}) if n == 0 else say("I did not read the key.")
    if "pipeline" in ql:
        return call("run_command", {"command": "git log --oneline | head -1"}) if n == 0 else say("I did not run it.")
    return say("OK.")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        record("GET", self.path, None)
        if self.path == "/api/tags":
            self._json(200, {"models": [{"name": m, "model": m, "size": 1000000, "digest": "stubvoice0001",
                                         "details": {"family": "stub", "parameter_size": "1B", "quantization_level": "Q4"}} for m in MODELS]})
        elif self.path == "/api/ps":
            with LOCK:
                loaded = LOADED[0]
            self._json(200, {"models": [{"name": MODEL, "model": MODEL, "size": 1000000, "size_vram": 1000000,
                                         "digest": "stubvoice0001"}] if loaded else []})
        elif self.path == "/api/version":
            self._json(200, {"version": "0.0.0-stub"})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n > 0 else b""
        try:
            body = json.loads(raw.decode() or "null")
        except ValueError:
            body = None
        record("POST", self.path, body)
        if not isinstance(body, dict):
            self._json(400, {"error": "bad body"})
            return
        if self.path == "/api/show":
            if body.get("model") not in MODELS:
                self._json(404, {"error": "model not found"})
                return
            self._json(200, {"capabilities": ["completion", "tools"],
                             "details": {"family": "stub", "parameter_size": "1B", "quantization_level": "Q4"},
                             "model_info": {"general.architecture": "stub", "stub.context_length": 8192}})
            return
        if self.path != "/api/chat":
            self._json(404, {"error": "not found"})
            return
        if body.get("model") not in MODELS:
            self._json(404, {"error": "model '%s' not found" % body.get("model")})
            return
        with LOCK:
            LOADED[0] = body.get("keep_alive") != 0
        msgs = body.get("messages") or []
        done = {"model": MODEL, "done": True, "done_reason": "stop", "prompt_eval_count": 20, "eval_count": 5,
                "eval_duration": 5000000, "total_duration": 9000000, "load_duration": 0}
        if not msgs:
            self._json(200, dict(done, done_reason="load", message={"role": "assistant", "content": ""}))
            return
        if body.get("stream") is False:
            self._json(200, dict(done, message={"role": "assistant",
                                                "content": json.dumps({"title": "Stub title", "category": "code"})}))
            return
        frames = play(body)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Connection", "close")
        self.end_headers()
        for f in frames:
            self.wfile.write((json.dumps(dict(f, model=MODEL, done=False)) + "\n").encode())
            self.wfile.flush()
            time.sleep(0.02)
        self.wfile.write((json.dumps(dict(done, message={"role": "assistant", "content": ""})) + "\n").encode())
        self.wfile.flush()
        self.close_connection = True


def main():
    LOG[0] = open(sys.argv[1], "a", encoding="utf-8")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    srv.daemon_threads = True
    print("LISTEN %d" % srv.server_address[1], flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
