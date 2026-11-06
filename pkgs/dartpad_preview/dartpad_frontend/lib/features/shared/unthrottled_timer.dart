// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

const _workerScript = '''
const timers = new Map();
self.onmessage = (e) => {
  const parts = String(e.data).split(':');
  const cmd = parts[0];
  const id = parts[1];
  if (cmd === 'set') {
    const ms = Number(parts[2]);
    const tid = setTimeout(() => {
      timers.delete(id);
      self.postMessage(id);
    }, ms);
    timers.set(id, tid);
  } else if (cmd === 'clear') {
    const tid = timers.get(id);
    if (tid !== undefined) {
      clearTimeout(tid);
      timers.delete(id);
    }
  }
};
self.postMessage('ready');
''';

/// Schedules a one-shot [Timer] backed by a dedicated inline Blob [web.Worker]
/// so delays remain accurate (`< 1,000 ms`) when the browser tab is occluded or
/// in the background while an external MCP coding agent drives DartPad.
///
/// Falls back to a standard [Timer] when [duration] is zero or negative, or if
/// creating a Blob worker is unsupported by the current environment.
Timer createUnthrottledTimer(Duration duration, void Function() callback) {
  if (duration <= Duration.zero) {
    return Timer(duration, callback);
  }
  final dispatcher = _WorkerTimerDispatcher.instance;
  if (dispatcher == null) {
    return Timer(duration, callback);
  }
  return dispatcher.schedule(duration, Zone.current.bindCallbackGuarded(callback));
}

/// Waits for [duration] without main-thread `window.setTimeout` background tab
/// clamping (`1 Hz`).
Future<void> unthrottledDelay(Duration duration) {
  if (duration <= Duration.zero) {
    return Future<void>.value();
  }
  final completer = Completer<void>();
  createUnthrottledTimer(duration, completer.complete);
  return completer.future;
}

final class _WorkerTimerDispatcher {
  _WorkerTimerDispatcher._(this._worker) {
    _worker.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (data == null || !data.typeofEquals('string')) {
        return;
      }
      final text = (data as JSString).toDart;
      if (text == 'ready') {
        _ready = true;
        for (final msg in _queuedMessages) {
          try {
            _worker.postMessage(msg.toJS);
          } catch (_) {}
        }
        _queuedMessages.clear();
        return;
      }
      final id = int.tryParse(text);
      if (id == null) {
        return;
      }
      final handle = _pending.remove(id);
      handle?._fire();
    }).toJS;
    _worker.onerror = ((web.Event _) {
      _failed = true;
      _instance = null;
      _queuedMessages.clear();
      _pending.clear();
    }).toJS;
  }

  static _WorkerTimerDispatcher? _instance;
  static bool _failed = false;

  static _WorkerTimerDispatcher? get instance {
    if (_failed) {
      return null;
    }
    final existing = _instance;
    if (existing != null) {
      return existing;
    }
    try {
      final parts = <JSAny>[_workerScript.toJS].toJS;
      final blob = web.Blob(parts, web.BlobPropertyBag(type: 'text/javascript'));
      final url = web.URL.createObjectURL(blob);
      final worker = web.Worker(url.toJS);
      final created = _WorkerTimerDispatcher._(worker);
      _instance = created;
      return created;
    } catch (_) {
      _failed = true;
      return null;
    }
  }

  final web.Worker _worker;
  final Map<int, _WorkerTimerHandle> _pending = <int, _WorkerTimerHandle>{};
  final List<String> _queuedMessages = <String>[];
  bool _ready = false;
  int _nextId = 1;

  Timer schedule(Duration duration, void Function() callback) {
    final id = _nextId++;
    final handle = _WorkerTimerHandle(this, id, duration, callback);
    _pending[id] = handle;
    final msg = 'set:$id:${duration.inMilliseconds}';
    if (!_ready) {
      _queuedMessages.add(msg);
      return handle;
    }
    try {
      _worker.postMessage(msg.toJS);
      return handle;
    } catch (_) {
      _pending.remove(id);
      return handle;
    }
  }

  void _cancel(int id) {
    if (_pending.remove(id) == null) {
      return;
    }
    final clearMsg = 'clear:$id';
    if (!_ready) {
      _queuedMessages.removeWhere((entry) => entry.startsWith('set:$id:'));
      return;
    }
    try {
      _worker.postMessage(clearMsg.toJS);
    } catch (_) {
      // Ignore worker postMessage errors during teardown.
    }
  }
}

final class _WorkerTimerHandle implements Timer {
  _WorkerTimerHandle(this._dispatcher, this._id, Duration duration, this._callback) {
    // Backstop main-thread timer in case the Blob worker is blocked by CSP or
    // still initializing; in a background tab the worker fires at `duration`
    // (`< 1,000 ms`) and cancels this fallback before it ticks.
    _fallbackTimer = Timer(duration + const Duration(milliseconds: 40), _fire);
  }

  final _WorkerTimerDispatcher _dispatcher;
  final int _id;
  final void Function() _callback;
  Timer? _fallbackTimer;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  void _fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _tick = 1;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _dispatcher._cancel(_id);
    _callback();
  }

  @override
  void cancel() {
    if (!_active) {
      return;
    }
    _active = false;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _dispatcher._cancel(_id);
  }
}
