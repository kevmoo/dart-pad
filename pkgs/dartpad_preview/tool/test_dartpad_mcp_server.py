#!/usr/bin/env python3
"""Comprehensive self-test suite for `dartpad_mcp_server.py`.

Verifies without requiring a Jaspr frontend build:
1. Dual-stack (`127.0.0.1`, `[::1]`) HTTP static file serving,
   SPA fallback, path-traversal protection, and exact MIME types (including raw `.tar.gz`
   without `Content-Encoding` corruption and `.wasm` -> `application/wasm`).
2. Cold-start 20s startup race handling when `tools/call` arrives before the browser
   tab finishes connecting `/mcp-ws` and sending `webmcp/hello`.
3. `GET /healthz` connected tab tracking and tool counts.
4. `POST /mcp` MCP Streamable HTTP (`initialize`, `notifications/initialized`, `ping`,
   `tools/list`, `tools/call`), RFC 6455 PING/PONG, and >100 KB 64-bit WebSocket frames.
5. Multi-tab `sessionId` routing (defaulting to most recently active tab, explicit
   `sessionId` targeting, and stripping synthetic `sessionId` on wire) + cached
   `tools/list` response when all tabs disconnect during a page reload.
6. `--stdio --connect-http` subprocess round-trips over pure JSON-RPC `stdin`/`stdout`.
7. `--stdio --port 0` all-in-one embedded HTTP/WS + `stdio` mode.
"""

from __future__ import annotations

import asyncio
import base64
import gzip
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

BRIDGE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BRIDGE_DIR)

from dartpad_mcp_server import WebSocketConnection  # noqa: E402

SERVER_SCRIPT = os.path.join(BRIDGE_DIR, "dartpad_mcp_server.py")
NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))

MOCK_DARTPAD_TOOLS = [
    {
        "name": "dartpad_get_status",
        "description": "Returns current DartPad workspace & preview status.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "dartpad_list_files",
        "description": "Lists workspace files.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "recursive": {"type": "boolean"},
            },
        },
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "dartpad_read_file",
        "description": "Reads a file from the workspace.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
        },
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "dartpad_write_files",
        "description": "Writes files and awaits settled analyzer diagnostics.",
        "inputSchema": {
            "type": "object",
            "properties": {"files": {"type": "array"}},
            "required": ["files"],
        },
        "annotations": {"readOnlyHint": False},
    },
    {
        "name": "dartpad_get_diagnostics",
        "description": "Returns analyzer diagnostics.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "dartpad_pub",
        "description": "Runs dart pub commands.",
        "inputSchema": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        },
        "annotations": {"readOnlyHint": False},
    },
    {
        "name": "dartpad_run_or_reload",
        "description": "Runs, hot-reloads, or hot-restarts the preview.",
        "inputSchema": {
            "type": "object",
            "properties": {"action": {"type": "string"}},
        },
        "annotations": {"readOnlyHint": False},
    },
    {
        "name": "dartpad_get_logs",
        "description": "Returns buffered console and runtime error logs.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "dartpad_inspect_widget_tree",
        "description": "Returns the Flutter widget summary tree via VM Service.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
]


def http_get(url: str) -> tuple[int, dict[str, str], bytes]:
    req = urllib.request.Request(url, method="GET")
    try:
        with NO_PROXY.open(req, timeout=10.0) as resp:
            headers = {k.lower(): v for k, v in resp.headers.items()}
            return resp.status, headers, resp.read()
    except urllib.error.HTTPError as exc:
        headers = {k.lower(): v for k, v in exc.headers.items()}
        return exc.code, headers, exc.read()


def http_post_json(url: str, payload: Any) -> tuple[int, Any]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with NO_PROXY.open(req, timeout=15.0) as resp:
        raw = resp.read()
        return resp.status, (json.loads(raw.decode("utf-8")) if raw else None)


