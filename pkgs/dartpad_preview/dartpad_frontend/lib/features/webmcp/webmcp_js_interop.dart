// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

import 'package:web/web.dart' as web;

import 'webmcp_models.dart';

/// `window.sessionStorage` key storing the stable per-tab WebMCP session alias.
const webMcpTabIdStorageKey = 'dartpad.webmcp.tabId';

const _tabIdAlphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
final _validClientTabIdPattern = RegExp(r'^tab-[a-z0-9]{4,12}$');

/// Mints a fresh random `tab-<4chars>` client tab identifier.
String mintRandomClientTabId() {
  final rng = Random();
  final suffix = StringBuffer();
  for (var i = 0; i < 4; i++) {
    suffix.write(_tabIdAlphabet[rng.nextInt(_tabIdAlphabet.length)]);
  }
  return 'tab-$suffix';
}

/// Reads or mints a stable per-tab WebMCP identifier (`tab-xxxx`) persisted in
/// `window.sessionStorage` across reloads and bridge switches.
String readOrMintClientTabId({String storageKey = webMcpTabIdStorageKey}) {
  try {
    final existing = web.window.sessionStorage.getItem(storageKey)?.trim();
    if (existing != null && _validClientTabIdPattern.hasMatch(existing)) {
      return existing;
    }
  } catch (_) {
    // Restricted iframe/storage contexts fall back to an in-memory identifier.
  }
  final minted = mintRandomClientTabId();
  try {
    web.window.sessionStorage.setItem(storageKey, minted);
  } catch (_) {
    // Ignore sessionStorage quota or sandbox access errors.
  }
  return minted;
}

@JS('JSON.stringify')
external JSString? _jsJsonStringify(JSAny? value);

@JS('JSON.parse')
external JSAny? _jsJsonParse(JSString text);

const _polyfillMarkerProperty = '_isDartPadWebMcpPolyfill';

/// Registers DartPad WebMCP tools on W3C `document.modelContext` (installing a
/// standard-Chrome polyfill when absent) and mirrors the full helper API onto
/// `window.dartpadMcp`.
final class WebMcpBrowserRegistry {
  WebMcpBrowserRegistry();

  final Map<String, JSObject> _registeredJsTools = <String, JSObject>{};
  final Map<String, WebMcpToolSpec> _dartSpecs = <String, WebMcpToolSpec>{};
  JSObject? _nativeDocumentContext;
  JSObject? _nativeNavigatorContext;
  bool _installed = false;

  /// Installs the browser surface (if needed) and registers [tools].
  void registerTools(List<WebMcpToolSpec> tools) {
    _ensureInstalled();
    for (final spec in tools) {
      _dartSpecs[spec.name] = spec;
      final jsTool = _buildJsToolObject(spec);
      _registerJsTool(jsTool);
    }
  }

  /// Unregisters tools owned by this registry instance.
  void dispose() {
    final names = _dartSpecs.keys.toList(growable: false);
    _dartSpecs.clear();
    for (final name in names) {
      _unregisterByName(name);
    }
  }

  void _ensureInstalled() {
    if (_installed) {
      return;
    }
    _installed = true;

    final docObject = web.document as JSObject;
    final existingDocContext = docObject.getProperty<JSAny?>('modelContext'.toJS);
    if (_isNativeContext(existingDocContext)) {
      _nativeDocumentContext = existingDocContext as JSObject;
    }

    final navObject = web.window.navigator as JSObject;
    final existingNavContext = navObject.getProperty<JSAny?>('modelContext'.toJS);
    if (_isNativeContext(existingNavContext)) {
      _nativeNavigatorContext = existingNavContext as JSObject;
    }

    final polyfillApi = _createPolyfillObject();
    (web.window as JSObject).setProperty('dartpadMcp'.toJS, polyfillApi);

    if (_nativeDocumentContext case final nativeCtx?) {
      _augmentNativeContext(nativeCtx, polyfillApi);
    } else {
      docObject.setProperty('modelContext'.toJS, polyfillApi);
    }
  }

  bool _isNativeContext(JSAny? candidate) {
    if (candidate == null || candidate.isUndefinedOrNull || !candidate.typeofEquals('object')) {
      return false;
    }
    final marker = (candidate as JSObject).getProperty<JSAny?>(_polyfillMarkerProperty.toJS);
    return marker == null || marker.isUndefinedOrNull;
  }

  void _augmentNativeContext(JSObject nativeCtx, JSObject polyfillApi) {
    if (!nativeCtx.has('getTools')) {
      nativeCtx.setProperty('getTools'.toJS, polyfillApi.getProperty<JSAny?>('getTools'.toJS));
    }
    if (!nativeCtx.has('executeTool')) {
      nativeCtx.setProperty('executeTool'.toJS, polyfillApi.getProperty<JSAny?>('executeTool'.toJS));
    }
  }

  JSObject _createPolyfillObject() {
    final api = JSObject();
    api.setProperty(_polyfillMarkerProperty.toJS, true.toJS);
    api.setProperty('registerTool'.toJS, _registerJsTool.toJS);
    api.setProperty(
      'unregisterTool'.toJS,
      (([JSAny? toolOrName]) => _unregisterByName(_extractToolName(toolOrName)).toJS).toJS,
    );
    api.setProperty(
      'clearContext'.toJS,
      (([JSAny? _]) {
        _dartSpecs.clear();
        _registeredJsTools.clear();
      }).toJS,
    );
    api.setProperty(
      'getTools'.toJS,
      (([JSAny? _]) => _registeredJsTools.values.toList(growable: false).toJS).toJS,
    );
    api.setProperty(
      'executeTool'.toJS,
      (([JSAny? toolOrName, JSAny? rawArgs]) => _executeToolFromJs(toolOrName, rawArgs).toJS).toJS,
    );
    return api;
  }

