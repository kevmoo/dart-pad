// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:meta/meta.dart';

/// Asynchronous handler invoked for a WebMCP tool call.
typedef WebMcpToolHandler =
    Future<Map<String, Object?>> Function(
      Map<String, Object?> arguments,
    );

/// Connection lifecycle phase of the outbound loopback WebSocket MCP bridge.
enum McpConnectionPhase {
  /// Loopback WebSocket bridge is inactive (default until enabled or `?mcp_port=`).
  disabled,

  /// Actively attempting or retrying connection to `ws://127.0.0.1:<port>/mcp-ws`.
  connecting,

  /// Connected to the local MCP bridge with `webmcp/hello` announced.
  connected,
}

/// Immutable snapshot of DartPad's outbound loopback MCP bridge state.
@immutable
final class McpBridgeStatus {
  const McpBridgeStatus({
    this.phase = McpConnectionPhase.disabled,
    this.port = 8787,
    this.endpoint,
    this.activeToolCalls = 0,
    this.lastToolName,
  });

  final McpConnectionPhase phase;
  final int port;
  final Uri? endpoint;
  final int activeToolCalls;
  final String? lastToolName;

  bool get isBusy => activeToolCalls > 0;

  McpBridgeStatus copyWith({
    McpConnectionPhase? phase,
    int? port,
    Uri? endpoint,
    bool clearEndpoint = false,
    int? activeToolCalls,
    String? lastToolName,
  }) => McpBridgeStatus(
    phase: phase ?? this.phase,
    port: port ?? this.port,
    endpoint: clearEndpoint ? null : (endpoint ?? this.endpoint),
    activeToolCalls: activeToolCalls ?? this.activeToolCalls,
    lastToolName: lastToolName ?? this.lastToolName,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpBridgeStatus &&
          phase == other.phase &&
          port == other.port &&
          endpoint == other.endpoint &&
          activeToolCalls == other.activeToolCalls &&
          lastToolName == other.lastToolName;

  @override
  int get hashCode => Object.hash(phase, port, endpoint, activeToolCalls, lastToolName);
}

/// Declarative specification and handler for a single DartPad WebMCP tool.
final class WebMcpToolSpec {
  const WebMcpToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.readOnlyHint,
    required this.handler,
  });

  /// Canonical MCP tool name (for example `dartpad_get_status`).
  final String name;

  /// Human- and model-readable tool description.
  final String description;

  /// JSON Schema describing the tool's input object.
  final Map<String, Object?> inputSchema;

  /// Whether the tool only reads workspace/runtime state without mutating it.
  final bool readOnlyHint;

  /// Asynchronous implementation returning a JSON-serializable object map.
  final WebMcpToolHandler handler;

  /// Serializes tool metadata for MCP `tools/list` and `webmcp/hello` payloads.
  Map<String, Object?> toWireJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    'annotations': {
      'readOnlyHint': readOnlyHint,
    },
  };
}
