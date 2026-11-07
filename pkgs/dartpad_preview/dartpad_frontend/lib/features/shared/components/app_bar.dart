// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:web/web.dart' as web;

import '../../../app_styles.dart';
import '../../editor/components/small_screen_tab_bar.dart';
import '../../startup/examples.g.dart';
import '../../webmcp/webmcp_models.dart';
import '../icons.dart';
import 'dropdown_menu.dart';
import 'icon_button.dart' as dp;
import 'theme_toggle.dart';

const FontFamily _headerFontFamily = .list([
  FontFamily('Google Sans Flex'),
  FontFamily('Roboto'),
  FontFamily('ui-sans'),
  FontFamilies.sansSerif,
]);

/// The main [AppBar] with the DartPad logo, title, theme toggle, and
/// overflow menu.
final class AppBar extends StatelessComponent {
  const AppBar({
    this.onSelectExample,
    this.mcpStatus,
    this.onOpenConnectAgent,
    this.isEmbedMode = false,
    this.isSmallScreen = false,
    this.smallScreenTabBar,
    super.key,
  });

  /// Called when the user selects an example from the New menu.
  final void Function(Example example)? onSelectExample;

  /// Reactive outbound WebMCP bridge connection status for the agent pill.
  final ValueListenable<McpBridgeStatus>? mcpStatus;

  /// Opens the Connect Coding Agent modal dialog.
  final VoidCallback? onOpenConnectAgent;

  /// Whether the application is running in embed mode.
  final bool isEmbedMode;

  /// Code / Output [SmallScreenTabBar] displayed in small-screen layouts.
  final SmallScreenTabBar? smallScreenTabBar;

  /// Whether this [AppBar] is being rendered in a small-screen layout.
  final bool isSmallScreen;

  void _openLink(String uri) {
    web.window.open(uri, '_blank');
  }

  List<DropdownMenuEntry> _buildExampleItems() {
    final entries = <DropdownMenuEntry>[];
    String? lastSubcategory;

    for (final example in Examples.all) {
      if (example.subcategory != null && example.subcategory != lastSubcategory) {
        entries.add(DropdownMenuDivider(label: example.subcategory!));
        lastSubcategory = example.subcategory;
      }
      entries.add(
        DropdownMenuItem(
          label: example.name,
          leadingImage: example.icon,
          onPressed: () => onSelectExample?.call(example),
        ),
      );
    }

    return entries;
  }

  @override
  Component build(BuildContext context) {
    return switch ((isEmbedMode, isSmallScreen)) {
      // Large embedded layouts show neither AppBar nor SmallScreenTabBar.
      (true, false) => const Component.fragment([]),
      // Small embedded layouts show only SmallScreenTabBar.
      (true, true) => smallScreenTabBar ?? const Component.fragment([]),
      // Large standalone layouts show AppBar.
      (false, false) => _buildAppBar(),
      // Small standalone layouts show AppBar and SmallScreenTabBar.
      (false, true) => _buildAppBar(smallScreenTabBar),
    };
  }

  Component _buildForkBanner() {
    return div(
      classes: 'app-bar-fork-banner',
      attributes: const {'role': 'region', 'aria-label': 'Unofficial fork notice'},
      [
        div(classes: 'app-bar-fork-banner-text', [
          const Icon('warning', size: 15),
          if (isSmallScreen)
            const span([.text('Unofficial WebMCP fork —')])
          else
            const span([
              strong([.text('Unofficial experimental WebMCP fork')]),
              .text(' ('),
              a(
                href: 'https://github.com/kevmoo/dart-pad/tree/webmcp-prototype',
                target: Target.blank,
                classes: 'app-bar-fork-repo-link',
                attributes: {'rel': 'noopener noreferrer'},
                [.text('kevmoo/dart-pad')],
              ),
              .text(') — Not the official DartPad.'),
            ]),
        ]),
        const a(
          href: 'https://preview.dartpad.dev/',
          target: Target.blank,
          classes: 'app-bar-fork-official-cta',
          attributes: {'rel': 'noopener noreferrer'},
          [
            span([.text('Official preview.dartpad.dev')]),
            Icon('open_in_new', size: 13),
          ],
        ),
      ],
    );
  }

