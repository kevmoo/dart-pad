// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:web/web.dart' as web;

import '../../../../app_styles.dart';
import '../../shared/components/icon_button.dart';
import '../../shared/icons.dart';
import '../webmcp_models.dart';

const _focusableSelector = 'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])';

/// Canonical remote Dart package git descriptor for `dart run` / `dart install`.
const dartPadMcpGitSpec = 'dartpad_mcp@{git: https://github.com/kevmoo/dartpad_mcp}';

/// Fallback zero-dependency Python 3 bridge URL for environments without standalone `dart`.
const dartPadMcpPythonUrl =
    'https://raw.githubusercontent.com/kevmoo/dart-pad/webmcp-prototype/'
    'pkgs/dartpad_preview/tool/dartpad_mcp_server.py';

/// Selectable starter objectives appended to the copied coding-agent bootstrap prompt.
enum AgentStarterTask {
  inspect(
    'Inspect & Ready',
    'Inspect the live workspace status, list files, inspect the running Flutter widget tree, '
        'and ask what I want to build.',
  ),
  materialMakeover(
    'Material 3 Makeover',
    'Restyle `lib/main.dart` into a crisp, interactive Material 3 mini-dashboard, hot-reload '
        'the preview, verify zero analyzer or runtime errors, and inspect the widget tree.',
  ),
  miniGame(
    'Interactive Mini-App',
    'Build a playful, self-contained interactive Flutter mini-app with smooth animations in '
        '`lib/main.dart`, hot-reload the preview, and verify zero diagnostics or runtime errors.',
  );

  const AgentStarterTask(this.label, this.instruction);

  final String label;
  final String instruction;
}

/// Browser-specific Local Network Access / MixedContent notice for loopback WebSockets.
final class AgentBrowserNotice {
  const AgentBrowserNotice({
    required this.message,
    required this.isBlockingError,
  });

  final String message;
  final bool isBlockingError;
}

/// Detects Safari `MixedContentChecker` blocks or Chrome Local Network Access prompts
/// when connecting from an `https:` origin to `ws://127.0.0.1`.
AgentBrowserNotice? detectLocalBridgeBrowserWarning({
  required String protocol,
  required String userAgent,
  int port = 8787,
}) {
  if (protocol != 'https:') {
    return null;
  }
  final ua = userAgent.toLowerCase();
  final isSafari =
      ua.contains('safari') &&
      !ua.contains('chrome') &&
      !ua.contains('chromium') &&
      !ua.contains('crios') &&
      !ua.contains('edg') &&
      !ua.contains('fxios');
  if (isSafari) {
    return const AgentBrowserNotice(
      isBlockingError: true,
      message:
          'Safari blocks https:// pages from opening ws://127.0.0.1 loopback WebSockets. '
          'Open this URL in Chrome to connect a local CLI coding agent.',
    );
  }
  return AgentBrowserNotice(
    isBlockingError: false,
    message:
        'Click Allow if Chrome prompts for Local Network Access so this tab can reach '
        '127.0.0.1:$port. If your agent runs on a remote SSH/Cloudtop host, forward '
        'port $port (ssh -L $port:127.0.0.1:$port).',
  );
}

String _buildConnectablePageUrl(String rawHref, int port) {
  final parsed = Uri.tryParse(rawHref);
  if (parsed == null || (!parsed.isScheme('http') && !parsed.isScheme('https'))) {
    return 'https://dartpad-webmcp.web.app/?mcp_port=$port';
  }
  final params = Map<String, String>.from(parsed.queryParameters);
  params.remove('mcp');
  params['mcp_port'] = '$port';
  return parsed.replace(queryParameters: params).toString();
}

