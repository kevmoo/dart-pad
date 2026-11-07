// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dartpad/dartpad.dart';
import 'package:dartpad_editor/dartpad_editor.dart';
import 'package:dartpad_frontend/features/editor/codemirror/code_mirror_tab.dart';
import 'package:dartpad_frontend/features/preview/models/run_mode.dart';
import 'package:dartpad_frontend/features/shared/app_event_bus.dart';
import 'package:dartpad_frontend/features/shared/task_status.dart';
import 'package:dartpad_frontend/features/shared/unthrottled_timer.dart';
import 'package:dartpad_frontend/features/startup/project_loader.dart';
import 'package:dartpad_frontend/features/webmcp/components/connect_agent_dialog.dart';
import 'package:dartpad_frontend/features/webmcp/dartpad_mcp_controller.dart';
import 'package:dartpad_frontend/features/webmcp/webmcp_models.dart';
import 'package:dartpad_frontend/features/workspace/data/workspace_repository.dart';
import 'package:dartpad_frontend/features/workspace/workspace_session.dart';
import 'package:dartpad_frontend/sdks.g.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import '../../project_fixture.dart';

@JS('JSON.stringify')
external JSString? _jsJsonStringify(JSAny? value);

final class _FakeHost implements DartPadMcpHost {
  _FakeHost({required this.activeSession});

  @override
  WorkspaceSession? activeSession;

  @override
  bool isInitializingWorkspace = false;

  @override
  String? workspacePreparationFailure;

  @override
  Future<void>? workspaceToolsReady;

  @override
  String? sessionId = '3';

  @override
  Uri currentUri = Uri.parse('http://127.0.0.1:8080/?s=3');
}

