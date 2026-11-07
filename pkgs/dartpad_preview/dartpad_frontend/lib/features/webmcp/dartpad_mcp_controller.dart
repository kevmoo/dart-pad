// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:dartpad/dartpad.dart';
import 'package:dartpad_editor/dartpad_editor.dart';
import 'package:jaspr/jaspr.dart';

import '../editor/codemirror/code_mirror_tab.dart';
import '../preview/models/preview_state.dart';
import '../preview/models/run_mode.dart';
import '../shared/events/log_event.dart';
import '../shared/supported_file_types.dart';
import '../shared/task_status.dart';
import '../shared/unthrottled_timer.dart';
import '../startup/project_loader.dart';
import '../startup/query_parameters.dart';
import '../workspace/workspace_session.dart';
import 'webmcp_js_interop.dart';
import 'webmcp_models.dart';
import 'webmcp_ws_client.dart';

const _allowedPubCommands = <String>{'get', 'add', 'remove', 'upgrade', 'outdated'};
const _allowedRunActions = <String>{'auto', 'run', 'hot_reload', 'hot_restart'};
const _inspectorGroupName = 'webmcp';

/// Host state bridge supplied by the top-level application state to
/// [DartPadMcpController].
abstract interface class DartPadMcpHost {
  /// The currently active workspace session, or `null` while loading.
  WorkspaceSession? get activeSession;

  /// Whether the workspace is still loading project files or switching SDKs.
  bool get isInitializingWorkspace;

  /// Fatal workspace preparation error, if startup failed.
  String? get workspacePreparationFailure;

  /// Completes when background startup tools (initial pub get, auto-run, LSP)
  /// have finished attaching for [activeSession].
  Future<void>? get workspaceToolsReady;

  /// The current session id (`s` query parameter), if assigned.
  String? get sessionId;

  /// The current browser URI (reflecting `history.replaceState` updates).
  Uri get currentUri;
}

/// Orchestrates DartPad Preview's unified WebMCP tool suite across both W3C
/// `document.modelContext` (in-browser) and an optional outbound WebSocket
/// MCP relay (`?mcp=1`, `?mcp_port=`, `?mcp_ws=`).
final class DartPadMcpController {
  DartPadMcpController({
    required this.host,
    bool installBrowserRegistry = true,
    bool connectWebSocket = true,
    this.analyzerIdleWindow = const Duration(milliseconds: 180),
    this.analyzerSettleTimeout = const Duration(seconds: 15),
    this.postRunFrameDelay = const Duration(milliseconds: 300),
    this.customPubRunner,
  }) {
    tools = _buildToolSpecs();
    if (installBrowserRegistry) {
      _browserRegistry = WebMcpBrowserRegistry()..registerTools(tools);
    }
    if (connectWebSocket) {
      final wsEndpoint = QueryParameters.resolveMcpWebSocketUri(host.currentUri);
      if (wsEndpoint != null) {
        enableLocalBridge(customEndpoint: wsEndpoint);
      }
    }
  }

  final DartPadMcpHost host;
  final Duration analyzerIdleWindow;
  final Duration analyzerSettleTimeout;
  final Duration postRunFrameDelay;

  /// Optional test hook overriding worker `pub` execution.
  final Future<String> Function(
    WorkspaceSession session, {
    required String path,
    required String command,
    required List<String> args,
  })?
  customPubRunner;

  /// All registered WebMCP tool definitions in canonical order.
  late final List<WebMcpToolSpec> tools;

  final ValueNotifier<McpBridgeStatus> _status = ValueNotifier(const McpBridgeStatus());

  /// Reactive outbound MCP WebSocket bridge status for UI pills and dialogs.
  ValueListenable<McpBridgeStatus> get statusListenable => _status;

  McpBridgeStatus get status => _status.value;

  WebMcpBrowserRegistry? _browserRegistry;
  WebMcpWsClient? _wsClient;
  bool _disposed = false;

  /// Starts or retargets the outbound loopback MCP WebSocket bridge in memory
  /// without requiring a full page reload.
  void enableLocalBridge({int port = 8787, Uri? customEndpoint}) {
    if (_disposed) {
      return;
    }
    final target =
        customEndpoint ??
        Uri(
          scheme: 'ws',
          host: '127.0.0.1',
          port: port,
          path: '/mcp-ws',
        );
    final effectivePort = target.hasPort ? target.port : port;
    if (_wsClient?.endpoint == target && _status.value.phase != McpConnectionPhase.disabled) {
      return;
    }
    _wsClient?.dispose();
    _status.value = McpBridgeStatus(
      phase: McpConnectionPhase.connecting,
      port: effectivePort,
      endpoint: target,
    );
    late final WebMcpWsClient client;
    client = WebMcpWsClient(
      endpoint: target,
      tools: tools,
      getSessionId: () => host.sessionId,
      getPageUrl: () => host.currentUri.toString(),
      onConnectionChanged: ({required isConnected}) {
        if (_disposed || !identical(_wsClient, client)) {
          return;
        }
        _status.value = _status.value.copyWith(
          phase: isConnected ? McpConnectionPhase.connected : McpConnectionPhase.connecting,
          activeToolCalls: isConnected ? _status.value.activeToolCalls : 0,
        );
      },
      onToolActivity: (toolName, {required started}) {
        if (_disposed || !identical(_wsClient, client)) {
          return;
        }
        final current = _status.value.activeToolCalls;
        final nextCount = started ? current + 1 : (current > 0 ? current - 1 : 0);
        _status.value = _status.value.copyWith(
          activeToolCalls: nextCount,
          lastToolName: toolName,
        );
      },
    );
    _wsClient = client..start();
  }

