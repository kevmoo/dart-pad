// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'webmcp_models.dart';

/// Outbound reconnecting JSON-RPC 2.0 WebSocket client bridging browser-resident
/// DartPad WebMCP tools to a local MCP relay daemon.
final class WebMcpWsClient {
  WebMcpWsClient({
    required this.endpoint,
    required List<WebMcpToolSpec> tools,
    required this.getSessionId,
    required this.getPageUrl,
    this.reconnectDelay = const Duration(seconds: 1),
  }) : _tools = List<WebMcpToolSpec>.unmodifiable(tools),
       _toolsByName = <String, WebMcpToolSpec>{
         for (final tool in tools) tool.name: tool,
       };

  final Uri endpoint;
  final List<WebMcpToolSpec> _tools;
  final Map<String, WebMcpToolSpec> _toolsByName;
  final String? Function() getSessionId;
  final String Function() getPageUrl;
  final Duration reconnectDelay;

  web.WebSocket? _socket;
  Timer? _reconnectTimer;
  bool _disposed = false;
  String? _lastAnnouncedSessionId;
  String? _lastAnnouncedUrl;

  /// Opens the initial WebSocket connection and enables automatic reconnect.
  void start() {
    if (_disposed) {
      return;
    }
    _connect();
  }

  /// Re-announces `webmcp/hello` if the session id or browser URL changed while
  /// the WebSocket is already open.
  void notifyMetadataChanged() {
    final socket = _socket;
    if (_disposed || socket == null || socket.readyState != web.WebSocket.OPEN) {
      return;
    }
    final sessionId = getSessionId();
    final url = getPageUrl();
    if (sessionId == _lastAnnouncedSessionId && url == _lastAnnouncedUrl) {
      return;
    }
    _sendHello(socket);
  }

  /// Permanently closes the WebSocket client and cancels reconnect timers.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        socket.close();
      } catch (_) {
        // Ignore close errors during teardown.
      }
    }
  }

  void _connect() {
    if (_disposed || _socket != null) {
      return;
    }
    web.WebSocket socket;
    try {
      socket = web.WebSocket(endpoint.toString());
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _socket = socket;
    socket.onopen = ((web.Event _) {
      if (_disposed || !identical(_socket, socket)) {
        socket.close();
        return;
      }
      _sendHello(socket);
    }).toJS;
    socket.onmessage = ((web.MessageEvent event) {
      final raw = event.data;
      if (raw != null && raw.typeofEquals('string')) {
        unawaited(_handleMessage(socket, (raw as JSString).toDart));
      }
    }).toJS;
    socket.onclose = ((web.CloseEvent _) {
      if (identical(_socket, socket)) {
        _socket = null;
        _scheduleReconnect();
      }
    }).toJS;
  }

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer != null) {
      return;
    }
    _reconnectTimer = Timer(reconnectDelay, () {
      _reconnectTimer = null;
      _connect();
    });
  }

  void _sendHello(web.WebSocket socket) {
    final sessionId = getSessionId();
    final url = getPageUrl();
    _lastAnnouncedSessionId = sessionId;
    _lastAnnouncedUrl = url;
    _sendJson(socket, <String, Object?>{
      'jsonrpc': '2.0',
      'method': 'webmcp/hello',
      'params': <String, Object?>{
        'sessionId': sessionId,
        'url': url,
        'tools': <Map<String, Object?>>[
          for (final tool in _tools) tool.toWireJson(),
        ],
      },
    });
  }

  Future<void> _handleMessage(web.WebSocket socket, String payload) async {
    final Map<String, Object?> message;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        return;
      }
      message = Map<String, Object?>.from(decoded);
    } catch (_) {
      return;
    }

    if (!message.containsKey('id')) {
      return;
    }
    final id = message['id'];
    final method = message['method'] as String?;
    if (method == null) {
      return;
    }

    final response = await _dispatchRequest(id, method, message['params']);
    if (!_disposed && identical(_socket, socket) && socket.readyState == web.WebSocket.OPEN) {
      _sendJson(socket, response);
    }
  }

  Future<Map<String, Object?>> _dispatchRequest(
    Object? id,
    String method,
    Object? rawParams,
  ) async {
    switch (method) {
      case 'ping':
        return <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': const <String, Object?>{},
        };
      case 'tools/list':
        return <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{
            'tools': <Map<String, Object?>>[
              for (final tool in _tools) tool.toWireJson(),
            ],
          },
        };
      case 'tools/call':
        return _executeToolCall(id, rawParams);
      default:
        return <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, Object?>{
            'code': -32601,
            'message': 'Method not found: $method',
          },
        };
    }
  }

  Future<Map<String, Object?>> _executeToolCall(Object? id, Object? rawParams) async {
    final params = rawParams is Map ? Map<String, Object?>.from(rawParams) : const <String, Object?>{};
    final name = params['name'] as String? ?? '';
    final spec = _toolsByName[name];
    if (spec == null) {
      return _buildCallToolError(id, 'Unknown tool: $name');
    }
    final rawArgs = params['arguments'];
    final arguments = rawArgs is Map ? Map<String, Object?>.from(rawArgs) : const <String, Object?>{};
    try {
      final result = await spec.handler(arguments);
      return <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{
              'type': 'text',
              'text': jsonEncode(result),
            },
          ],
          'structuredContent': result,
          'isError': false,
        },
      };
    } catch (error) {
      return _buildCallToolError(id, error.toString());
    }
  }

  Map<String, Object?> _buildCallToolError(Object? id, String message) => <String, Object?>{
    'jsonrpc': '2.0',
    'id': id,
    'result': <String, Object?>{
      'content': <Map<String, Object?>>[
        <String, Object?>{
          'type': 'text',
          'text': message,
        },
      ],
      'structuredContent': <String, Object?>{
        'error': message,
      },
      'isError': true,
    },
  };

  void _sendJson(web.WebSocket socket, Map<String, Object?> payload) {
    if (socket.readyState != web.WebSocket.OPEN) {
      return;
    }
    socket.send(jsonEncode(payload).toJS);
  }
}
