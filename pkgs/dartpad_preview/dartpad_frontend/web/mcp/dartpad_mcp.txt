// Copyright (c) 2026, Kevin Moore. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Default TCP port for the local DartPad WebMCP HTTP/WebSocket bridge.
const defaultBridgePort = 8787;

/// Supported Model Context Protocol JSON-RPC versions, newest first.
const supportedMcpVersions = <String>['2025-06-18', '2025-03-26', '2024-11-05'];

const _serverInfo = <String, Object?>{
  'name': 'dartpad_mcp',
  'version': '0.1.0',
};

const _serverInstructions =
    'Controls a live DartPad Preview browser tab (Flutter/Dart compiler, LSP '
    'analyzer, pub, hot reload, console/error logs, and VM Service widget tree '
    'inspector) via WebMCP.';

const _usageText = '''
Zero-dependency local MCP-over-WebSocket bridge for DartPad Preview.

Usage:
  dartpad_mcp [serve] [options]
  dartpad_mcp status [--port <port>] [--connect-http <url>] [--require-tab] [--session <id>]
  dartpad_mcp tools [--port <port>] [--connect-http <url>] [--session <id>]
  dartpad_mcp call <tool> [json_args] [--stdin] [--session <id>] [--port <port>]

Options:
  --port <port>           TCP port to listen on or query (default: 8787).
  --host <host>           Interface to bind: localhost (default), 127.0.0.1, ::1, 0.0.0.0, ::.
  --stdio                 Serve MCP JSON-RPC 2.0 over stdin/stdout (auto-attaches if :port is active).
  --connect-http <url>    Forward stdio or CLI requests to an existing http://...:<port>/mcp endpoint.
  --wait-timeout <sec>    Seconds to wait for a DartPad tab to connect on cold start (default: 20).
  --call-timeout <sec>    Seconds to wait for a browser tool call response (default: 120).
  --port-file <path>      Write the bound TCP port to <path> once listening.
  --session <id>          Target a specific DartPad tab sessionId (`s` query param or `tab-xxxx`).
  --stdin                 Read JSON arguments object from stdin for `call`.
  --require-tab           Exit with code 2 from `status` when no matching DartPad tab is connected.
  -h, --help              Show this usage information.
''';

/// CLI subcommands supported by `dartpad_mcp`.
enum BridgeSubcommand { serve, status, tools, call }

/// Exception thrown on invalid CLI flags or arguments (exit code 64).
final class CliUsageException implements Exception {
  const CliUsageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Parsed command-line configuration for `dartpad_mcp`.
final class BridgeCliConfig {
  const BridgeCliConfig({
    required this.subcommand,
    required this.host,
    required this.port,
    required this.stdio,
    required this.showHelp,
    required this.useStdinArgs,
    required this.requireTab,
    required this.waitTimeout,
    required this.callTimeout,
    this.hasExplicitWaitTimeout = false,
    this.connectHttp,
    this.portFile,
    this.sessionId,
    this.toolName,
    this.rawJsonArgs,
  });

  final BridgeSubcommand subcommand;
  final String host;
  final int port;
  final bool stdio;
  final bool showHelp;
  final bool useStdinArgs;
  final bool requireTab;
  final Duration waitTimeout;
  final bool hasExplicitWaitTimeout;
  final Duration callTimeout;
  final String? connectHttp;
  final String? portFile;
  final String? sessionId;
  final String? toolName;
  final String? rawJsonArgs;

  /// Resolves the target HTTP `/mcp` endpoint URI for client operations.
  Uri get resolvedMcpUri =>
      normalizeMcpEndpointUri(connectHttp ?? 'http://127.0.0.1:$port/mcp');

  /// Resolves the target HTTP `/healthz` endpoint URI for health checks.
  Uri get resolvedHealthUri => resolvedMcpUri.replace(path: '/healthz');
}

final class _MutableCliOptions {
  String host = 'localhost';
  int port = defaultBridgePort;
  bool stdio = false;
  bool showHelp = false;
  bool useStdinArgs = false;
  bool requireTab = false;
  Duration waitTimeout = const Duration(seconds: 20);
  bool hasExplicitWaitTimeout = false;
  Duration callTimeout = const Duration(seconds: 120);
  String? connectHttp;
  String? portFile;
  String? sessionId;
  final List<String> positionals = <String>[];
}

/// Parses raw command-line [args] into an immutable [BridgeCliConfig].
BridgeCliConfig parseBridgeCliArgs(List<String> args) {
  final opts = _MutableCliOptions();
  var stopFlags = false;
  var index = 0;
  while (index < args.length) {
    final token = args[index];
    if (stopFlags || !token.startsWith('-') || token == '-') {
      opts.positionals.add(token);
      index++;
      continue;
    }
    if (token == '--') {
      stopFlags = true;
      index++;
      continue;
    }
    index = _consumeFlag(args, index, opts);
  }
  if (opts.showHelp) {
    return _finalizeConfig(BridgeSubcommand.serve, opts, null, null);
  }
  return _resolveSubcommand(opts);
}

int _consumeFlag(List<String> args, int index, _MutableCliOptions opts) {
  final raw = args[index];
  final eq = raw.indexOf('=');
  final name = eq >= 0 ? raw.substring(0, eq) : raw;
  final inlineVal = eq >= 0 ? raw.substring(eq + 1) : null;

  String readVal() {
    if (inlineVal != null) {
      return inlineVal;
    }
    if (index + 1 >= args.length) {
      throw CliUsageException('Option $name requires a value.');
    }
    index++;
    return args[index];
  }

  switch (name) {
    case '-h' || '--help':
      opts.showHelp = true;
    case '--stdio':
      opts.stdio = true;
    case '--stdin':
      opts.useStdinArgs = true;
    case '--require-tab':
      opts.requireTab = true;
    case '--host':
      opts.host = readVal();
    case '--port':
      opts.port = _parsePort(readVal());
    case '--connect-http':
      opts.connectHttp = readVal();
    case '--port-file':
      opts.portFile = readVal();
    case '--session':
      opts.sessionId = readVal();
    case '--wait-timeout':
      opts
        ..waitTimeout = _parseSeconds(readVal(), name)
        ..hasExplicitWaitTimeout = true;
    case '--call-timeout':
      opts.callTimeout = _parseSeconds(readVal(), name);
    default:
      throw CliUsageException(
        'Unknown option "$name". Run `dartpad_mcp --help` for usage.',
      );
  }
  return index + 1;
}

int _parsePort(String value) {
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 0 || parsed > 65535) {
    throw CliUsageException('Invalid --port "$value" (expected 0..65535).');
  }
  return parsed;
}