  /// Stops outbound loopback WebSocket reconnects and marks the bridge disabled.
  void disableLocalBridge() {
    if (_disposed) {
      return;
    }
    final currentPort = _status.value.port;
    _wsClient?.dispose();
    _wsClient = null;
    _status.value = McpBridgeStatus(
      phase: McpConnectionPhase.disabled,
      port: currentPort,
    );
  }

  /// Invokes a tool directly by [name] (used by unit tests and internal callers).
  Future<Map<String, Object?>> callTool(
    String name, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) {
    final spec = tools.where((entry) => entry.name == name).firstOrNull;
    if (spec == null) {
      throw ArgumentError.value(name, 'name', 'Unknown WebMCP tool.');
    }
    return spec.handler(arguments);
  }

  /// Notifies the outbound WebSocket client when session metadata (`s` or URL)
  /// updates after startup.
  void notifySessionChanged() {
    if (!_disposed) {
      _wsClient?.notifyMetadataChanged();
    }
  }

  /// Releases browser tool registrations and closes any active WebSocket bridge.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _wsClient?.dispose();
    _wsClient = null;
    _browserRegistry?.dispose();
    _browserRegistry = null;
    _status.dispose();
  }

  List<WebMcpToolSpec> _buildToolSpecs() => List<WebMcpToolSpec>.unmodifiable(<WebMcpToolSpec>[
    WebMcpToolSpec(
      name: 'dartpad_get_status',
      description:
          'Returns live DartPad workspace status including sessionId, SDK, run mode, '
          'entrypoint, preview state, open tabs, analyzer activity, and diagnostic counts.',
      readOnlyHint: true,
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      },
      handler: _handleGetStatus,
    ),
    WebMcpToolSpec(
      name: 'dartpad_list_files',
      description: 'Lists files and folders in the active DartPad workspace.',
      readOnlyHint: true,
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{
            'type': 'string',
            'description': 'Workspace-relative directory path (defaults to project root).',
          },
          'recursive': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether to recurse into subdirectories (defaults to true).',
          },
        },
      },
      handler: _handleListFiles,
    ),
    WebMcpToolSpec(
      name: 'dartpad_read_file',
      description: 'Reads the current contents of a workspace file (preferring live open editor buffers).',
      readOnlyHint: true,
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{
            'type': 'string',
            'description': 'Workspace-relative file path to read (for example "lib/main.dart").',
          },
        },
        'required': <String>['path'],
      },
      handler: _handleReadFile,
    ),
    WebMcpToolSpec(
      name: 'dartpad_write_files',
      description:
          'Creates, updates, or deletes files in the DartPad workspace, syncs open CodeMirror tabs '
          'and the worker filesystem, waits for the Dart analyzer to settle, and returns diagnostics.',
      readOnlyHint: false,
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'files': <String, Object?>{
            'type': 'array',
            'description': 'Files to create or overwrite.',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'path': <String, Object?>{'type': 'string'},
                'content': <String, Object?>{'type': 'string'},
              },
              'required': <String>['path', 'content'],
            },
          },
          'deletePaths': <String, Object?>{
            'type': 'array',
            'description': 'Workspace-relative file or folder paths to delete.',
            'items': <String, Object?>{'type': 'string'},
          },
          'openInEditor': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether written files should be opened in editor tabs (defaults to true).',
          },
        },
      },
      handler: _handleWriteFiles,
    ),
    WebMcpToolSpec(
      name: 'dartpad_get_diagnostics',
      description: 'Waits for active analysis to settle and returns current Dart analyzer diagnostics.',
      readOnlyHint: true,
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'severity': <String, Object?>{
            'type': 'string',
            'description': 'Optional severity filter: error, warning, info, or hint.',
          },
        },
      },
      handler: _handleGetDiagnostics,
    ),
    WebMcpToolSpec(
      name: 'dartpad_pub',
      description: 'Runs a Dart/Flutter pub command (get, add, remove, upgrade, outdated) in the workspace.',
      readOnlyHint: false,
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'command': <String, Object?>{
            'type': 'string',
            'enum': <String>['get', 'add', 'remove', 'upgrade', 'outdated'],
            'description': 'Pub subcommand to execute.',
          },
          'args': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
            'description': 'Optional arguments passed to pub (such as package names for "add").',
          },
        },
        'required': <String>['command'],
      },
      handler: _handlePub,
    ),
    WebMcpToolSpec(
      name: 'dartpad_run_or_reload',
      description:
          'Compiles and runs, hot-reloads, or hot-restarts the preview application and returns '
          'updated preview state, console logs, runtime errors, and analyzer diagnostics.',
      readOnlyHint: false,
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>['auto', 'run', 'hot_reload', 'hot_restart'],
            'description': 'Execution action (defaults to "auto", preferring hot_reload when available).',
          },
          'entrypoint': <String, Object?>{
            'type': 'string',
            'description': 'Optional workspace-relative Dart entrypoint to run.',
          },
        },
      },
      handler: _handleRunOrReload,
    ),
    WebMcpToolSpec(
      name: 'dartpad_get_logs',
      description: 'Reads buffered console output and runtime errors from the preview sandbox.',
      readOnlyHint: true,
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'errorsOnly': <String, Object?>{
            'type': 'boolean',
            'description': 'When true, returns only error entries.',
          },
          'clear': <String, Object?>{
            'type': 'boolean',
            'description': 'When true, clears the sandbox log buffer after reading.',
          },
          'limit': <String, Object?>{
            'type': 'integer',
            'description': 'Maximum number of most-recent log entries to return.',
          },
        },
      },
      handler: _handleGetLogs,
    ),
    WebMcpToolSpec(
      name: 'dartpad_inspect_widget_tree',
      description:
          'Connects to the running sandbox Dart VM Service and returns the Flutter widget summary '
          'tree (with text previews) or isolate details for non-Flutter runs.',
      readOnlyHint: true,
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      },
      handler: _handleInspectWidgetTree,
    ),
  ]);

  Future<Map<String, Object?>> _handleGetStatus(Map<String, Object?> _) async {
    final session = await _waitForActiveSession();
    final sdk = session.repository.sdk;
    final diagnostics = session.diagnostics.diagnostics;
    return <String, Object?>{
      'sessionId': host.sessionId,
      'sdk': sdk.id,
      'sdkVersion': sdk.flutterVersion ?? sdk.dartVersion,
      'dartVersion': sdk.dartVersion,
      'flutterVersion': sdk.flutterVersion,
      'runMode': session.preview.previewMode.name,
      'entrypoint': session.preview.entrypoint,
      'previewState': _previewStateName(session.preview.state),
      'canHotReload': session.preview.canHotReload,
      'isInitializing': host.isInitializingWorkspace,
      'isAnalyzing': _isSessionAnalyzing(session),
      'openTabs': <String>[for (final tab in session.tabs.openTabs) tab.path],
      'activeFile': session.tabs.activeFile,
      'diagnosticCounts': _countDiagnosticsBySeverity(diagnostics),
    };
  }

  Future<Map<String, Object?>> _handleListFiles(Map<String, Object?> args) async {
    final session = await _waitForActiveSession();
    final rawPath = args['path'] as String?;
    final targetPath = rawPath == null
        ? normalizeWorkspacePath(session.initialProject.root)
        : ProjectLoader.normalizePath(rawPath, allowRoot: true);
    final recursive = args['recursive'] as bool? ?? true;
    final rawEntries = await session.repository.workspaceResourceApi.listDirectory(
      path: targetPath,
      recursive: recursive,
    );
    final includeDotDartTool = targetPath == '.dart_tool' || targetPath.startsWith('.dart_tool/');
    final filtered =
        rawEntries
            .where((entry) => includeDotDartTool || !entry.path.split('/').contains('.dart_tool'))
            .toList(growable: false)
          ..sort((a, b) => a.path.compareTo(b.path));
    return <String, Object?>{
      'path': targetPath,
      'recursive': recursive,
      'entries': <Map<String, Object?>>[
        for (final entry in filtered)
          <String, Object?>{
            'path': entry.path,
            'type': entry.type,
          },
      ],
      'files': <String>[
        for (final entry in filtered)
          if (entry.type == 'file') entry.path,
      ],
    };
  }

  Future<Map<String, Object?>> _handleReadFile(Map<String, Object?> args) async {
    final session = await _waitForActiveSession();
    final rawPath = args['path'] as String?;
    if (rawPath == null || rawPath.trim().isEmpty) {
      throw ArgumentError.value(rawPath, 'path', 'Expected a non-empty workspace file path.');
    }
    final path = ProjectLoader.normalizePath(rawPath);
    final openTab = session.tabs.getTab(path);
    if (openTab is CodeMirrorTab) {
      return <String, Object?>{
        'path': path,
        'content': openTab.content,
        'isOpen': true,
        'isDirty': openTab.hasUnsavedChanges,
      };
    }
    final api = session.repository.workspaceResourceApi;
    if (!await api.fileExist(path)) {
      throw StateError('File not found in workspace: $path');
    }
    final content = await api.readFileAsText(path);
    return <String, Object?>{
      'path': path,
      'content': content,
      'isOpen': openTab != null,
      'isDirty': false,
    };
  }

  Future<Map<String, Object?>> _handleWriteFiles(Map<String, Object?> args) async {
    final session = await _waitForActiveSession();
    await _awaitWorkspaceToolsReady();

    final openInEditor = args['openInEditor'] as bool? ?? true;
    final deleteList = _parseStringList(args['deletePaths'], fieldName: 'deletePaths');
    final fileWrites = _parseFileWrites(args['files']);

    var activityObserved = false;
    final activitySub = session.languageServerClient?.analyzerActivityStream.listen((_) {
      activityObserved = true;
    });

    try {
      final deletedPaths = await _applyDeletes(session, deleteList);
      final writtenPaths = await _applyFileWrites(
        session,
        fileWrites,
        openInEditor: openInEditor,
      );
      await session.fileTree.refresh();
      await session.repository.flush();
      if (deletedPaths.isNotEmpty || writtenPaths.isNotEmpty) {
        await _waitForAnalyzerSettle(
          session,
          expectNewActivity: () => activityObserved,
        );
      }
      return <String, Object?>{
        'writtenPaths': writtenPaths,
        'deletedPaths': deletedPaths,
        'diagnostics': _serializeDiagnostics(session),
      };
    } finally {
      await activitySub?.cancel();
    }
  }

  Future<List<String>> _applyDeletes(WorkspaceSession session, List<String> rawPaths) async {
    final api = session.repository.workspaceResourceApi;
    final deleted = <String>[];
    for (final rawPath in rawPaths) {
      final path = ProjectLoader.normalizePath(rawPath);
      session.languageServerClient?.invalidateDiagnostics(path);
      session.tabs.closeFile(path, discardChanges: true);
      if (await api.fileExist(path) || await api.folderExist(path)) {
        await api.deleteFileSystemEntity(path);
        deleted.add(path);
      }
    }
    return deleted;
  }

  Future<List<String>> _applyFileWrites(
    WorkspaceSession session,
    List<({String path, String content})> writes, {
    required bool openInEditor,
  }) async {
    if (writes.isEmpty) {
      return const <String>[];
    }
    final api = session.repository.workspaceResourceApi;
    // Stage 1: Write all files and parent directories to the workspace and
    // flush to the worker so cross-file imports resolve immediately on LSP didChange.
    for (final write in writes) {
      session.languageServerClient?.invalidateDiagnostics(write.path);
      await _ensureParentFolders(api, write.path);
      await api.writeFileFromText(write.path, write.content);
    }
    await session.repository.flush();

    // Stage 2: Update live CodeMirror buffers or open newly written tabs.
    final writtenPaths = <String>[];
    for (final write in writes) {
      await _syncEditorTabAfterWrite(
        session,
        write.path,
        write.content,
        openInEditor: openInEditor,
      );
      writtenPaths.add(write.path);
    }
    return writtenPaths;
  }

  Future<void> _syncEditorTabAfterWrite(
    WorkspaceSession session,
    String path,
    String content, {
    required bool openInEditor,
  }) async {
    final existingTab = session.tabs.getTab(path);
    if (existingTab is WorkspaceCodeMirrorTab) {
      await existingTab.writeContentFromMcp(content);
      return;
    }
    if (openInEditor && isSupportedFile(path)) {
      await session.tabs.openWorkspaceFile(path);
    }
  }

  Future<void> _ensureParentFolders(WorkspaceResourceApi api, String filePath) async {
    final parent = parentWorkspacePath(filePath);
    if (parent.isEmpty) {
      return;
    }
    final segments = parent.split('/');
    var current = '';
    for (final segment in segments) {
      current = current.isEmpty ? segment : '$current/$segment';
      if (!await api.folderExist(current)) {
        await api.createFolder(current);
      }
    }
  }

  Future<Map<String, Object?>> _handleGetDiagnostics(Map<String, Object?> args) async {
    final session = await _waitForActiveSession();
    await _awaitWorkspaceToolsReady();
    if (_isSessionAnalyzing(session)) {
      await _waitForAnalyzerSettle(session);
    }
    final severityFilter = (args['severity'] as String?)?.trim().toLowerCase();
    final serialized = _serializeDiagnostics(session, severityFilter: severityFilter);
    return <String, Object?>{
      'isAnalyzing': _isSessionAnalyzing(session),
      'count': serialized.length,
      'diagnostics': serialized,
    };
  }

  Future<Map<String, Object?>> _handlePub(Map<String, Object?> args) async {
    final session = await _waitForActiveSession();
    await _awaitWorkspaceToolsReady();

    final command = (args['command'] as String?)?.trim() ?? '';
    if (!_allowedPubCommands.contains(command)) {
      throw ArgumentError.value(
        command,
        'command',
        'Supported pub commands: ${_allowedPubCommands.join(', ')}.',
      );
    }
    final pubArgs = _parseStringList(args['args'], fieldName: 'args');
    await session.tabs.saveAllTabs();
    await session.repository.flush();

    var activityObserved = false;
    final activitySub = session.languageServerClient?.analyzerActivityStream.listen((_) {
      activityObserved = true;
    });

    try {
      final projectRoot = normalizeWorkspacePath(session.initialProject.root);
      final log = await _executeWorkspacePub(
        session,
        projectRoot: projectRoot,
        command: command,
        args: pubArgs,
      );
      await _syncPubspecAfterPub(session, projectRoot: projectRoot);
      await session.fileTree.refresh();
      await session.repository.flush();
      if (command != 'outdated') {
        await _waitForAnalyzerSettle(
          session,
          expectNewActivity: () => activityObserved,
        );
      }
      return <String, Object?>{
        'command': command,
        'args': pubArgs,
        'log': log,
        'diagnostics': _serializeDiagnostics(session),
      };
    } finally {
      await activitySub?.cancel();
    }
  }

  Future<String> _executeWorkspacePub(
    WorkspaceSession session, {
    required String projectRoot,
    required String command,
    required List<String> args,
  }) async {
    final kind = _taskKindForPub(command);
    final blocksPreview = command != 'outdated';
    return session.taskStatus.runTask<String>(
      kind,
      () async {
        session.events.dispatch(LogEvent('Running pub $command ${args.join(' ')}'.trim()));
        final String log;
        if (customPubRunner case final runner?) {
          log = await runner(session, path: projectRoot, command: command, args: args);
        } else {
          final workspace = await session.repository.readyWorkspace;
          log = await _invokeWorkerPub(
            workspace,
            path: projectRoot,
            command: command,
            args: args,
          );
        }
        if (log.isNotEmpty) {
          session.events.dispatch(LogEvent(log));
        }
        return log;
      },
      blocksPreview: blocksPreview,
    );
  }

  Future<String> _invokeWorkerPub(
    Workspace workspace, {
    required String path,
    required String command,
    required List<String> args,
  }) async {
    if (command == 'get' && args.isEmpty) {
      try {
        final offlineResult = await workspace.pub(
          path: path,
          command: 'get',
          args: const <String>['--offline'],
        );
        return offlineResult.log;
      } catch (_) {
        // Fall back to online resolution when cached packages are insufficient.
      }
    }
    final result = await workspace.pub(path: path, command: command, args: args);
    return result.log;
  }

  Future<void> _syncPubspecAfterPub(
    WorkspaceSession session, {
    required String projectRoot,
  }) async {
    final pubspecPath = joinWorkspacePath(projectRoot, 'pubspec.yaml');
    try {
      final String updated;
      if (customPubRunner != null) {
        updated = await session.repository.workspaceResourceApi.readFileAsText(pubspecPath);
      } else {
        final workspace = await session.repository.readyWorkspace;
        updated = await workspace.readFileAsText(pubspecPath);
        await session.repository.workspaceResourceApi.writeFileFromText(pubspecPath, updated);
      }
      final tab = session.tabs.getTab(pubspecPath);
      if (tab is WorkspaceCodeMirrorTab) {
        tab.syncSavedContent(updated);
      }
    } catch (_) {
      // Ignore if the workspace does not contain a pubspec.yaml.
    }
  }

  Future<Map<String, Object?>> _handleRunOrReload(Map<String, Object?> args) async {
    final session = await _waitForActiveSession();
    final action = (args['action'] as String?)?.trim() ?? 'auto';
    if (!_allowedRunActions.contains(action)) {
      throw ArgumentError.value(
        action,
        'action',
        'Supported actions: ${_allowedRunActions.join(', ')}.',
      );
    }
    final rawEntrypoint = args['entrypoint'] as String?;
    final requestedEntrypoint = rawEntrypoint == null || rawEntrypoint.trim().isEmpty
        ? null
        : ProjectLoader.normalizePath(rawEntrypoint);

    await _waitForPreviewIdle(session);
    await _dispatchPreviewAction(
      session,
      action: action,
      requestedEntrypoint: requestedEntrypoint,
    );
    if (postRunFrameDelay > Duration.zero) {
      await unthrottledDelay(postRunFrameDelay);
    }

    final preview = session.preview;
    final logEntries = preview.readSandboxLogs();
    final errors = <String>[
      for (final entry in logEntries)
        if (entry.isError) entry.message,
      ?preview.lastActionError,
    ];
    return <String, Object?>{
      'previewState': _previewStateName(preview.state),
      'entrypoint': preview.entrypoint,
      'mode': preview.previewMode.name,
      'canHotReload': preview.canHotReload,
      'logs': <String>[
        for (final entry in logEntries)
          if (!entry.isError) entry.message,
      ],
      'errors': errors,
      'diagnostics': _serializeDiagnostics(session),
    };
  }

  Future<void> _dispatchPreviewAction(
    WorkspaceSession session, {
    required String action,
    required String? requestedEntrypoint,
  }) async {
    final preview = session.preview;
    final sameEntrypoint = requestedEntrypoint == null || requestedEntrypoint == preview.entrypoint;
    switch (action) {
      case 'hot_reload':
        if (!preview.canHotReload) {
          throw StateError(
            'Hot reload is unavailable while previewState is ${_previewStateName(preview.state)} '
            '(mode: ${preview.previewMode.name}).',
          );
        }
        await preview.hotReloadCode();
      case 'hot_restart':
        if (preview.canRestart && sameEntrypoint) {
          await preview.restartCode();
        } else {
          await preview.runCode(_requireEntrypoint(requestedEntrypoint ?? preview.entrypoint));
        }
      case 'run':
        await preview.runCode(_requireEntrypoint(requestedEntrypoint ?? preview.entrypoint));
      case 'auto':
        if (preview.canHotReload && sameEntrypoint) {
          await preview.hotReloadCode();
        } else if (preview.canRestart && sameEntrypoint) {
          await preview.restartCode();
        } else {
          await preview.runCode(_requireEntrypoint(requestedEntrypoint ?? preview.entrypoint));
        }
    }
  }

  Future<Map<String, Object?>> _handleGetLogs(Map<String, Object?> args) async {
    final session = await _waitForActiveSession();
    final errorsOnly = args['errorsOnly'] as bool? ?? false;
    final clear = args['clear'] as bool? ?? false;
    final rawLimit = args['limit'];
    final limit = rawLimit is num ? rawLimit.toInt() : null;
    final entries = session.preview.readSandboxLogs(
      errorsOnly: errorsOnly,
      clear: clear,
      limit: limit,
    );
    return <String, Object?>{
      'count': entries.length,
      'entries': <Map<String, Object?>>[for (final entry in entries) entry.toJson()],
      'logs': <String>[
        for (final entry in entries)
          if (!entry.isError) entry.message,
      ],
      'errors': <String>[
        for (final entry in entries)
          if (entry.isError) entry.message,
      ],
    };
  }

  Future<Map<String, Object?>> _handleInspectWidgetTree(Map<String, Object?> _) async {
    final session = await _waitForActiveSession();
    try {
      return await _inspectSandboxVm(session, forceReconnect: false);
    } catch (_) {
      return _inspectSandboxVm(session, forceReconnect: true);
    }
  }

  Future<Map<String, Object?>> _inspectSandboxVm(
    WorkspaceSession session, {
    required bool forceReconnect,
  }) async {
    final vmService = await session.preview.connectVmService(forceReconnect: forceReconnect);
    final vm = await vmService.getVM();
    final isolates = vm.isolates;
    if (isolates == null || isolates.isEmpty) {
      throw StateError('No running Dart isolate found in the preview sandbox.');
    }
    final isolateRef = isolates.where((entry) => entry.name == 'main').firstOrNull ?? isolates.first;
    final isolateId = isolateRef.id;
    if (isolateId == null || isolateId.isEmpty) {
      throw StateError('Main isolate in preview sandbox has no isolateId.');
    }

    if (session.preview.previewMode == RunMode.flutter) {
      final flutterTree = await _tryInspectFlutterTree(vmService, isolateId);
      if (flutterTree != null) {
        return <String, Object?>{
          'isolateId': isolateId,
          'isolateName': isolateRef.name,
          'isFlutter': true,
          'tree': flutterTree,
        };
      }
    }

    final isolate = await vmService.getIsolate(isolateId);
    return <String, Object?>{
      'isolateId': isolateId,
      'isolateName': isolate.name,
      'isFlutter': false,
      'tree': <String, Object?>{
        'type': 'Isolate',
        'id': isolate.id,
        'name': isolate.name,
        'number': isolate.number,
        'rootLib': isolate.rootLib?.uri,
        'extensionRPCs': isolate.extensionRPCs ?? const <String>[],
      },
    };
  }

  Future<Object?> _tryInspectFlutterTree(VmService vmService, String isolateId) async {
    Set<String> extensions = const <String>{};
    for (var attempt = 0; attempt < 15; attempt++) {
      final isolate = await vmService.getIsolate(isolateId);
      extensions = (isolate.extensionRPCs ?? const <String>[]).toSet();
      if (extensions.contains('ext.flutter.inspector.getRootWidgetSummaryTreeWithPreviews') ||
          extensions.contains('ext.flutter.inspector.getRootWidgetSummaryTree')) {
        break;
      }
      await unthrottledDelay(const Duration(milliseconds: 100));
    }

    final extensionMethod = extensions.contains('ext.flutter.inspector.getRootWidgetSummaryTreeWithPreviews')
        ? 'ext.flutter.inspector.getRootWidgetSummaryTreeWithPreviews'
        : extensions.contains('ext.flutter.inspector.getRootWidgetSummaryTree')
        ? 'ext.flutter.inspector.getRootWidgetSummaryTree'
        : null;
    if (extensionMethod == null) {
      return null;
    }

    final response = await vmService.callServiceExtension(
      extensionMethod,
      isolateId: isolateId,
      args: const <String, String>{
        'groupName': _inspectorGroupName,
        'objectGroup': _inspectorGroupName,
      },
    );
    await _disposeInspectorGroup(vmService, isolateId, extensions);
    final rawPayload = response.json?['result'] ?? response.json;
    return rawPayload == null ? null : jsonDecode(jsonEncode(rawPayload));
  }

  Future<void> _disposeInspectorGroup(
    VmService vmService,
    String isolateId,
    Set<String> extensions,
  ) async {
    if (!extensions.contains('ext.flutter.inspector.disposeGroup')) {
      return;
    }
    try {
      await vmService.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: isolateId,
        args: const <String, String>{
          'objectGroup': _inspectorGroupName,
          'arg': _inspectorGroupName,
        },
      );
    } catch (_) {
      // Best-effort object-group disposal.
    }
  }

  Future<WorkspaceSession> _waitForActiveSession() async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!_disposed && DateTime.now().isBefore(deadline)) {
      if (host.workspacePreparationFailure case final failure?) {
        throw StateError(failure);
      }
      final session = host.activeSession;
      if (session != null && !session.isDisposed && !host.isInitializingWorkspace) {
        return session;
      }
      await unthrottledDelay(const Duration(milliseconds: 50));
    }
    if (host.activeSession case final session? when !session.isDisposed) {
      return session;
    }
    throw StateError(host.workspacePreparationFailure ?? 'Timed out waiting for DartPad workspace initialization.');
  }

  Future<void> _awaitWorkspaceToolsReady() async {
    final readyFuture = host.workspaceToolsReady;
    if (readyFuture == null) {
      return;
    }
    try {
      await readyFuture.timeout(analyzerSettleTimeout);
    } catch (_) {
      // Proceed even if initial tool startup timed out; analyzer status checks
      // handle unavailable or slow servers gracefully.
    }
  }

  Future<void> _waitForPreviewIdle(WorkspaceSession session) async {
    bool isIdle() =>
        _disposed ||
        session.isDisposed ||
        (!session.taskStatus.hasBlockingPreviewTask && !session.preview.state.isTransitioning);
    if (isIdle()) {
      return;
    }
    final completer = Completer<void>();
    void check() {
      if (!completer.isCompleted && isIdle()) {
        completer.complete();
      }
    }

    final timeoutTimer = createUnthrottledTimer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    session.taskStatus.addListener(check);
    session.preview.addListener(check);
    try {
      check();
      await completer.future;
    } finally {
      timeoutTimer.cancel();
      session.taskStatus.removeListener(check);
      session.preview.removeListener(check);
    }
  }

  Future<void> _waitForAnalyzerSettle(
    WorkspaceSession session, {
    bool Function()? expectNewActivity,
  }) async {
    final lsc = session.languageServerClient;
    if (lsc == null || session.analyzerStatus.isUnavailable) {
      return;
    }
    final deadline = DateTime.now().add(analyzerSettleTimeout);
    if (expectNewActivity != null) {
      await _waitForInitialActivitySignal(session, expectNewActivity, deadline);
    }
    if (_disposed || session.isDisposed || session.analyzerStatus.isUnavailable) {
      return;
    }
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      return;
    }
    if (analyzerIdleWindow <= Duration.zero && !_isSessionAnalyzing(session) && session.analyzerStatus.isInitialized) {
      return;
    }

    final completer = Completer<void>();
    Timer? idleTimer;

    void finish() {
      idleTimer?.cancel();
      idleTimer = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    void evaluate([Object? _]) {
      if (completer.isCompleted) {
        return;
      }
      if (_disposed || session.isDisposed || session.analyzerStatus.isUnavailable) {
        finish();
        return;
      }
      if (_isSessionAnalyzing(session) || !session.analyzerStatus.isInitialized) {
        idleTimer?.cancel();
        idleTimer = null;
        return;
      }
      if (analyzerIdleWindow <= Duration.zero) {
        finish();
        return;
      }
      idleTimer ??= createUnthrottledTimer(analyzerIdleWindow, () {
        idleTimer = null;
        if (!_isSessionAnalyzing(session) && session.analyzerStatus.isInitialized) {
          finish();
        } else {
          evaluate();
        }
      });
    }

    final deadlineTimer = createUnthrottledTimer(remaining, finish);
    final activitySub = lsc.analyzerActivityStream.listen(evaluate, onError: evaluate);
    session.taskStatus.addListener(evaluate);
    session.diagnostics.addListener(evaluate);
    try {
      evaluate();
      await completer.future;
    } finally {
      deadlineTimer.cancel();
      idleTimer?.cancel();
      await activitySub.cancel();
      session.taskStatus.removeListener(evaluate);
      session.diagnostics.removeListener(evaluate);
    }
  }

  Future<void> _waitForInitialActivitySignal(
    WorkspaceSession session,
    bool Function() activitySeen,
    DateTime outerDeadline,
  ) async {
    bool isReady() =>
        _disposed ||
        session.isDisposed ||
        session.analyzerStatus.isUnavailable ||
        activitySeen() ||
        _isSessionAnalyzing(session);
    if (isReady()) {
      return;
    }
    final remainingOuter = outerDeadline.difference(DateTime.now());
    if (remainingOuter <= Duration.zero) {
      return;
    }
    const maxSignalWindow = Duration(milliseconds: 600);
    final windowDuration = remainingOuter < maxSignalWindow ? remainingOuter : maxSignalWindow;

    final completer = Completer<void>();
    void check([Object? _]) {
      if (!completer.isCompleted && isReady()) {
        completer.complete();
      }
    }

    final windowTimer = createUnthrottledTimer(windowDuration, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    final activitySub = session.languageServerClient?.analyzerActivityStream.listen(
      check,
      onError: check,
    );
    session.taskStatus.addListener(check);
    session.diagnostics.addListener(check);
    try {
      check();
      await completer.future;
    } finally {
      windowTimer.cancel();
      await activitySub?.cancel();
      session.taskStatus.removeListener(check);
      session.diagnostics.removeListener(check);
    }
  }

  bool _isSessionAnalyzing(WorkspaceSession session) =>
      session.analyzerStatus.isAnalyzing || (session.languageServerClient?.isAnalyzing ?? false);

  List<Map<String, Object?>> _serializeDiagnostics(
    WorkspaceSession session, {
    String? severityFilter,
  }) {
    final entries = session.diagnostics.diagnostics;
    return <Map<String, Object?>>[
      for (final entry in entries)
        if (severityFilter == null || severityFilter.isEmpty || entry.diagnostic.severity.name == severityFilter)
          <String, Object?>{
            'file': entry.fileName,
            'line': entry.diagnostic.line + 1,
            'character': entry.diagnostic.character + 1,
            'column': entry.diagnostic.character + 1,
            'severity': entry.diagnostic.severity.name,
            'code': entry.diagnostic.raw?['code']?.toString(),
            'message': entry.diagnostic.message,
          },
    ];
  }
}