/// Builds a self-contained bootstrap prompt that lets a user's coding agent start
/// the local bridge, confirm tab connectivity, register MCP, and act in Turn 1.
String buildAgentBootstrapPrompt({
  required int port,
  required String? sessionId,
  required AgentStarterTask starterTask,
  String? pageUrl,
}) {
  final sessionClause = (sessionId != null && sessionId.isNotEmpty) ? ' (session s=$sessionId)' : '';
  final sessionFlag = (sessionId != null && sessionId.isNotEmpty) ? ' --session $sessionId' : '';
  final defaultQuery = (sessionId != null && sessionId.isNotEmpty) ? 's=$sessionId&mcp_port=$port' : 'mcp_port=$port';
  final targetTabUrl = (pageUrl != null && pageUrl.isNotEmpty)
      ? pageUrl
      : 'https://dartpad-webmcp.web.app/?$defaultQuery';
  return '''
Connect to my DartPad Preview browser tab at $targetTabUrl$sessionClause, which dials `ws://127.0.0.1:$port/mcp-ws` on the browser's machine:
(If you are running on a remote SSH/Cloudtop host instead of the machine running my browser, ask me to forward port $port via `ssh -L $port:127.0.0.1:$port` or run the bridge locally.)

1. Start the zero-dependency local MCP bridge in the background on port $port (skip if `http://127.0.0.1:$port/healthz` already responds):
   - Preferred (Dart 3.12+): `dart run '$dartPadMcpGitSpec' --port $port`
   - Fallback (if standalone `dart` is unavailable): `curl -fsSL $dartPadMcpPythonUrl -o /tmp/dartpad_mcp_server.py && python3 /tmp/dartpad_mcp_server.py --port $port`
2. Wait ~1-2s for the open tab's auto-reconnect loop, then verify `connectedTabs` is non-empty:
   `dart run '$dartPadMcpGitSpec' status --port $port --require-tab` (or `python3 /tmp/dartpad_mcp_server.py status --port $port --require-tab`)
   - If `connectedTabs` is empty (exit code 2): open `$targetTabUrl` in Chrome if no tab is open yet, or if the tab is open on `https://`, ask me to click **Allow** on Chrome's Local Network Access prompt in the address bar (Safari blocks `https://` -> `ws://127.0.0.1`), then re-run `status --require-tab`.
3. Register `http://127.0.0.1:$port/mcp` (Streamable HTTP) or `--stdio` as an MCP server if supported, AND call DartPad tools immediately right now without restarting:
   - List tools and exact JSON schemas first: `dart run '$dartPadMcpGitSpec' tools --port $port$sessionFlag` (or `python3 /tmp/dartpad_mcp_server.py tools --port $port$sessionFlag`)
   - Call a tool with JSON args matching `inputSchema` (e.g. `dartpad_write_files` takes `{"files":[{"path":"lib/main.dart","content":"..."}]}`):
     `dart run '$dartPadMcpGitSpec' call <tool_name> --stdin --port $port$sessionFlag << 'EOF'`
4. Task: ${starterTask.instruction}''';
}

/// Modal dialog that activates DartPad's loopback WebMCP bridge and provides a
/// one-click "Tell Your Agent" bootstrap prompt plus manual CLI setup options.
final class ConnectAgentDialog extends StatefulComponent {
  const ConnectAgentDialog({
    required this.statusListenable,
    required this.sessionId,
    required this.onEnableBridge,
    required this.onDisableBridge,
    required this.onClose,
    super.key,
  });

  final ValueListenable<McpBridgeStatus> statusListenable;
  final String? sessionId;
  final void Function(int port) onEnableBridge;
  final VoidCallback onDisableBridge;
  final VoidCallback onClose;

  @override
  State<ConnectAgentDialog> createState() => _ConnectAgentDialogState();

  @css
  static List<StyleRule> get styles => _ConnectAgentDialogState.styles;
}

final class _ConnectAgentDialogState extends State<ConnectAgentDialog> {
  AgentStarterTask _selectedTask = AgentStarterTask.inspect;
  bool _showManualSetup = false;
  String? _copiedKey;
  late String _portInput;
  Timer? _copiedResetTimer;
  StreamSubscription<web.KeyboardEvent>? _keySubscription;