class MockBrowserTab:
    """Simulated DartPad Preview browser tab speaking `/mcp-ws` RFC 6455 WebSocket."""

    def __init__(self, port: int, session_id: str) -> None:
        self.port = port
        self.session_id = session_id
        self.ws: WebSocketConnection | None = None
        self._task: asyncio.Task[None] | None = None
        self.tools_list_count = 0
        self.received_calls: list[dict[str, Any]] = []

    async def connect(self) -> None:
        reader, writer = await asyncio.open_connection(
            "127.0.0.1", self.port, limit=16 * 1024 * 1024
        )
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        req = (
            f"GET /mcp-ws HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        writer.write(req.encode("ascii"))
        await writer.drain()
        resp_head = await reader.readuntil(b"\r\n\r\n")
        assert b"101 Switching Protocols" in resp_head, f"Handshake failed: {resp_head!r}"

        self.ws = WebSocketConnection(reader, writer, is_client=True)
        await self.ws.send_json(
            {
                "jsonrpc": "2.0",
                "method": "webmcp/hello",
                "params": {
                    "sessionId": self.session_id,
                    "url": f"http://127.0.0.1:{self.port}/?s={self.session_id}&mcp=1",
                    "tools": MOCK_DARTPAD_TOOLS,
                },
            }
        )
        self._task = asyncio.create_task(self._serve_loop())

    async def _serve_loop(self) -> None:
        assert self.ws is not None
        while True:
            raw = await self.ws.recv_message()
            if raw is None:
                break
            assert isinstance(raw, str)
            msg = json.loads(raw)
            req_id = msg.get("id")
            method = msg.get("method")

            if method == "tools/list":
                self.tools_list_count += 1
                await self.ws.send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"tools": MOCK_DARTPAD_TOOLS},
                    }
                )
            elif method == "tools/call":
                params = msg.get("params") or {}
                self.received_calls.append(params)
                name = params.get("name")
                args = params.get("arguments") or {}

                if name == "dartpad_inspect_widget_tree":
                    # Exercise > 65,535 byte 64-bit WebSocket frames!
                    big_tree = "MissionCard -> " + ("StatTile " * 9000)
                    res: dict[str, Any] = {
                        "sessionId": self.session_id,
                        "isolateId": "isolates/123",
                        "tree": big_tree,
                    }
                else:
                    res = {
                        "sessionId": self.session_id,
                        "tool": name,
                        "echoArgs": args,
                    }

                await self.ws.send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "content": [{"type": "text", "text": json.dumps(res)}],
                            "structuredContent": res,
                            "isError": False,
                        },
                    }
                )

    async def send_ping(self) -> None:
        assert self.ws is not None
        await self.ws.send_frame(0x9, b"keepalive")

    async def disconnect(self) -> None:
        if self.ws is not None:
            await self.ws.close()
        if self._task is not None:
            await self._task


async def wait_for_port_file(port_file: str, timeout: float = 10.0) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.isfile(port_file):
            txt = open(port_file, encoding="utf-8").read().strip()
            if txt.isdigit() and int(txt) > 0:
                return int(txt)
        await asyncio.sleep(0.05)
    raise TimeoutError(f"Server did not write bound port to {port_file}")


