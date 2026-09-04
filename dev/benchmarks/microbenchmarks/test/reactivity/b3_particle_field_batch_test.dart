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
// TODO(fork): add a Signal-batch variant once packages/flutter exposes a
// batched-write API for the retained scene graph (see B9).

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointMode;

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
        home: SizedBox.expand(child: CustomPaint(painter: _ParticlePainter(positions, repaintTick))),
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
}
