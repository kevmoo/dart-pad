#!/usr/bin/env python3
"""Zero-dependency Local MCP Server & Static/WebSocket Relay Bridge for DartPad Preview.

Supports:
1. Dual-stack (IPv6 `::` + IPv4 `127.0.0.1`) HTTP/1.1 static server for DartPad's
   `build/jaspr` bundle, with accurate MIME types (`.wasm`, `.mjs`, `.tar.gz` raw
   bytes without transparent Content-Encoding corruption, `.dill`, fonts, etc.).
2. RFC 6455 WebSocket server on `GET /mcp-ws` accepting outbound WebMCP browser tab
   connections (`webmcp/hello`, `tools/list`, `tools/call`), supporting multi-tab
   routing via optional `sessionId` (defaulting to most recently active tab),
   20s cold-start connection wait, and cached `tools/list` across reloads.
3. Health status endpoint on `GET /healthz`.
4. MCP Streamable HTTP JSON-RPC 2.0 endpoint on `POST /mcp`.
5. Standard MCP `stdio` JSON-RPC 2.0 mode (`--stdio`), either forwarding to an
   already-running daemon (`--connect-http http://127.0.0.1:<PORT>/mcp`) or hosting
   its own HTTP + `/mcp-ws` listener in-process (`--port 0` / `--port <PORT>`).
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import copy
import email.parser
import hashlib
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
DEFAULT_STATIC_DIR = os.path.normpath(
    os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..",
        "dartpad_frontend",
        "build",
        "jaspr",
    )
)
SUPPORTED_MCP_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
SERVER_INFO = {
    "name": "dartpad-webmcp-bridge",
    "version": "0.1.0",
}
SERVER_INSTRUCTIONS = (
    "Controls a live DartPad Preview browser tab (Flutter/Dart compiler, LSP "
    "analyzer, pub, hot reload, console/error logs, and VM Service widget tree "
    "inspector) via WebMCP."
)

# Exact MIME types required by DartPad Preview + WebAssembly + Jaspr assets.
# IMPORTANT: `.tar.gz` / `.tgz` MUST be served as `application/gzip` WITHOUT a
# `Content-Encoding: gzip` header so browser `fetch()` hands raw gzip bytes to
# DartPad's JS `DecompressionStream('gzip')`.
MIME_TYPES: dict[str, str] = {
    ".html": "text/html; charset=utf-8",
    ".htm": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".cjs": "text/javascript; charset=utf-8",
    ".wasm": "application/wasm",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".map": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".ico": "image/x-icon",
    ".ttf": "font/ttf",
    ".otf": "font/otf",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".tar.gz": "application/gzip",
    ".tgz": "application/gzip",
    ".gz": "application/gzip",
    ".tar": "application/x-tar",
    ".dill": "application/octet-stream",
    ".bin": "application/octet-stream",
    ".frag": "application/octet-stream",
    ".dart": "text/plain; charset=utf-8",
    ".yaml": "text/plain; charset=utf-8",
    ".yml": "text/plain; charset=utf-8",
    ".md": "text/markdown; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
}

SPA_ASSET_PREFIXES = ("/assets/", "/dartpad/", "/examples/", "/packages/", "/canvaskit/")

NO_PROXY_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def log_err(msg: str) -> None:
    """Writes diagnostic output strictly to stderr so stdout stays pure JSON-RPC."""
    ts = time.strftime("%H:%M:%S")
    sys.stderr.write(f"[dartpad-mcp {ts}] {msg}\n")
    sys.stderr.flush()


def guess_content_type(path: str) -> str:
    lower = path.lower()
    if lower.endswith(".tar.gz"):
        return MIME_TYPES[".tar.gz"]
    _, ext = os.path.splitext(lower)
    return MIME_TYPES.get(ext, "application/octet-stream")


def xor_mask(data: bytes, mask: bytes) -> bytes:
    """Fast C-accelerated RFC 6455 payload masking/unmasking in pure Python stdlib."""
    if not data:
        return data
    n = len(data)
    full_mask = (mask * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(full_mask, "big")).to_bytes(
        n, "big"
    )


class WebSocketConnection:
    """Async RFC 6455 WebSocket stream wrapper supporting large & fragmented frames."""

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        *,
        is_client: bool = False,
    ) -> None:
        self.reader = reader
        self.writer = writer
        self.is_client = is_client
        self._write_lock = asyncio.Lock()
        self.closed = False

    async def send_frame(self, opcode: int, payload: bytes = b"") -> None:
        if self.closed:
            raise ConnectionError("WebSocket is closed")
        b0 = 0x80 | (opcode & 0x0F)
        mask_bit = 0x80 if self.is_client else 0x00
        n = len(payload)
        if n < 126:
            header = bytes([b0, mask_bit | n])
        elif n < 65536:
            header = bytes([b0, mask_bit | 126]) + struct.pack("!H", n)
        else:
            header = bytes([b0, mask_bit | 127]) + struct.pack("!Q", n)

        async with self._write_lock:
            if self.closed:
                raise ConnectionError("WebSocket is closed")
            if self.is_client:
                mask = os.urandom(4)
                self.writer.write(header + mask + xor_mask(payload, mask))
            else:
                self.writer.write(header + payload)
            await self.writer.drain()

    async def send_text(self, text: str) -> None:
        await self.send_frame(0x1, text.encode("utf-8"))

    async def send_json(self, obj: Any) -> None:
        await self.send_text(json.dumps(obj, separators=(",", ":")))

    async def close(self, code: int = 1000, reason: str = "") -> None:
        if self.closed:
            return
        try:
            payload = struct.pack("!H", code) + reason.encode("utf-8")[:123]
            await self.send_frame(0x8, payload)
        except Exception:
            pass
        finally:
            self.closed = True
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass

    async def recv_message(self) -> str | bytes | None:
        """Reads a complete (possibly fragmented) message while handling PING/PONG/CLOSE."""
        fragments: list[bytes] = []
        msg_opcode: int | None = None

        while True:
            try:
                head = await self.reader.readexactly(2)
            except (asyncio.IncompleteReadError, ConnectionError, OSError):
                self.closed = True
                return None

            b0, b1 = head[0], head[1]
            fin = (b0 & 0x80) != 0
            opcode = b0 & 0x0F
            masked = (b1 & 0x80) != 0
            length = b1 & 0x7F

            try:
                if length == 126:
                    ext = await self.reader.readexactly(2)
                    length = struct.unpack("!H", ext)[0]
                elif length == 127:
                    ext = await self.reader.readexactly(8)
                    length = struct.unpack("!Q", ext)[0]

                mask_key = await self.reader.readexactly(4) if masked else b""
                payload = await self.reader.readexactly(length) if length > 0 else b""
            except (asyncio.IncompleteReadError, ConnectionError, OSError):
                self.closed = True
                return None

            if masked:
                payload = xor_mask(payload, mask_key)

            if opcode == 0x8:  # CLOSE
                await self.close()
                return None
            if opcode == 0x9:  # PING
                try:
                    await self.send_frame(0xA, payload)
                except Exception:
                    return None
                continue
            if opcode == 0xA:  # PONG
                continue

            if opcode in (0x1, 0x2):
                msg_opcode = opcode
                fragments = [payload]
                if fin:
                    raw = b"".join(fragments)
                    return raw.decode("utf-8", errors="replace") if msg_opcode == 0x1 else raw
            elif opcode == 0x0:
                if msg_opcode is None:
                    continue
                fragments.append(payload)
                if fin:
                    raw = b"".join(fragments)
                    return raw.decode("utf-8", errors="replace") if msg_opcode == 0x1 else raw


@dataclass
class BrowserTabSession:
    conn_id: int
    ws: WebSocketConnection
    peer: str
    session_id: str = ""
    url: str = ""
    tools: list[dict[str, Any]] = field(default_factory=list)
    native_session_id_props: set[str] = field(default_factory=set)
    connected_at: float = field(default_factory=time.time)
    last_active_at: float = field(default_factory=time.time)
    ready: bool = False
    pending_requests: dict[str, asyncio.Future[dict[str, Any]]] = field(
        default_factory=dict
    )

    def touch(self) -> None:
        self.last_active_at = time.time()


def _extract_session_id_from_url(url: str, fallback: str) -> str:
    if url:
        try:
            parsed = urllib.parse.urlsplit(url)
            qs = urllib.parse.parse_qs(parsed.query)
            if "s" in qs and qs["s"]:
                return str(qs["s"][0])
        except Exception:
            pass
    return fallback


def _augment_tools_for_mcp(
    raw_tools: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], set[str]]:
    """Normalizes tool schemas and exposes optional `sessionId` for multi-tab routing."""
    normalized: list[dict[str, Any]] = []
    native_sid_tools: set[str] = set()

    for t in raw_tools:
        if not isinstance(t, dict) or not t.get("name"):
            continue
        item = copy.deepcopy(t)
        name = str(item["name"])
        item.setdefault("description", "")
        schema = item.get("inputSchema")
        if not isinstance(schema, dict):
            schema = {"type": "object", "properties": {}}
            item["inputSchema"] = schema
        schema.setdefault("type", "object")
        props = schema.get("properties")
        if not isinstance(props, dict):
            props = {}
            schema["properties"] = props
        if "sessionId" in props:
            native_sid_tools.add(name)
        else:
            props["sessionId"] = {
                "type": "string",
                "description": (
                    "Optional DartPad tab sessionId to target when multiple tabs are "
                    "connected (defaults to the most recently active tab)."
                ),
            }
        normalized.append(item)
    return normalized, native_sid_tools


class BridgeHub:
    """Coordinates connected DartPad WebMCP browser tabs and MCP JSON-RPC requests."""

    def __init__(
        self,
        *,
        static_dir: str,
        wait_timeout: float = 20.0,
        call_timeout: float = 120.0,
    ) -> None:
        self.static_dir = static_dir
        self.wait_timeout = wait_timeout
        self.call_timeout = call_timeout
        self.bound_port: int = 0
        self._next_conn_id = 0
        self._next_rpc_seq = 0
        self._tabs: dict[int, BrowserTabSession] = {}
        self._cached_tools: list[dict[str, Any]] = []
        self._tab_cond = asyncio.Condition()

    def register_ws(self, ws: WebSocketConnection, peer: str) -> BrowserTabSession:
        self._next_conn_id += 1
        tab = BrowserTabSession(conn_id=self._next_conn_id, ws=ws, peer=peer)
        self._tabs[tab.conn_id] = tab
        return tab

    async def unregister_ws(self, tab: BrowserTabSession) -> None:
        self._tabs.pop(tab.conn_id, None)
        err = ConnectionError(
            f"Browser tab (sessionId={tab.session_id or 'unknown'}) disconnected"
        )
        for fut in list(tab.pending_requests.values()):
            if not fut.done():
                fut.set_exception(err)
        tab.pending_requests.clear()
        async with self._tab_cond:
            self._tab_cond.notify_all()

    async def handle_ws_connection(self, ws: WebSocketConnection, peer: str) -> None:
        tab = self.register_ws(ws, peer)
        log_err(f"WS connected: conn={tab.conn_id} peer={peer}")
        try:
            while True:
                msg = await ws.recv_message()
                if msg is None:
                    break
                if isinstance(msg, bytes):
                    msg = msg.decode("utf-8", errors="replace")
                try:
                    data = json.loads(msg)
                except json.JSONDecodeError as exc:
                    log_err(f"Invalid JSON from tab conn={tab.conn_id}: {exc}")
                    continue
                if not isinstance(data, dict):
                    continue
                await self._on_tab_message(tab, data)
        finally:
            await self.unregister_ws(tab)
            await ws.close()
            log_err(
                f"WS disconnected: conn={tab.conn_id} sessionId={tab.session_id or '-'}"
            )

    async def _on_tab_message(
        self, tab: BrowserTabSession, data: dict[str, Any]
    ) -> None:
        method = data.get("method")
        if method in ("webmcp/hello", "webmcp/toolsChanged"):
            params = data.get("params") if isinstance(data.get("params"), dict) else {}
            url = str(params.get("url") or tab.url or "")
            raw_sid = params.get("sessionId")
            if raw_sid is not None and str(raw_sid) != "":
                sid = str(raw_sid)
            else:
                sid = _extract_session_id_from_url(url, f"tab-{tab.conn_id}")
            raw_tools = params.get("tools")
            if isinstance(raw_tools, list):
                tools, native_sid = _augment_tools_for_mcp(raw_tools)
                tab.tools = tools
                tab.native_session_id_props = native_sid
                if tools:
                    self._cached_tools = copy.deepcopy(tools)
            tab.session_id = sid
            tab.url = url
            tab.ready = True
            tab.touch()
            log_err(
                f"Tab ready: conn={tab.conn_id} sessionId={tab.session_id!r} "
                f"tools={len(tab.tools)} url={tab.url}"
            )
            if "id" in data and data["id"] is not None:
                await tab.ws.send_json(
                    {"jsonrpc": "2.0", "id": data["id"], "result": {"ok": True}}
                )
            async with self._tab_cond:
                self._tab_cond.notify_all()
            return

        if method == "ping" and "id" in data:
            tab.touch()
            await tab.ws.send_json({"jsonrpc": "2.0", "id": data["id"], "result": {}})
            return

        if "id" in data and ("result" in data or "error" in data):
            req_id = str(data["id"])
            tab.touch()
            fut = tab.pending_requests.pop(req_id, None)
            if fut is not None and not fut.done():
                fut.set_result(data)

    def ready_tabs_sorted(self) -> list[BrowserTabSession]:
        tabs = [t for t in self._tabs.values() if t.ready and not t.ws.closed]
        tabs.sort(key=lambda t: (t.last_active_at, t.conn_id), reverse=True)
        return tabs

    def select_tab(self, session_id: str | None = None) -> BrowserTabSession | None:
        ready = self.ready_tabs_sorted()
        if not ready:
            return None
        if session_id is not None and str(session_id) != "":
            target = str(session_id)
            for t in ready:
                if t.session_id == target:
                    return t
            return None
        return ready[0]

    async def wait_for_tab(
        self, session_id: str | None = None, timeout: float | None = None
    ) -> BrowserTabSession | None:
        tab = self.select_tab(session_id)
        if tab is not None:
            return tab
        wait_s = self.wait_timeout if timeout is None else timeout
        if wait_s <= 0:
            return None
        deadline = time.monotonic() + wait_s
        async with self._tab_cond:
            while True:
                tab = self.select_tab(session_id)
                if tab is not None:
                    return tab
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                try:
                    await asyncio.wait_for(self._tab_cond.wait(), timeout=remaining)
                except asyncio.TimeoutError:
                    return self.select_tab(session_id)

    async def send_tab_rpc(
        self,
        tab: BrowserTabSession,
        method: str,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        self._next_rpc_seq += 1
        rpc_id = f"req-{self._next_rpc_seq}"
        loop = asyncio.get_running_loop()
        fut: asyncio.Future[dict[str, Any]] = loop.create_future()
        tab.pending_requests[rpc_id] = fut
        tab.touch()

        payload: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": rpc_id,
            "method": method,
        }
        if params is not None:
            payload["params"] = params

        try:
            await tab.ws.send_json(payload)
            return await asyncio.wait_for(fut, timeout=self.call_timeout)
        finally:
            tab.pending_requests.pop(rpc_id, None)

    def health_snapshot(self) -> dict[str, Any]:
        tabs = self.ready_tabs_sorted()
        active_tool_count = (
            len(tabs[0].tools) if tabs else len(self._cached_tools)
        )
        return {
            "ok": True,
            "port": self.bound_port,
            "staticDir": self.static_dir,
            "staticDirExists": os.path.isdir(self.static_dir),
            "connectedTabs": [
                {
                    "connId": t.conn_id,
                    "sessionId": t.session_id,
                    "url": t.url,
                    "toolCount": len(t.tools),
                    "connectedAt": round(t.connected_at, 3),
                    "lastActiveAt": round(t.last_active_at, 3),
                    "isActiveDefault": idx == 0,
                }
                for idx, t in enumerate(tabs)
            ],
            "toolCount": active_tool_count,
            "cachedToolCount": len(self._cached_tools),
        }

    async def handle_mcp_payload(self, payload: Any) -> Any | None:
        """Handles single or batch MCP JSON-RPC 2.0 messages."""
        if isinstance(payload, list):
            if not payload:
                return {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32600, "message": "Empty JSON-RPC batch"},
                }
            results = await asyncio.gather(
                *(self._handle_single_mcp(item) for item in payload)
            )
            responses = [r for r in results if r is not None]
            return responses if responses else None
        return await self._handle_single_mcp(payload)

    async def _handle_single_mcp(self, req: Any) -> dict[str, Any] | None:
        if not isinstance(req, dict):
            return {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32600, "message": "Invalid JSON-RPC message"},
            }

        has_id = "id" in req
        req_id = req.get("id")
        method = req.get("method")

        # JSON-RPC notifications (no `id`) or responses produce no response message.
        if not has_id:
            return None

        if not isinstance(method, str):
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32600, "message": "Missing JSON-RPC method"},
            }

        params = req.get("params") if isinstance(req.get("params"), dict) else {}

        if method == "initialize":
            client_ver = str(params.get("protocolVersion") or "")
            negotiated = (
                client_ver
                if client_ver in SUPPORTED_MCP_VERSIONS
                else SUPPORTED_MCP_VERSIONS[1]
            )
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": negotiated,
                    "capabilities": {
                        "tools": {"listChanged": False},
                    },
                    "serverInfo": SERVER_INFO,
                    "instructions": SERVER_INSTRUCTIONS,
                },
            }

        if method == "ping":
            return {"jsonrpc": "2.0", "id": req_id, "result": {}}

        if method == "resources/list":
            return {"jsonrpc": "2.0", "id": req_id, "result": {"resources": []}}

        if method == "prompts/list":
            return {"jsonrpc": "2.0", "id": req_id, "result": {"prompts": []}}

        if method == "tools/list":
            return await self._handle_tools_list(req_id, params)

        if method == "tools/call":
            return await self._handle_tools_call(req_id, params)

        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }

    async def _handle_tools_list(
        self, req_id: Any, params: dict[str, Any]
    ) -> dict[str, Any]:
        requested_sid = params.get("sessionId")
        tab = self.select_tab(requested_sid)

        if tab is None:
            # During a page reload, respond immediately from cached tools if already seen.
            if self._cached_tools and requested_sid is None:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"tools": copy.deepcopy(self._cached_tools)},
                }
            # On cold start before any tab has connected, wait up to wait_timeout (20s).
            tab = await self.wait_for_tab(requested_sid)

        if tab is not None:
            try:
                ws_resp = await self.send_tab_rpc(tab, "tools/list", {})
                if "result" in ws_resp and isinstance(ws_resp["result"], dict):
                    raw_tools = ws_resp["result"].get("tools")
                    if isinstance(raw_tools, list):
                        tools, native_sid = _augment_tools_for_mcp(raw_tools)
                        tab.tools = tools
                        tab.native_session_id_props = native_sid
                        if tools:
                            self._cached_tools = copy.deepcopy(tools)
                        return {
                            "jsonrpc": "2.0",
                            "id": req_id,
                            "result": {"tools": tools},
                        }
            except Exception as exc:
                log_err(f"tools/list WS round-trip fallback ({exc})")
                if tab.tools:
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"tools": copy.deepcopy(tab.tools)},
                    }

        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": copy.deepcopy(self._cached_tools)},
        }

    async def _handle_tools_call(
        self, req_id: Any, params: dict[str, Any]
    ) -> dict[str, Any]:
        name = params.get("name")
        if not isinstance(name, str) or not name:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {
                    "code": -32602,
                    "message": "Invalid params: tools/call requires non-empty 'name'",
                },
            }

        raw_args = params.get("arguments")
        if raw_args is None:
            args: dict[str, Any] = {}
        elif isinstance(raw_args, dict):
            args = copy.deepcopy(raw_args)
        else:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {
                    "code": -32602,
                    "message": "Invalid params: 'arguments' must be an object",
                },
            }

        raw_sid = args.get("sessionId")
        if raw_sid is None:
            raw_sid = params.get("sessionId")
        requested_sid = str(raw_sid).strip() if raw_sid is not None else ""
        tab = await self.wait_for_tab(requested_sid if requested_sid else None)
        if tab is None:
            hint_url = (
                f"http://127.0.0.1:{self.bound_port}/?s=3&mcp=1"
                if self.bound_port
                else "the DartPad Preview tab with ?mcp=1"
            )
            sid_msg = f" (sessionId={requested_sid!r})" if requested_sid else ""
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                f"No connected DartPad browser tab{sid_msg} after "
                                f"waiting {self.wait_timeout:.1f}s. Open {hint_url} in Chrome."
                            ),
                        }
                    ],
                    "isError": True,
                },
            }

        if "sessionId" in args and name not in tab.native_session_id_props:
            args.pop("sessionId", None)

        try:
            ws_resp = await self.send_tab_rpc(
                tab, "tools/call", {"name": name, "arguments": args}
            )
        except asyncio.TimeoutError:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                f"Timed out after {self.call_timeout:.1f}s waiting for "
                                f"browser tool '{name}'."
                            ),
                        }
                    ],
                    "isError": True,
                },
            }
        except Exception as exc:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": f"Browser tab transport error calling '{name}': {exc}",
                        }
                    ],
                    "isError": True,
                },
            }

        if "error" in ws_resp and isinstance(ws_resp["error"], dict):
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": ws_resp["error"],
            }

        res = ws_resp.get("result")
        if isinstance(res, dict) and isinstance(res.get("content"), list):
            return {"jsonrpc": "2.0", "id": req_id, "result": res}

        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(res) if not isinstance(res, str) else res,
                    }
                ],
                "structuredContent": res if isinstance(res, dict) else {"value": res},
                "isError": False,
            },
        }


HTTP_STATUS_TEXT = {
    101: "Switching Protocols",
    200: "OK",
    202: "Accepted",
    204: "No Content",
    400: "Bad Request",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    500: "Internal Server Error",
}

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, HEAD, POST, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Accept, Mcp-Session-Id, Last-Event-ID",
    "Access-Control-Allow-Private-Network": "true",
}


async def _read_chunked_body(reader: asyncio.StreamReader) -> bytes:
    chunks: list[bytes] = []
    while True:
        size_line = await reader.readline()
        if not size_line:
            break
        size_str = size_line.split(b";", 1)[0].strip()
        size = int(size_str, 16)
        if size == 0:
            # Consume trailing CRLF after final 0 chunk.
            while True:
                trailer = await reader.readline()
                if trailer in (b"\r\n", b"\n", b""):
                    break
            break
        chunks.append(await reader.readexactly(size))
        await reader.readexactly(2)  # trailing CRLF
    return b"".join(chunks)


async def _write_http_response(
    writer: asyncio.StreamWriter,
    status: int,
    headers: dict[str, str],
    body: bytes = b"",
    *,
    head_only: bool = False,
) -> None:
    reason = HTTP_STATUS_TEXT.get(status, "OK")
    merged = dict(CORS_HEADERS)
    merged.update(headers)
    merged.setdefault("Content-Length", str(len(body)))
    lines = [f"HTTP/1.1 {status} {reason}\r\n"]
    for k, v in merged.items():
        lines.append(f"{k}: {v}\r\n")
    lines.append("\r\n")
    writer.write("".join(lines).encode("latin-1"))
    if body and not head_only:
        writer.write(body)
    await writer.drain()


def _resolve_static_file(static_dir: str, url_path: str) -> str | None:
    root_real = os.path.realpath(static_dir)
    if not os.path.isdir(root_real):
        return None

    clean_path = urllib.parse.unquote(url_path)
    rel = clean_path.lstrip("/")
    candidate = os.path.realpath(os.path.join(root_real, rel))

    if candidate != root_real and not candidate.startswith(root_real + os.sep):
        return None

    if os.path.isdir(candidate):
        idx = os.path.join(candidate, "index.html")
        if os.path.isfile(idx):
            return idx

    if os.path.isfile(candidate):
        return candidate

    # SPA fallback to index.html for client-side routes (never for asset paths or files with extensions).
    if not any(clean_path.startswith(p) for p in SPA_ASSET_PREFIXES):
        _, ext = os.path.splitext(clean_path)
        if not ext:
            idx = os.path.join(root_real, "index.html")
            if os.path.isfile(idx):
                return idx

    return None


async def handle_tcp_client(
    hub: BridgeHub,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> None:
    peername = writer.get_extra_info("peername")
    peer_str = str(peername)
    try:
        while True:
            try:
                raw_head = await asyncio.wait_for(
                    reader.readuntil(b"\r\n\r\n"), timeout=65.0
                )
            except (
                asyncio.TimeoutError,
                asyncio.IncompleteReadError,
                ConnectionError,
                OSError,
            ):
                break

            head_text = raw_head.decode("latin-1")
            request_line, _, header_block = head_text.partition("\r\n")
            parts = request_line.split(" ")
            if len(parts) < 3:
                await _write_http_response(
                    writer,
                    400,
                    {"Content-Type": "text/plain; charset=utf-8", "Connection": "close"},
                    b"Bad Request",
                )
                break

            method, raw_target, http_version = parts[0].upper(), parts[1], parts[2].upper()
            headers = email.parser.HeaderParser().parsestr(header_block)
            conn_hdr = (headers.get("Connection") or "").lower()
            keep_alive = (
                conn_hdr != "close"
                if http_version == "HTTP/1.1"
                else conn_hdr == "keep-alive"
            )
            conn_resp_val = "keep-alive" if keep_alive else "close"

            parsed_target = urllib.parse.urlsplit(raw_target)
            path = parsed_target.path or "/"
            norm_path = path.rstrip("/") or "/"

            # 1. RFC 6455 WebSocket Upgrade on GET /mcp-ws
            upgrade_hdr = (headers.get("Upgrade") or "").lower()
            if method == "GET" and norm_path == "/mcp-ws" and "websocket" in upgrade_hdr:
                ws_key = (headers.get("Sec-WebSocket-Key") or "").strip()
                if not ws_key:
                    await _write_http_response(
                        writer,
                        400,
                        {"Content-Type": "text/plain; charset=utf-8", "Connection": "close"},
                        b"Missing Sec-WebSocket-Key",
                    )
                    break
                accept_val = base64.b64encode(
                    hashlib.sha1((ws_key + WS_GUID).encode("ascii")).digest()
                ).decode("ascii")
                handshake = (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept_val}\r\n"
                )
                proto = headers.get("Sec-WebSocket-Protocol")
                if proto:
                    first_proto = proto.split(",")[0].strip()
                    if first_proto:
                        handshake += f"Sec-WebSocket-Protocol: {first_proto}\r\n"
                handshake += "\r\n"
                writer.write(handshake.encode("latin-1"))
                await writer.drain()

                ws = WebSocketConnection(reader, writer, is_client=False)
                await hub.handle_ws_connection(ws, peer_str)
                return

            # Read HTTP request body if present.
            te = (headers.get("Transfer-Encoding") or "").lower()
            cl_str = headers.get("Content-Length")
            body = b""
            if "chunked" in te:
                body = await _read_chunked_body(reader)
            elif cl_str:
                cl = int(cl_str)
                if cl > 0:
                    body = await reader.readexactly(cl)

            # 2. CORS Preflight
            if method == "OPTIONS":
                await _write_http_response(
                    writer, 204, {"Connection": conn_resp_val}, b""
                )
                if not keep_alive:
                    break
                continue

            # 3. GET /healthz
            if norm_path == "/healthz" and method in ("GET", "HEAD"):
                payload_bytes = json.dumps(hub.health_snapshot()).encode("utf-8")
                await _write_http_response(
                    writer,
                    200,
                    {
                        "Content-Type": "application/json; charset=utf-8",
                        "Cache-Control": "no-store",
                        "Connection": conn_resp_val,
                    },
                    payload_bytes,
                    head_only=(method == "HEAD"),
                )
                if not keep_alive:
                    break
                continue

            # 4. MCP Streamable HTTP endpoint (`/mcp`)
            if norm_path == "/mcp":
                if method == "POST":
                    try:
                        req_json = json.loads(body.decode("utf-8"))
                    except Exception as exc:
                        err_resp = json.dumps(
                            {
                                "jsonrpc": "2.0",
                                "id": None,
                                "error": {
                                    "code": -32700,
                                    "message": f"Parse error: {exc}",
                                },
                            }
                        ).encode("utf-8")
                        await _write_http_response(
                            writer,
                            400,
                            {
                                "Content-Type": "application/json; charset=utf-8",
                                "Connection": conn_resp_val,
                            },
                            err_resp,
                        )
                        if not keep_alive:
                            break
                        continue

                    mcp_resp = await hub.handle_mcp_payload(req_json)
                    if mcp_resp is None:
                        await _write_http_response(
                            writer,
                            202,
                            {"Connection": conn_resp_val},
                            b"",
                        )
                    else:
                        resp_bytes = json.dumps(mcp_resp).encode("utf-8")
                        await _write_http_response(
                            writer,
                            200,
                            {
                                "Content-Type": "application/json; charset=utf-8",
                                "Cache-Control": "no-store",
                                "Connection": conn_resp_val,
                            },
                            resp_bytes,
                        )
                    if not keep_alive:
                        break
                    continue

                if method == "DELETE":
                    await _write_http_response(
                        writer, 200, {"Connection": conn_resp_val}, b""
                    )
                    if not keep_alive:
                        break
                    continue

                # Per MCP Streamable HTTP spec, 405 on GET /mcp tells clients this
                # server returns synchronous JSON on POST /mcp without needing an SSE GET stream.
                await _write_http_response(
                    writer,
                    405,
                    {
                        "Allow": "POST, DELETE, OPTIONS",
                        "Content-Type": "text/plain; charset=utf-8",
                        "Connection": conn_resp_val,
                    },
                    b"Method Not Allowed",
                    head_only=(method == "HEAD"),
                )
                if not keep_alive:
                    break
                continue

            # 5. Static file serving from `--static-dir`
            if method not in ("GET", "HEAD"):
                await _write_http_response(
                    writer,
                    405,
                    {
                        "Allow": "GET, HEAD, OPTIONS",
                        "Content-Type": "text/plain; charset=utf-8",
                        "Connection": conn_resp_val,
                    },
                    b"Method Not Allowed",
                )
                if not keep_alive:
                    break
                continue

            file_path = _resolve_static_file(hub.static_dir, path)
            if file_path is None:
                not_found = json.dumps(
                    {"error": "Not Found", "path": path, "staticDir": hub.static_dir}
                ).encode("utf-8")
                await _write_http_response(
                    writer,
                    404,
                    {
                        "Content-Type": "application/json; charset=utf-8",
                        "Cache-Control": "no-store",
                        "Connection": conn_resp_val,
                    },
                    not_found,
                    head_only=(method == "HEAD"),
                )
                if not keep_alive:
                    break
                continue

            st = os.stat(file_path)
            content_type = guess_content_type(file_path)
            resp_headers = {
                "Content-Type": content_type,
                "Content-Length": str(st.st_size),
                "Cache-Control": "max-age=0, must-revalidate",
                "Connection": conn_resp_val,
            }
            await _write_http_response(
                writer, 200, resp_headers, b"", head_only=True
            )
            if method == "GET" and st.st_size > 0:
                with open(file_path, "rb") as fh:
                    while True:
                        chunk = fh.read(262144)
                        if not chunk:
                            break
                        writer.write(chunk)
                        await writer.drain()

            if not keep_alive:
                break
    except (ConnectionError, OSError):
        pass
    except Exception as exc:
        log_err(f"HTTP connection error from {peer_str}: {exc}")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


def create_dual_stack_socket(host: str, port: int) -> socket.socket:
    """Creates a dual-stack IPv6+IPv4 socket bound to `::` (or specific host)."""
    if host in ("::", ""):
        try:
            sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            sock.bind(("::", port))
            return sock
        except OSError as exc:
            log_err(f"Dual-stack IPv6 bind fallback to 0.0.0.0 ({exc})")
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("0.0.0.0", port))
            return sock

    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    af, socktype, proto, _, sa = infos[0]
    sock = socket.socket(af, socktype, proto)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if af == socket.AF_INET6:
        try:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
    sock.bind(sa)
    return sock


def normalize_connect_http_url(url: str) -> str:
    raw = url.strip()
    if "://" not in raw:
        raw = f"http://{raw}"
    parsed = urllib.parse.urlsplit(raw)
    path = parsed.path or "/mcp"
    if path == "/":
        path = "/mcp"
    return urllib.parse.urlunsplit(
        (parsed.scheme or "http", parsed.netloc, path, parsed.query, "")
    )


def _resolve_client_urls(args: argparse.Namespace) -> tuple[str, str]:
    port = args.port if args.port is not None else 8787
    mcp_url = normalize_connect_http_url(
        args.connect_http or f"http://127.0.0.1:{port}/mcp"
    )
    parsed = urllib.parse.urlsplit(mcp_url)
    health_url = urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, "/healthz", "", "")
    )
    return mcp_url, health_url


def _fetch_health_sync(health_url: str, timeout: float = 1.5) -> dict[str, Any] | None:
    req = urllib.request.Request(
        health_url,
        headers={"Accept": "application/json"},
        method="GET",
    )
    try:
        with NO_PROXY_OPENER.open(req, timeout=timeout) as resp:
            if resp.status != 200:
                return None
            data = json.loads(resp.read().decode("utf-8"))
            if isinstance(data, dict) and data.get("ok") is True:
                return data
    except Exception:
        return None
    return None


def _post_mcp_http_sync(
    url: str,
    payload: Any,
    timeout: float,
    *,
    retry_connect: bool = True,
) -> Any | None:
    body = json.dumps(payload).encode("utf-8")
    deadline = time.monotonic() + (5.0 if retry_connect else 0.0)
    attempt = 0

    while True:
        attempt += 1
        req = urllib.request.Request(
            url,
            data=body,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
            method="POST",
        )
        try:
            with NO_PROXY_OPENER.open(req, timeout=timeout) as resp:
                status = resp.status
                raw = resp.read()
                if status == 202 or not raw.strip():
                    return None
                return json.loads(raw.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            if raw:
                try:
                    return json.loads(raw.decode("utf-8"))
                except Exception:
                    pass
            raise RuntimeError(f"HTTP {exc.code} from {url}: {raw.decode('utf-8', 'replace')}") from exc
        except urllib.error.URLError as exc:
            # Brief retry window if the daemon is still binding right at startup.
            if retry_connect and time.monotonic() < deadline and attempt < 15:
                time.sleep(0.15)
                continue
            raise RuntimeError(f"Cannot reach DartPad MCP bridge at {url}: {exc}") from exc


def _maybe_open_browser(url: str) -> None:
    candidates = [
        os.environ.get("CHROME_BIN") or "",
        "/usr/bin/google-chrome",
        shutil.which("google-chrome") or "",
        shutil.which("chromium") or "",
        shutil.which("xdg-open") or "",
        shutil.which("open") or "",
    ]
    for binary in candidates:
        if binary and os.path.isfile(binary) and os.access(binary, os.X_OK):
            log_err(f"Launching browser: {binary} {url}")
            subprocess.Popen(
                [binary, url],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return
    log_err(f"No browser launcher found; open {url} manually.")


async def run_stdio_loop(
    handler_fn,
    *,
    stop_event: asyncio.Event,
) -> None:
    """Reads MCP JSON-RPC 2.0 messages from stdin and writes pure JSON-RPC lines to stdout."""
    loop = asyncio.get_running_loop()
    msg_queue: asyncio.Queue[bytes | None] = asyncio.Queue()
    stdout_lock = threading.Lock()

    def stdin_reader() -> None:
        buf = sys.stdin.buffer
        try:
            while True:
                line = buf.readline()
                if not line:
                    break
                # Support optional LSP-style Content-Length framing in addition to
                # standard MCP newline-delimited JSON-RPC.
                if line.lower().startswith(b"content-length:"):
                    cl = int(line.split(b":", 1)[1].strip())
                    while True:
                        hdr = buf.readline()
                        if hdr in (b"\r\n", b"\n", b""):
                            break
                    payload_bytes = buf.read(cl)
                    if not payload_bytes:
                        break
                    loop.call_soon_threadsafe(msg_queue.put_nowait, payload_bytes)
                else:
                    stripped = line.strip()
                    if stripped:
                        loop.call_soon_threadsafe(msg_queue.put_nowait, stripped)
        except Exception as exc:
            log_err(f"stdin reader error: {exc}")
        finally:
            loop.call_soon_threadsafe(msg_queue.put_nowait, None)

    threading.Thread(target=stdin_reader, name="mcp-stdin", daemon=True).start()

    def write_stdout(obj: Any) -> None:
        encoded = (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")
        with stdout_lock:
            sys.stdout.buffer.write(encoded)
            sys.stdout.buffer.flush()

    in_flight: set[asyncio.Task[None]] = set()

    async def process_one(raw_bytes: bytes) -> None:
        try:
            msg = json.loads(raw_bytes.decode("utf-8"))
        except Exception as exc:
            write_stdout(
                {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32700, "message": f"Parse error: {exc}"},
                }
            )
            return

        try:
            resp = await handler_fn(msg)
        except Exception as exc:
            req_id = msg.get("id") if isinstance(msg, dict) else None
            if isinstance(msg, dict) and "id" not in msg:
                return
            resp = {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32603, "message": f"Internal error: {exc}"},
            }

        if resp is not None:
            write_stdout(resp)

    while not stop_event.is_set():
        item = await msg_queue.get()
        if item is None:
            break
        task = asyncio.create_task(process_one(item))
        in_flight.add(task)
        task.add_done_callback(in_flight.discard)

    if in_flight:
        await asyncio.gather(*in_flight, return_exceptions=True)
    stop_event.set()


def _resolve_stdio_proxy_url(args: argparse.Namespace) -> str | None:
    if not args.stdio:
        return None
    if args.connect_http:
        return normalize_connect_http_url(args.connect_http)
    if args.port == 0:
        return None
    mcp_url, health_url = _resolve_client_urls(args)
    if _fetch_health_sync(health_url, timeout=0.8) is not None:
        return mcp_url
    return None


def _print_cli_rpc_outcome(resp: Any) -> int:
    if not isinstance(resp, dict):
        sys.stderr.write("Unexpected empty or non-object response from MCP bridge.\n")
        return 1
    if isinstance(resp.get("error"), dict):
        sys.stderr.write(json.dumps(resp["error"], indent=2) + "\n")
        return 1
    result = resp.get("result")
    if isinstance(result, dict) and result.get("isError") is True:
        sys.stderr.write(json.dumps(result, indent=2) + "\n")
        return 1
    payload = (
        result["structuredContent"]
        if isinstance(result, dict) and "structuredContent" in result
        else result
    )
    sys.stdout.write(json.dumps(payload, indent=2) + "\n")
    return 0


def run_cli_subcommand(args: argparse.Namespace) -> int:
    pos = list(args.command_args)
    verb = pos[0]
    rest = pos[1:]
    mcp_url, health_url = _resolve_client_urls(args)
    total_timeout = args.wait_timeout + args.call_timeout + 5.0

    if verb == "status":
        if rest:
            sys.stderr.write(f"Unexpected extra arguments for `status`: {' '.join(rest)}\n")
            return 64
        health = _fetch_health_sync(health_url, timeout=2.5)
        if health is None:
            sys.stderr.write(f"No DartPad MCP bridge reachable at {health_url}.\n")
            return 1
        sys.stdout.write(json.dumps(health, indent=2) + "\n")
        tabs = health.get("connectedTabs")
        if args.require_tab and (not isinstance(tabs, list) or len(tabs) == 0):
            return 2
        return 0

    if verb == "tools":
        if rest:
            sys.stderr.write(f"Unexpected extra arguments for `tools`: {' '.join(rest)}\n")
            return 64
        params: dict[str, Any] = {}
        if args.session:
            params["sessionId"] = args.session
        try:
            resp = _post_mcp_http_sync(
                mcp_url,
                {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": params},
                total_timeout,
                retry_connect=False,
            )
        except Exception as exc:
            sys.stderr.write(f"Failed querying tools at {mcp_url}: {exc}\n")
            return 1
        return _print_cli_rpc_outcome(resp)

    if verb == "call":
        if not rest or len(rest) > 2:
            sys.stderr.write(
                "Usage: dartpad_mcp_server.py call <tool_name> [json_args] [--stdin]\n"
            )
            return 64
        if args.stdin and len(rest) > 1:
            sys.stderr.write("Pass either [json_args] or --stdin to `call`, not both.\n")
            return 64
        tool_name = rest[0]
        raw_args = sys.stdin.read() if args.stdin else (rest[1] if len(rest) == 2 else "{}")
        stripped = raw_args.strip()
        try:
            parsed_args = json.loads(stripped) if stripped else {}
        except Exception as exc:
            sys.stderr.write(f"Invalid JSON tool arguments: {exc}\n")
            return 64
        if not isinstance(parsed_args, dict):
            sys.stderr.write("Invalid JSON tool arguments: expected a JSON object (`{...}`).\n")
            return 64
        if args.session and "sessionId" not in parsed_args:
            parsed_args["sessionId"] = args.session
        try:
            resp = _post_mcp_http_sync(
                mcp_url,
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {"name": tool_name, "arguments": parsed_args},
                },
                total_timeout,
                retry_connect=False,
            )
        except Exception as exc:
            sys.stderr.write(f"Failed calling {tool_name} at {mcp_url}: {exc}\n")
            return 1
        return _print_cli_rpc_outcome(resp)

    sys.stderr.write(
        f"Unknown command {verb!r}. Expected `serve`, `status`, `tools`, or `call`.\n"
    )
    return 64


async def async_main(args: argparse.Namespace) -> int:
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except NotImplementedError:
            pass

    # Mode A: `--stdio` forwarding to `--connect-http <URL>` or an already-active bridge on `:port`.
    proxy_url = await asyncio.to_thread(_resolve_stdio_proxy_url, args)
    if proxy_url is not None:
        total_timeout = args.wait_timeout + args.call_timeout + 10.0
        log_err(f"Starting stdio MCP client forwarding to {proxy_url}")

        async def forward_http(msg: Any) -> Any | None:
            return await asyncio.to_thread(
                _post_mcp_http_sync, proxy_url, msg, total_timeout
            )

        await run_stdio_loop(forward_http, stop_event=stop_event)
        return 0

    # Mode B: Start dual-stack HTTP + `/mcp-ws` + `/mcp` + `/healthz` hub
    # (either standalone daemon or combined with `--stdio`).
    port = args.port if args.port is not None else 8787

    hub = BridgeHub(
        static_dir=os.path.abspath(args.static_dir),
        wait_timeout=args.wait_timeout,
        call_timeout=args.call_timeout,
    )
    sock = create_dual_stack_socket(args.host, port)
    actual_port = sock.getsockname()[1]
    hub.bound_port = actual_port

    server = await asyncio.start_server(
        lambda r, w: handle_tcp_client(hub, r, w),
        sock=sock,
        limit=16 * 1024 * 1024,
    )

    hostname = socket.getfqdn() or "localhost"
    local_url = f"http://127.0.0.1:{actual_port}/?s=3&mcp=1"
    host_url = f"http://{hostname}:{actual_port}/?s=3&mcp=1"
    log_err(f"Listening dual-stack on port {actual_port} (static-dir: {hub.static_dir})")
    log_err(f"  DartPad Local URL : {local_url}")
    log_err(f"  DartPad Remote URL: {host_url}")
    log_err(f"  WebSocket Hub     : ws://127.0.0.1:{actual_port}/mcp-ws")
    log_err(f"  MCP HTTP Endpoint : http://127.0.0.1:{actual_port}/mcp")
    log_err(f"  Health Check      : http://127.0.0.1:{actual_port}/healthz")

    if args.port_file:
        with open(args.port_file, "w", encoding="utf-8") as pf:
            pf.write(f"{actual_port}\n")

    if args.open_browser:
        _maybe_open_browser(args.browser_url or local_url)

    async with server:
        if args.stdio:
            await run_stdio_loop(hub.handle_mcp_payload, stop_event=stop_event)
        else:
            await stop_event.wait()

    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Zero-dependency DartPad Preview WebMCP Server, Relay Bridge & CLI "
            "(`serve`, `status`, `tools`, `call`)."
        )
    )
    parser.add_argument(
        "command_args",
        nargs="*",
        help="Optional CLI subcommand: `serve` (default), `status`, `tools`, or `call <tool> [json]`.",
    )
    parser.add_argument(
        "--host",
        default="::",
        help="Host interface to bind (default '::' dual-stack IPv6+IPv4).",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help="TCP port to listen on or query (default: 8787).",
    )
    parser.add_argument(
        "--static-dir",
        default=os.environ.get("DARTPAD_STATIC_DIR", DEFAULT_STATIC_DIR),
        help="Path to built DartPad `build/jaspr` directory.",
    )
    parser.add_argument(
        "--stdio",
        action="store_true",
        help="Enable standard MCP JSON-RPC 2.0 over stdin/stdout (auto-attaches if :port is active).",
    )
    parser.add_argument(
        "--connect-http",
        default=None,
        help="Forward stdio or CLI requests to a running bridge's http://...:<PORT>/mcp.",
    )
    parser.add_argument(
        "--session",
        default=None,
        help="Target a specific DartPad tab sessionId (`s` query param) in `tools` or `call`.",
    )
    parser.add_argument(
        "--stdin",
        action="store_true",
        help="Read JSON arguments object from stdin for `call`.",
    )
    parser.add_argument(
        "--require-tab",
        action="store_true",
        help="Exit with code 2 from `status` when zero DartPad tabs are connected.",
    )
    parser.add_argument(
        "--open-browser",
        action="store_true",
        help="Launch Chrome pointing at http://127.0.0.1:<PORT>/?s=3&mcp=1.",
    )
    parser.add_argument(
        "--browser-url",
        default=None,
        help="Override URL opened when --open-browser is set.",
    )
    parser.add_argument(
        "--wait-timeout",
        type=float,
        default=20.0,
        help="Seconds to wait for a browser tab to connect on cold start (default: 20).",
    )
    parser.add_argument(
        "--call-timeout",
        type=float,
        default=120.0,
        help="Seconds to wait for a browser tool call response (default: 120).",
    )
    parser.add_argument(
        "--port-file",
        default=None,
        help="Optional file path to write the bound TCP port once listening.",
    )
    if hasattr(parser, "parse_intermixed_args"):
        return parser.parse_intermixed_args(argv)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    pos = list(args.command_args)
    if pos and pos[0] != "serve":
        sys.exit(run_cli_subcommand(args))
    if len(pos) > 1:
        sys.stderr.write(f"Unexpected extra arguments for `serve`: {' '.join(pos[1:])}\n")
        sys.exit(64)
    try:
        code = asyncio.run(async_main(args))
    except KeyboardInterrupt:
        code = 0
    sys.exit(code)


if __name__ == "__main__":
    main()