Map<String, int> _countDiagnosticsBySeverity(List<DiagnosticEntry> entries) {
  var errors = 0;
  var warnings = 0;
  var infos = 0;
  var hints = 0;
  for (final entry in entries) {
    switch (entry.diagnostic.severity) {
      case DiagnosticSeverity.error:
        errors++;
      case DiagnosticSeverity.warning:
        warnings++;
      case DiagnosticSeverity.info:
        infos++;
      case DiagnosticSeverity.hint:
        hints++;
    }
  }
  return <String, int>{
    'error': errors,
    'warning': warnings,
    'info': infos,
    'hint': hints,
    'total': entries.length,
  };
}

String _previewStateName(PreviewState state) => switch (state) {
  PreviewInitial() => 'initial',
  PreviewPaused() => 'paused',
  PreviewStarting() => 'starting',
  PreviewRunning() => 'running',
  PreviewDartReady() => 'dart_ready',
  PreviewRestarting() => 'restarting',
  PreviewHotReloading() => 'hot_reloading',
  PreviewStopping() => 'stopping',
  PreviewCompileError() => 'compile_error',
};

TaskKind _taskKindForPub(String command) => switch (command) {
  'upgrade' => TaskKind.pubUpgrade,
  'outdated' => TaskKind.pubOutdated,
  _ => TaskKind.pubGet,
};