  Component _buildAppBar([SmallScreenTabBar? smallScreenTabBar]) {
    final isNewDisabled = onSelectExample == null;

    final appBar = div(classes: 'app-bar', [
      // Fork corner ribbon overlay.
      const div(classes: 'app-bar-preview-ribbon-wrapper', [
        div(classes: 'app-bar-preview-ribbon', [.text('FORK')]),
      ]),
      // Left section: logo + title + new menu.
      div(classes: 'app-bar-left', [
        const img(
          src: 'images/dart-192.svg',
          alt: 'Dart',
          classes: 'app-bar-logo',
        ),
        const span(classes: 'app-bar-title', [.text('DartPad')]),
        const div(classes: 'app-bar-divider', []),
        DropdownMenu(
          alignLeft: true,
          disabled: isNewDisabled,
          trigger: button(
            classes: 'app-bar-text-button',
            disabled: isNewDisabled,
            attributes: {
              'aria-label': 'New',
              'title': 'Start new Dart/Flutter project from preset',
            },
            [
              const Icon('add_circle', size: 18),
              if (!isSmallScreen) const span(classes: 'app-bar-button-label', [.text('New')]),
            ],
          ),
          items: _buildExampleItems(),
        ),
      ]),
      // Spacer.
      const div(classes: 'app-bar-spacer', []),
      // Right section: agent pill + theme toggle + overflow menu.
      div(classes: 'app-bar-right', [
        if (mcpStatus != null && onOpenConnectAgent != null) _buildConnectAgentPill(mcpStatus!, onOpenConnectAgent!),
        const ThemeToggle(),
        DropdownMenu(
          trigger: const dp.IconButton(
            icon: 'apps',
            iconSize: 28.0,
            tooltip: 'More options',
            label: 'More options',
          ),
          items: [
            DropdownMenuItem(
              label: 'Official preview.dartpad.dev',
              trailingIcon: 'launch',
              onPressed: () => _openLink('https://preview.dartpad.dev/'),
            ),
            DropdownMenuItem(
              label: 'Install SDK',
              trailingIcon: 'launch',
              onPressed: () => _openLink('https://flutter.dev/get-started'),
            ),
            DropdownMenuItem(
              label: 'Sharing guide',
              trailingIcon: 'launch',
              onPressed: () => _openLink(
                'https://github.com/dart-lang/dart-pad/wiki/Sharing-Guide',
              ),
            ),
          ],
        ),
      ]),
    ]);

    return div(classes: 'app-bar-container', [
      _buildForkBanner(),
      appBar,
      ?smallScreenTabBar,
    ]);
  }