  @override
  void initState() {
    super.initState();
    _portInput = '${component.statusListenable.value.port}';
    _keySubscription = web.EventStreamProviders.keyDownEvent.forTarget(web.document).listen(_handleKeyDown);
    Timer.run(() {
      if (!mounted) {
        return;
      }
      final copyBtn =
          web.document.querySelector(
                '.connect-agent-backdrop .connect-agent-primary-btn',
              )
              as web.HTMLElement?;
      copyBtn?.focus();
    });
  }

  @override
  void dispose() {
    _copiedResetTimer?.cancel();
    _copiedResetTimer = null;
    _keySubscription?.cancel();
    _keySubscription = null;
    super.dispose();
  }

  void _handleKeyDown(web.KeyboardEvent event) {
    if (event.defaultPrevented) {
      return;
    }
    if (event.key == 'Escape') {
      event.preventDefault();
      component.onClose();
    } else if (event.key == 'Tab') {
      _trapFocus(event);
    }
  }

  void _trapFocus(web.KeyboardEvent event) {
    final backdrop = web.document.querySelector('.connect-agent-backdrop');
    if (backdrop == null) {
      return;
    }
    final focusable = backdrop.querySelectorAll(_focusableSelector);
    if (focusable.length == 0) {
      return;
    }
    final first = focusable.item(0) as web.HTMLElement?;
    final last = focusable.item(focusable.length - 1) as web.HTMLElement?;
    if (first == null || last == null) {
      return;
    }
    final active = web.document.activeElement;
    if (event.shiftKey && active == first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && active == last) {
      event.preventDefault();
      first.focus();
    }
  }

  Future<void> _copyText(String key, String text) async {
    try {
      await web.window.navigator.clipboard.writeText(text).toDart;
      if (!mounted) {
        return;
      }
      _copiedResetTimer?.cancel();
      setState(() => _copiedKey = key);
      _copiedResetTimer = Timer(const Duration(milliseconds: 2200), () {
        if (mounted) {
          setState(() => _copiedKey = null);
        }
      });
    } catch (_) {
      // Clipboard API may be unavailable in restricted contexts; prompt remains selectable.
    }
  }

  void _applyPort() {
    final parsed = int.tryParse(_portInput.trim());
    if (parsed == null || parsed <= 0 || parsed > 65535) {
      return;
    }
    component.onEnableBridge(parsed);
  }

  @override
  Component build(BuildContext context) {
    return ValueListenableBuilder<McpBridgeStatus>(
      listenable: component.statusListenable,
      builder: (context, status) {
        final browserNotice = detectLocalBridgeBrowserWarning(
          protocol: web.window.location.protocol,
          userAgent: web.window.navigator.userAgent,
          port: status.port,
        );
        final prompt = buildAgentBootstrapPrompt(
          port: status.port,
          sessionId: component.sessionId,
          starterTask: _selectedTask,
          pageUrl: _buildConnectablePageUrl(web.window.location.href, status.port),
        );
        final parsedPort = int.tryParse(_portInput.trim());
        final canApplyPort = parsedPort != null && parsedPort > 0 && parsedPort <= 65535 && parsedPort != status.port;

        return div(
          classes: 'connect-agent-backdrop',
          events: {
            'click': (event) {
              if (event.target == event.currentTarget) {
                component.onClose();
              }
            },
          },
          attributes: const {
            'role': 'dialog',
            'aria-modal': 'true',
            'aria-labelledby': 'connect-agent-dialog-title',
          },
          [
            div(classes: 'connect-agent-dialog', [
              _buildHeader(),
              div(classes: 'connect-agent-body', [
                _buildStatusRow(status, canApplyPort: canApplyPort),
                if (browserNotice != null) _buildBrowserNotice(browserNotice),
                _buildTaskSelector(),
                _buildPrimaryCopySection(prompt),
                _buildManualSetupSection(status.port),
              ]),
            ]),
          ],
        );
      },
    );
  }

