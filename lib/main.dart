// // main.dart
// import 'dart:isolate';
// import 'dart:math' as math;
// import 'package:flutter/material.dart';

// import 'fastpath_ui.dart'; // your core with FastPathWorkerRegistry

// // -------------------------
// // TOP-LEVEL HEAVY WORKER
// // -------------------------
// // Must be top-level. Runs inside a spawned isolate. Receives Map messages,
// // does heavy CPU work, and replies with latency (ms) + any meta.
// //
// // WARNING: This deliberately does heavy work to demonstrate the pipeline.
// // Reduce the LOOP_ITERS to make it less heavy on slower machines.
// const int LOOP_ITERS = 3000000;

// void heavyWorker(SendPort sendPort) {
//   final port = ReceivePort();
//   sendPort.send(port.sendPort);

//   port.listen((msg) {
//     if (msg is Map) {
//       final int gestureId = msg['gestureId'] ?? 0;
//       final int seq = msg['seq'] ?? 0;
//       final bool isFinal = msg['isFinal'] ?? false;
//       final dx = (msg['dx'] ?? 0.0) as double;
//       final dy = (msg['dy'] ?? 0.0) as double;

//       // Start timing inside worker
//       final sw = Stopwatch()..start();

//       // Real heavy compute simulation (replace with real ML / physics in practice)
//       double acc = 0.0;
//       // Use dx/dy slightly to vary work per message
//       final base = dx + dy;
//       for (int i = 0; i < LOOP_ITERS; i++) {
//         // A mix of sin/cos to be expensive and non-trivial
//         acc += math.sin(i * 0.0007 + base) * math.cos(i * 0.0003 + base);
//       }

//       sw.stop();

//       // Send back result (keep map primitive-only)
//       sendPort.send({
//         'gestureId': gestureId,
//         'seq': seq,
//         'latency': sw.elapsedMilliseconds,
//         'isFinal': isFinal,
//         'meta': {
//           'workUnits': acc.abs(),
//           'iters': LOOP_ITERS,
//         },
//       });
//     }
//   });
// }

// // -------------------------
// // Demo App: uses FastPathWidget
// // -------------------------
// void main() {
//   // Register worker in the registry under a name before runApp
//   FastPathWorkerRegistry.register('heavyWorker', heavyWorker);

//   runApp(const MaterialApp(home: HeavyDemoPage()));
// }

// class HeavyDemoPage extends StatefulWidget {
//   const HeavyDemoPage({super.key});
//   @override
//   State<HeavyDemoPage> createState() => _HeavyDemoPageState();
// }

// class _HeavyDemoPageState extends State<HeavyDemoPage> {
//   final FastPathController _ctrl = FastPathController();

//   // UI-side drawing points & latency (local measurement)
//   final List<Offset> _points = [];
//   final List<int> _uiLatencies = []; // newest-first
//   final List<int> _workerLatencies = []; // newest-first (reports from worker)
//   static const int _maxSamples = 100;

//   bool _useFastPath = true;
//   int _numPointsShown = 800;

//   @override
//   void initState() {
//     super.initState();
//     _ctrl.setUseFastPath(true);
//   }

//   @override
//   void dispose() {
//     _ctrl.dispose();
//     super.dispose();
//   }

//   int _percentile(List<int> a, double p) {
//     if (a.isEmpty) return 0;
//     final sorted = List<int>.from(a)..sort();
//     final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
//     return sorted[idx];
//   }

//   void _onClassifiedMove(GestureMove move) {
//     // UI-side latency stopwatch
//     final sw = Stopwatch()..start();

//     setState(() {
//       final last = _points.isNotEmpty ? _points.last : const Offset(200, 300);
//       final next = last + move.delta;
//       _points.add(next);
//       if (_points.length > _numPointsShown) {
//         _points.removeRange(0, _points.length - _numPointsShown);
//       }
//     });

//     WidgetsBinding.instance.addPostFrameCallback((_) {
//       sw.stop();
//       final ms = sw.elapsedMilliseconds;
//       setState(() {
//         _uiLatencies.insert(0, ms);
//         if (_uiLatencies.length > _maxSamples) _uiLatencies.removeLast();
//       });
//     });
//   }