Duration _parseSeconds(String value, String flagName) {
  final parsed = double.tryParse(value);
  if (parsed == null || parsed.isNaN || parsed.isInfinite || parsed < 0) {
    throw CliUsageException(
      'Invalid $flagName "$value" (expected non-negative seconds).',
    );
  }
  return Duration(milliseconds: (parsed * 1000).round());
}

BridgeCliConfig _resolveSubcommand(_MutableCliOptions opts) {
  final pos = opts.positionals;
  if (pos.isEmpty) {
    return _finalizeConfig(BridgeSubcommand.serve, opts, null, null);
  }
  final verb = pos.first;
  final rest = pos.sublist(1);
  return switch (verb) {
    'serve' when rest.isEmpty => _finalizeConfig(
      BridgeSubcommand.serve,
      opts,
      null,
      null,
    ),
    'status' when rest.isEmpty => _finalizeConfig(
      BridgeSubcommand.status,
      opts,
      null,
      null,
    ),
    'tools' when rest.isEmpty => _finalizeConfig(
      BridgeSubcommand.tools,
      opts,
      null,
      null,
    ),
    'call' => _resolveCallSubcommand(opts, rest),
    'serve' || 'status' || 'tools' => throw CliUsageException(
      'Unexpected extra arguments for `$verb`: ${rest.join(' ')}.',
    ),
    _ => throw CliUsageException(
      'Unknown command "$verb". '
      'Expected `serve`, `status`, `tools`, or `call`.',
    ),
  };
}

BridgeCliConfig _resolveCallSubcommand(
  _MutableCliOptions opts,
  List<String> rest,
) {
  if (rest.isEmpty || rest.length > 2) {
    throw const CliUsageException(
      'Usage: `dartpad_mcp call <tool_name> [json_args] [--stdin]`.',
    );
  }
  if (opts.useStdinArgs && rest.length > 1) {
    throw const CliUsageException(
      'Pass either `[json_args]` or `--stdin` to `call`, not both.',
    );
  }
  return _finalizeConfig(
    BridgeSubcommand.call,
    opts,
    rest.first,
    rest.length == 2 ? rest[1] : null,
  );
}

BridgeCliConfig _finalizeConfig(
  BridgeSubcommand subcommand,
  _MutableCliOptions opts,
  String? toolName,
  String? rawJsonArgs,
) => BridgeCliConfig(
  subcommand: subcommand,
  host: opts.host,
  port: opts.port,
  stdio: opts.stdio,
  showHelp: opts.showHelp,
  useStdinArgs: opts.useStdinArgs,
  requireTab: opts.requireTab,
  waitTimeout: opts.waitTimeout,
  hasExplicitWaitTimeout: opts.hasExplicitWaitTimeout,
  callTimeout: opts.callTimeout,
  connectHttp: opts.connectHttp,
  portFile: opts.portFile,
  sessionId: opts.sessionId,
  toolName: toolName,
  rawJsonArgs: rawJsonArgs,
);

/// Normalizes an HTTP URL string so empty or `/` paths target `/mcp`.
Uri normalizeMcpEndpointUri(String rawUrl) {
  final trimmed = rawUrl.trim();
  final parsed = Uri.parse(
    trimmed.contains('://') ? trimmed : 'http://$trimmed',
  );
  final normalizedPath = (parsed.path.isEmpty || parsed.path == '/')
      ? '/mcp'
      : parsed.path;
  return parsed.replace(path: normalizedPath);
}

final class _BrowserTab {
  _BrowserTab({required this.connId, required this.socket, required this.peer})
    : connectedAt = DateTime.now(),
      lastActiveAt = DateTime.now();

  final int connId;
  final WebSocket socket;
  final String peer;
  final DateTime connectedAt;
  DateTime lastActiveAt;
  String sessionId = '';
  String clientTabId = '';
  String url = '';
  bool ready = false;
  bool closed = false;
  List<Map<String, Object?>> tools = const <Map<String, Object?>>[];
  Set<String> nativeSessionIdTools = const <String>{};
  final Map<String, Completer<Map<String, Object?>>> pendingRequests =
      <String, Completer<Map<String, Object?>>>{};

  bool matchesSession(String target) =>
      sessionId == target || (clientTabId.isNotEmpty && clientTabId == target);

  void touch() {
    lastActiveAt = DateTime.now();
  }
}

/// In-process HTTP (`/mcp`, `/healthz`) and RFC 6455 WebSocket (`/mcp-ws`)
/// relay bridging DartPad Preview browser tabs to MCP clients.
final class DartPadMcpBridge {
  DartPadMcpBridge({
    this.waitTimeout = const Duration(seconds: 20),
    this.callTimeout = const Duration(seconds: 120),
    this.logSink,
  });

  final Duration waitTimeout;
  final Duration callTimeout;
  final StringSink? logSink;

  final List<HttpServer> _servers = <HttpServer>[];
  final List<StreamSubscription<HttpRequest>> _serverSubs =
      <StreamSubscription<HttpRequest>>[];
  final Map<int, _BrowserTab> _tabs = <int, _BrowserTab>{};
  final List<Completer<void>> _tabWaiters = <Completer<void>>[];
  List<Map<String, Object?>> _cachedTools = const <Map<String, Object?>>[];

  int _boundPort = 0;
  int _nextConnId = 0;
  int _nextRpcSeq = 0;
  bool _closed = false;

  /// Bound TCP port once started, or `0` before [start] completes.
  int get port => _boundPort;

  void _log(String message) {
    logSink?.writeln('[dartpad_mcp] $message');
  }

  /// Binds the HTTP + `/mcp-ws` listener on [host] and [port].
  static Future<DartPadMcpBridge> start({
    String host = 'localhost',
    int port = defaultBridgePort,
    Duration waitTimeout = const Duration(seconds: 20),
    Duration callTimeout = const Duration(seconds: 120),
    StringSink? logSink,
  }) async {
    final bridge = DartPadMcpBridge(
      waitTimeout: waitTimeout,
      callTimeout: callTimeout,
      logSink: logSink,
    );
    try {
      await bridge._bindServers(host, port);
      return bridge;
    } catch (_) {
      await bridge.close();
      rethrow;
    }
  }