  Component _buildHeader() => div(classes: 'connect-agent-header', [
    const div(classes: 'connect-agent-title-group', [
      Icon('smart_toy', size: 18),
      h2(id: 'connect-agent-dialog-title', [.text('Connect Coding Agent')]),
    ]),
    IconButton(
      icon: 'close',
      label: 'Close connect agent dialog',
      onClick: (_) => component.onClose(),
    ),
  ]);

  Component _buildStatusRow(McpBridgeStatus status, {required bool canApplyPort}) {
    final (dotClass, label) = switch (status.phase) {
      McpConnectionPhase.connected when status.isBusy => (
        'status-dot-connected',
        'Connected on :${status.port} · running ${status.lastToolName ?? 'tool'}…',
      ),
      McpConnectionPhase.connected => (
        'status-dot-connected',
        'Connected to local bridge on :${status.port}',
      ),
      McpConnectionPhase.connecting => (
        'status-dot-waiting',
        'Waiting for local bridge on ws://127.0.0.1:${status.port}/mcp-ws…',
      ),
      McpConnectionPhase.disabled => (
        'status-dot-disabled',
        'Local WebSocket bridge paused',
      ),
    };

    return div(classes: 'connect-agent-status-bar', [
      div(classes: 'connect-agent-status-main', [
        span(classes: 'connect-agent-dot $dotClass', const []),
        span(classes: 'connect-agent-status-text', [.text(label)]),
      ]),
      div(classes: 'connect-agent-port-controls', [
        const span(classes: 'connect-agent-port-label', [.text('Port')]),
        input(
          classes: 'connect-agent-port-input',
          attributes: {
            'type': 'number',
            'min': '1',
            'max': '65535',
            'value': _portInput,
            'aria-label': 'Local MCP bridge port',
          },
          events: {
            'input': (event) {
              final target = event.target as web.HTMLInputElement?;
              if (target != null) {
                setState(() => _portInput = target.value);
              }
            },
            'keydown': (event) {
              final keyEvent = event as web.KeyboardEvent;
              if (keyEvent.key == 'Enter') {
                _applyPort();
              }
            },
          },
        ),
        if (canApplyPort)
          button(
            classes: 'connect-agent-small-btn',
            attributes: const {'type': 'button'},
            onClick: _applyPort,
            const [.text('Apply')],
          ),
        button(
          classes: 'connect-agent-small-btn',
          attributes: const {'type': 'button'},
          onClick: () {
            if (status.phase == McpConnectionPhase.disabled) {
              final nextPort = int.tryParse(_portInput.trim()) ?? status.port;
              component.onEnableBridge(nextPort);
            } else {
              component.onDisableBridge();
            }
          },
          [.text(status.phase == McpConnectionPhase.disabled ? 'Enable' : 'Pause')],
        ),
      ]),
    ]);
  }

  Component _buildBrowserNotice(AgentBrowserNotice notice) => div(
    classes: notice.isBlockingError
        ? 'connect-agent-notice connect-agent-notice-error'
        : 'connect-agent-notice connect-agent-notice-info',
    [
      Icon(notice.isBlockingError ? 'warning' : 'info', size: 16),
      span([.text(notice.message)]),
    ],
  );

  Component _buildTaskSelector() => div(classes: 'connect-agent-section', [
    const span(classes: 'connect-agent-section-label', [
      .text('1. Choose what your agent should do first'),
    ]),
    div(classes: 'connect-agent-chips', [
      for (final task in AgentStarterTask.values)
        button(
          classes: task == _selectedTask ? 'connect-agent-chip connect-agent-chip-active' : 'connect-agent-chip',
          attributes: {
            'type': 'button',
            'aria-pressed': '${task == _selectedTask}',
          },
          onClick: () => setState(() => _selectedTask = task),
          [.text(task.label)],
        ),
    ]),
  ]);