  void _registerJsTool(JSObject jsTool) {
    final name = _extractToolName(jsTool);
    if (name.isEmpty) {
      throw ArgumentError('WebMCP registerTool requires a non-empty tool name.');
    }
    _registeredJsTools[name] = jsTool;
    _forwardNativeRegister(_nativeDocumentContext, name, jsTool);
    _forwardNativeRegister(_nativeNavigatorContext, name, jsTool);
  }

  bool _unregisterByName(String name) {
    if (name.isEmpty) {
      return false;
    }
    final removed = _registeredJsTools.remove(name) != null;
    _forwardNativeUnregister(_nativeDocumentContext, name);
    _forwardNativeUnregister(_nativeNavigatorContext, name);
    return removed;
  }

  void _forwardNativeRegister(JSObject? nativeCtx, String name, JSObject jsTool) {
    if (nativeCtx == null || !nativeCtx.has('registerTool')) {
      return;
    }
    _forwardNativeUnregister(nativeCtx, name);
    try {
      nativeCtx.callMethodVarArgs<JSAny?>('registerTool'.toJS, <JSAny?>[jsTool]);
    } catch (_) {
      // Ignore native experimental registration mismatches; the polyfill
      // registry remains authoritative for in-page callers.
    }
  }

  void _forwardNativeUnregister(JSObject? nativeCtx, String name) {
    if (nativeCtx == null || !nativeCtx.has('unregisterTool')) {
      return;
    }
    try {
      nativeCtx.callMethodVarArgs<JSAny?>('unregisterTool'.toJS, <JSAny?>[name.toJS]);
    } catch (_) {
      // Ignore unregister errors when the tool was not previously registered.
    }
  }

  JSObject _buildJsToolObject(WebMcpToolSpec spec) {
    final tool = JSObject();
    tool.setProperty('name'.toJS, spec.name.toJS);
    tool.setProperty('description'.toJS, spec.description.toJS);
    tool.setProperty('inputSchema'.toJS, _encodePlainJsObject(spec.inputSchema));
    tool.setProperty(
      'annotations'.toJS,
      _encodePlainJsObject(<String, Object?>{'readOnlyHint': spec.readOnlyHint}),
    );
    tool.setProperty('readOnlyHint'.toJS, spec.readOnlyHint.toJS);
    tool.setProperty(
      'execute'.toJS,
      (([JSAny? rawArgs, JSAny? _]) => _invokeSpec(spec, rawArgs).toJS).toJS,
    );
    return tool;
  }

  Future<JSAny?> _executeToolFromJs(JSAny? toolOrName, JSAny? rawArgs) async {
    final name = _extractToolName(toolOrName);
    if (_dartSpecs[name] case final spec?) {
      return _invokeSpec(spec, rawArgs);
    }
    final fallbackTool = toolOrName != null && !toolOrName.isUndefinedOrNull && toolOrName.typeofEquals('object')
        ? toolOrName as JSObject
        : null;
    final jsTool = _registeredJsTools[name] ?? fallbackTool;
    if (jsTool != null && jsTool.has('execute')) {
      final executeFn = jsTool.getProperty<JSAny?>('execute'.toJS);
      if (executeFn != null && executeFn.typeofEquals('function')) {
        final rawResult = (executeFn as JSFunction).callAsFunction(jsTool, rawArgs ?? JSObject());
        if (rawResult != null && rawResult.typeofEquals('object') && (rawResult as JSObject).has('then')) {
          return (rawResult as JSPromise<JSAny?>).toDart;
        }
        return rawResult;
      }
    }
    throw StateError('Unknown WebMCP tool: $name');
  }

  Future<JSAny?> _invokeSpec(WebMcpToolSpec spec, JSAny? rawArgs) async {
    final decodedArgs = _decodeJsArguments(rawArgs);
    final result = await spec.handler(decodedArgs);
    return _encodePlainJsObject(result);
  }
}

String _extractToolName(JSAny? toolOrName) {
  if (toolOrName == null || toolOrName.isUndefinedOrNull) {
    return '';
  }
  if (toolOrName.typeofEquals('string')) {
    return (toolOrName as JSString).toDart;
  }
  if (toolOrName.typeofEquals('object')) {
    final nameProp = (toolOrName as JSObject).getProperty<JSAny?>('name'.toJS);
    if (nameProp != null && nameProp.typeofEquals('string')) {
      return (nameProp as JSString).toDart;
    }
  }
  return '';
}

Map<String, Object?> _decodeJsArguments(JSAny? rawArgs) {
  if (rawArgs == null || rawArgs.isUndefinedOrNull) {
    return const <String, Object?>{};
  }
  final serialized = _jsJsonStringify(rawArgs)?.toDart;
  if (serialized == null || serialized.isEmpty) {
    return const <String, Object?>{};
  }
  final decoded = jsonDecode(serialized);
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  if (decoded is Map) {
    return Map<String, Object?>.from(decoded);
  }
  throw const FormatException('WebMCP tool arguments must be a JSON object.');
}

JSAny? _encodePlainJsObject(Map<String, Object?> value) => _jsJsonParse(jsonEncode(value).toJS);