  Future<void> _bindServers(String host, int requestedPort) async {
    if (host == 'localhost') {
      final v4 = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        requestedPort,
      );
      _attachServer(v4);
      _boundPort = v4.port;
      await _tryBindLoopbackV6(_boundPort);
      return;
    }
    if (host == '::') {
      final server = await _bindDualStackAny(requestedPort);
      _attachServer(server);
      _boundPort = server.port;
      return;
    }
    final server = await HttpServer.bind(host, requestedPort);
    _attachServer(server);
    _boundPort = server.port;
  }

  Future<void> _tryBindLoopbackV6(int boundPort) async {
    try {
      final v6 = await HttpServer.bind(
        InternetAddress.loopbackIPv6,
        boundPort,
        v6Only: true,
      );
      _attachServer(v6);
    } on SocketException {
      // Host may have IPv6 loopback disabled; IPv4 loopback remains active.
    }
  }

  Future<HttpServer> _bindDualStackAny(int requestedPort) async {
    try {
      return await HttpServer.bind(InternetAddress.anyIPv6, requestedPort);
    } on SocketException {
      return HttpServer.bind(InternetAddress.anyIPv4, requestedPort);
    }
  }

  void _attachServer(HttpServer server) {
    _servers.add(server);
    _serverSubs.add(
      server.listen((request) {
        unawaited(_handleHttpRequest(request));
      }),
    );
  }

  /// Closes all bound HTTP servers, active WebSockets, and pending RPCs.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final sub in _serverSubs) {
      await sub.cancel();
    }
    _serverSubs.clear();
    for (final tab in _tabs.values.toList(growable: false)) {
      await _closeTab(tab);
    }
    _tabs.clear();
    _notifyTabChange();
    for (final server in _servers) {
      await server.close(force: true);
    }
    _servers.clear();
  }

  Future<void> _closeTab(_BrowserTab tab) async {
    tab.closed = true;
    _failPendingRequests(tab);
    try {
      await tab.socket.close(WebSocketStatus.normalClosure);
    } catch (_) {
      // Ignore socket close errors during teardown.
    }
  }

  /// Returns a structured status snapshot for `GET /healthz`.
  Map<String, Object?> healthSnapshot() {
    final tabs = _readyTabsSorted();
    final activeTools = tabs.isNotEmpty
        ? tabs.first.tools.length
        : _cachedTools.length;
    return <String, Object?>{
      'ok': true,
      'port': _boundPort,
      'connectedTabs': <Map<String, Object?>>[
        for (var i = 0; i < tabs.length; i++)
          <String, Object?>{
            'connId': tabs[i].connId,
            'sessionId': tabs[i].sessionId,
            if (tabs[i].clientTabId.isNotEmpty)
              'clientTabId': tabs[i].clientTabId,
            'url': tabs[i].url,
            'toolCount': tabs[i].tools.length,
            'connectedAt': tabs[i].connectedAt.toUtc().toIso8601String(),
            'lastActiveAt': tabs[i].lastActiveAt.toUtc().toIso8601String(),
            'isActiveDefault': i == 0,
          },
      ],
      'toolCount': activeTools,
      'cachedToolCount': _cachedTools.length,
    };
  }

  List<_BrowserTab> _readyTabsSorted() =>
      _tabs.values
          .where((tab) => tab.ready && !tab.closed)
          .toList(growable: false)
        ..sort((a, b) {
          final cmp = b.lastActiveAt.compareTo(a.lastActiveAt);
          return cmp != 0 ? cmp : b.connId.compareTo(a.connId);
        });

  _BrowserTab? _selectTab([String? sessionId]) {
    final ready = _readyTabsSorted();
    if (ready.isEmpty) {
      return null;
    }
    if (sessionId == null || sessionId.isEmpty) {
      return ready.first;
    }
    for (final tab in ready) {
      if (tab.matchesSession(sessionId)) {
        return tab;
      }
    }
    return null;
  }

  void _notifyTabChange() {
    if (_tabWaiters.isEmpty) {
      return;
    }
    final waiters = List<Completer<void>>.of(_tabWaiters);
    _tabWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  Duration _resolveWaitTimeout(Map<String, Object?> params) {
    final overrideMs = params['waitTimeoutMs'];
    if (overrideMs is num && !overrideMs.isNaN && !overrideMs.isInfinite) {
      return overrideMs <= 0
          ? Duration.zero
          : Duration(milliseconds: overrideMs.round());
    }
    return waitTimeout;
  }

  Future<_BrowserTab?> _waitForTab([
    String? sessionId,
    Duration? customTimeout,
  ]) async {
    final effectiveWait = customTimeout ?? waitTimeout;
    final immediate = _selectTab(sessionId);
    if (immediate != null || _closed || effectiveWait <= Duration.zero) {
      return immediate;
    }
    final deadline = DateTime.now().add(effectiveWait);
    while (!_closed) {
      final found = _selectTab(sessionId);
      if (found != null) {
        return found;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        return null;
      }
      final waiter = Completer<void>();
      _tabWaiters.add(waiter);
      await _awaitWaiterOrTimeout(waiter, remaining);
    }
    return null;
  }

  Future<void> _awaitWaiterOrTimeout(
    Completer<void> waiter,
    Duration timeout,
  ) async {
    final timer = Timer(timeout, () {
      _tabWaiters.remove(waiter);
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    });
    try {
      await waiter.future;
    } finally {
      timer.cancel();
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    _applyCorsHeaders(request.response.headers);
    final rawPath = request.uri.path;
    final normPath = rawPath.length > 1 && rawPath.endsWith('/')
        ? rawPath.substring(0, rawPath.length - 1)
        : (rawPath.isEmpty ? '/' : rawPath);

    if (request.method == 'OPTIONS') {
      await _sendEmpty(request.response, HttpStatus.noContent);
      return;
    }
    if (normPath == '/mcp-ws' && request.method == 'GET') {
      await _handleWebSocketUpgrade(request);
      return;
    }
    if (normPath == '/healthz' &&
        (request.method == 'GET' || request.method == 'HEAD')) {
      await _sendJson(
        request.response,
        HttpStatus.ok,
        healthSnapshot(),
        headOnly: request.method == 'HEAD',
      );
      return;
    }
    if (normPath == '/mcp') {
      await _handleMcpHttpEndpoint(request);
      return;
    }
    await _sendText(request.response, HttpStatus.notFound, 'Not Found');
  }

  void _applyCorsHeaders(HttpHeaders headers) {
    headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, HEAD, POST, DELETE, OPTIONS')
      ..set(
        'Access-Control-Allow-Headers',
        'Content-Type, Accept, Mcp-Session-Id, Last-Event-ID',
      )
      ..set('Access-Control-Allow-Private-Network', 'true');
  }

  Future<void> _handleWebSocketUpgrade(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await _sendText(
        request.response,
        HttpStatus.badRequest,
        'Expected WebSocket Upgrade',
      );
      return;
    }
    final peer = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final socket = await WebSocketTransformer.upgrade(request);
    _registerWebSocket(socket, peer);
  }

  void _registerWebSocket(WebSocket socket, String peer) {
    final tab = _BrowserTab(connId: ++_nextConnId, socket: socket, peer: peer);
    _tabs[tab.connId] = tab;
    _log('Tab connected: conn=${tab.connId} peer=$peer');
    unawaited(_pumpTabSocket(tab));
  }

  Future<void> _pumpTabSocket(_BrowserTab tab) async {
    try {
      await for (final rawEvent in tab.socket) {
        _onSocketEvent(tab, rawEvent);
      }
    } catch (_) {
      // Treat transport errors as socket closure.
    } finally {
      _onSocketClosed(tab);
    }
  }

  void _onSocketEvent(_BrowserTab tab, Object? rawEvent) {
    final text = switch (rawEvent) {
      final String s => s,
      final List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    if (text == null) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is Map<String, Object?>) {
      _onTabJsonMessage(tab, decoded);
    }
  }

  void _onTabJsonMessage(_BrowserTab tab, Map<String, Object?> data) {
    final method = data['method'];
    if (method == 'webmcp/hello' || method == 'webmcp/toolsChanged') {
      _handleTabHello(tab, data);
      return;
    }
    if (method == 'ping' && data.containsKey('id')) {
      tab.touch();
      _sendSocketJson(tab, <String, Object?>{
        'jsonrpc': '2.0',
        'id': data['id'],
        'result': const <String, Object?>{},
      });
      return;
    }
    if (data.containsKey('id') &&
        (data.containsKey('result') || data.containsKey('error'))) {
      final completer = tab.pendingRequests.remove('${data['id']}');
      if (completer != null && !completer.isCompleted) {
        completer.complete(data);
      }
    }
  }

  void _handleTabHello(_BrowserTab tab, Map<String, Object?> data) {
    final params = _asObjectMap(data['params']);
    final url = '${params['url'] ?? tab.url}';
    final clientTabId =
        _nonEmptyString(params['clientTabId']) ?? tab.clientTabId;
    final sid = _resolveHelloSessionId(
      tab,
      params['sessionId'],
      clientTabId,
      url,
    );
    if (params['tools'] case final List<Object?> rawTools) {
      final (:tools, :nativeSessionIdTools) = _augmentToolsForMcp(rawTools);
      tab
        ..tools = tools
        ..nativeSessionIdTools = nativeSessionIdTools;
      if (tools.isNotEmpty) {
        _cachedTools = tools;
      }
    }
    tab
      ..sessionId = sid
      ..clientTabId = clientTabId
      ..url = url
      ..ready = true
      ..touch();
    _log(
      'Tab ready: conn=${tab.connId} sessionId=$sid tools=${tab.tools.length}',
    );
    _sendSocketJson(tab, <String, Object?>{
      'jsonrpc': '2.0',
      'method': 'webmcp/welcome',
      'params': <String, Object?>{'sessionId': sid},
    });
    if (data['id'] case final Object id) {
      _sendSocketJson(tab, <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': <String, Object?>{'ok': true, 'sessionId': sid},
      });
    }
    _notifyTabChange();
  }

  String _resolveHelloSessionId(
    _BrowserTab tab,
    Object? rawSid,
    String clientTabId,
    String url,
  ) {
    if (_nonEmptyString(rawSid) case final explicit?) {
      return explicit;
    }
    final fallback = clientTabId.isNotEmpty ? clientTabId : 'tab-${tab.connId}';
    return _extractSessionIdFromUrl(url, fallback);
  }

  void _onSocketClosed(_BrowserTab tab) {
    if (_tabs.remove(tab.connId) == null) {
      return;
    }
    tab.closed = true;
    _failPendingRequests(tab);
    _log('Tab disconnected: conn=${tab.connId} sessionId=${tab.sessionId}');
    _notifyTabChange();
  }

  void _failPendingRequests(_BrowserTab tab) {
    final label = tab.sessionId.isEmpty ? 'unknown' : tab.sessionId;
    final error = StateError('DartPad tab ($label) disconnected.');
    for (final completer in tab.pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    tab.pendingRequests.clear();
  }

  void _sendSocketJson(_BrowserTab tab, Map<String, Object?> payload) {
    if (tab.closed || tab.socket.readyState != WebSocket.open) {
      return;
    }
    tab.socket.add(jsonEncode(payload));
  }

  Future<Map<String, Object?>> _sendTabRpc(
    _BrowserTab tab,
    String method,
    Map<String, Object?> params, {
    bool touchTab = true,
  }) async {
    final rpcId = 'req-${++_nextRpcSeq}';
    final completer = Completer<Map<String, Object?>>();
    tab.pendingRequests[rpcId] = completer;
    if (touchTab) {
      tab.touch();
    }
    _sendSocketJson(tab, <String, Object?>{
      'jsonrpc': '2.0',
      'id': rpcId,
      'method': method,
      'params': params,
    });
    try {
      return await completer.future.timeout(callTimeout);
    } finally {
      tab.pendingRequests.remove(rpcId);
    }
  }

  Future<void> _handleMcpHttpEndpoint(HttpRequest request) async {
    if (request.method == 'DELETE') {
      await _sendEmpty(request.response, HttpStatus.ok);
      return;
    }
    if (request.method != 'POST') {
      request.response.headers.set('Allow', 'POST, DELETE, OPTIONS');
      await _sendText(
        request.response,
        HttpStatus.methodNotAllowed,
        'Method Not Allowed',
      );
      return;
    }
    final Object? decoded;
    try {
      final rawBody = await utf8.decoder.bind(request).join();
      decoded = jsonDecode(rawBody);
    } on FormatException catch (error) {
      await _sendJson(
        request.response,
        HttpStatus.badRequest,
        _rpcError(null, -32700, 'Parse error: ${error.message}'),
      );
      return;
    }
    final result = await handleMcpPayload(decoded);
    if (result == null) {
      await _sendEmpty(request.response, HttpStatus.accepted);
      return;
    }
    await _sendJson(request.response, HttpStatus.ok, result);
  }

  /// Dispatches a single or batch MCP JSON-RPC 2.0 request payload.
  Future<Object?> handleMcpPayload(Object? payload) async {
    if (payload is List<Object?>) {
      if (payload.isEmpty) {
        return _rpcError(null, -32600, 'Empty JSON-RPC batch');
      }
      final responses = <Map<String, Object?>>[];
      for (final item in payload) {
        final single = await _handleSingleMcp(item);
        if (single != null) {
          responses.add(single);
        }
      }
      return responses.isEmpty ? null : responses;
    }
    return _handleSingleMcp(payload);
  }

  Future<Map<String, Object?>?> _handleSingleMcp(Object? rawReq) async {
    if (rawReq is! Map<String, Object?>) {
      return _rpcError(null, -32600, 'Invalid JSON-RPC message');
    }
    if (!rawReq.containsKey('id')) {
      return null;
    }
    final reqId = rawReq['id'];
    final method = rawReq['method'];
    if (method is! String) {
      return _rpcError(reqId, -32600, 'Missing JSON-RPC method');
    }
    final params = _asObjectMap(rawReq['params']);
    return switch (method) {
      'initialize' => _handleInitialize(reqId, params),
      'ping' => _rpcResult(reqId, const <String, Object?>{}),
      'resources/list' => _rpcResult(reqId, const <String, Object?>{
        'resources': <Object?>[],
      }),
      'prompts/list' => _rpcResult(reqId, const <String, Object?>{
        'prompts': <Object?>[],
      }),
      'tools/list' => _handleToolsList(reqId, params),
      'tools/call' => _handleToolsCall(reqId, params),
      _ => _rpcError(reqId, -32601, 'Method not found: $method'),
    };
  }

  Map<String, Object?> _handleInitialize(
    Object? reqId,
    Map<String, Object?> params,
  ) {
    final requested = '${params['protocolVersion'] ?? ''}';
    final negotiated = supportedMcpVersions.contains(requested)
        ? requested
        : supportedMcpVersions[1];
    return _rpcResult(reqId, <String, Object?>{
      'protocolVersion': negotiated,
      'capabilities': const <String, Object?>{
        'tools': <String, Object?>{'listChanged': false},
      },
      'serverInfo': _serverInfo,
      'instructions': _serverInstructions,
    });
  }

  Future<Map<String, Object?>> _handleToolsList(
    Object? reqId,
    Map<String, Object?> params,
  ) async {
    final requestedSid = _nonEmptyString(params['sessionId']);
    final effectiveWait = _resolveWaitTimeout(params);
    var tab = _selectTab(requestedSid);
    if (tab == null && _cachedTools.isNotEmpty && requestedSid == null) {
      return _rpcResult(reqId, <String, Object?>{'tools': _cachedTools});
    }
    tab ??= await _waitForTab(requestedSid, effectiveWait);
    if (tab != null) {
      final liveTools = await _queryTabTools(
        tab,
        touchTab: requestedSid == null,
      );
      return _rpcResult(reqId, <String, Object?>{'tools': liveTools});
    }
    if (requestedSid != null) {
      return _rpcError(
        reqId,
        -32002,
        _missingTabMessage(requestedSid, effectiveWait),
      );
    }
    return _rpcResult(reqId, <String, Object?>{'tools': _cachedTools});
  }

  Future<List<Map<String, Object?>>> _queryTabTools(
    _BrowserTab tab, {
    required bool touchTab,
  }) async {
    try {
      final wsResp = await _sendTabRpc(
        tab,
        'tools/list',
        const <String, Object?>{},
        touchTab: touchTab,
      );
      final res = _asObjectMap(wsResp['result']);
      if (res['tools'] case final List<Object?> rawTools) {
        final (:tools, :nativeSessionIdTools) = _augmentToolsForMcp(rawTools);
        tab
          ..tools = tools
          ..nativeSessionIdTools = nativeSessionIdTools;
        if (tools.isNotEmpty) {
          _cachedTools = tools;
        }
        return tools;
      }
    } catch (_) {
      // Fall back to tools announced during `webmcp/hello`.
    }
    return tab.tools.isNotEmpty ? tab.tools : _cachedTools;
  }

  Future<Map<String, Object?>> _handleToolsCall(
    Object? reqId,
    Map<String, Object?> params,
  ) async {
    final name = _nonEmptyString(params['name']);
    if (name == null) {
      return _rpcError(
        reqId,
        -32602,
        "Invalid params: tools/call requires non-empty 'name'",
      );
    }
    final rawArgs = params['arguments'];
    if (rawArgs != null && rawArgs is! Map<String, Object?>) {
      return _rpcError(
        reqId,
        -32602,
        "Invalid params: 'arguments' must be an object",
      );
    }
    final callArgs = <String, Object?>{
      if (rawArgs is Map<String, Object?>) ...rawArgs,
    };
    final requestedSid =
        _nonEmptyString(callArgs['sessionId']) ??
        _nonEmptyString(params['sessionId']);
    final effectiveWait = _resolveWaitTimeout(params);
    final tab = await _waitForTab(requestedSid, effectiveWait);
    if (tab == null) {
      return _rpcResult(reqId, _missingTabResult(requestedSid, effectiveWait));
    }
    if (!tab.nativeSessionIdTools.contains(name)) {
      callArgs.remove('sessionId');
    }
    return _invokeTabTool(
      reqId,
      tab,
      name,
      callArgs,
      touchTab: requestedSid == null,
    );
  }

  String _missingTabMessage(String? requestedSid, Duration waited) {
    final sidSuffix = requestedSid == null ? '' : ' (sessionId=$requestedSid)';
    final waitSec = (waited.inMilliseconds / 1000).toStringAsFixed(1);
    return 'No connected DartPad browser tab$sidSuffix after waiting '
        '${waitSec}s. Click "Connect Agent" in your DartPad Preview tab '
        '(port $_boundPort).';
  }

  Map<String, Object?> _missingTabResult(
    String? requestedSid,
    Duration waited,
  ) => _toolTextError(_missingTabMessage(requestedSid, waited));

  Future<Map<String, Object?>> _invokeTabTool(
    Object? reqId,
    _BrowserTab tab,
    String name,
    Map<String, Object?> callArgs, {
    required bool touchTab,
  }) async {
    final Map<String, Object?> wsResp;
    try {
      wsResp = await _sendTabRpc(tab, 'tools/call', <String, Object?>{
        'name': name,
        'arguments': callArgs,
      }, touchTab: touchTab);
    } on TimeoutException {
      final sec = (callTimeout.inMilliseconds / 1000).toStringAsFixed(1);
      return _rpcResult(
        reqId,
        _toolTextError(
          "Timed out after ${sec}s waiting for browser tool '$name'.",
        ),
      );
    } catch (error) {
      return _rpcResult(
        reqId,
        _toolTextError("Browser tab transport error calling '$name': $error"),
      );
    }
    if (wsResp['error'] case final Map<String, Object?> err) {
      return <String, Object?>{'jsonrpc': '2.0', 'id': reqId, 'error': err};
    }
    final res = wsResp['result'];
    if (res is Map<String, Object?> && res['content'] is List<Object?>) {
      return _rpcResult(reqId, res);
    }
    return _rpcResult(reqId, <String, Object?>{
      'content': <Map<String, Object?>>[
        <String, Object?>{
          'type': 'text',
          'text': res is String ? res : jsonEncode(res),
        },
      ],
      'structuredContent': res is Map<String, Object?>
          ? res
          : <String, Object?>{'value': res},
      'isError': false,
    });
  }
}

