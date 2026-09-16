import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'fastpath_ui.dart';

const int LOOP_ITERS = 3000000;

void heavyWorker(dynamic sendPort) {
  final port = ReceivePort();
  sendPort.send(port.sendPort);

  port.listen((msg) {
    if (msg is Map) {
      final int gestureId = msg['gestureId'] ?? 0;
      final int seq = msg['seq'] ?? 0;
      final bool isFinal = msg['isFinal'] ?? false;
      final dx = (msg['dx'] ?? 0.0) as double;
      final dy = (msg['dy'] ?? 0.0) as double;

      final sw = Stopwatch()..start();
      double acc = 0.0;
      final base = dx + dy;
      for (int i = 0; i < LOOP_ITERS; i++) {
        acc += math.sin(i * 0.0007 + base) * math.cos(i * 0.0003 + base);
      }
      sw.stop();

      sendPort.send({
        'gestureId': gestureId,
        'seq': seq,
        'latency': sw.elapsedMilliseconds,
        'isFinal': isFinal,
        'meta': {'workUnits': acc.abs(), 'iters': LOOP_ITERS},
      });
    }
  });
}

void main() {
  FastPathWorkerRegistry.register('heavyWorker', heavyWorker);
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: HeavyDemoPage(),
  ));
}

class StrokeSegment {
  final Offset start;
  final Offset end;
  final bool isHeavy;

  StrokeSegment({required this.start, required this.end, required this.isHeavy});
}

class HeavyDemoPage extends StatefulWidget {
  const HeavyDemoPage({super.key});
  @override
  State<HeavyDemoPage> createState() => _HeavyDemoPageState();
}

class _HeavyDemoPageState extends State<HeavyDemoPage> {
  final FastPathController _ctrl = FastPathController();

  final List<StrokeSegment> _segments = [];
  Offset? _lastPosition;
  final List<int> _uiLatencies = [];
  final List<int> _workerLatencies = [];
  static const int _maxSamples = 100;

  bool _useFastPath = true;
  int _fastCount = 0;
  int _heavyCount = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.setUseFastPath(true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int _percentile(List<int> a, double p) {
    if (a.isEmpty) return 0;
    final sorted = List<int>.from(a)..sort();
    final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  void _onClassifiedMove(GestureMove move) {
    final sw = Stopwatch()..start();

    setState(() {
      if (move.isStart) {
        _lastPosition = move.position;
        return;
      }

      if (_lastPosition != null) {
        _segments.add(StrokeSegment(
          start: _lastPosition!,
          end: move.position,
          isHeavy: move.isHeavy,
        ));
        _lastPosition = move.position;

        if (move.isHeavy) {
          _heavyCount++;
        } else {
          _fastCount++;
        }

        if (_segments.length > 1200) {
          _segments.removeRange(0, _segments.length - 1200);
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      setState(() {
        _uiLatencies.insert(0, ms);
        if (_uiLatencies.length > _maxSamples) _uiLatencies.removeLast();
      });
    });
  }

  void _onWorkerSamples(List<int> samples) {
    setState(() {
      _workerLatencies
        ..clear()
        ..addAll(samples);
      if (_workerLatencies.length > _maxSamples) {
        _workerLatencies.removeRange(_maxSamples, _workerLatencies.length);
      }
    });
  }

  Color _getLatencyColor(int ms) {
    if (ms < 16) return const Color(0xFF00FF88);
    if (ms < 33) return Colors.amberAccent;
    return const Color(0xFFFF3366);
  }

  @override
  Widget build(BuildContext context) {
    final uiP50 = _percentile(_uiLatencies, 0.5);
    final workerP50 = _percentile(_workerLatencies, 0.5);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A12),
      appBar: AppBar(
        title: const Text('Flutter Pulse Engine', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: const Color(0xFF161626),
        elevation: 4,
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _useFastPath ? const Color(0xFF00FF88) : const Color(0xFFFF5500),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
              onPressed: () => setState(() {
                _useFastPath = !_useFastPath;
                _ctrl.setUseFastPath(_useFastPath);
              }),
              icon: Icon(_useFastPath ? Icons.flash_on : Icons.block, size: 16),
              label: Text(_useFastPath ? 'FastPath Active' : 'Baseline Mode', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: () => setState(() {
              _segments.clear();
              _uiLatencies.clear();
              _workerLatencies.clear();
              _fastCount = 0;
              _heavyCount = 0;
              _lastPosition = null;
            }),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: FastPathWidget(
              controller: _ctrl,
              config: const FastPathConfig(
                workerName: 'heavyWorker',
                coalesceWindowMs: 8,
                maxQueueSize: 8,
                uiBlockingSimMs: 35,
              ),
              customClassifier: _DiagonalClassifier(),
              onClassifiedMove: _onClassifiedMove,
              onLatencySamples: _onWorkerSamples,
              child: CustomPaint(
                painter: _CanvasPainter(List<StrokeSegment>.from(_segments)),
                child: Container(color: Colors.transparent),
              ),
            ),
          ),

          // Enhanced Telemetry Overlay
          Positioned(
            left: 16,
            top: 16,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF121220).withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
                boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10)],
              ),
              child: DefaultTextStyle(
                style: const TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: _getLatencyColor(uiP50), shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Text('UI p50 Latency: ', style: const TextStyle(color: Colors.white70)),
                        Text('$uiP50 ms', style: TextStyle(color: _getLatencyColor(uiP50), fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFFF5500), shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        const Text('Worker p50 Latency: ', style: TextStyle(color: Colors.white70)),
                        Text('$workerP50 ms', style: const TextStyle(color: Color(0xFFFF5500), fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const Divider(color: Colors.white24, height: 16),
                    Row(
                      children: [
                        Container(width: 10, height: 3, color: const Color(0xFF00FF88)),
                        const SizedBox(width: 6),
                        Text('Fast Path (UI): $_fastCount', style: const TextStyle(color: Color(0xFF00FF88))),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(width: 10, height: 3, color: const Color(0xFFFF5500)),
                        const SizedBox(width: 6),
                        Text('Heavy Path (Worker): $_heavyCount', style: const TextStyle(color: Color(0xFFFF5500))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagonalClassifier implements FastPathClassifier {
  @override
  bool isHeavy(PointerEvent e) {
    return e.localDelta.dx.abs() > 8 && e.localDelta.dy.abs() > 8;
  }

  @override
  void reset() {}
}

class _CanvasPainter extends CustomPainter {
  final List<StrokeSegment> segments;
  _CanvasPainter(this.segments);

  @override
  void paint(Canvas canvas, Size size) {
    final fastPaint = Paint()
      ..color = const Color(0xFF00FF88)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    final heavyPaint = Paint()
      ..color = const Color(0xFFFF5500)
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;

    for (final seg in segments) {
      canvas.drawLine(seg.start, seg.end, seg.isHeavy ? heavyPaint : fastPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter oldDelegate) => true;
}