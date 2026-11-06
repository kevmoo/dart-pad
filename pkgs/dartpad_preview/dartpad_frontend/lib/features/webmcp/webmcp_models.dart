// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Asynchronous handler invoked for a WebMCP tool call.
typedef WebMcpToolHandler =
    Future<Map<String, Object?>> Function(
      Map<String, Object?> arguments,
    );

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