Map<String, Object?> _asObjectMap(Object? value) =>
    value is Map<String, Object?> ? value : const <String, Object?>{};

String? _nonEmptyString(Object? value) {
  if (value == null) {
    return null;
  }
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

String _extractSessionIdFromUrl(String rawUrl, String fallback) {
  final uri = Uri.tryParse(rawUrl);
  final sid = uri?.queryParameters['s'];
  return (sid != null && sid.isNotEmpty) ? sid : fallback;
}

({List<Map<String, Object?>> tools, Set<String> nativeSessionIdTools})
_augmentToolsForMcp(List<Object?> rawTools) {
  final normalized = <Map<String, Object?>>[];
  final nativeSid = <String>{};
  for (final entry in rawTools) {
    if (entry is! Map<String, Object?>) {
      continue;
    }
    final name = _nonEmptyString(entry['name']);
    if (name == null) {
      continue;
    }
    normalized.add(_normalizeSingleTool(entry, name, nativeSid));
  }
  return (tools: normalized, nativeSessionIdTools: nativeSid);
}

Map<String, Object?> _normalizeSingleTool(
  Map<String, Object?> raw,
  String name,
  Set<String> nativeSid,
) {
  final item = (jsonDecode(jsonEncode(raw)) as Map<String, Object?>)
    ..putIfAbsent('description', () => '');
  final rawSchema = item['inputSchema'];
  final schema =
      (rawSchema is Map<String, Object?>
            ? rawSchema
            : <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{},
              })
        ..putIfAbsent('type', () => 'object');
  final rawProps = schema['properties'];
  final props = rawProps is Map<String, Object?>
      ? rawProps
      : <String, Object?>{};
  if (props.containsKey('sessionId')) {
    nativeSid.add(name);
  } else {
    props['sessionId'] = const <String, Object?>{
      'type': 'string',
      'description':
          'Optional DartPad tab sessionId to target when multiple tabs are '
          'connected (defaults to the most recently active tab).',
    };
  }
  schema['properties'] = props;
  item['inputSchema'] = schema;
  return item;
}