//   void _onWorkerSamples(List<int> samples) {
//     setState(() {
//       // core may send latency samples (worker-side); keep a copy
//       _workerLatencies.clear();
//       _workerLatencies.addAll(samples);
//       if (_workerLatencies.length > _maxSamples) {
//         _workerLatencies.removeRange(_maxSamples, _workerLatencies.length);
//       }
//     });
//   }

//   @override
//   Widget build(BuildContext context) {
//     final uiP50 = _percentile(_uiLatencies, 0.5);
//     final workerP50 = _percentile(_workerLatencies, 0.5);
//     final latestWorker = _workerLatencies.isEmpty ? 0 : _workerLatencies.first;
//     final latestUi = _uiLatencies.isEmpty ? 0 : _uiLatencies.first;

//     return Scaffold(
//       appBar: AppBar(
//         title: const Text('Heavy Worker Demo (main.dart)'),
//         backgroundColor: Colors.deepPurple,
//         actions: [
//           TextButton(
//             onPressed: () => setState(() {
//               _useFastPath = !_useFastPath;
//               _ctrl.setUseFastPath(_useFastPath);
//             }),
//             child: Text(_useFastPath ? 'Use Baseline' : 'Use FastPath',
//                 style: const TextStyle(color: Colors.white)),
//           ),
//           IconButton(
//             icon: const Icon(Icons.clear),
//             onPressed: () => setState(() {
//               _points.clear();
//               _uiLatencies.clear();
//               _workerLatencies.clear();
//             }),
//           ),
//         ],
//       ),
//       body: Stack(
//         children: [
//           // Drawing area
//           Positioned.fill(
//             child: FastPathWidget(
//               controller: _ctrl,
//               config: const FastPathConfig(
//                 workerName: 'heavyWorker', // use the heavy worker we registered
//                 coalesceWindowMs: 10,
//                 maxQueueSize: 8,
//                 uiBlockingSimMs: 0, // ensure core won't simulate UI blocking
//               ),
//               customClassifier: _DiagonalClassifier(), // decide when to offload
//               onClassifiedMove: _onClassifiedMove,
//               onLatencySamples: _onWorkerSamples, // get worker-side reported latencies
//               child: CustomPaint(
//                 painter: _Painter(List<Offset>.from(_points)),
//                 child: Container(color: Colors.black),
//               ),
//             ),
//           ),

//           // Overlay telemetry
//           Positioned(
//             left: 12,
//             top: 12,
//             child: Container(
//               padding: const EdgeInsets.all(10),
//               decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
//               child: DefaultTextStyle(
//                 style: const TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 12),
//                 child: Column(
//                   crossAxisAlignment: CrossAxisAlignment.start,
//                   children: [
//                     Text('UI p50: ${uiP50} ms  latest: ${latestUi} ms'),
//                     const SizedBox(height: 6),
//                     Text('Worker p50: ${workerP50} ms  latest: ${latestWorker} ms'),
//                     const SizedBox(height: 6),
//                     Text('Worker iters: $LOOP_ITERS'),
//                     const SizedBox(height: 6),
//                     Text('Points: ${_points.length}'),
//                   ],
//                 ),
//               ),
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }

// // Simple diagonal classifier (offloads when both axes move enough)
// class _DiagonalClassifier implements FastPathClassifier {
//   @override
//   bool isHeavy(PointerEvent e) {
//     return e.localDelta.dx.abs() > 8 && e.localDelta.dy.abs() > 8;
//   }

//   @override
//   void reset() {}
// }

// // Simple painter
// class _Painter extends CustomPainter {
//   final List<Offset> pts;
//   _Painter(this.pts);

//   @override
//   void paint(Canvas c, Size s) {
//     final p = Paint()
//       ..color = Colors.lightGreenAccent
//       ..strokeWidth = 3
//       ..strokeCap = StrokeCap.round;
//     for (int i = 1; i < pts.length; i++) {
//       c.drawLine(pts[i - 1], pts[i], p);
//     }
//   }

//   @override
//   bool shouldRepaint(covariant _Painter old) => true;
// }

import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'fastpath_ui.dart'; // your FastPath core file