String _requireEntrypoint(String? entrypoint) {
  if (entrypoint == null || entrypoint.isEmpty) {
    throw StateError('No Dart entrypoint is configured for this workspace.');
  }
  return entrypoint;
}

List<String> _parseStringList(Object? raw, {required String fieldName}) {
  if (raw == null) {
    return const <String>[];
  }
  if (raw is! List) {
    throw ArgumentError.value(raw, fieldName, 'Expected a list of strings.');
  }
  return <String>[
    for (final item in raw)
      if (item is String) item else throw ArgumentError.value(item, fieldName, 'Expected string elements.'),
  ];
}

List<({String path, String content})> _parseFileWrites(Object? raw) {
  if (raw == null) {
    return const <({String path, String content})>[];
  }
  if (raw is! List) {
    throw ArgumentError.value(raw, 'files', 'Expected a list of {path, content} objects.');
  }
  final writes = <({String path, String content})>[];
  for (final item in raw) {
    if (item is! Map) {
      throw ArgumentError.value(item, 'files', 'Each file entry must be an object.');
    }
    final path = item['path'];
    final content = item['content'];
    if (path is! String || content is! String) {
      throw ArgumentError.value(item, 'files', 'Each file entry requires string "path" and "content" fields.');
    }
    writes.add((path: ProjectLoader.normalizePath(path), content: content));
  }
  return writes;
}