Map<String, Object?> _rpcResult(Object? id, Object? result) =>
    <String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result};

Map<String, Object?> _rpcError(Object? id, int code, String message) =>
    <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{'code': code, 'message': message},
    };

Map<String, Object?> _toolTextError(String message) => <String, Object?>{
  'content': <Map<String, Object?>>[
    <String, Object?>{'type': 'text', 'text': message},
  ],
  'isError': true,
};

Future<void> _sendEmpty(HttpResponse response, int statusCode) async {
  response.statusCode = statusCode;
  await response.close();
}

Future<void> _sendText(
  HttpResponse response,
  int statusCode,
  String text,
) async {
  final bytes = utf8.encode(text);
  response
    ..statusCode = statusCode
    ..headers.contentType = ContentType.text
    ..headers.contentLength = bytes.length
    ..add(bytes);
  await response.close();
}

Future<void> _sendJson(
  HttpResponse response,
  int statusCode,
  Object payload, {
  bool headOnly = false,
}) async {
  final bytes = utf8.encode(jsonEncode(payload));
  response
    ..statusCode = statusCode
    ..headers.set('Content-Type', 'application/json; charset=utf-8')
    ..headers.set('Cache-Control', 'no-store')
    ..headers.contentLength = bytes.length;
  if (!headOnly) {
    response.add(bytes);
  }
  await response.close();
}