  Component _buildConnectAgentPill(
    ValueListenable<McpBridgeStatus> listenable,
    VoidCallback onPressed,
  ) {
    return ValueListenableBuilder<McpBridgeStatus>(
      listenable: listenable,
      builder: (context, status) {
        final (pillStateClass, dotClass, label, tooltip) = switch (status.phase) {
          McpConnectionPhase.connected when status.isBusy => (
            'app-bar-agent-pill-connected',
            'app-bar-agent-dot-connected',
            'Agent busy…',
            'Agent running ${status.lastToolName ?? 'tool'} on :${status.port}',
          ),
          McpConnectionPhase.connected => (
            'app-bar-agent-pill-connected',
            'app-bar-agent-dot-connected',
            'Agent Connected',
            'Coding agent connected on :${status.port} (click for options)',
          ),
          McpConnectionPhase.connecting => (
            'app-bar-agent-pill-waiting',
            'app-bar-agent-dot-waiting',
            'Waiting :${status.port}…',
            'Waiting for local MCP bridge on ws://127.0.0.1:${status.port}/mcp-ws',
          ),
          McpConnectionPhase.disabled => (
            'app-bar-agent-pill-idle',
            null,
            'Connect Agent',
            'Connect a local coding agent via WebMCP',
          ),
        };

        return button(
          classes: 'app-bar-agent-pill $pillStateClass',
          attributes: {
            'type': 'button',
            'aria-label': label,
            'title': tooltip,
          },
          onClick: onPressed,
          [
            if (dotClass != null)
              span(classes: 'app-bar-agent-dot $dotClass', const [])
            else
              const Icon('smart_toy', size: 16),
            if (!isSmallScreen) span(classes: 'app-bar-button-label', [.text(label)]),
          ],
        );
      },
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.app-bar-container').styles(
      display: .flex,
      position: const .relative(),
      zIndex: const ZIndex(200),
      flexDirection: .column,
      flex: const .shrink(0),
    ),
    css('.app-bar').styles(
      display: .flex,
      position: const .relative(),
      zIndex: const ZIndex(200),
      height: 52.px,
      minHeight: 52.px,
      padding: .symmetric(horizontal: 16.px),
      border: .only(
        bottom: .solid(color: colorBorder, width: 1.px),
      ),
      alignItems: .center,
      gap: Gap.all(8.px),
      flex: const .shrink(0),
      fontFamily: _headerFontFamily,
      backgroundColor: colorSurface,
      raw: {
        'font-optical-sizing': 'auto',
        '-webkit-font-smoothing': 'antialiased',
        '-moz-osx-font-smoothing': 'grayscale',
      },
    ),
    css('.app-bar-preview-ribbon-wrapper').styles(
      position: const .absolute(top: Unit.zero, left: Unit.zero),
      zIndex: const ZIndex(250),
      width: 80.px,
      height: 100.percent,
      overflow: .hidden,
      raw: {'pointer-events': 'none'},
    ),
    css('.app-bar-fork-banner').styles(
      display: .flex,
      minHeight: 30.px,
      padding: .symmetric(vertical: 4.px, horizontal: 14.px),
      border: .only(
        bottom: .solid(color: const Color('#d97706'), width: 1.px),
      ),
      flexWrap: .wrap,
      justifyContent: .center,
      alignItems: .center,
      gap: Gap.all(10.px),
      color: const Color('#78350f'),
      fontFamily: _headerFontFamily,
      fontSize: 12.px,
      lineHeight: 1.35.em,
      backgroundColor: const Color('#fffbeb'),
    ),
    css('.app-bar-fork-banner-text').styles(
      display: .inlineFlex,
      flexWrap: .wrap,
      alignItems: .center,
      gap: Gap.all(4.px),
    ),
    css('.app-bar-fork-repo-link').styles(
      color: const Color('#92400e'),
      fontWeight: .w600,
      textDecoration: const TextDecoration(line: .underline),
    ),
    css('.app-bar-fork-official-cta').styles(
      display: .inlineFlex,
      padding: .symmetric(vertical: 2.px, horizontal: 9.px),
      border: .all(color: const Color('#d97706'), width: 1.px),
      radius: .circular(999.px),
      alignItems: .center,
      gap: Gap.all(4.px),
      color: const Color('#78350f'),
      fontSize: 11.5.px,
      fontWeight: .w700,
      textDecoration: TextDecoration.none,
      whiteSpace: .noWrap,
      backgroundColor: const Color('#fde68a'),
    ),
    css('.app-bar-fork-official-cta:hover').styles(
      backgroundColor: const Color('#fcd34d'),
    ),
    css('.app-bar-preview-ribbon').styles(
      position: const .absolute(),
      width: 95.px,
      padding: .symmetric(vertical: 3.px),
      shadow: BoxShadow(
        offsetX: .zero,
        offsetY: 2.px,
        blur: 5.px,
        color: const .rgba(0, 0, 0, 0.35),
      ),
      transform: .rotate((-45).deg),
      color: Colors.white,
      textAlign: .center,
      fontSize: 8.5.px,
      fontWeight: .w900,
      letterSpacing: 1.2.px,
      backgroundColor: const Color('#b45309'),
      raw: {
        'top': '14px',
        'left': '-28px',
        'text-transform': 'uppercase',
        'user-select': 'none',
      },
    ),
    // Dark theme styles matching dart.dev chrome.
    css('html[data-theme="dark"]', [
      css('.app-bar-fork-banner').styles(
        border: .only(
          bottom: .solid(color: const Color('#b45309'), width: 1.px),
        ),
        color: const Color('#fef3c7'),
        backgroundColor: const Color('#2d1f0a'),
      ),
      css('.app-bar-fork-repo-link').styles(
        color: const Color('#fcd34d'),
      ),
      css('.app-bar-fork-official-cta').styles(
        border: .all(color: const Color('#d97706'), width: 1.px),
        color: const Color('#fef3c7'),
        backgroundColor: const Color('#452c0c'),
      ),
      css('.app-bar-fork-official-cta:hover').styles(
        backgroundColor: const Color('#5c3b10'),
      ),
      css('.app-bar', [
        css('&').styles(
          border: .only(
            bottom: .solid(color: const Color('#394c60'), width: 1.px),
          ),
          backgroundColor: const Color('#1c2834'),
        ),
        css('.app-bar-title').styles(color: const Color('#f3f4f6')),
        css('.app-bar-divider').styles(backgroundColor: const Color('#394c60')),
        css('.app-bar-text-button').styles(color: const Color('#f3f4f6')),
        css('.app-bar-text-button:hover').styles(backgroundColor: const Color('#253446')),
        css('.app-bar-agent-pill').styles(
          border: .all(color: const Color('#394c60'), width: 1.px),
          color: const Color('#f3f4f6'),
          backgroundColor: const Color('#223040'),
        ),
        css('.app-bar-agent-pill:hover').styles(backgroundColor: const Color('#2b3c50')),
        css('.app-bar-agent-pill-connected').styles(
          border: .all(color: const Color('#2e7d32'), width: 1.px),
        ),
        css('.app-bar-agent-pill-waiting').styles(
          border: .all(color: const Color('#ef6c00'), width: 1.px),
        ),
        css('.icon-button').styles(color: const Color('#a8acad')),
        css('.icon-button:hover').styles(color: const Color('#40c4ff')),
      ]),
    ]),
    css('.app-bar-left').styles(
      display: .flex,
      position: const .relative(),
      zIndex: const ZIndex(99),
      alignItems: .center,
      gap: Gap.all(8.px),
    ),
    css('.app-bar-spacer').styles(
      flex: const Flex(grow: 1),
    ),
    css('.app-bar-right').styles(
      display: .flex,
      position: const .relative(),
      zIndex: const ZIndex(99),
      alignItems: .center,
      gap: Gap.all(8.px),
    ),
    css('.app-bar-logo').styles(
      width: 36.px,
      height: 36.px,
    ),
    css('.app-bar-title').styles(
      userSelect: .none,
      color: colorOnContainer,
      fontFamily: _headerFontFamily,
      fontSize: 28.px,
      fontWeight: .w400,
      lineHeight: 1.25.em,
      raw: {
        'font-variant-ligatures': 'none',
      },
    ),
    css('.app-bar-divider').styles(
      width: 1.px,
      height: 24.px,
      margin: .symmetric(horizontal: 4.px),
      backgroundColor: colorBorder,
    ),

    // -- Text button (New) --
    css('.app-bar-text-button').styles(
      display: .flex,
      padding: .symmetric(horizontal: 10.px, vertical: 6.px),
      border: .none,
      radius: .circular(6.px),
      cursor: .pointer,
      alignItems: .center,
      gap: Gap.all(6.px),
      color: colorOnSurface,
      fontFamily: _headerFontFamily,
      fontSize: 14.px,
      fontWeight: .w500,
      backgroundColor: Colors.transparent,
    ),
    css('.app-bar-text-button:hover').styles(
      backgroundColor: colorBorder,
    ),
    css('.app-bar-text-button:disabled').styles(
      opacity: 0.5,
      cursor: .defaultCursor,
      raw: {'pointer-events': 'none'},
    ),
    css('.app-bar-button-label').styles(
      whiteSpace: .noWrap,
    ),
    css('.app-bar-agent-pill').styles(
      display: .flex,
      padding: .symmetric(horizontal: 10.px, vertical: 5.px),
      border: .all(color: colorBorder, width: 1.px),
      radius: .circular(999.px),
      cursor: .pointer,
      alignItems: .center,
      gap: Gap.all(6.px),
      color: colorOnContainer,
      fontFamily: _headerFontFamily,
      fontSize: 12.px,
      fontWeight: .w600,
      backgroundColor: colorContainer,
    ),
    css('.app-bar-agent-pill:hover').styles(
      backgroundColor: colorBorder,
    ),
    css('.app-bar-agent-pill-connected').styles(
      border: .all(color: const Color('#2e7d32'), width: 1.px),
    ),
    css('.app-bar-agent-pill-waiting').styles(
      border: .all(color: const Color('#ef6c00'), width: 1.px),
    ),
    css('.app-bar-agent-dot').styles(
      display: .inlineBlock,
      width: 8.px,
      height: 8.px,
      radius: .circular(99.px),
      flex: const .shrink(0),
    ),
    css('.app-bar-agent-dot-connected').styles(
      backgroundColor: const Color('#2e7d32'),
      raw: {'box-shadow': '0 0 0 2px rgba(76, 175, 80, 0.25)'},
    ),
    css('.app-bar-agent-dot-waiting').styles(
      backgroundColor: const Color('#ef6c00'),
      raw: {'box-shadow': '0 0 0 2px rgba(251, 192, 44, 0.28)'},
    ),
  ];
}