async def run_tests() -> None:
    with tempfile.TemporaryDirectory(prefix="dartpad_bridge_test_") as tmp:
        static_dir = os.path.join(tmp, "jaspr")
        os.makedirs(os.path.join(static_dir, "assets"), exist_ok=True)
        os.makedirs(os.path.join(static_dir, "dartpad"), exist_ok=True)
        os.makedirs(os.path.join(static_dir, "examples"), exist_ok=True)

        with open(os.path.join(static_dir, "index.html"), "w", encoding="utf-8") as f:
            f.write("<!doctype html><title>DartPad Mock</title>\n")
        with open(os.path.join(static_dir, "main.dart.js"), "w", encoding="utf-8") as f:
            f.write("console.log('ok');\n")
        with open(os.path.join(static_dir, "dartpad", "worker.wasm"), "wb") as f:
            f.write(b"\x00asm\x01\x00\x00\x00")
        tar_gz_bytes = gzip.compress(b"mock-tar-archive-payload" * 50)
        with open(
            os.path.join(static_dir, "examples", "counter.tar.gz"), "wb"
        ) as f:
            f.write(tar_gz_bytes)
        with open(os.path.join(static_dir, "dartpad", "platform.dill"), "wb") as f:
            f.write(b"\x90\xab\xcd\xef")

        port_file = os.path.join(tmp, "daemon.port")
        daemon = subprocess.Popen(
            [
                sys.executable,
                SERVER_SCRIPT,
                "--port",
                "0",
                "--static-dir",
                static_dir,
                "--port-file",
                port_file,
                "--wait-timeout",
                "5.0",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        try:
            port = await wait_for_port_file(port_file)
            print(f"[PASS] Daemon listening dual-stack on port {port}")

            # 1. Dual-stack HTTP & static MIME type checks
            st, hdrs, body = await asyncio.to_thread(
                http_get, f"http://127.0.0.1:{port}/?s=3&mcp=1"
            )
            assert st == 200 and b"DartPad Mock" in body
            assert "text/html" in hdrs["content-type"]

            st_v6, _, _ = await asyncio.to_thread(
                http_get, f"http://[::1]:{port}/healthz"
            )
            assert st_v6 == 200, f"IPv6 [::1] failed with {st_v6}"

            fqdn = socket.getfqdn()
            if fqdn:
                try:
                    socket.getaddrinfo(fqdn, port, 0, socket.SOCK_STREAM)
                except OSError:
                    fqdn = ""
            if fqdn:
                st_host, _, _ = await asyncio.to_thread(
                    http_get, f"http://{fqdn}:{port}/healthz"
                )
                assert st_host == 200, f"Hostname {fqdn} failed with {st_host}"

            st_wasm, hdrs_wasm, _ = await asyncio.to_thread(
                http_get, f"http://127.0.0.1:{port}/dartpad/worker.wasm"
            )
            assert st_wasm == 200 and hdrs_wasm["content-type"] == "application/wasm"

            st_tgz, hdrs_tgz, body_tgz = await asyncio.to_thread(
                http_get, f"http://127.0.0.1:{port}/examples/counter.tar.gz"
            )
            assert st_tgz == 200
            assert hdrs_tgz["content-type"] == "application/gzip"
            assert "content-encoding" not in hdrs_tgz, (
                ".tar.gz must NOT set Content-Encoding!"
            )
            assert body_tgz == tar_gz_bytes

            st_404, _, _ = await asyncio.to_thread(
                http_get, f"http://127.0.0.1:{port}/assets/missing.png"
            )
            assert st_404 == 404
            print("[PASS] Dual-stack IPv4/IPv6/FQDN + MIME types + raw .tar.gz verified")

            # 2. Cold-start wait race: fire `tools/call` BEFORE browser tab connects!
            cold_call_task = asyncio.create_task(
                asyncio.to_thread(
                    http_post_json,
                    f"http://127.0.0.1:{port}/mcp",
                    {
                        "jsonrpc": "2.0",
                        "id": "cold-1",
                        "method": "tools/call",
                        "params": {"name": "dartpad_get_status", "arguments": {}},
                    },
                )
            )
            await asyncio.sleep(0.25)
            tab3 = MockBrowserTab(port, "3")
            await tab3.connect()

            st_cold, resp_cold = await cold_call_task
            assert st_cold == 200
            assert resp_cold["result"]["structuredContent"]["sessionId"] == "3"
            print("[PASS] Cold-start startup race wait before webmcp/hello verified")

            # 3. GET /healthz shows connected tab
            st_hz, _, hz_bytes = await asyncio.to_thread(
                http_get, f"http://127.0.0.1:{port}/healthz"
            )
            hz = json.loads(hz_bytes.decode("utf-8"))
            assert st_hz == 200 and hz["ok"] is True
            assert hz["toolCount"] == 9
            assert len(hz["connectedTabs"]) == 1
            assert hz["connectedTabs"][0]["sessionId"] == "3"
            print("[PASS] GET /healthz connected tab & toolCount=9 verified")

            # 4. POST /mcp Streamable HTTP round-trips + >64KB WebSocket frames
            mcp_url = f"http://127.0.0.1:{port}/mcp"
            st_init, r_init = await asyncio.to_thread(
                http_post_json,
                mcp_url,
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {},
                        "clientInfo": {"name": "test", "version": "1.0"},
                    },
                },
            )
            assert st_init == 200
            assert r_init["result"]["protocolVersion"] == "2024-11-05"

            st_notif, r_notif = await asyncio.to_thread(
                http_post_json,
                mcp_url,
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
            )
            assert st_notif == 202 and r_notif is None

            await tab3.send_ping()

            st_list, r_list = await asyncio.to_thread(
                http_post_json,
                mcp_url,
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            )
            assert st_list == 200
            assert len(r_list["result"]["tools"]) == 9
            assert tab3.tools_list_count >= 1

            st_big, r_big = await asyncio.to_thread(
                http_post_json,
                mcp_url,
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "dartpad_inspect_widget_tree",
                        "arguments": {},
                    },
                },
            )
            assert st_big == 200
            tree_str = r_big["result"]["structuredContent"]["tree"]
            assert len(tree_str) > 80_000
            print(
                f"[PASS] POST /mcp round-trips + 64-bit WS frame ({len(tree_str)} bytes) verified"
            )

            # 5. Multi-tab routing (`sessionId`)
            tab7 = MockBrowserTab(port, "7")
            await tab7.connect()
            await asyncio.sleep(0.05)

            # Default goes to most recently active tab ("7")
            _, r_def = await asyncio.to_thread(
                http_post_json,
                mcp_url,
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": {
                        "name": "dartpad_read_file",
                        "arguments": {"path": "lib/main.dart"},
                    },
                },
            )
            assert r_def["result"]["structuredContent"]["sessionId"] == "7"

            # Explicit `sessionId: "3"` targets tab "3" and strips synthetic `sessionId`
            _, r_t3 = await asyncio.to_thread(
                http_post_json,
                mcp_url,
                {
                    "jsonrpc": "2.0",
                    "id": 5,
                    "method": "tools/call",
                    "params": {
                        "name": "dartpad_read_file",
                        "arguments": {"path": "lib/main.dart", "sessionId": "3"},
                    },
                },
            )
            assert r_t3["result"]["structuredContent"]["sessionId"] == "3"
            assert "sessionId" not in r_t3["result"]["structuredContent"]["echoArgs"]
            print("[PASS] Multi-tab routing (active default + explicit sessionId) verified")

            # 6. `--stdio --connect-http` subprocess test
            stdio_proc = subprocess.Popen(
                [
                    sys.executable,
                    SERVER_SCRIPT,
                    "--stdio",
                    "--connect-http",
                    mcp_url,
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert stdio_proc.stdin is not None and stdio_proc.stdout is not None

            def stdio_rpc(msg: dict[str, Any]) -> dict[str, Any] | None:
                assert stdio_proc.stdin is not None and stdio_proc.stdout is not None
                stdio_proc.stdin.write(
                    (json.dumps(msg) + "\n").encode("utf-8")
                )
                stdio_proc.stdin.flush()
                if "id" not in msg:
                    return None
                line = stdio_proc.stdout.readline()
                assert line, "Unexpected EOF on --stdio stdout"
                return json.loads(line.decode("utf-8"))

            s_init = await asyncio.to_thread(
                stdio_rpc,
                {
                    "jsonrpc": "2.0",
                    "id": 101,
                    "method": "initialize",
                    "params": {"protocolVersion": "2025-03-26", "capabilities": {}},
                },
            )
            assert s_init is not None and s_init["id"] == 101
            assert s_init["result"]["protocolVersion"] == "2025-03-26"

            await asyncio.to_thread(
                stdio_rpc, {"jsonrpc": "2.0", "method": "notifications/initialized"}
            )

            s_list = await asyncio.to_thread(
                stdio_rpc, {"jsonrpc": "2.0", "id": 102, "method": "tools/list"}
            )
            assert s_list is not None and len(s_list["result"]["tools"]) == 9

            s_call = await asyncio.to_thread(
                stdio_rpc,
                {
                    "jsonrpc": "2.0",
                    "id": 103,
                    "method": "tools/call",
                    "params": {
                        "name": "dartpad_write_files",
                        "arguments": {
                            "files": [{"path": "lib/main.dart", "content": "void main() {}"}],
                            "sessionId": "7",
                        },
                    },
                },
            )
            assert s_call is not None and s_call["id"] == 103
            assert s_call["result"]["structuredContent"]["sessionId"] == "7"
            assert s_call["result"]["isError"] is False

            stdio_proc.stdin.close()
            stdio_rc = await asyncio.to_thread(stdio_proc.wait, 5.0)
            assert stdio_rc == 0
            print("[PASS] `--stdio --connect-http` clean stdin/stdout round-trips verified")

            # 6b. CLI subcommands (`status`, `tools`, `call --stdin --session`) + `--stdio` active-port auto-attach
            st_cli = await asyncio.to_thread(
                subprocess.run,
                [sys.executable, SERVER_SCRIPT, "status", "--port", str(port), "--require-tab"],
                capture_output=True,
                text=True,
                timeout=10.0,
            )
            assert st_cli.returncode == 0, f"status failed: {st_cli.stderr}"
            st_cli_json = json.loads(st_cli.stdout)
            assert len(st_cli_json["connectedTabs"]) == 2

            tools_cli = await asyncio.to_thread(
                subprocess.run,
                [sys.executable, SERVER_SCRIPT, "tools", "--port", str(port), "--session", "3"],
                capture_output=True,
                text=True,
                timeout=10.0,
            )
            assert tools_cli.returncode == 0, f"tools failed: {tools_cli.stderr}"
            tools_cli_json = json.loads(tools_cli.stdout)
            assert len(tools_cli_json["tools"]) == 9

            call_cli = await asyncio.to_thread(
                subprocess.run,
                [
                    sys.executable,
                    SERVER_SCRIPT,
                    "call",
                    "dartpad_read_file",
                    "--stdin",
                    "--port",
                    str(port),
                    "--session",
                    "3",
                ],
                input='{"path": "pubspec.yaml"}',
                capture_output=True,
                text=True,
                timeout=10.0,
            )
            assert call_cli.returncode == 0, f"call failed: {call_cli.stderr}"
            call_cli_json = json.loads(call_cli.stdout)
            assert call_cli_json["sessionId"] == "3"
            assert call_cli_json["echoArgs"] == {"path": "pubspec.yaml"}

            # Verify `--stdio --port <active_port>` auto-attaches to the running daemon instead of EADDRINUSE
            auto_stdio = subprocess.Popen(
                [sys.executable, SERVER_SCRIPT, "--stdio", "--port", str(port)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert auto_stdio.stdin is not None and auto_stdio.stdout is not None
            auto_stdio.stdin.write(
                b'{"jsonrpc":"2.0","id":201,"method":"tools/call","params":{"name":"dartpad_get_status","arguments":{"sessionId":"3"}}}\n'
            )
            auto_stdio.stdin.flush()
            auto_line = await asyncio.to_thread(auto_stdio.stdout.readline)
            auto_resp = json.loads(auto_line.decode("utf-8"))
            assert auto_resp["id"] == 201
            assert auto_resp["result"]["structuredContent"]["sessionId"] == "3"
            auto_stdio.stdin.close()
            assert (await asyncio.to_thread(auto_stdio.wait, 5.0)) == 0
            print("[PASS] CLI subcommands (`status`, `tools`, `call --stdin`) + `--stdio` auto-attach verified")

            # Disconnect both tabs and verify cached `tools/list` responds immediately (<200ms)
            await tab3.disconnect()
            await tab7.disconnect()
            await asyncio.sleep(0.05)

            empty_st_cli = await asyncio.to_thread(
                subprocess.run,
                [sys.executable, SERVER_SCRIPT, "status", "--port", str(port), "--require-tab"],
                capture_output=True,
                text=True,
                timeout=10.0,
            )
            assert empty_st_cli.returncode == 2, (
                f"Expected exit code 2 when --require-tab has zero tabs, got {empty_st_cli.returncode}"
            )

            t0 = time.monotonic()
            _, r_cached = await asyncio.to_thread(
                http_post_json,
                mcp_url,
                {"jsonrpc": "2.0", "id": 99, "method": "tools/list"},
            )
            dt = time.monotonic() - t0
            assert len(r_cached["result"]["tools"]) == 9
            assert dt < 0.5, f"Cached tools/list took {dt:.2f}s instead of responding immediately!"
            print(f"[PASS] Cached fallback `tools/list` during reload responded in {dt*1000:.1f}ms")

        finally:
            daemon.terminate()
            try:
                daemon.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()

        # 7. All-in-one `--stdio --port 0` standalone mode test
        embedded_port_file = os.path.join(tmp, "embedded.port")
        emb_proc = subprocess.Popen(
            [
                sys.executable,
                SERVER_SCRIPT,
                "--stdio",
                "--port",
                "0",
                "--static-dir",
                static_dir,
                "--port-file",
                embedded_port_file,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            assert emb_proc.stdin is not None and emb_proc.stdout is not None
            emb_port = await wait_for_port_file(embedded_port_file)
            emb_tab = MockBrowserTab(emb_port, "3")
            await emb_tab.connect()

            emb_proc.stdin.write(
                b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}\n'
                b'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"dartpad_get_status","arguments":{}}}\n'
            )
            emb_proc.stdin.flush()

            l1 = json.loads(
                (await asyncio.to_thread(emb_proc.stdout.readline)).decode("utf-8")
            )
            l2 = json.loads(
                (await asyncio.to_thread(emb_proc.stdout.readline)).decode("utf-8")
            )
            results_by_id = {l1["id"]: l1, l2["id"]: l2}
            assert "serverInfo" in results_by_id[1]["result"]
            assert results_by_id[2]["result"]["structuredContent"]["sessionId"] == "3"

            await emb_tab.disconnect()
            emb_proc.stdin.close()
            assert (await asyncio.to_thread(emb_proc.wait, 5.0)) == 0
            print("[PASS] All-in-one `--stdio --port 0` embedded server verified")
        finally:
            if emb_proc.poll() is None:
                emb_proc.terminate()
                emb_proc.wait(timeout=5.0)

        # 8. Independent WHATWG WebSocket client interoperability check via Node v24
        node_port_file = os.path.join(tmp, "node_interop.port")
        node_daemon = subprocess.Popen(
            [
                sys.executable,
                SERVER_SCRIPT,
                "--port",
                "0",
                "--static-dir",
                static_dir,
                "--port-file",
                node_port_file,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            nport = await wait_for_port_file(node_port_file)
            node_js = f"""
const ws = new WebSocket('ws://127.0.0.1:{nport}/mcp-ws');
ws.onopen = () => {{
  ws.send(JSON.stringify({{
    jsonrpc: '2.0',
    method: 'webmcp/hello',
    params: {{
      sessionId: 'node-tab',
      url: 'http://127.0.0.1:{nport}/?s=node-tab&mcp=1',
      tools: [{{ name: 'dartpad_get_status', description: 'ok', inputSchema: {{ type: 'object', properties: {{}} }} }}]
    }}
  }}));
}};
ws.onmessage = (ev) => {{
  const msg = JSON.parse(ev.data);
  if (msg.method === 'tools/call') {{
    ws.send(JSON.stringify({{
      jsonrpc: '2.0',
      id: msg.id,
      result: {{
        content: [{{ type: 'text', text: '{{"browser":"whatwg-ws"}}' }}],
        structuredContent: {{ browser: 'whatwg-ws' }},
        isError: false
      }}
    }}));
    setTimeout(() => ws.close(), 50);
  }}
}};
"""
            node_client = subprocess.Popen(
                ["node", "-e", node_js],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                _, n_resp = await asyncio.to_thread(
                    http_post_json,
                    f"http://127.0.0.1:{nport}/mcp",
                    {
                        "jsonrpc": "2.0",
                        "id": "w1",
                        "method": "tools/call",
                        "params": {"name": "dartpad_get_status", "arguments": {}},
                    },
                )
                assert n_resp["result"]["structuredContent"]["browser"] == "whatwg-ws"
                assert (await asyncio.to_thread(node_client.wait, 5.0)) == 0
                print("[PASS] Independent WHATWG WebSocket (Node v24) interop verified")
            finally:
                if node_client.poll() is None:
                    node_client.kill()
                    node_client.wait()
        finally:
            node_daemon.terminate()
            node_daemon.wait(timeout=5.0)

    print("\nALL 8 BRIDGE SELF-TEST SUITES PASSED!")


if __name__ == "__main__":
    asyncio.run(run_tests())
