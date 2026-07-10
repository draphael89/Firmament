#!/usr/bin/env python3
"""Gate 0 spike: drive `codex app-server` programmatically over stdio JSON-RPC.

Proves: headless subscription-authenticated structured extraction — the
CodexProvider contract (thread/start -> turn/start with outputSchema -> final
agent message), no TTY, no user in the loop.
"""
import json, subprocess, sys, threading, time

PROC = subprocess.Popen(
    ["codex", "app-server"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, bufsize=1,
)

pending = {}
notifications = []
server_requests = []
lock = threading.Lock()
next_id = [0]

def reader():
    for line in PROC.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            print("NONJSON:", line[:200], file=sys.stderr)
            continue
        with lock:
            if "id" in msg and ("result" in msg or "error" in msg):
                pending[msg["id"]] = msg
            elif "id" in msg and "method" in msg:
                server_requests.append(msg)
            else:
                notifications.append(msg)

threading.Thread(target=reader, daemon=True).start()

def send(method, params=None, is_notification=False):
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not is_notification:
        next_id[0] += 1
        msg["id"] = next_id[0]
    PROC.stdin.write(json.dumps(msg) + "\n")
    PROC.stdin.flush()
    return None if is_notification else next_id[0]

def wait(req_id, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if req_id in pending:
                return pending.pop(req_id)
        time.sleep(0.05)
    raise TimeoutError(f"no response to request {req_id}")

# 1. initialize
rid = send("initialize", {"clientInfo": {"name": "firmament-spike", "title": "Firmament Spike", "version": "0.0.1"}})
init = wait(rid, 30)
print("INITIALIZE:", json.dumps(init.get("result", init.get("error")))[:400])
send("initialized", is_notification=True)

# 2. thread/start — ephemeral, read-only sandbox
rid = send("thread/start", {
    "ephemeral": True,
    "sandbox": "read-only",
    "cwd": "/private/tmp",
})
resp = wait(rid, 30)
if "error" in resp:
    print("THREAD/START ERROR:", json.dumps(resp["error"])[:500]); sys.exit(1)
thread_id = resp["result"].get("threadId") or resp["result"].get("thread", {}).get("id")
print("THREAD:", thread_id)

# 3. turn/start — structured extraction with outputSchema
schema = {
    "type": "object",
    "properties": {
        "title": {"type": "string"},
        "primary_facet": {"type": "string", "enum": ["self", "others", "agents"]},
        "mood": {"type": "string"},
    },
    "required": ["title", "primary_facet", "mood"],
    "additionalProperties": False,
}
rid = send("turn/start", {
    "threadId": thread_id,
    "model": "gpt-5.6-terra",
    "effort": "low",
    "input": [{"type": "text", "text": (
        "You are a personal-vault analysis pipeline. Analyze this voice-note "
        "transcript and return JSON matching the output schema.\n\n"
        "Transcript: 'Walked the dog this morning, kept thinking about whether "
        "the vault app should process entries on ingest or nightly. Leaning "
        "ingest. Also need to call mom back.'"
    )}],
    "outputSchema": schema,
})
resp = wait(rid, 60)
if "error" in resp:
    print("TURN/START ERROR:", json.dumps(resp["error"])[:500]); sys.exit(1)
turn_id = resp["result"]["turn"]["id"]
print("TURN STARTED:", turn_id)

# 4. wait for turn completion via notifications
deadline = time.time() + 300
final_status, agent_text = None, None
seen = 0
while time.time() < deadline and final_status is None:
    time.sleep(0.2)
    with lock:
        batch = notifications[seen:]
        seen = len(notifications)
    for n in batch:
        m = n.get("method", "")
        p = n.get("params", {})
        if m in ("turn/completed", "turn/failed"):
            if p.get("turn", {}).get("id") == turn_id or p.get("turnId") == turn_id:
                final_status = m
                print("FINAL:", m, json.dumps(p)[:1500])
        elif "item" in m:
            item = p.get("item", {})
            if item.get("type") in ("agentMessage", "agent_message"):
                agent_text = item.get("text") or item.get("content")
print("TURN STATUS:", final_status)
print("AGENT MESSAGE:", json.dumps(agent_text)[:1200] if agent_text else None)
if agent_text:
    try:
        parsed = json.loads(agent_text if isinstance(agent_text, str) else json.dumps(agent_text))
        print("SCHEMA-VALID JSON:", json.dumps(parsed))
    except Exception as e:
        print("JSON PARSE FAILED:", e)
with lock:
    print("NOTIFICATION METHODS SEEN:", json.dumps(sorted({n.get("method","") for n in notifications})))
    if server_requests:
        print("SERVER REQUESTS (approvals?):", json.dumps(server_requests)[:400])

PROC.terminate()
print("SPIKE COMPLETE")
