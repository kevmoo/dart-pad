// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

final RegExp _workspacePrefixPattern = RegExp(
  r'^(?:file:///workspace/|/workspace/|org-dartlang-app:///)',
);
final RegExp _padSlotPrefixPattern = RegExp(r'^pad_\d+/');
final RegExp _pubCacheHostedPattern = RegExp(
  r'(?:^|/)\.pub-cache/hosted/[^/]+/([a-zA-Z0-9_]+)-[^/]+/(?:lib/)?(.+)$',
);
final RegExp _pubCacheGitPattern = RegExp(
  r'(?:^|/)\.pub-cache/git/([a-zA-Z0-9_]+)-[^/]+/(?:lib/)?(.+)$',
);
final RegExp _sdkPackagesPattern = RegExp(
  r'(?:^|/)packages/([a-zA-Z0-9_]+)/(?:lib/)?(.+)$',
);
final RegExp _dartSdkLibPattern = RegExp(r'(?:^|/)(?:dart-)?sdk/lib/(.+)$');
final RegExp _mainHeaderPattern = RegExp(
  r'\bmain\s*(?:<[^>]*>)?\s*\([^)]*\)\s*(?:async\s*\*?|sync\s*\*)?\s*',
);
final RegExp _runAppWidgetPattern = RegExp(
  r'\brunApp\s*\(\s*(?:const\s+|new\s+)?([A-Za-z_$][A-Za-z0-9_$]*)',
);

/// Result of compacting a Flutter `WidgetInspectorService` summary tree for MCP.
final class CompactedWidgetTree {
  const CompactedWidgetTree({
    required this.tree,
    required this.totalNodeCount,
    required this.returnedNodeCount,
    required this.prunedFrameworkNodeCount,
  });

  final Object? tree;
  final int totalNodeCount;
  final int returnedNodeCount;
  final int prunedFrameworkNodeCount;
}

/// Returns `true` when [rawUri] points to a file inside the user's DartPad
/// workspace rather than the Flutter SDK or `.pub-cache`.
bool isWorkspaceInspectorUri(String? rawUri) {
  if (rawUri == null || rawUri.isEmpty) {
    return false;
  }
  if (_workspacePrefixPattern.hasMatch(rawUri)) {
    return true;
  }
  return !rawUri.contains('://') &&
      !rawUri.startsWith('/') &&
      !rawUri.startsWith('package:') &&
      !rawUri.startsWith('dart:') &&
      !rawUri.contains('.pub-cache/');
}