  Component _buildPrimaryCopySection(String prompt) {
    final copied = _copiedKey == 'prompt';
    return div(classes: 'connect-agent-section', [
      const span(classes: 'connect-agent-section-label', [
        .text('2. Copy & paste into Claude Code, Gemini CLI, Cursor, or Antigravity'),
      ]),
      button(
        classes: 'connect-agent-primary-btn',
        attributes: const {'type': 'button'},
        onClick: () => unawaited(_copyText('prompt', prompt)),
        [
          Icon(copied ? 'check' : 'content_copy', size: 16),
          span([
            .text(
              copied ? 'Copied! Paste into your coding agent' : 'Copy Prompt for Your Agent',
            ),
          ]),
        ],
      ),
      pre(classes: 'connect-agent-prompt-preview', [
        code([.text(prompt)]),
      ]),
    ]);
  }

  Component _buildManualSetupSection(int port) {
    final dartRunCmd = "dart run '$dartPadMcpGitSpec' --port $port";
    final claudeMcpCmd = 'claude mcp add --transport http dartpad http://127.0.0.1:$port/mcp';

    return div(classes: 'connect-agent-manual', [
      button(
        classes: 'connect-agent-manual-toggle',
        attributes: {
          'type': 'button',
          'aria-expanded': '$_showManualSetup',
        },
        onClick: () => setState(() => _showManualSetup = !_showManualSetup),
        [
          const span([.text('Manual CLI & Single-File Download')]),
          Icon(_showManualSetup ? 'expand_less' : 'expand_more', size: 16),
        ],
      ),
      if (_showManualSetup)
        div(classes: 'connect-agent-manual-body', [
          _buildCommandRow('Run bridge (Dart 3.12+)', 'dart-run', dartRunCmd),
          _buildCommandRow('Register in Claude Code', 'claude-mcp', claudeMcpCmd),
          const div(classes: 'connect-agent-download-row', [
            span(classes: 'connect-agent-download-hint', [
              .text('No Git access or offline? Download the zero-dependency dart:io script directly:'),
            ]),
            a(
              href: 'mcp/dartpad_mcp.txt',
              classes: 'connect-agent-download-link',
              attributes: {'download': 'dartpad_mcp.dart'},
              [
                Icon('download', size: 15),
                span([.text('Download dartpad_mcp.dart')]),
              ],
            ),
          ]),
        ]),
    ]);
  }

  Component _buildCommandRow(String title, String copyKey, String command) {
    final copied = _copiedKey == copyKey;
    return div(classes: 'connect-agent-cmd-block', [
      span(classes: 'connect-agent-cmd-label', [.text(title)]),
      div(classes: 'connect-agent-cmd-row', [
        code(classes: 'connect-agent-cmd-code', [.text(command)]),
        button(
          classes: 'connect-agent-small-btn',
          attributes: {'type': 'button', 'aria-label': 'Copy $title command'},
          onClick: () => unawaited(_copyText(copyKey, command)),
          [
            Icon(copied ? 'check' : 'content_copy', size: 14),
            span([.text(copied ? 'Copied' : 'Copy')]),
          ],
        ),
      ]),
    ]);
  }

