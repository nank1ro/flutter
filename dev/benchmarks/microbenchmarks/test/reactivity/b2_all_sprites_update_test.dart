// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B2: 10,000 sprites, all mutated every frame. See
// docs/fine_grained_reactivity/BENCHMARKS.md. Throughput of the
// propagate/flush path when the dirty set is the whole graph.
//
// Baseline is the same per-sprite ValueListenableBuilder structure as B1,
// but every notifier is written each iteration, so every leaf rebuilds.
//
// The fork variant binds each sprite's colour to its own Signal through a
// ReactiveColoredBox and writes all 10,000 inside one batch, so the whole
// frame is one flush and 10,000 render-object setter calls, with no rebuild.
//
// The last variant is the ceiling this shape can reach before Phase 4: one
// ReactiveCustomPaint drawing 10,000 positions out of a single Float32List.
// It shows how much of the per-sprite number is the Stack's layout and paint
// of 10,000 children rather than the update mechanism.

import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kSpriteCount = 10000;

void main() {
  testWidgets('B2 ValueListenableBuilder update all 10000 every frame', (
    WidgetTester tester,
  ) async {
    final notifiers = List<ValueNotifier<Color>>.generate(
      kSpriteCount,
      (int i) => ValueNotifier<Color>(Colors.blue),
    );
    var buildCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: mountAllInRows([
          for (final n in notifiers)
            ValueListenableBuilder<Color>(
              valueListenable: n,
              builder: (BuildContext context, Color color, Widget? child) {
                buildCount++;
                return Container(width: 1, height: 1, color: color);
              },
            ),
        ]),
      ),
    );
    // Every sprite must be mounted, not just what a viewport would show.
    expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

    var frame = 0;
    const warmupIterations = 3;
    const timedIterations = 30;
    for (var w = 0; w < warmupIterations; w++) {
      final Color color = frame.isEven ? Colors.red : Colors.blue;
      for (final n in notifiers) {
        n.value = color;
      }
      frame++;
      await tester.pump();
    }
    buildCount = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        final Color color = frame.isEven ? Colors.red : Colors.blue;
        for (final n in notifiers) {
          n.value = color;
        }
        frame++;
        await tester.pump();
      },
    );
    // Liveness: every sprite must have rebuilt on every timed frame.
    expect(buildCount, kSpriteCount * timedIterations);
    printMedian('b2_value_listenable_update_all_10000', values);
  });

  testWidgets('B2 fork leaf ReactiveColoredBox update all 10000 in one batch', (
    WidgetTester tester,
  ) async {
    final signals = List<Signal<Color>>.generate(
      kSpriteCount,
      (int i) => Signal<Color>(Colors.blue),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: _BuildProbe(
          child: mountAllInRows([
            for (final s in signals)
              ReactiveColoredBox(color: s, child: const SizedBox(width: 1, height: 1)),
          ]),
        ),
      ),
    );
    expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

    // Render objects never get rebuilt in this variant, so their identity is
    // stable across the whole test: capture the list once, in sprite order.
    final List<RenderReactiveColoredBox> renderObjects = tester
        .renderObjectList<RenderReactiveColoredBox>(find.byType(ReactiveColoredBox))
        .toList();
    // Every 100th sprite, so a sample of 100 out of 10,000 is checked on
    // every timed frame without walking the whole list each time.
    final List<int> sampleIndices = [
      for (var idx = 0; idx < kSpriteCount; idx += kSpriteCount ~/ 100) idx,
    ];

    var frame = 0;
    const warmupIterations = 3;
    const timedIterations = 30;
    for (var w = 0; w < warmupIterations; w++) {
      final Color color = frame.isEven ? Colors.red : Colors.blue;
      batch<void>(() {
        for (final s in signals) {
          s.value = color;
        }
      });
      frame++;
      await tester.pump();
    }
    _probeBuilds = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        final Color color = frame.isEven ? Colors.red : Colors.blue;
        batch<void>(() {
          for (final s in signals) {
            s.value = color;
          }
        });
        frame++;
        await tester.pump();
        // Liveness on a sample every timed frame: proof the writes actually
        // reach the render objects, not just the last one.
        for (final idx in sampleIndices) {
          expect(renderObjects[idx].color, color);
        }
      },
    );
    // Liveness: the last-written sprite took the final value too.
    expect(renderObjects.last.color, frame.isEven ? Colors.blue : Colors.red);
    // Proof that nothing rebuilt.
    expect(_probeBuilds, 0);
    printMedian('b2_fork_leaf_reactive_colored_box_update_all_10000', values);
  });

  testWidgets('B2 fork ceiling one ReactiveCustomPaint drawing 10000 positions', (
    WidgetTester tester,
  ) async {
    final positions = Float32List(kSpriteCount * 2);
    for (var i = 0; i < positions.length; i++) {
      positions[i] = (i % 400).toDouble();
    }
    final generation = Signal<int>(0);
    final painter = _PositionsPainter(positions, generation);

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
      warmup: 3,
      iterations: 30,
      body: () async {
        for (var i = 0; i < positions.length; i++) {
          positions[i] += 0.1;
        }
        frame++;
        generation.value = frame;
        await tester.pump();
      },
    );
    // One repaint per write, and no rebuild.
    expect(painter.paints, 30 + 3);
    expect(_probeBuilds, 0);
    printMedian('b2_fork_ceiling_single_reactive_custom_paint_10000', values);
  });
}

/// Draws every position in one call, and reads [generation] while painting so
/// that bumping it is what repaints.
class _PositionsPainter extends CustomPainter {
  _PositionsPainter(this.positions, this.generation);

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
  bool shouldRepaint(_PositionsPainter oldDelegate) => false;
}

/// Counts its own builds, so a benchmark can assert that a signal write
/// rebuilt nothing. Only render-object elements sit between it and the
/// sprites, and those cannot be marked dirty on their own: if this counter
/// stays at zero, nothing on the path from the root to the leaf rebuilt.
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