void main() {
  setUpAll(() async {
    final script = web.document.createElement('script') as web.HTMLScriptElement;
    final loaded = web.EventStreamProviders.loadEvent.forTarget(script).first;
    script.src = 'packages/codemirror_dart/assets/codemirror-dart.bundle.js';
    web.document.head!.appendChild(script);
    await loaded;
  });

  late MemoryWorkspaceResourceApi api;
  late List<({String path, String command, List<String> args})> pubCalls;
  late WorkspaceSession session;
  late _FakeHost host;
  late DartPadMcpController controller;

  setUp(() async {
    api = MemoryWorkspaceResourceApi();
    pubCalls = <({String path, String command, List<String> args})>[];
    final initialFiles = <String, String>{
      'pubspec.yaml': 'name: sample_app\ndependencies:\n',
      'lib/main.dart': "void main() {\n  print('hello');\n}\n",
    };
    await ProjectLoader.writeFiles(api.root, testProjectContents(initialFiles));
    final events = AppEventBus();
    final taskStatus = TaskStatusController();
    final repository = WorkspaceRepository(
      events: events,
      taskStatus: taskStatus,
      workspaceResourceApi: api,
      sdk: defaultSdk,
      workspaceFuture: Completer<Workspace>().future,
    );
    final initial = testProject(files: initialFiles);
    session = WorkspaceSession.create(
      repository,
      initialProject: initial,
      initialMode: RunMode.flutter,
    );
    await session.openProjectFiles();

    host = _FakeHost(activeSession: session);
    controller = DartPadMcpController(
      host: host,
      connectWebSocket: false,
      analyzerIdleWindow: const Duration(milliseconds: 20),
      postRunFrameDelay: Duration.zero,
      customPubRunner: (_, {required path, required command, required args}) async {
        pubCalls.add((path: path, command: command, args: args));
        if (command == 'add' && args.isNotEmpty) {
          final pubspecPath = joinWorkspacePath(path, 'pubspec.yaml');
          final existing = await api.readFileAsText(pubspecPath);
          await api.writeFileFromText(pubspecPath, '$existing  ${args.first}: ^1.19.0\n');
        }
        return 'Resolving dependencies...\nGot dependencies!';
      },
    );
  });

  tearDown(() async {
    controller.dispose();
    await session.dispose();
  });

  test('exposes all 9 WebMCP tools on document.modelContext and window.dartpadMcp', () async {
    final docObj = web.document as JSObject;
    final modelContext = docObj.getProperty<JSObject>('modelContext'.toJS);
    final jsTools = modelContext.callMethodVarArgs<JSArray<JSObject>>('getTools'.toJS);
    final toolList = jsTools.toDart;
    final names = <String>[
      for (final tool in toolList) tool.getProperty<JSString>('name'.toJS).toDart,
    ];
    expect(names, <String>[
      'dartpad_get_status',
      'dartpad_list_files',
      'dartpad_read_file',
      'dartpad_write_files',
      'dartpad_get_diagnostics',
      'dartpad_pub',
      'dartpad_run_or_reload',
      'dartpad_get_logs',
      'dartpad_inspect_widget_tree',
    ]);

    // Execute by tool name string.
    final byNamePromise = modelContext.callMethodVarArgs<JSPromise<JSAny?>>(
      'executeTool'.toJS,
      <JSAny?>['dartpad_get_status'.toJS, JSObject()],
    );
    final byNameRaw = await byNamePromise.toDart;
    final byNameMap = jsonDecode(_jsJsonStringify(byNameRaw)!.toDart) as Map<String, Object?>;
    expect(byNameMap['sessionId'], '3');
    expect(byNameMap['entrypoint'], 'lib/main.dart');
    expect(byNameMap['previewState'], 'initial');

    // Execute by RegisteredTool object from getTools().
    final statusToolObj = toolList.first;
    final byObjPromise = modelContext.callMethodVarArgs<JSPromise<JSAny?>>(
      'executeTool'.toJS,
      <JSAny?>[statusToolObj, JSObject()],
    );
    final byObjRaw = await byObjPromise.toDart;
    final byObjMap = jsonDecode(_jsJsonStringify(byObjRaw)!.toDart) as Map<String, Object?>;
    expect(byObjMap['sessionId'], '3');
    expect(byObjMap['activeFile'], 'lib/main.dart');
  });

  test('reads live editor buffers, writes nested files, and deletes files', () async {
    final mainTab = session.tabs.getTab('lib/main.dart') as WorkspaceCodeMirrorTab;
    mainTab.editor.text = "void main() {\n  print('unsaved edit');\n}\n";

    final liveRead = await controller.callTool('dartpad_read_file', <String, Object?>{
      'path': 'lib/main.dart',
    });
    expect(liveRead['isOpen'], isTrue);
    expect(liveRead['isDirty'], isTrue);
    expect(liveRead['content'], contains('unsaved edit'));

    final writeResult = await controller.callTool('dartpad_write_files', <String, Object?>{
      'files': <Map<String, Object?>>[
        <String, Object?>{
          'path': 'lib/widgets/card.dart',
          'content': 'class DemoCard {}\n',
        },
        <String, Object?>{
          'path': 'lib/main.dart',
          'content': "import 'widgets/card.dart';\nvoid main() {}\n",
        },
      ],
    });
    expect(writeResult['writtenPaths'], <String>['lib/widgets/card.dart', 'lib/main.dart']);
    expect(await api.readFileAsText('lib/widgets/card.dart'), 'class DemoCard {}\n');
    expect(mainTab.content, contains('widgets/card.dart'));
    expect(mainTab.hasUnsavedChanges, isFalse);

    final listed = await controller.callTool('dartpad_list_files', const <String, Object?>{});
    expect(listed['files'], containsAll(<String>['lib/main.dart', 'lib/widgets/card.dart', 'pubspec.yaml']));

    final deleted = await controller.callTool('dartpad_write_files', <String, Object?>{
      'deletePaths': <String>['lib/widgets/card.dart'],
    });
    expect(deleted['deletedPaths'], <String>['lib/widgets/card.dart']);
    expect(await api.fileExist('lib/widgets/card.dart'), isFalse);
    expect(session.tabs.getTab('lib/widgets/card.dart'), isNull);
  });

  test('runs pub commands and synchronizes updated pubspec.yaml into open tab', () async {
    await session.tabs.openWorkspaceFile('pubspec.yaml');
    final pubspecTab = session.tabs.getTab('pubspec.yaml') as WorkspaceCodeMirrorTab;

    final pubResult = await controller.callTool('dartpad_pub', <String, Object?>{
      'command': 'add',
      'args': <String>['collection'],
    });
    expect(pubResult['log'], contains('Got dependencies!'));
    expect(pubCalls.single.command, 'add');
    expect(pubCalls.single.args, <String>['collection']);
    expect(pubspecTab.content, contains('collection: ^1.19.0'));
    expect(pubspecTab.hasUnsavedChanges, isFalse);
  });

  test('createUnthrottledTimer fires and supports cancellation', () async {
    var cancelledFired = false;
    final cancelled = createUnthrottledTimer(const Duration(milliseconds: 25), () {
      cancelledFired = true;
    });
    expect(cancelled.isActive, isTrue);
    expect(cancelled.tick, 0);
    cancelled.cancel();
    expect(cancelled.isActive, isFalse);

    var activeFired = false;
    final active = createUnthrottledTimer(const Duration(milliseconds: 15), () {
      activeFired = true;
    });
    await unthrottledDelay(const Duration(milliseconds: 40));
    expect(activeFired, isTrue);
    expect(active.isActive, isFalse);
    expect(active.tick, 1);
    expect(cancelledFired, isFalse);
  });

  test('enableLocalBridge and disableLocalBridge update statusListenable without page reload', () {
    expect(controller.status.phase, McpConnectionPhase.disabled);
    expect(controller.status.port, 8787);

    final observed = <McpBridgeStatus>[];
    void record() => observed.add(controller.status);
    controller.statusListenable.addListener(record);
    addTearDown(() => controller.statusListenable.removeListener(record));

    controller.enableLocalBridge(port: 9123);
    expect(controller.status.phase, McpConnectionPhase.connecting);
    expect(controller.status.port, 9123);
    expect(controller.status.endpoint, Uri.parse('ws://127.0.0.1:9123/mcp-ws'));

    controller.disableLocalBridge();
    expect(controller.status.phase, McpConnectionPhase.disabled);
    expect(controller.status.port, 9123);
    expect(controller.status.endpoint, isNull);
    expect(observed.length, greaterThanOrEqualTo(2));
  });

  test('detectLocalBridgeBrowserWarning and buildAgentBootstrapPrompt cover browser and CLI invariants', () {
    expect(
      detectLocalBridgeBrowserWarning(
        protocol: 'http:',
        userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15',
      ),
      isNull,
    );

    final safariHttps = detectLocalBridgeBrowserWarning(
      protocol: 'https:',
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15',
    );
    expect(safariHttps, isNotNull);
    expect(safariHttps!.isBlockingError, isTrue);
    expect(safariHttps.message, contains('Safari blocks https://'));

    final chromeHttps = detectLocalBridgeBrowserWarning(
      protocol: 'https:',
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/142.0.0.0 Safari/537.36',
    );
    expect(chromeHttps, isNotNull);
    expect(chromeHttps!.isBlockingError, isFalse);
    expect(chromeHttps.message, contains('Local Network Access'));

    final prompt = buildAgentBootstrapPrompt(
      port: 8788,
      sessionId: '7',
      starterTask: AgentStarterTask.materialMakeover,
    );
    expect(prompt, contains('ws://127.0.0.1:8788/mcp-ws'));
    expect(prompt, contains("dart run '$dartPadMcpGitSpec' --port 8788"));
    expect(prompt, contains('python3 /tmp/dartpad_mcp_server.py status --port 8788 --require-tab'));
    expect(prompt, contains('--session 7'));
    expect(prompt, contains(AgentStarterTask.materialMakeover.instruction));
  });
}
