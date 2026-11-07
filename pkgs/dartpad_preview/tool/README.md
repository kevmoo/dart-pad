# DartPad WebMCP Local Bridge (`dartpad_mcp_server.py`)

Zero-dependency Python 3 standard-library HTTP static server and
MCP-over-WebSocket relay bridge that lets local coding agents (Claude Code,
Gemini CLI, Cursor, Antigravity) drive DartPad Preview running in Chrome with
zero npm or pip packages installed.

## 1. Build Static Assets Once (When Building DartPad Locally)

From `pkgs/dartpad_preview`:

```bash
dart pub get
(cd dartpad_frontend && dart run tool/setup_sdk_assets.dart)
(cd examples && dart run build_examples.dart)
(cd dartpad_frontend && dart run jaspr_cli:jaspr build)
```

## 2. Start the Local Bridge Server

From `pkgs/dartpad_preview`:

```bash
python3 tool/dartpad_mcp_server.py --port 8787
```

Open Chrome to <http://127.0.0.1:8787/?s=3&mcp=1> (or point a deployed build at
`?mcp_port=8787`). Verify registration via:

```bash
curl -s http://127.0.0.1:8787/healthz
```

## 3. Connect Your Coding Agent (`stdio` or Streamable HTTP)

- **Streamable HTTP (`POST /mcp`)**:

  ```bash
  claude mcp add --transport http dartpad http://127.0.0.1:8787/mcp
  ```

- **`stdio` proxy attached to the running daemon**:

  ```bash
  python3 tool/dartpad_mcp_server.py --stdio --connect-http http://127.0.0.1:8787/mcp
  ```

- **All-in-one single-process `stdio` + embedded HTTP/WS server**:

  ```bash
  python3 tool/dartpad_mcp_server.py --stdio --port 8787 --open-browser
  ```

- **Zero-restart CLI subcommands (`status`, `tools`, `call`)** (matching
  [`kevmoo/dartpad_mcp`](https://github.com/kevmoo/dartpad_mcp)):

  ```bash
  python3 tool/dartpad_mcp_server.py status --port 8787 --require-tab
  python3 tool/dartpad_mcp_server.py tools --port 8787
  python3 tool/dartpad_mcp_server.py call dartpad_get_status --port 8787
  ```

## 4. Run Self-Tests

```bash
python3 tool/test_dartpad_mcp_server.py
```