  static List<StyleRule> get styles => [
    css('.connect-agent-backdrop').styles(
      display: .flex,
      position: .fixed(top: 0.px, left: 0.px, right: 0.px, bottom: 0.px),
      zIndex: const ZIndex(9999),
      justifyContent: .center,
      alignItems: .center,
      backgroundColor: const Color('rgba(0, 0, 0, 0.55)'),
    ),
    css('.connect-agent-dialog').styles(
      display: .flex,
      width: 560.px,
      maxWidth: 92.vw,
      maxHeight: 88.vh,
      padding: .zero,
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(8.px),
      shadow: BoxShadow(
        offsetX: .zero,
        offsetY: 12.px,
        blur: 32.px,
        color: const .rgba(0, 0, 0, 0.35),
      ),
      overflow: .hidden,
      flexDirection: .column,
      color: colorOnSurface,
      backgroundColor: colorSurface,
    ),
    css('.connect-agent-header').styles(
      display: .flex,
      padding: .symmetric(vertical: 10.px, horizontal: 16.px),
      border: .only(
        bottom: .solid(color: colorBorder, width: 1.px),
      ),
      justifyContent: .spaceBetween,
      alignItems: .center,
      gap: Gap.all(10.px),
    ),
    css('.connect-agent-title-group').styles(
      display: .flex,
      alignItems: .center,
      gap: Gap.all(8.px),
      color: colorOnContainer,
    ),
    css('.connect-agent-header h2').styles(
      margin: .zero,
      fontSize: 15.px,
      fontWeight: .w600,
    ),
    css('.connect-agent-body').styles(
      display: .flex,
      minHeight: 0.px,
      padding: .all(16.px),
      overflow: const .only(y: .auto),
      flexDirection: .column,
      gap: Gap.all(14.px),
      flex: const .grow(1),
    ),
    css('.connect-agent-status-bar').styles(
      display: .flex,
      padding: .symmetric(vertical: 8.px, horizontal: 12.px),
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(6.px),
      flexWrap: .wrap,
      justifyContent: .spaceBetween,
      alignItems: .center,
      gap: Gap.all(8.px),
      backgroundColor: colorContainer,
    ),
    css('.connect-agent-status-main').styles(
      display: .flex,
      alignItems: .center,
      gap: Gap.all(8.px),
    ),
    css('.connect-agent-dot').styles(
      display: .inlineBlock,
      width: 9.px,
      height: 9.px,
      radius: .circular(99.px),
      flex: const .shrink(0),
    ),
    css('.status-dot-connected').styles(
      backgroundColor: const Color('#2e7d32'),
      raw: {'box-shadow': '0 0 0 3px rgba(76, 175, 80, 0.22)'},
    ),
    css('.status-dot-waiting').styles(
      backgroundColor: const Color('#ef6c00'),
      raw: {'box-shadow': '0 0 0 3px rgba(251, 192, 44, 0.25)'},
    ),
    css('.status-dot-disabled').styles(
      backgroundColor: const Color('#8b97a6'),
    ),
    css('.connect-agent-status-text').styles(
      color: colorOnContainer,
      fontSize: 12.px,
      fontWeight: .w500,
    ),
    css('.connect-agent-port-controls').styles(
      display: .flex,
      alignItems: .center,
      gap: Gap.all(6.px),
    ),
    css('.connect-agent-port-label').styles(
      fontSize: 11.px,
    ),
    css('.connect-agent-port-input').styles(
      width: 66.px,
      padding: .symmetric(vertical: 4.px, horizontal: 6.px),
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(4.px),
      color: colorOnContainer,
      fontFamily: monospaceFontFamily,
      fontSize: 12.px,
      backgroundColor: colorSurface,
    ),
    css('.connect-agent-small-btn').styles(
      display: .inlineFlex,
      padding: .symmetric(vertical: 4.px, horizontal: 8.px),
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(4.px),
      cursor: .pointer,
      alignItems: .center,
      gap: Gap.all(4.px),
      color: colorOnContainer,
      fontSize: 11.px,
      fontWeight: .w500,
      backgroundColor: colorSurface,
    ),
    css('.connect-agent-small-btn:hover').styles(
      backgroundColor: colorBorder,
    ),
    css('.connect-agent-notice').styles(
      display: .flex,
      padding: .symmetric(vertical: 8.px, horizontal: 10.px),
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(6.px),
      alignItems: .center,
      gap: Gap.all(8.px),
      fontSize: 12.px,
      lineHeight: 1.4.em,
    ),
    css('.connect-agent-notice-error').styles(
      border: .all(color: colorError, width: 1.px),
      color: colorOnContainer,
      backgroundColor: colorErrorSurface,
    ),
    css('.connect-agent-notice-info').styles(
      color: colorOnSurface,
      backgroundColor: colorContainer,
    ),
    css('.connect-agent-section').styles(
      display: .flex,
      flexDirection: .column,
      gap: Gap.all(8.px),
    ),
    css('.connect-agent-section-label').styles(
      color: colorOnContainer,
      fontSize: 12.px,
      fontWeight: .w600,
    ),
    css('.connect-agent-chips').styles(
      display: .flex,
      flexWrap: .wrap,
      gap: Gap.all(6.px),
    ),
    css('.connect-agent-chip').styles(
      padding: .symmetric(vertical: 5.px, horizontal: 10.px),
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(999.px),
      cursor: .pointer,
      color: colorOnSurface,
      fontSize: 12.px,
      fontWeight: .w500,
      backgroundColor: colorContainer,
    ),
    css('.connect-agent-chip-active').styles(
      border: .all(color: colorPrimary, width: 1.px),
      color: colorPrimary,
      fontWeight: .w600,
    ),
    css('.connect-agent-primary-btn').styles(
      display: .flex,
      width: 100.percent,
      padding: .symmetric(vertical: 10.px, horizontal: 14.px),
      border: .none,
      radius: .circular(6.px),
      cursor: .pointer,
      justifyContent: .center,
      alignItems: .center,
      gap: Gap.all(8.px),
      color: Colors.white,
      fontSize: 13.px,
      fontWeight: .w600,
      backgroundColor: colorPrimary,
    ),
    css('.connect-agent-primary-btn:hover').styles(
      opacity: 0.92,
    ),
    css('.connect-agent-prompt-preview').styles(
      maxHeight: 148.px,
      padding: .all(10.px),
      margin: .zero,
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(6.px),
      overflow: .auto,
      color: colorOnContainer,
      fontFamily: monospaceFontFamily,
      fontSize: 11.px,
      lineHeight: 1.45.em,
      whiteSpace: .preWrap,
      backgroundColor: colorContainer,
    ),
    css('.connect-agent-manual').styles(
      display: .flex,
      padding: .only(top: 10.px),
      border: .only(
        top: .solid(color: colorBorder, width: 1.px),
      ),
      flexDirection: .column,
      gap: Gap.all(10.px),
    ),
    css('.connect-agent-manual-toggle').styles(
      display: .flex,
      width: 100.percent,
      padding: .symmetric(vertical: 6.px, horizontal: 8.px),
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(4.px),
      cursor: .pointer,
      justifyContent: .spaceBetween,
      alignItems: .center,
      color: colorOnSurface,
      fontSize: 12.px,
      fontWeight: .w500,
      backgroundColor: colorContainer,
    ),
    css('.connect-agent-manual-body').styles(
      display: .flex,
      flexDirection: .column,
      gap: Gap.all(8.px),
    ),
    css('.connect-agent-cmd-block').styles(
      display: .flex,
      flexDirection: .column,
      gap: Gap.all(4.px),
    ),
    css('.connect-agent-cmd-label').styles(
      fontSize: 11.px,
      fontWeight: .w500,
    ),
    css('.connect-agent-cmd-row').styles(
      display: .flex,
      alignItems: .center,
      gap: Gap.all(6.px),
    ),
    css('.connect-agent-cmd-code').styles(
      padding: .symmetric(vertical: 5.px, horizontal: 8.px),
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(4.px),
      overflow: const .only(x: .auto),
      flex: const .grow(1),
      color: colorOnContainer,
      fontFamily: monospaceFontFamily,
      fontSize: 11.px,
      whiteSpace: .noWrap,
      backgroundColor: colorContainer,
    ),
    css('.connect-agent-download-row').styles(
      display: .flex,
      padding: .only(top: 4.px),
      flexWrap: .wrap,
      justifyContent: .spaceBetween,
      alignItems: .center,
      gap: Gap.all(8.px),
    ),
    css('.connect-agent-download-hint').styles(
      fontSize: 11.px,
    ),
    css('.connect-agent-download-link').styles(
      display: .inlineFlex,
      padding: .symmetric(vertical: 5.px, horizontal: 10.px),
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(4.px),
      alignItems: .center,
      gap: Gap.all(5.px),
      color: colorPrimary,
      fontSize: 12.px,
      fontWeight: .w600,
      textDecoration: TextDecoration.none,
      backgroundColor: colorContainer,
    ),
  ];
}
