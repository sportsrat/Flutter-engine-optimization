import 'dart:async';
import 'dart:collection';
import 'dart:isolate' as isolate;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart';

class FastPathConfig {
  final int coalesceWindowMs;
  final int maxQueueSize;
  final int uiBlockingSimMs;
  final double velocityThreshold;
  final double distanceThreshold;
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

abstract class FastPathClassifier {
  bool isHeavy(PointerEvent e);
  void reset();
}

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
  final Offset position;
  final int seq;
  final int gestureId;
  final bool isHeavy;
  final bool isStart;

  GestureMove({
    required this.delta,
    required this.position,
    required this.seq,
    required this.gestureId,
    required this.isHeavy,
    this.isStart = false,
  });
}

typedef WorkerEntry = void Function(dynamic sendPort);

class FastPathWorkerRegistry {
  static final Map<String, WorkerEntry> _entries = {};

  static void register(String name, WorkerEntry entry) {
    _entries[name] = entry;
  }

  static WorkerEntry? get(String name) => _entries[name];
}

abstract class _PortChannel {
  void send(dynamic message);
  void close();
}

class _WebPortChannel implements _PortChannel {
  final StreamController _controller = StreamController.broadcast();
  final void Function(dynamic) _onMessage;

  _WebPortChannel(this._onMessage) {
    _controller.stream.listen(_onMessage);
  }

  @override
  void send(dynamic message) => _controller.add(message);

  @override
  void close() => _controller.close();
}

class _NativePortChannel implements _PortChannel {
  final isolate.SendPort _port;
  _NativePortChannel(this._port);

  @override
  void send(dynamic message) => _port.send(message);

  @override
  void close() {}
}

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

  isolate.Isolate? _nativeWorker;
  _PortChannel? _workerChannel;
  isolate.ReceivePort? _nativeReceivePort;

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
    final ready = Completer<_PortChannel>();

    final workerEntry =
        (_cfg.workerName != null ? FastPathWorkerRegistry.get(_cfg.workerName!) : null) ??
            _defaultWorkerEntry;

    if (kIsWeb) {
      final fromWorker = StreamController.broadcast();
      fromWorker.stream.listen((msg) {
        if (_disposed) return;
        _onWorkerMessage(msg);
      });

      final mockSendPort = _WebMockSendPort(fromWorker);
      workerEntry(mockSendPort);

      _workerChannel = _WebPortChannel((msg) => mockSendPort.dispatchToWorker(msg));
      ready.complete(_workerChannel);
    } else {
      _nativeReceivePort = isolate.ReceivePort();
      _nativeReceivePort!.listen((msg) {
        if (_disposed) return;
        if (msg is isolate.SendPort) {
          final channel = _NativePortChannel(msg);
          _workerChannel = channel;
          if (!ready.isCompleted) ready.complete(channel);
        } else {
          _onWorkerMessage(msg);
        }
      });

      _nativeWorker = await isolate.Isolate.spawn(workerEntry, _nativeReceivePort!.sendPort);
    }

    _workerChannel = await ready.future;

    while (_outgoingQueue.isNotEmpty) {
      _workerChannel?.send(_outgoingQueue.removeFirst());
    }
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
    if (_workerChannel == null) {
      if (_outgoingQueue.length >= _cfg.maxQueueSize) _outgoingQueue.removeFirst();
      _outgoingQueue.add(msg);
      return;
    }
    _workerChannel?.send(msg);
  }

  void _handlePointerDown(PointerDownEvent e) {
    _gestureIdCounter++;
    _currentGestureId = _gestureIdCounter;
    _gestureStates[_currentGestureId] = 'active';
    _classifier.reset();

    widget.onClassifiedMove?.call(GestureMove(
      delta: Offset.zero,
      position: e.localPosition,
      seq: ++_seqCounter,
      gestureId: _currentGestureId,
      isHeavy: false,
      isStart: true,
    ));

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
      _simulateHeavyBlocking(_cfg.uiBlockingSimMs);
      widget.onClassifiedMove?.call(GestureMove(
        delta: e.localDelta,
        position: e.localPosition,
        seq: seq,
        gestureId: _currentGestureId,
        isHeavy: isHeavy,
      ));
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
        position: e.localPosition,
        seq: seq,
        gestureId: _currentGestureId,
        isHeavy: true,
      ));
    } else {
      widget.onClassifiedMove?.call(GestureMove(
        delta: e.localDelta,
        position: e.localPosition,
        seq: seq,
        gestureId: _currentGestureId,
        isHeavy: false,
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

  void _simulateHeavyBlocking(int ms) {
    final sw = Stopwatch()..start();
    double acc = 0;
    while (sw.elapsedMilliseconds < ms) {
      for (int i = 0; i < 4000; i++) {
        acc += math.sqrt(i * 1.2345);
      }
    }
    if (acc.isNaN) debugPrint('');
  }

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
    _workerChannel?.close();
    _nativeWorker?.kill(priority: isolate.Isolate.immediate);
    _nativeReceivePort?.close();
  }

  @override
  void dispose() {
    _disposeInternals();
    super.dispose();
  }
}

class _WebMockSendPort {
  final StreamController _replyController;
  final StreamController _incomingController = StreamController.broadcast();

  _WebMockSendPort(this._replyController);

  void send(dynamic message) => _replyController.add(message);

  void dispatchToWorker(dynamic message) => _incomingController.add(message);

  _WebMockReceivePort get receivePort => _WebMockReceivePort(_incomingController);
}

class _WebMockReceivePort {
  final StreamController _controller;
  _WebMockReceivePort(this._controller);

  void listen(void Function(dynamic) onData) {
    _controller.stream.listen(onData);
  }
}

void _defaultWorkerEntry(dynamic sendPort) {
  final StreamController ctrl = StreamController.broadcast();
  sendPort.send(ctrl.sink);

  ctrl.stream.listen((msg) {
    if (msg is Map) {
      final int gestureId = msg['gestureId'] ?? 0;
      final int seq = msg['seq'] ?? 0;
      final bool isFinal = msg['isFinal'] ?? false;

      sendPort.send({
        'gestureId': gestureId,
        'seq': seq,
        'latency': 0,
        'isFinal': isFinal,
      });
    }
  });
}