/// Sends a JSON-RPC 2.0 POST request to an active bridge's `/mcp` endpoint.
Future<Object?> postMcpHttp(
  Uri mcpUri,
  Object payload, {
  Duration timeout = const Duration(seconds: 130),
}) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.postUrl(mcpUri).timeout(timeout);
    final body = utf8.encode(jsonEncode(payload));
    request
      ..headers.set('Content-Type', 'application/json')
      ..headers.set('Accept', 'application/json, text/event-stream')
      ..headers.contentLength = body.length
      ..add(body);
    final response = await request.close().timeout(timeout);
    final raw = await utf8.decoder.bind(response).join().timeout(timeout);
    if (response.statusCode == HttpStatus.accepted || raw.trim().isEmpty) {
      return null;
    }
    return jsonDecode(raw);
  } finally {
    client.close(force: true);
  }
}

/// Queries `GET /healthz` on [healthUri], returning `null` if unreachable.
Future<Map<String, Object?>?> fetchBridgeHealth(
  Uri healthUri, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.getUrl(healthUri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final raw = await utf8.decoder.bind(response).join().timeout(timeout);
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?> && decoded['ok'] == true
        ? decoded
        : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Runs the MCP JSON-RPC 2.0 stdio transport loop over [input] and [out].
Future<void> runMcpStdioLoop({
  required Stream<List<int>> input,
  required StringSink out,
  required Future<Object?> Function(Object? payload) handler,
}) async {
  final inFlight = <Future<void>>{};
  await for (final rawMessage in _decodeStdioMessages(input)) {
    final future = _dispatchStdioMessage(rawMessage, out, handler);
    inFlight.add(future);
    unawaited(future.whenComplete(() => inFlight.remove(future)));
  }
  if (inFlight.isNotEmpty) {
    await Future.wait(inFlight.toList(growable: false));
  }
}

Future<void> _dispatchStdioMessage(
  String rawMessage,
  StringSink out,
  Future<Object?> Function(Object? payload) handler,
) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(rawMessage);
  } on FormatException catch (error) {
    _writeSafe(
      out,
      jsonEncode(_rpcError(null, -32700, 'Parse error: ${error.message}')),
    );
    return;
  }
  try {
    final response = await handler(decoded);
    if (response != null) {
      _writeSafe(out, jsonEncode(response));
    }
  } catch (error) {
    if (decoded is Map<String, Object?> && !decoded.containsKey('id')) {
      return;
    }
    final reqId = decoded is Map<String, Object?> ? decoded['id'] : null;
    _writeSafe(
      out,
      jsonEncode(_rpcError(reqId, -32603, 'Internal error: $error')),
    );
  }
}

Stream<String> _decodeStdioMessages(Stream<List<int>> input) async* {
  final buffer = BytesBuilder(copy: false);
  var expectedLength = -1;

  await for (final chunk in input) {
    buffer.add(chunk);
    while (true) {
      final bytes = buffer.toBytes();
      final extracted = _extractNextStdioFrame(bytes, expectedLength);
      if (extracted == null) {
        break;
      }
      expectedLength = extracted.nextExpectedLength;
      buffer.clear();
      if (extracted.remaining.isNotEmpty) {
        buffer.add(extracted.remaining);
      }
      if (extracted.message case final msg? when msg.isNotEmpty) {
        yield msg;
      }
    }
  }
  final tail = utf8.decode(buffer.toBytes(), allowMalformed: true).trim();
  if (tail.isNotEmpty && expectedLength < 0) {
    yield tail;
  }
}

