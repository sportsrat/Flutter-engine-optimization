// fast_path_core_with_custom_workers.dart
// FastPath core — now supports user-defined custom worker isolates.

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart';

/// ---------------- PUBLIC API ----------------

class FastPathConfig {
  final int coalesceWindowMs;
  final int maxQueueSize;
  final int uiBlockingSimMs;
  final double velocityThreshold;
  final double distanceThreshold;

  /// Optional name of a registered custom worker
  final String? workerName;

  const FastPathConfig({
    this.coalesceWindowMs = 8,
    this.maxQueueSize = 8,
    this.uiBlockingSimMs = 35,
    this.velocityThreshold = 0.05,
    this.distanceThreshold = 40.0,
    this.workerName,
  });
}

class FastPathController {
  final _ready = Completer<void>();
  void Function()? _onDispose;
  bool useFastPath = true;
  Future<void> get ready => _ready.future;

  void _markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void _registerDispose(void Function() cb) => _onDispose = cb;
  void dispose() => _onDispose?.call();
  void setUseFastPath(bool v) => useFastPath = v;
}

/// Interface for custom classifiers
abstract class FastPathClassifier {
  bool isHeavy(PointerEvent e);
  void reset();
}

/// Default classifier based on configurable thresholds
class DefaultFastClassifier implements FastPathClassifier {
  Offset? lastPos;
  int lastTime = 0;
  final FastPathConfig cfg;
  DefaultFastClassifier(this.cfg);

  @override
  bool isHeavy(PointerEvent e) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final dt = (now - lastTime).clamp(1, 1000);
    lastTime = now;
    if (lastPos == null) {
      lastPos = e.localPosition;
      return false;
    }
    final dx = (e.localPosition - lastPos!).distance;
    lastPos = e.localPosition;
    final velocity = dx / dt;
    return velocity < cfg.velocityThreshold || dx > cfg.distanceThreshold;
  }

  @override
  void reset() {
    lastPos = null;
    lastTime = 0;
  }
}

class GestureMove {
  final Offset delta;
  final int seq;
  final int gestureId;
  GestureMove({required this.delta, required this.seq, required this.gestureId});
}

/// ---------------- CUSTOM WORKER REGISTRY ----------------
///
/// Apps can register their own isolate entrypoints
/// before the FastPathWidget is used.

typedef WorkerEntry = void Function(SendPort sendPort);

class FastPathWorkerRegistry {
  static final Map<String, WorkerEntry> _entries = {};

  /// Register a new worker (must be top-level function)
  static void register(String name, WorkerEntry entry) {
    _entries[name] = entry;
  }

  /// Internal: get worker by name
  static WorkerEntry? get(String name) => _entries[name];
}

/// ---------------- MAIN WIDGET ----------------

class FastPathWidget extends StatefulWidget {
  final Widget child;
  final FastPathConfig config;
  final FastPathController? controller;
  final void Function(List<int>)? onLatencySamples;
  final void Function(GestureMove)? onClassifiedMove;
  final void Function(PointerEvent)? onRawPointer;
  final FastPathClassifier? customClassifier;

  const FastPathWidget({
    required this.child,
    this.config = const FastPathConfig(),
    this.controller,
    this.onLatencySamples,
    this.onClassifiedMove,
    this.onRawPointer,
    this.customClassifier,
    super.key,
  });

  @override
  State<FastPathWidget> createState() => _FastPathWidgetState();
}

class _FastPathWidgetState extends State<FastPathWidget> {
  final List<int> _latencies = [];
  static const int _maxLatSamples = 60;

  int _gestureIdCounter = 0;
  int _seqCounter = 0;
  int _currentGestureId = -1;
  final Map<int, String> _gestureStates = {};
  final Map<int, int> _lastSeq = {};
  final Queue<Map<String, dynamic>> _outgoingQueue = Queue();

  int _lastCoalesceTime = 0;
  bool _disposed = false;

  Isolate? _worker;
  SendPort? _workerPort;
  final ReceivePort _uiReceive = ReceivePort();

  late final FastPathClassifier _classifier;
  late final FastPathController _controller;
  late FastPathConfig _cfg;

  @override
  void initState() {
    super.initState();
    _cfg = widget.config;
    _classifier = widget.customClassifier ?? DefaultFastClassifier(_cfg);
    _controller = widget.controller ?? FastPathController();
    _controller._registerDispose(_disposeInternals);
    _spawnWorker().then((_) => _controller._markReady());
  }