// -------------------------
// TOP-LEVEL HEAVY WORKER
// -------------------------
// Runs off the UI thread (spawned by FastPath).
// Performs deliberately expensive math for demo purposes.
const int LOOP_ITERS = 3000000;

void heavyWorker(SendPort sendPort) {
  final port = ReceivePort();
  sendPort.send(port.sendPort);

  port.listen((msg) {
    if (msg is Map) {
      final int gestureId = msg['gestureId'] ?? 0;
      final int seq = msg['seq'] ?? 0;
      final bool isFinal = msg['isFinal'] ?? false;
      final dx = (msg['dx'] ?? 0.0) as double;
      final dy = (msg['dy'] ?? 0.0) as double;

      // Real heavy compute simulation (like ML or physics)
      final sw = Stopwatch()..start();
      double acc = 0.0;
      final base = dx + dy;
      for (int i = 0; i < LOOP_ITERS; i++) {
        acc += math.sin(i * 0.0007 + base) * math.cos(i * 0.0003 + base);
      }
      sw.stop();

      // Send latency result back
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

// -------------------------
// MAIN APP ENTRY
// -------------------------
void main() {
  FastPathWorkerRegistry.register('heavyWorker', heavyWorker);
  runApp(const MaterialApp(home: HeavyDemoPage()));
}

class HeavyDemoPage extends StatefulWidget {
  const HeavyDemoPage({super.key});
  @override
  State<HeavyDemoPage> createState() => _HeavyDemoPageState();
}

class _HeavyDemoPageState extends State<HeavyDemoPage> {
  final FastPathController _ctrl = FastPathController();
  final List<Offset> _points = [];
  final List<int> _uiLatencies = [];
  final List<int> _workerLatencies = [];
  static const int _maxSamples = 100;

  @override
  void initState() {
    super.initState();
    _ctrl.setUseFastPath(true); // always fast path
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
      final last = _points.isNotEmpty ? _points.last : const Offset(200, 300);
      final next = last + move.delta;
      _points.add(next);
      if (_points.length > 800) {
        _points.removeRange(0, _points.length - 800);
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

  @override
  Widget build(BuildContext context) {
    final uiP50 = _percentile(_uiLatencies, 0.5);
    final workerP50 = _percentile(_workerLatencies, 0.5);

    return Scaffold(
      appBar: AppBar(
        title: const Text('FastPath Heavy Demo'),
        backgroundColor: Colors.deepPurple,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => setState(() {
              _points.clear();
              _uiLatencies.clear();
              _workerLatencies.clear();
            }),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Drawing area
          Positioned.fill(
            child: FastPathWidget(
              controller: _ctrl,
              config: const FastPathConfig(
                workerName: 'heavyWorker', // our custom heavy isolate
                coalesceWindowMs: 10,
                maxQueueSize: 8,
                uiBlockingSimMs: 0,
              ),
              customClassifier: _DiagonalClassifier(),
              onClassifiedMove: _onClassifiedMove,
              onLatencySamples: _onWorkerSamples,
              child: CustomPaint(
                painter: _Painter(List<Offset>.from(_points)),
                child: Container(color: Colors.black),
              ),
            ),
          ),

          // Telemetry overlay
          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: DefaultTextStyle(
                style: const TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('FAST PATH MODE (Heavy Worker Active)'),
                    const SizedBox(height: 6),
                    Text('UI p50: ${uiP50} ms'),
                    Text('Worker p50: ${workerP50} ms'),
                    const SizedBox(height: 6),
                    Text('Iterations: $LOOP_ITERS'),
                    const SizedBox(height: 6),
                    Text('Samples: ${_workerLatencies.length}'),
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

// Simple diagonal classifier — defines what counts as "heavy"
class _DiagonalClassifier implements FastPathClassifier {
  @override
  bool isHeavy(PointerEvent e) {
    return e.localDelta.dx.abs() > 8 && e.localDelta.dy.abs() > 8;
  }

  @override
  void reset() {}
}

// Draws the stroke path
class _Painter extends CustomPainter {
  final List<Offset> pts;
  _Painter(this.pts);

  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = Colors.lightGreenAccent
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (int i = 1; i < pts.length; i++) {
      c.drawLine(pts[i - 1], pts[i], p);
    }
  }

  @override
  bool shouldRepaint(covariant _Painter old) => true;
}