({String? message, Uint8List remaining, int nextExpectedLength})?
_extractNextStdioFrame(Uint8List bytes, int expectedLength) {
  if (expectedLength >= 0) {
    if (bytes.length < expectedLength) {
      return null;
    }
    final body = utf8.decode(
      Uint8List.sublistView(bytes, 0, expectedLength),
      allowMalformed: true,
    );
    return (
      message: body.trim(),
      remaining: Uint8List.sublistView(bytes, expectedLength),
      nextExpectedLength: -1,
    );
  }
  final nl = bytes.indexOf(0x0A);
  if (nl < 0) {
    return null;
  }
  final line = utf8
      .decode(Uint8List.sublistView(bytes, 0, nl), allowMalformed: true)
      .trim();
  final rest = Uint8List.sublistView(bytes, nl + 1);
  if (line.toLowerCase().startsWith('content-length:')) {
    return _consumeHeaderBlock(line, rest);
  }
  return (message: line, remaining: rest, nextExpectedLength: -1);
}

({String? message, Uint8List remaining, int nextExpectedLength})?
_consumeHeaderBlock(String firstLine, Uint8List afterFirstLine) {
  final lenText = firstLine.split(':').sublist(1).join(':').trim();
  final parsedLen = int.tryParse(lenText);
  if (parsedLen == null || parsedLen < 0) {
    return (message: null, remaining: afterFirstLine, nextExpectedLength: -1);
  }
  var offset = 0;
  while (offset < afterFirstLine.length) {
    final nextNl = afterFirstLine.indexOf(0x0A, offset);
    if (nextNl < 0) {
      return null;
    }
    final hdr = utf8
        .decode(
          Uint8List.sublistView(afterFirstLine, offset, nextNl),
          allowMalformed: true,
        )
        .trim();
    offset = nextNl + 1;
    if (hdr.isEmpty) {
      return (
        message: null,
        remaining: Uint8List.sublistView(afterFirstLine, offset),
        nextExpectedLength: parsedLen,
      );
    }
  }
  return null;
}

/// Executes the `dartpad_mcp` CLI with injectable streams and returns an exit
/// code.
Future<int> runDartPadMcpCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
  Stream<List<int>>? input,
  Future<void>? stopSignal,
}) async {
  final outSink = out ?? stdout;
  final errSink = err ?? stderr;
  final inStream = input ?? stdin;

  final BridgeCliConfig config;
  try {
    config = parseBridgeCliArgs(args);
  } on CliUsageException catch (error) {
    errSink.writeln('Error: ${error.message}');
    return 64;
  }

  if (config.showHelp) {
    _writeSafe(outSink, _usageText, newline: false);
    return 0;
  }

  try {
    return await switch (config.subcommand) {
      BridgeSubcommand.status => _runStatusCommand(config, outSink, errSink),
      BridgeSubcommand.tools => _runToolsCommand(config, outSink, errSink),
      BridgeSubcommand.call => _runCallCommand(
        config,
        inStream,
        outSink,
        errSink,
      ),
      BridgeSubcommand.serve => _runServeCommand(
        config,
        inStream,
        outSink,
        errSink,
        stopSignal,
      ),
    };
  } on IOException catch (error) {
    if (_isBrokenPipeError(error)) {
      return 0;
    }
    rethrow;
  }
}

Future<int> _runStatusCommand(
  BridgeCliConfig config,
  StringSink out,
  StringSink err,
) async {
  final health = await fetchBridgeHealth(config.resolvedHealthUri);
  if (health == null) {
    err.writeln(
      'No DartPad MCP bridge reachable at ${config.resolvedHealthUri}.',
    );
    return 1;
  }
  final requestedSid = _nonEmptyString(config.sessionId);
  final matched = _augmentHealthForSession(health, requestedSid);
  _writeSafe(out, const JsonEncoder.withIndent('  ').convert(health));
  if (!config.requireTab) {
    return 0;
  }
  return _evaluateRequiredTabExit(
    health,
    requestedSid: requestedSid,
    matched: matched,
    healthUri: config.resolvedHealthUri,
    err: err,
  );
}

bool _tabEntryMatchesSession(Object? rawTab, String target) {
  if (rawTab is! Map<String, Object?>) {
    return false;
  }
  return rawTab['sessionId'] == target || rawTab['clientTabId'] == target;
}

bool _augmentHealthForSession(
  Map<String, Object?> health,
  String? requestedSid,
) {
  final tabs = health['connectedTabs'];
  final tabList = tabs is List<Object?> ? tabs : const <Object?>[];
  if (requestedSid == null) {
    return tabList.isNotEmpty;
  }
  final matched = tabList.any(
    (entry) => _tabEntryMatchesSession(entry, requestedSid),
  );
  health['requestedSessionId'] = requestedSid;
  health['matchedSession'] = matched;
  return matched;
}

int _evaluateRequiredTabExit(
  Map<String, Object?> health, {
  required String? requestedSid,
  required bool matched,
  required Uri healthUri,
  required StringSink err,
}) {
  if (matched) {
    return 0;
  }
  if (requestedSid != null) {
    final connected = _connectedSessionSummary(health['connectedTabs']);
    err.writeln(
      'No connected DartPad tab matching session "$requestedSid" at '
      '$healthUri ($connected).',
    );
  }
  return 2;
}

String _connectedSessionSummary(Object? rawTabs) {
  if (rawTabs is! List<Object?> || rawTabs.isEmpty) {
    return 'connected sessions: none';
  }
  final labels = <String>[
    for (final entry in rawTabs)
      if (entry is Map<String, Object?> && entry['sessionId'] != null)
        '${entry['sessionId']}',
  ];
  return labels.isEmpty
      ? 'connected sessions: none'
      : 'connected sessions: ${labels.join(', ')}';
}

Future<int> _runToolsCommand(
  BridgeCliConfig config,
  StringSink out,
  StringSink err,
) async {
  final timeout =
      config.waitTimeout + config.callTimeout + const Duration(seconds: 5);
  try {
    final resp = await postMcpHttp(config.resolvedMcpUri, <String, Object?>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
      'params': <String, Object?>{
        if (config.sessionId != null) 'sessionId': config.sessionId,
        if (config.hasExplicitWaitTimeout)
          'waitTimeoutMs': config.waitTimeout.inMilliseconds,
      },
    }, timeout: timeout);
    return _printCliRpcOutcome(resp, out, err);
  } catch (error) {
    err.writeln('Failed querying tools at ${config.resolvedMcpUri}: $error');
    return 1;
  }
}

