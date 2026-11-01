#!/usr/bin/python3
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-04, AC-04.01, AC-04.03, AC-04.05, AC-04.06, AC-04.09.
"""Synthetic, read-only JSON-RPC subprocess used without Codex credentials."""
import json
import os
from pathlib import Path
import sys
import time

directory = Path(__file__).parent
scenario = Path(__file__).name
(directory / "child.pid").write_text(str(os.getpid()))
if scenario == "broken-pipe":
    sys.stdin.close()
    raise SystemExit(0)
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialized":
        continue
    if method == "initialize":
        assert message["params"]["clientInfo"]["name"] == "lunlet"
        response = {"id": message["id"], "result": {"userAgent": "synthetic"}}
    elif method == "account/read":
        assert message["params"].get("refreshToken") is False
        response = {"id": message["id"], "result": {"account": {"type": "chatgpt", "email": "developer@example.invalid", "planType": "pro"}}}
    elif method == "account/rateLimits/read":
        if scenario in ["timeout", "cancel"]:
            (directory / "waiting").touch()
            time.sleep(60)
            break
        response = {"id": message["id"], "result": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 25}}}}
        if scenario == "wrong-id":
            print(json.dumps({"id": 999, "result": {"rateLimits": {"primary": {"usedPercent": 99}}}}), flush=True)
        elif scenario == "rpc-error":
            response = {"id": message["id"], "error": {"code": -32000, "message": "synthetic-private-provider-detail"}}
        elif scenario == "malformed":
            print("not-json", flush=True)
            continue
    else:
        raise SystemExit(61)
    print(json.dumps(response), flush=True)