  Future<void> _spawnWorker() async {
    final ready = Completer<SendPort>();

    final workerEntry =
        (_cfg.workerName != null ? FastPathWorkerRegistry.get(_cfg.workerName!) : null) ??
            _defaultWorkerEntry;

    _worker = await Isolate.spawn(workerEntry, _uiReceive.sendPort);
    _uiReceive.listen((msg) {
      if (_disposed) return;
      if (msg is SendPort) {
        _workerPort = msg;
        ready.complete(msg);
      } else {
        _onWorkerMessage(msg);
      }
    });

    _workerPort = await ready.future;
  }

  void _onWorkerMessage(dynamic msg) {
    if (msg is! Map) return;
    final int gestureId = msg['gestureId'] ?? 0;
    final int seq = msg['seq'] ?? 0;
    final int latency = msg['latency'] ?? 0;
    final bool isFinal = msg['isFinal'] ?? false;

    if (_gestureStates[gestureId] != 'active' && !isFinal) return;
    if (seq < (_lastSeq[gestureId] ?? -1)) return;
    _lastSeq[gestureId] = seq;

    _latencies.insert(0, latency);
    if (_latencies.length > _maxLatSamples) _latencies.removeLast();
    widget.onLatencySamples?.call(List<int>.from(_latencies));

    if (isFinal) _gestureStates[gestureId] = 'done';
  }

  void _sendToWorker(Map<String, dynamic> msg) {
    if (_workerPort == null) {
      if (_outgoingQueue.length >= _cfg.maxQueueSize) _outgoingQueue.removeFirst();
      _outgoingQueue.add(msg);
      return;
    }
    _workerPort?.send(msg);
  }

  void _handlePointerDown(PointerDownEvent e) {
    _gestureIdCounter++;
    _currentGestureId = _gestureIdCounter;
    _gestureStates[_currentGestureId] = 'active';
    _classifier.reset();
    widget.onRawPointer?.call(e);
  }

  void _handlePointerMove(PointerMoveEvent e) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCoalesceTime < _cfg.coalesceWindowMs) return;
    _lastCoalesceTime = now;

    final sw = Stopwatch()..start();
    final isHeavy = _classifier.isHeavy(e);
    final seq = ++_seqCounter;

    if (!_controller.useFastPath) {
      
    } else if (isHeavy) {
      final msg = {
        'gestureId': _currentGestureId,
        'seq': seq,
        'type': 'move',
        'dx': e.localDelta.dx,
        'dy': e.localDelta.dy,
      };
      _sendToWorker(msg);
      widget.onClassifiedMove?.call(GestureMove(
        delta: e.localDelta,
        seq: seq,
        gestureId: _currentGestureId,
      ));
    } else {
      widget.onClassifiedMove?.call(GestureMove(
        delta: e.localDelta,
        seq: seq,
        gestureId: _currentGestureId,
      ));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      _latencies.insert(0, ms);
      if (_latencies.length > _maxLatSamples) _latencies.removeLast();
      widget.onLatencySamples?.call(List<int>.from(_latencies));
    });

    widget.onRawPointer?.call(e);
  }

  void _handlePointerUp(PointerUpEvent e) {
    final gestureId = _currentGestureId;
    _sendToWorker({
      'gestureId': gestureId,
      'seq': ++_seqCounter,
      'type': 'end',
      'isFinal': true,
    });
    widget.onRawPointer?.call(e);
  }

  // void _simulateHeavyBlocking(int ms) {
  //   final sw = Stopwatch()..start();
  //   double acc = 0;
  //   while (sw.elapsedMilliseconds < ms) {
  //     for (int i = 0; i < 4000; i++) {
  //       acc += math.sqrt(i * 1.2345);
  //     }
  //   }
  //   if (acc.isNaN) debugPrint('');
  // }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      child: widget.child,
    );
  }

  Future<void> _disposeInternals() async {
    _disposed = true;
    _worker?.kill(priority: Isolate.immediate);
    _uiReceive.close();
  }

  @override
  void dispose() {
    _disposeInternals();
    super.dispose();
  }
}

/// ---------------- DEFAULT WORKER ----------------

// ---------------- CLEAN WORKER (no fake heaviness) ----------------
void _defaultWorkerEntry(SendPort sendPort) {
  final port = ReceivePort();
  sendPort.send(port.sendPort);

  port.listen((msg) {
    if (msg is Map) {
      final int gestureId = msg['gestureId'] ?? 0;
      final int seq = msg['seq'] ?? 0;
      final bool isFinal = msg['isFinal'] ?? false;



      sendPort.send({
        'gestureId': gestureId,
        'seq': seq,
        'latency': 0, // near-instant — isolates just pass data through
        'isFinal': isFinal,
      });
    }
  });
}
