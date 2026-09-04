// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B3: particle field, 50,000 particles, position written every frame in one
// batch. See docs/fine_grained_reactivity/BENCHMARKS.md. Isolates
// allocation in the hot path and batching correctness.
//
// Both variants run in one process, interleaved and rotated by
// `runInterleaved`.
//
// Baseline (best current practice for this shape in vanilla Flutter): a
// single CustomPainter over a pre-allocated Float32List of positions,
// repainted via a ChangeNotifier `repaint` tick and drawn with a single
// `canvas.drawRawPoints` call. No widget tree rebuild and no per-particle
// allocation happens on the hot path.
//
// The fork variant is the same Float32List and the same single
// drawRawPoints, behind a ReactiveCustomPaint. A Float32List mutated in place
// is not a change any signal can see, so a Signal<int> generation counter sits
// beside it, is bumped once after the write loop, and is read inside paint().
//
// Render objects: one per variant. There is no collapsed-model variant --
// `RCustomPaint` was removed from the Phase 5 spike -- and no scene variant
// here; the scene's particle row is measured against these two in b9.

import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kParticleCount = 50000;
const int kWarmup = 3;
const int kTimed = 15;

int _probeBuilds = 0;

Float32List _seedPositions() {
  final positions = Float32List(kParticleCount * 2);
  final random = math.Random(0);
  for (var i = 0; i < positions.length; i++) {
    positions[i] = random.nextDouble() * 400;
  }
  return positions;
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter(this.positions, Listenable repaintTick) : super(repaint: repaintTick);

  final Float32List positions;
  int paints = 0;

  static final Paint _paint = Paint()
    ..color = Colors.white
    ..strokeWidth = 1
    ..strokeCap = StrokeCap.square;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRawPoints(PointMode.points, positions, _paint);
  }

  @override
  bool shouldRepaint(_ParticlePainter oldDelegate) => !identical(oldDelegate, this);
}

/// The same painter as the baseline, but it reads a signal while painting
/// instead of listening to a [Listenable].
class _ReactiveParticlePainter extends CustomPainter {
  _ReactiveParticlePainter(this.positions, this.generation);

  final Float32List positions;
  final Signal<int> generation;
  int paints = 0;

  static final Paint _paint = Paint()
    ..color = Colors.white
    ..strokeWidth = 1
    ..strokeCap = StrokeCap.square;

  @override
  void paint(Canvas canvas, Size size) {
    generation.value;
    paints++;
    canvas.drawRawPoints(PointMode.points, positions, _paint);
  }

  @override
  // Not `false`: when a later round hands this render object a new painter,
  // the reads the new painter makes must be re-tracked, which only happens
  // if it repaints once. Inside a timed loop the painter never changes, so
  // this is never consulted there.
  bool shouldRepaint(_ReactiveParticlePainter oldDelegate) => !identical(oldDelegate, this);
}

/// Counts its own builds, so the benchmark can assert that the batch of writes
/// never entered the build pipeline.
class _BuildProbe extends StatelessWidget {
  const _BuildProbe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    _probeBuilds++;
    return child;
  }
}

Future<double> _customPainterBaseline(WidgetTester tester) async {
  final Float32List positions = _seedPositions();
  final repaintTick = ValueNotifier<int>(0);
  final painter = _ParticlePainter(positions, repaintTick);
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox.expand(child: CustomPaint(painter: painter)),
    ),
  );

  var frame = 0;
  painter.paints = 0;
  final List<double> values = await timeIterations(
    warmup: kWarmup,
    iterations: kTimed,
    body: () async {
      for (var i = 0; i < positions.length; i++) {
        positions[i] += 0.1;
      }
      repaintTick.value = ++frame;
      await tester.pump();
    },
  );
  // Liveness: exactly one repaint per frame.
  expect(painter.paints, kWarmup + kTimed);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _reactiveCustomPaint(WidgetTester tester) async {
  final Float32List positions = _seedPositions();
  final generation = Signal<int>(0);
  final painter = _ReactiveParticlePainter(positions, generation);
  await tester.pumpWidget(
    MaterialApp(
      home: _BuildProbe(
        child: SizedBox.expand(child: ReactiveCustomPaint(painter: painter)),
      ),
    ),
  );

  var frame = 0;
  _probeBuilds = 0;
  painter.paints = 0;
  final List<double> values = await timeIterations(
    warmup: kWarmup,
    iterations: kTimed,
    body: () async {
      batch<void>(() {
        for (var i = 0; i < positions.length; i++) {
          positions[i] += 0.1;
        }
        generation.value = ++frame;
      });
      await tester.pump();
    },
  );
  // Exactly one repaint per frame, and nothing rebuilt.
  expect(painter.paints, kWarmup + kTimed);
  expect(_probeBuilds, 0);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

void main() {
  testWidgets('B3 50000 particles, one batch per frame', (WidgetTester tester) async {
    await runInterleaved(tester, 'b3', <BenchVariant>[
      const BenchVariant('custompainter_best_practice', _customPainterBaseline),
      const BenchVariant('phase3_reactive_custom_paint', _reactiveCustomPaint),
    ]);
  });
}
