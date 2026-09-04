// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B3: particle field, 50,000 particles, position written every frame in one
// batch. See docs/fine_grained_reactivity/BENCHMARKS.md. Isolates
// allocation in the hot path and batching correctness.
//
// Baseline (best current practice for this shape in vanilla Flutter): a
// single CustomPainter over a pre-allocated Float32List of positions,
// repainted via a ChangeNotifier `repaint` tick and drawn with a single
// `canvas.drawRawPoints` call. No widget tree rebuild and no per-particle
// allocation happens on the hot path: the timed region is the 100,000-entry
// position write loop, the notify, and the single-call raw-points paint.
//
// The fork variant is the same Float32List and the same single
// drawRawPoints, behind a ReactiveCustomPaint. A Float32List mutated in place
// is not a change any signal can see, so a Signal<int> generation counter sits
// beside it, is bumped once after the write loop, and is read inside paint():
// the whole frame is one signal write, one effect flush and one repaint.

import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kParticleCount = 50000;

class _ParticlePainter extends CustomPainter {
  _ParticlePainter(this.positions, Listenable repaintTick) : super(repaint: repaintTick);

  final Float32List positions;
  static final Paint _paint = Paint()
    ..color = Colors.white
    ..strokeWidth = 1
    ..strokeCap = StrokeCap.square;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRawPoints(PointMode.points, positions, _paint);
  }

  @override
  bool shouldRepaint(_ParticlePainter oldDelegate) => false; // repaint is driven by `repaint` tick.
}

void main() {
  testWidgets('B3 CustomPainter draw 50000 particle positions', (WidgetTester tester) async {
    final positions = Float32List(kParticleCount * 2);
    final random = math.Random(0);
    for (var i = 0; i < positions.length; i++) {
      positions[i] = random.nextDouble() * 400;
    }
    final repaintTick = ValueNotifier<int>(0);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(
          child: CustomPaint(painter: _ParticlePainter(positions, repaintTick)),
        ),
      ),
    );

    var frame = 0;
    final List<double> values = await timeIterations(
      warmup: 5,
      iterations: 60,
      body: () async {
        for (var i = 0; i < positions.length; i++) {
          positions[i] += 0.1;
        }
        frame++;
        repaintTick.value = frame;
        await tester.pump();
      },
    );
    printMedian('b3_custompainter_50000_particles', values);
  });

  testWidgets('B3 fork ReactiveCustomPaint 50000 particles in one batch', (
    WidgetTester tester,
  ) async {
    final positions = Float32List(kParticleCount * 2);
    final random = math.Random(0);
    for (var i = 0; i < positions.length; i++) {
      positions[i] = random.nextDouble() * 400;
    }
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
    const warmupIterations = 5;
    const timedIterations = 60;
    _probeBuilds = 0;
    painter.paints = 0;
    final List<double> values = await timeIterations(
      warmup: warmupIterations,
      iterations: timedIterations,
      body: () async {
        batch<void>(() {
          for (var i = 0; i < positions.length; i++) {
            positions[i] += 0.1;
          }
          frame++;
          generation.value = frame;
        });
        await tester.pump();
      },
    );
    // Exactly one repaint per frame, and nothing rebuilt.
    expect(painter.paints, warmupIterations + timedIterations);
    expect(_probeBuilds, 0);
    printMedian('b3_fork_reactive_custom_paint_50000_particles', values);
  });
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
  bool shouldRepaint(_ReactiveParticlePainter oldDelegate) => false;
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

int _probeBuilds = 0;
