// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:clock/clock.dart';

import 'task_status.dart';
import 'unthrottled_timer.dart';

/// Tracks analyzer readiness and translates LSP analysis activity into
/// application tasks.
///
/// Analyzer startup and the first complete analysis are represented by a
/// [TaskKind.startingAnalyzer] task. Later analysis cycles trigger a
/// [TaskKind.analyzing] task which reuses the same task key, replacing earlier
/// analysis entries in recent task history.
///
/// [idleDebounce] defines how long the controller waits after receiving an
/// `isAnalyzing: false` event before completing active analysis tasks. This
/// avoids flickering when the analyzer repeatedly transitions between busy and
/// idle in quick succession (e.g. while indexing multiple files during reference
/// search).
final class AnalyzerStatusController {
  AnalyzerStatusController(
    this._taskStatus, {
    this.idleDebounce = const Duration(milliseconds: 50),
  });

  final TaskStatusController _taskStatus;

  /// The delay before marking active analysis tasks as succeeded after the
  /// analyzer reports it is no longer analyzing.
  final Duration idleDebounce;

  TaskStatusHandle? _initializationTask;
  TaskStatusHandle? _currentTask;
  Timer? _idleTimer;
  bool _startingTask = false;
  bool _initializationFinished = false;
  bool _unavailable = false;
  bool _disposed = false;

  /// Whether the analyzer is currently initializing or analyzing files.
  bool get isAnalyzing =>
      !_disposed && (_startingTask || _initializationTask != null || _currentTask != null || _idleTimer != null);

  /// Whether initial analyzer startup has finished (either ready or unavailable).
  bool get isInitialized => _initializationFinished;

  /// Whether the analyzer failed to start or disconnected.
  bool get isUnavailable => _unavailable;

  TaskStatusHandle _startTask(TaskKind kind) {
    _startingTask = true;
    try {
      return _taskStatus.startTask(kind);
    } finally {
      _startingTask = false;
    }
  }

  /// Starts the task spanning analyzer startup and initial analysis.
  void beginInitialization() {
    if (_disposed || _initializationTask != null || _initializationFinished) {
      return;
    }
    _cancelIdleTimer();
    _initializationTask = _startTask(TaskKind.startingAnalyzer);
  }

  /// Applies an analyzer busy/idle notification.
  void update({required bool isAnalyzing}) {
    if (_disposed) {
      return;
    }
    if (isAnalyzing) {
      _cancelIdleTimer();
      _unavailable = false;
      if (_initializationTask != null) {
        return;
      }
      if (!_initializationFinished) {
        _initializationTask = _startTask(TaskKind.startingAnalyzer);
        return;
      }
      _currentTask ??= _startTask(TaskKind.analyzing);
      return;
    }

    if (_unavailable) {
      return;
    }

    if (_initializationTask case final task?) {
      _initializationTask = null;
      _initializationFinished = true;
      task.succeed();
    }

    if (_currentTask == null) {
      return;
    }

    if (idleDebounce == Duration.zero) {
      final task = _currentTask;
      _currentTask = null;
      task?.succeed();
    } else {
      final finished = clock.now();
      _idleTimer?.cancel();
      _idleTimer = createUnthrottledTimer(idleDebounce, () {
        _idleTimer = null;
        if (!_disposed) {
          final task = _currentTask;
          _currentTask = null;
          task?.succeed(finishedAt: finished);
        }
      });
    }
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// Marks the analyzer as unavailable after startup or stream failure.
  void markUnavailable() {
    if (_disposed) {
      return;
    }
    _cancelIdleTimer();
    final initTask = _initializationTask;
    final currentTask = _currentTask;
    final hadActiveTask = initTask != null || currentTask != null;
    final wasInitialized = _initializationFinished;
    _initializationTask = null;
    _currentTask = null;
    _initializationFinished = true;
    _unavailable = true;
    initTask?.fail();
    currentTask?.fail();
    if (!hadActiveTask) {
      final kind = wasInitialized ? TaskKind.analyzing : TaskKind.startingAnalyzer;
      _taskStatus.startTask(kind).fail();
    }
  }

  /// Resets the controller state and cancels any pending analysis tasks.
  void reset() {
    if (_disposed) {
      return;
    }
    _cancelIdleTimer();
    final initTask = _initializationTask;
    final currentTask = _currentTask;
    _initializationTask = null;
    _currentTask = null;
    _initializationFinished = false;
    _unavailable = false;
    initTask?.cancel();
    currentTask?.cancel();
  }

  /// Cancels any active tasks and disposes the controller.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancelIdleTimer();
    final initTask = _initializationTask;
    final currentTask = _currentTask;
    _initializationTask = null;
    _currentTask = null;
    initTask?.cancel();
    currentTask?.cancel();
  }
}