Future<int> _runCallCommand(
  BridgeCliConfig config,
  Stream<List<int>> input,
  StringSink out,
  StringSink err,
) async {
  final Map<String, Object?> toolArgs;
  try {
    toolArgs = await _readCallArguments(config, input);
  } on FormatException catch (error) {
    err.writeln('Invalid JSON tool arguments: ${error.message}');
    return 64;
  }
  if (config.sessionId case final sid?) {
    toolArgs.putIfAbsent('sessionId', () => sid);
  }
  final timeout =
      config.waitTimeout + config.callTimeout + const Duration(seconds: 5);
  try {
    final resp = await postMcpHttp(config.resolvedMcpUri, <String, Object?>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': <String, Object?>{
        'name': config.toolName,
        'arguments': toolArgs,
        if (config.hasExplicitWaitTimeout)
          'waitTimeoutMs': config.waitTimeout.inMilliseconds,
      },
    }, timeout: timeout);
    return _printCliRpcOutcome(resp, out, err);
  } catch (error) {
    err.writeln(
      'Failed calling ${config.toolName} at ${config.resolvedMcpUri}: $error',
    );
    return 1;
  }
}

Future<Map<String, Object?>> _readCallArguments(
  BridgeCliConfig config,
  Stream<List<int>> input,
) async {
  final raw = config.useStdinArgs
      ? await utf8.decoder.bind(input).join()
      : (config.rawJsonArgs ?? '{}');
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return <String, Object?>{};
  }
  final decoded = jsonDecode(trimmed);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Expected a JSON object (`{...}`).');
  }
  return Map<String, Object?>.of(decoded);
}

int _printCliRpcOutcome(Object? resp, StringSink out, StringSink err) {
  if (resp is! Map<String, Object?>) {
    err.writeln('Unexpected empty or non-object response from MCP bridge.');
    return 1;
  }
  if (resp['error'] case final Map<String, Object?> rpcErr) {
    err.writeln(const JsonEncoder.withIndent('  ').convert(rpcErr));
    return 1;
  }
  final result = resp['result'];
  if (result is Map<String, Object?> && result['isError'] == true) {
    err.writeln(const JsonEncoder.withIndent('  ').convert(result));
    return 1;
  }
  final payload =
      result is Map<String, Object?> && result.containsKey('structuredContent')
      ? result['structuredContent']
      : result;
  _writeSafe(out, const JsonEncoder.withIndent('  ').convert(payload));
  return 0;
}

/// Returns `true` when [error] represents a closed consumer pipe (`EPIPE`).
bool isBrokenPipeError(Object error) {
  final osCode = switch (error) {
    SocketException(:final osError?) => osError.errorCode,
    FileSystemException(:final osError?) => osError.errorCode,
    _ => null,
  };
  if (osCode == 32 || osCode == 232) {
    return true;
  }
  return '$error'.toLowerCase().contains('broken pipe');
}

bool _isBrokenPipeError(Object error) => isBrokenPipeError(error);

void _writeSafe(StringSink sink, String text, {bool newline = true}) {
  try {
    if (newline) {
      sink.writeln(text);
    } else {
      sink.write(text);
    }
  } on IOException catch (error) {
    if (!_isBrokenPipeError(error)) {
      rethrow;
    }
  }
}

Future<void> _flushSafe(IOSink sink) async {
  try {
    await sink.flush();
  } on IOException catch (error) {
    if (!_isBrokenPipeError(error)) {
      rethrow;
    }
  }
}

Future<int> _runServeCommand(
  BridgeCliConfig config,
  Stream<List<int>> input,
  StringSink out,
  StringSink err,
  Future<void>? stopSignal,
) async {
  final proxyUri = await _resolveStdioProxyTarget(config);
  if (proxyUri != null) {
    err.writeln(
      '[dartpad_mcp] Forwarding stdio MCP to active bridge at $proxyUri',
    );
    final timeout =
        config.waitTimeout + config.callTimeout + const Duration(seconds: 5);
    await runMcpStdioLoop(
      input: input,
      out: out,
      handler: (payload) => postMcpHttp(
        proxyUri,
        payload ?? const <String, Object?>{},
        timeout: timeout,
      ),
    );
    return 0;
  }

  final bridge = await DartPadMcpBridge.start(
    host: config.host,
    port: config.port,
    waitTimeout: config.waitTimeout,
    callTimeout: config.callTimeout,
    logSink: err,
  );
  try {
    await _announceBoundBridge(bridge, config, err);
    if (config.stdio) {
      await runMcpStdioLoop(
        input: input,
        out: out,
        handler: bridge.handleMcpPayload,
      );
    } else {
      await (stopSignal ?? _waitForProcessTermination());
    }
    return 0;
  } finally {
    await bridge.close();
  }
}

Future<Uri?> _resolveStdioProxyTarget(BridgeCliConfig config) async {
  if (!config.stdio) {
    return null;
  }
  if (config.connectHttp case final explicit?) {
    return normalizeMcpEndpointUri(explicit);
  }
  if (config.port == 0) {
    return null;
  }
  final existing = await fetchBridgeHealth(config.resolvedHealthUri);
  return existing != null ? config.resolvedMcpUri : null;
}

Future<void> _announceBoundBridge(
  DartPadMcpBridge bridge,
  BridgeCliConfig config,
  StringSink err,
) async {
  final bound = bridge.port;
  if (config.portFile case final path?) {
    await File(path).writeAsString('$bound\n');
  }
  err
    ..writeln('[dartpad_mcp] Listening on port $bound (host: ${config.host})')
    ..writeln('  WebSocket Hub     : ws://127.0.0.1:$bound/mcp-ws')
    ..writeln('  MCP HTTP Endpoint : http://127.0.0.1:$bound/mcp')
    ..writeln('  Health Check      : http://127.0.0.1:$bound/healthz');
}

Future<void> _waitForProcessTermination() async {
  final done = Completer<void>();
  StreamSubscription<ProcessSignal>? sigintSub;
  StreamSubscription<ProcessSignal>? sigtermSub;

  void finish(ProcessSignal _) {
    if (!done.isCompleted) {
      done.complete();
    }
  }

  sigintSub = ProcessSignal.sigint.watch().listen(finish);
  if (!Platform.isWindows) {
    sigtermSub = ProcessSignal.sigterm.watch().listen(finish);
  }
  try {
    await done.future;
  } finally {
    await sigintSub.cancel();
    await sigtermSub?.cancel();
  }
}

Future<void> main(List<String> args) async {
  unawaited(stdout.done.catchError((Object _) {}, test: isBrokenPipeError));
  unawaited(stderr.done.catchError((Object _) {}, test: isBrokenPipeError));
  final code = await runDartPadMcpCli(args);
  await _flushSafe(stdout);
  await _flushSafe(stderr);
  if (code != 0) {
    exitCode = code;
  }
}
