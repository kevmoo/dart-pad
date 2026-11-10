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
import 'package:dartpad_frontend/features/webmcp/webmcp_js_interop.dart';
import 'package:dartpad_frontend/features/webmcp/webmcp_models.dart';
import 'package:dartpad_frontend/features/webmcp/widget_tree_compactor.dart';
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
      'pubspec.yaml': 'name: sample_app\ndependencies:\n  flutter:\n    sdk: flutter\n  material_ui:\n',
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
    expect(byNameMap['dependencies'], <String>['flutter', 'material_ui']);
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

    final statusAfterPub = await controller.callTool('dartpad_get_status');
    expect(statusAfterPub['dependencies'], <String>['collection', 'flutter', 'material_ui']);
    expect(extractPubspecDependencyNames('not: [valid: yaml'), isEmpty);
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
      port: 8788,
    );
    expect(chromeHttps, isNotNull);
    expect(chromeHttps!.isBlockingError, isFalse);
    expect(chromeHttps.inlineCode, 'ssh -L 8788:127.0.0.1:8788');
    expect(chromeHttps.message, contains('Local Network Access'));
    expect(chromeHttps.message, contains('remote SSH host'));
    expect(chromeHttps.message, isNot(contains('Cloudtop')));
    expect(chromeHttps.message, contains('ssh -L 8788:127.0.0.1:8788'));

    expect(
      detectLocalBridgeBrowserWarning(
        protocol: 'https:',
        userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/142.0.0.0 Safari/537.36',
        port: 8788,
        localNetworkPermissionState: 'granted',
        isBridgeConnected: true,
      ),
      isNull,
    );

    final chromeDenied = detectLocalBridgeBrowserWarning(
      protocol: 'https:',
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/142.0.0.0 Safari/537.36',
      port: 8788,
      localNetworkPermissionState: 'denied',
      isBridgeConnected: false,
    );
    expect(chromeDenied, isNotNull);
    expect(chromeDenied!.isBlockingError, isTrue);
    expect(chromeDenied.message, contains('tune icon'));

    const status = McpBridgeStatus(
      phase: McpConnectionPhase.connected,
      port: 8787,
      assignedSessionId: 'tab-2',
    );
    expect(status.assignedSessionId, 'tab-2');
    expect(status.copyWith(clearAssignedSessionId: true).assignedSessionId, isNull);

    final prompt = buildAgentBootstrapPrompt(
      port: 8788,
      sessionId: '7',
      starterTask: AgentStarterTask.materialMakeover,
      pageUrl: 'https://dartpad-webmcp.web.app/?s=7&mcp_port=8788',
    );
    expect(prompt, contains('https://dartpad-webmcp.web.app/?s=7&mcp_port=8788 (session s=7)'));
    expect(prompt, contains('ws://127.0.0.1:8788/mcp-ws'));
    expect(prompt, contains('remote SSH host'));
    expect(prompt, isNot(contains('Cloudtop')));
    expect(prompt, isNot(contains('dart install')));
    expect(prompt, contains('ssh -L 8788:127.0.0.1:8788'));
    expect(prompt, contains('Local Network Access'));
    expect(prompt, contains("dart run '$dartPadMcpGitSpec' --detach --port 8788"));
    expect(prompt, contains('<dartpad_mcp_exe> status --port 8788 --require-tab --session 7'));
    expect(prompt, contains('python3 /tmp/dartpad_mcp_server.py status --port 8788 --require-tab --session 7'));
    expect(prompt, contains('<dartpad_mcp_exe> tools --port 8788 --session 7'));
    expect(prompt, contains('<dartpad_mcp_exe> call <tool_name> --stdin --port 8788 --session 7'));
    expect(prompt, isNot(contains(r'$CLI')));
    expect(prompt, contains('--session 7'));
    expect(prompt, contains(AgentStarterTask.materialMakeover.instruction));
    expect(AgentStarterTask.materialMakeover.instruction, contains('reload or restart'));

    final barePrompt = buildAgentBootstrapPrompt(
      port: 8788,
      sessionId: 'tab-k7m2',
      starterTask: AgentStarterTask.inspect,
    );
    expect(barePrompt, contains('https://dartpad-webmcp.web.app/?mcp_port=8788 (session tab-k7m2)'));
    expect(barePrompt, isNot(contains('s=tab-k7m2')));
    expect(barePrompt, contains('status --port 8788 --require-tab --session tab-k7m2'));
    expect(barePrompt, contains('tools --port 8788 --session tab-k7m2'));
  });

  test('mints and persists stable clientTabId in sessionStorage when host.sessionId is null', () async {
    const customStorageKey = 'dartpad.webmcp.tabId.test';
    web.window.sessionStorage.removeItem(customStorageKey);
    addTearDown(() => web.window.sessionStorage.removeItem(customStorageKey));

    final minted = readOrMintClientTabId(storageKey: customStorageKey);
    expect(minted, matches(RegExp(r'^tab-[0-9a-z]{4}$')));
    expect(readOrMintClientTabId(storageKey: customStorageKey), minted);

    host.sessionId = null;
    final bareStatus = await controller.callTool('dartpad_get_status');
    expect(bareStatus['sessionId'], controller.clientTabId);
    expect(bareStatus['clientTabId'], controller.clientTabId);
    expect(controller.effectiveSessionId, controller.clientTabId);

    final secondController = DartPadMcpController(
      host: host,
      installBrowserRegistry: false,
      connectWebSocket: false,
    );
    addTearDown(secondController.dispose);
    expect(secondController.clientTabId, controller.clientTabId);

    host.sessionId = '9';
    expect(secondController.effectiveSessionId, '9');
    expect(secondController.clientTabId, controller.clientTabId);
  });

  test('compactFlutterWidgetTree prunes pub-cache framework nodes and sanitizes host URIs', () {
    expect(
      sanitizeInspectorFileUri('file:///workspace/pad_1/lib/main.dart'),
      'lib/main.dart',
    );
    expect(
      sanitizeInspectorFileUri(
        'file:///usr/local/google/home/kevmoo/.pub-cache/hosted/pub.dev/material_ui-1.10.0/lib/src/scaffold.dart',
      ),
      'package:material_ui/src/scaffold.dart',
    );
    expect(
      sanitizeInspectorFileUri(
        'file:///usr/local/google/home/kevmoo/sdk/packages/flutter/lib/src/widgets/basic.dart',
      ),
      'package:flutter/src/widgets/basic.dart',
    );
    expect(isWorkspaceInspectorUri('file:///workspace/pad_1/lib/main.dart'), isTrue);
    expect(
      isWorkspaceInspectorUri(
        'file:///usr/local/google/home/kevmoo/.pub-cache/hosted/pub.dev/material_ui-1.10.0/lib/src/scaffold.dart',
      ),
      isFalse,
    );

    final rawTree = <String, Object?>{
      'description': '[root]',
      'widgetRuntimeType': 'RootWidget',
      'valueId': 'inspector-0',
      'hasChildren': true,
      'children': <Map<String, Object?>>[
        <String, Object?>{
          'description': 'M3DashboardApp',
          'widgetRuntimeType': 'M3DashboardApp',
          'valueId': 'inspector-1',
          'locationId': 11,
          'createdByLocalProject': true,
          'creationLocation': <String, Object?>{
            'file': 'file:///workspace/pad_1/lib/main.dart',
            'line': 9,
            'column': 7,
          },
          'children': <Map<String, Object?>>[
            <String, Object?>{
              'description': '_MaterialAppState',
              'widgetRuntimeType': 'Semantics',
              'valueId': 'inspector-2',
              'createdByLocalProject': true,
              'creationLocation': <String, Object?>{
                'file':
                    'file:///usr/local/google/home/kevmoo/.pub-cache/hosted/pub.dev/material_ui-1.10.0/lib/src/app.dart',
                'line': 142,
                'column': 12,
              },
              'children': <Map<String, Object?>>[
                <String, Object?>{
                  'description': 'Builder',
                  'widgetRuntimeType': 'Builder',
                  'valueId': 'inspector-3',
                  'creationLocation': <String, Object?>{
                    'file': 'file:///usr/local/google/home/kevmoo/sdk/packages/flutter/lib/src/widgets/basic.dart',
                    'line': 88,
                    'column': 9,
                  },
                  'children': <Map<String, Object?>>[
                    <String, Object?>{
                      'description': 'Text("Active Users: 1,284")',
                      'widgetRuntimeType': 'Text',
                      'textPreview': 'Active Users: 1,284',
                      'stateful': false,
                      'valueId': 'inspector-4',
                      'createdByLocalProject': true,
                      'creationLocation': <String, Object?>{
                        'file': 'file:///workspace/pad_1/lib/widgets/kpi_card.dart',
                        'line': 24,
                        'column': 14,
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
    };

    final compacted = compactFlutterWidgetTree(rawTree);
    expect(compacted.totalNodeCount, 5);
    expect(compacted.returnedNodeCount, 3);
    expect(compacted.prunedFrameworkNodeCount, 2);

    final serializedDefault = jsonEncode(compacted.tree);
    expect(serializedDefault, isNot(contains('/usr/local/google/home')));
    expect(serializedDefault, isNot(contains('valueId')));
    expect(serializedDefault, isNot(contains('createdByLocalProject')));
    expect(serializedDefault, contains('"file":"lib/main.dart"'));
    expect(serializedDefault, contains('"file":"lib/widgets/kpi_card.dart"'));
    expect(serializedDefault, contains('"textPreview":"Active Users: 1,284"'));

    final unpruned = compactFlutterWidgetTree(rawTree, includeFrameworkNodes: true);
    expect(unpruned.totalNodeCount, 5);
    expect(unpruned.returnedNodeCount, 5);
    expect(unpruned.prunedFrameworkNodeCount, 0);
    final serializedFull = jsonEncode(unpruned.tree);
    expect(serializedFull, isNot(contains('/usr/local/google/home')));
    expect(serializedFull, contains('package:material_ui/src/app.dart'));
    expect(serializedFull, contains('package:flutter/src/widgets/basic.dart'));
  });

  test('extractEntrypointLaunchSignature detects main() and root widget class changes', () {
    const counterV1 = '''
import 'package:flutter/material.dart';

void main() {
  runApp(const CounterApp());
}

class CounterApp extends StatelessWidget {
  const CounterApp({super.key});
  @override
  Widget build(BuildContext context) => const Text('v1');
}
''';
    const counterV2BuildEdit = '''
// Updated UI body only; hot_reload is safe!
import 'package:flutter/material.dart';

void main() {
  runApp(const CounterApp());
}

class CounterApp extends StatelessWidget {
  const CounterApp({super.key});
  @override
  Widget build(BuildContext context) => const Text('v2 with fresh styling');
}
''';
    const dashboardSwap = '''
import 'package:flutter/material.dart';

void main() => runApp(const M3DashboardApp());

class M3DashboardApp extends StatelessWidget {
  const M3DashboardApp({super.key});
  @override
  Widget build(BuildContext context) => const Text('dashboard');
}
''';
    const statefulSwap = '''
import 'package:flutter/material.dart';

void main() {
  runApp(const CounterApp());
}

class CounterApp extends StatefulWidget {
  const CounterApp({super.key});
  @override
  State<CounterApp> createState() => _CounterAppState();
}
class _CounterAppState extends State<CounterApp> {
  @override
  Widget build(BuildContext context) => const Text('stateful');
}
''';

    expect(extractRootAppWidgetName(counterV1), 'CounterApp');
    expect(extractRootAppWidgetName(dashboardSwap), 'M3DashboardApp');
    expect(
      extractEntrypointLaunchSignature(counterV1),
      extractEntrypointLaunchSignature(counterV2BuildEdit),
    );
    expect(
      extractEntrypointLaunchSignature(counterV1),
      isNot(extractEntrypointLaunchSignature(dashboardSwap)),
    );
    expect(
      extractEntrypointLaunchSignature(counterV1),
      isNot(extractEntrypointLaunchSignature(statefulSwap)),
    );
  });
}