/// Relativizes and sanitizes compiler/VM Service URIs so build-host filesystem
/// paths (`file:///usr/...`, `.pub-cache/...`, `packages/flutter/...`) never leak.
String sanitizeInspectorFileUri(String rawUri) {
  final String trimmed = rawUri.trim();
  if (trimmed.isEmpty || trimmed.startsWith('package:') || trimmed.startsWith('dart:')) {
    return trimmed;
  }
  final String normalized = trimmed.replaceAll(r'\', '/');
  if (_workspacePrefixPattern.firstMatch(normalized) case final Match m) {
    final String rest = normalized.substring(m.end).replaceFirst(_padSlotPrefixPattern, '');
    return rest.isEmpty ? 'main.dart' : rest;
  }
  if (_matchPackageUri(normalized) case final String packageUri) {
    return packageUri;
  }
  if (_dartSdkLibPattern.firstMatch(normalized) case final Match sdkMatch) {
    return 'dart:${sdkMatch.group(1)}';
  }
  if (normalized.contains('://') || normalized.startsWith('/') || RegExp(r'^[a-zA-Z]:/').hasMatch(normalized)) {
    final int slash = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.substring(slash + 1) : normalized;
  }
  return normalized;
}

String? _matchPackageUri(String normalized) {
  for (final RegExp pattern in <RegExp>[
    _pubCacheHostedPattern,
    _pubCacheGitPattern,
    _sdkPackagesPattern,
  ]) {
    if (pattern.firstMatch(normalized) case final Match m) {
      return 'package:${m.group(1)}/${m.group(2)}';
    }
  }
  return null;
}

/// Compacts a Flutter Widget Inspector JSON tree by sanitizing all file URIs,
/// stripping internal inspector noise fields, and splicing out intermediate
/// `.pub-cache` / framework nodes unless [includeFrameworkNodes] is `true`.
CompactedWidgetTree compactFlutterWidgetTree(
  Object? rawTree, {
  bool includeFrameworkNodes = false,
}) {
  if (rawTree is! Map) {
    return CompactedWidgetTree(
      tree: rawTree,
      totalNodeCount: 0,
      returnedNodeCount: 0,
      prunedFrameworkNodeCount: 0,
    );
  }
  final ({int count, bool hasWorkspace}) scan = _scanRawTree(rawTree);
  final _TreeCounter counter = _TreeCounter();
  final List<Map<String, Object?>> roots = _compactNode(
    rawTree,
    depth: 0,
    includeFrameworkNodes: includeFrameworkNodes,
    hasWorkspaceNodes: scan.hasWorkspace,
    counter: counter,
  );
  return CompactedWidgetTree(
    tree: roots.firstOrNull,
    totalNodeCount: scan.count,
    returnedNodeCount: counter.returned,
    prunedFrameworkNodeCount: counter.pruned,
  );
}

final class _TreeCounter {
  int returned = 0;
  int pruned = 0;
}

({int count, bool hasWorkspace}) _scanRawTree(Map<Object?, Object?> node) {
  var count = 1;
  var hasWorkspace = isWorkspaceInspectorUri(_extractRawLocationFile(node));
  if (node['children'] case final List<Object?> children) {
    for (final Object? child in children) {
      if (child is Map<Object?, Object?>) {
        final ({int count, bool hasWorkspace}) sub = _scanRawTree(child);
        count += sub.count;
        hasWorkspace = hasWorkspace || sub.hasWorkspace;
      }
    }
  }
  return (count: count, hasWorkspace: hasWorkspace);
}

List<Map<String, Object?>> _compactNode(
  Map<Object?, Object?> node, {
  required int depth,
  required bool includeFrameworkNodes,
  required bool hasWorkspaceNodes,
  required _TreeCounter counter,
}) {
  final List<Map<String, Object?>> compactedChildren = <Map<String, Object?>>[];
  if (node['children'] case final List<Object?> rawChildren) {
    for (final Object? child in rawChildren) {
      if (child is Map<Object?, Object?>) {
        compactedChildren.addAll(
          _compactNode(
            child,
            depth: depth + 1,
            includeFrameworkNodes: includeFrameworkNodes,
            hasWorkspaceNodes: hasWorkspaceNodes,
            counter: counter,
          ),
        );
      }
    }
  }

  final bool keepNode = _shouldKeepNode(
    node,
    depth: depth,
    includeFrameworkNodes: includeFrameworkNodes,
    hasWorkspaceNodes: hasWorkspaceNodes,
  );
  if (!keepNode) {
    counter.pruned++;
    return compactedChildren;
  }

  counter.returned++;
  return <Map<String, Object?>>[
    _buildCleanNodeMap(node, compactedChildren),
  ];
}

bool _shouldKeepNode(
  Map<Object?, Object?> node, {
  required int depth,
  required bool includeFrameworkNodes,
  required bool hasWorkspaceNodes,
}) {
  if (includeFrameworkNodes || depth == 0) {
    return true;
  }
  if (!hasWorkspaceNodes) {
    return depth <= 3;
  }
  return isWorkspaceInspectorUri(_extractRawLocationFile(node));
}

String? _extractRawLocationFile(Map<Object?, Object?> node) {
  final Object? loc = node['creationLocation'];
  if (loc is Map<Object?, Object?> && loc['file'] is String) {
    return loc['file'] as String;
  }
  return null;
}

Map<String, Object?> _buildCleanNodeMap(
  Map<Object?, Object?> node,
  List<Map<String, Object?>> children,
) {
  final Map<String, Object?> out = <String, Object?>{};
  if (node['description'] case final String desc when desc.isNotEmpty) {
    out['description'] = desc;
  }
  if (node['widgetRuntimeType'] case final String rt when rt.isNotEmpty) {
    out['widgetRuntimeType'] = rt;
  }
  if (node['textPreview'] case final String preview when preview.isNotEmpty) {
    out['textPreview'] = preview;
  }
  if (node['stateful'] == true) {
    out['stateful'] = true;
  }
  if (_sanitizeLocationMap(node['creationLocation']) case final Map<String, Object?> loc) {
    out['creationLocation'] = loc;
  }
  if (children.isNotEmpty) {
    out['children'] = children;
  }
  return out;
}

Map<String, Object?>? _sanitizeLocationMap(Object? rawLoc) {
  if (rawLoc is! Map<Object?, Object?>) {
    return null;
  }
  final Object? rawFile = rawLoc['file'];
  if (rawFile is! String || rawFile.isEmpty) {
    return null;
  }
  return <String, Object?>{
    'file': sanitizeInspectorFileUri(rawFile),
    if (rawLoc['line'] case final int line) 'line': line,
    if (rawLoc['column'] case final int column) 'column': column,
    if (rawLoc['name'] case final String name when name.isNotEmpty) 'name': name,
  };
}

/// Extracts the root widget class identifier passed to `runApp(...)` inside
/// `main()`, or `null` if none is present.
String? extractRootAppWidgetName(String source) {
  final String stripped = _stripDartComments(source);
  final String? mainSlice = _extractMainFunctionSlice(stripped);
  if (mainSlice == null) {
    return null;
  }
  return _runAppWidgetPattern.firstMatch(mainSlice)?.group(1);
}

/// Computes a whitespace- and comment-normalized signature of `main()` plus the
/// root `runApp(...)` widget's class declaration header so `dartpad_run_or_reload`
/// (`action: "auto"`) promotes to `hot_restart` whenever `main()` or the root
/// widget class changes.
String extractEntrypointLaunchSignature(String source) {
  final String stripped = _stripDartComments(source);
  final String? mainSlice = _extractMainFunctionSlice(stripped);
  if (mainSlice == null) {
    return '';
  }
  final String normalizedMain = _collapseWhitespace(mainSlice);
  final String? rootWidget = _runAppWidgetPattern.firstMatch(mainSlice)?.group(1);
  if (rootWidget == null) {
    return normalizedMain;
  }
  final RegExp classHeader = RegExp(
    '\\b(?:(?:abstract|base|final|interface|sealed|mixin)\\s+)*'
    'class\\s+${RegExp.escape(rootWidget)}\\b[^{;]*',
  );
  final String? rawHeader = classHeader.firstMatch(stripped)?.group(0);
  if (rawHeader == null) {
    return normalizedMain;
  }
  return '$normalizedMain|${_collapseWhitespace(rawHeader)}';
}

String _collapseWhitespace(String input) => input.trim().replaceAll(RegExp(r'\s+'), ' ');

String? _extractMainFunctionSlice(String stripped) {
  final Match? match = _mainHeaderPattern.firstMatch(stripped);
  if (match == null) {
    return null;
  }
  final int bodyStart = match.end;
  if (bodyStart >= stripped.length) {
    return stripped.substring(match.start);
  }
  if (stripped.startsWith('=>', bodyStart)) {
    final int semi = _findStatementSemicolon(stripped, bodyStart + 2);
    final int end = semi >= 0 ? semi + 1 : stripped.length;
    return stripped.substring(match.start, end);
  }
  if (stripped.codeUnitAt(bodyStart) == 0x7B /* { */ ) {
    final int closeBrace = _findMatchingBrace(stripped, bodyStart);
    final int end = closeBrace >= 0 ? closeBrace + 1 : stripped.length;
    return stripped.substring(match.start, end);
  }
  return stripped.substring(match.start, bodyStart);
}

int _findMatchingBrace(String text, int openIndex) {
  var depth = 0;
  var i = openIndex;
  while (i < text.length) {
    final int nextQuote = _skipStringLiteral(text, i);
    if (nextQuote > i) {
      i = nextQuote;
      continue;
    }
    final int ch = text.codeUnitAt(i);
    if (ch == 0x7B /* { */ ) {
      depth++;
    } else if (ch == 0x7D /* } */ ) {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
    i++;
  }
  return -1;
}

int _findStatementSemicolon(String text, int startIndex) {
  var parenDepth = 0;
  var braceDepth = 0;
  var i = startIndex;
  while (i < text.length) {
    final int nextQuote = _skipStringLiteral(text, i);
    if (nextQuote > i) {
      i = nextQuote;
      continue;
    }
    final int ch = text.codeUnitAt(i);
    if (ch == 0x28 /* ( */ ) {
      parenDepth++;
    } else if (ch == 0x29 /* ) */ && parenDepth > 0) {
      parenDepth--;
    } else if (ch == 0x7B /* { */ ) {
      braceDepth++;
    } else if (ch == 0x7D /* } */ && braceDepth > 0) {
      braceDepth--;
    } else if (ch == 0x3B /* ; */ && parenDepth == 0 && braceDepth == 0) {
      return i;
    }
    i++;
  }
  return -1;
}

String _stripDartComments(String source) {
  final StringBuffer out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final int stringEnd = _skipStringLiteral(source, i);
    if (stringEnd > i) {
      out.write(source.substring(i, stringEnd));
      i = stringEnd;
      continue;
    }
    if (source.startsWith('//', i)) {
      final int nl = source.indexOf('\n', i + 2);
      if (nl < 0) {
        break;
      }
      out.write('\n');
      i = nl + 1;
      continue;
    }
    if (source.startsWith('/*', i)) {
      final int endComment = source.indexOf('*/', i + 2);
      out.write(' ');
      i = endComment < 0 ? source.length : endComment + 2;
      continue;
    }
    out.writeCharCode(source.codeUnitAt(i));
    i++;
  }
  return out.toString();
}

int _skipStringLiteral(String source, int index) {
  var cursor = index;
  var isRaw = false;
  if (cursor + 1 < source.length &&
      source.codeUnitAt(cursor) == 0x72 /* r */ &&
      (source.codeUnitAt(cursor + 1) == 0x27 || source.codeUnitAt(cursor + 1) == 0x22)) {
    isRaw = true;
    cursor++;
  }
  final int quote = source.codeUnitAt(cursor);
  if (quote != 0x27 /* ' */ && quote != 0x22 /* " */ ) {
    return index;
  }
  final String triple = quote == 0x27 ? "'''" : '"""';
  if (source.startsWith(triple, cursor)) {
    final int close = _findTripleQuoteEnd(source, cursor + 3, triple, isRaw: isRaw);
    return close < 0 ? source.length : close;
  }
  cursor++;
  while (cursor < source.length) {
    final int ch = source.codeUnitAt(cursor);
    if (!isRaw && ch == 0x5C /* \ */ ) {
      cursor += 2;
      continue;
    }
    if (ch == quote || ch == 0x0A) {
      return cursor + 1;
    }
    cursor++;
  }
  return source.length;
}

int _findTripleQuoteEnd(
  String source,
  int start,
  String triple, {
  required bool isRaw,
}) {
  var cursor = start;
  while (cursor < source.length) {
    if (!isRaw && source.codeUnitAt(cursor) == 0x5C /* \ */ ) {
      cursor += 2;
      continue;
    }
    if (source.startsWith(triple, cursor)) {
      return cursor + 3;
    }
    cursor++;
  }
  return -1;
}
