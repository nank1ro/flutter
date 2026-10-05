// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B2: 10,000 sprites, all mutated every frame. See
// docs/fine_grained_reactivity/BENCHMARKS.md. Throughput of the
// propagate/flush path when the dirty set is the whole graph.
//
// All variants run in one process, interleaved and rotated by
// `runInterleaved`, so the ratios below are between measurements taken at the
// same point in the JIT warm-up curve.
//
// Render objects per sprite -- 1 in every variant that does 10,000 writes:
//   classic  Positioned > (Reactive)ColoredBox
//   collapsed  RPositioned > RBox
// No RepaintBoundary here, unlike B1: every sprite changes every frame, so a
// per-sprite boundary would be overhead in every variant alike and is not the
// best practice for this workload.
//
// The last variant is a different workload and is labelled as one: one
// ReactiveCustomPaint drawing all 10,000 positions out of a single
// Float32List, with one signal write and one repaint per frame instead of
// 10,000 writes into 10,000 render objects. It is a ceiling on the shape, not
// a comparison of update mechanisms, and no ratio against the other rows is
// published.

import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/reactive_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kSpriteCount = 10000;
const int kWarmup = 1;
const int kTimed = 6;

int _spriteBuilds = 0;
int _probeBuilds = 0;
int _effectRuns = 0;

/// A [ReadonlySignal] that counts its tracked reads, so the leaf variant can
/// assert that every sprite's binding ran once per frame. It does the same
/// work as the counting closure the variant used before ColoredBox took a
/// [ReadonlySignal]: one call and one increment per read.
final class _CountingRead implements ReadonlySignal<Color> {
  _CountingRead(this._source);

  final Signal<Color> _source;

  @override
  Color get value {
    _effectRuns += 1;
    return _source.value;
  }

  @override
  Color get peek => _source.peek;

  @override
  Color call() => value;
}

int _componentRuns = 0;

Color _colorForFrame(int frame) => frame.isEven ? Colors.red : Colors.blue;

/// A sprite that reads its own colour signal in its own build.
class _SignalSprite extends StatelessWidget {
  const _SignalSprite(this.color);

  final Signal<Color> color;

  @override
  Widget build(BuildContext context) {
    _spriteBuilds++;
    return ColoredBox(color: .fixed(color.value));
  }
}

/// Counts its own builds. Only render-object elements sit between it and the
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

Future<double> _valueListenable(WidgetTester tester) async {
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
              return ColoredBox(color: .fixed(color));
            },
          ),
      ]),
    ),
  );
  expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

  var frame = 0;
  for (var w = 0; w < kWarmup; w++) {
    final Color color = _colorForFrame(frame++);
    for (final n in notifiers) {
      n.value = color;
    }
    await tester.pump();
  }
  buildCount = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      final Color color = _colorForFrame(frame++);
      for (final n in notifiers) {
        n.value = color;
      }
      await tester.pump();
    },
  );
  // Liveness: every sprite rebuilt on every timed frame.
  expect(buildCount, kSpriteCount * kTimed);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _signalInBuild(WidgetTester tester) async {
  final signals = List<Signal<Color>>.generate(kSpriteCount, (int i) => Signal<Color>(Colors.blue));
  await tester.pumpWidget(
    MaterialApp(home: mountAllInRows([for (final s in signals) _SignalSprite(s)])),
  );
  expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

  var frame = 0;
  for (var w = 0; w < kWarmup; w++) {
    final Color color = _colorForFrame(frame++);
    batch<void>(() {
      for (final s in signals) {
        s.value = color;
      }
    });
    await tester.pump();
  }
  _spriteBuilds = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      final Color color = _colorForFrame(frame++);
      batch<void>(() {
        for (final s in signals) {
          s.value = color;
        }
      });
      await tester.pump();
    },
  );
  // Liveness: every sprite rebuilt on every timed frame.
  expect(_spriteBuilds, kSpriteCount * kTimed);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _leafBinding(WidgetTester tester) async {
  final signals = List<Signal<Color>>.generate(kSpriteCount, (int i) => Signal<Color>(Colors.blue));
  await tester.pumpWidget(
    MaterialApp(
      home: _BuildProbe(
        child: mountAllInRows([for (final s in signals) ColoredBox(color: _CountingRead(s))]),
      ),
    ),
  );
  expect(find.byType(Positioned), findsNWidgets(kSpriteCount));
  // Render objects are never rebuilt in this variant, so their identity is
  // stable for the whole run: capture the list once, in sprite order.
  final List<RenderObject> renderObjects = tester
      .renderObjectList<RenderObject>(
        // Only the sprites: the app shell has ColoredBoxes of its own.
        find.descendant(of: find.byType(_BuildProbe), matching: find.byType(ColoredBox)),
      )
      .toList();

  var frame = 0;
  for (var w = 0; w < kWarmup; w++) {
    final Color color = _colorForFrame(frame++);
    batch<void>(() {
      for (final s in signals) {
        s.value = color;
      }
    });
    await tester.pump();
  }
  _probeBuilds = 0;
  _effectRuns = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      final Color color = _colorForFrame(frame++);
      batch<void>(() {
        for (final s in signals) {
          s.value = color;
        }
      });
      await tester.pump();
    },
  );
  // Liveness, outside the timed region so it costs no variant anything: one
  // effect run per sprite per frame, a sample of 100 render objects really
  // holding the last colour written, and nothing rebuilt.
  expect(_effectRuns, kSpriteCount * kTimed);
  final Color last = _colorForFrame(frame - 1);
  for (var idx = 0; idx < kSpriteCount; idx += kSpriteCount ~/ 100) {
    expect(renderObjects[idx], paints..rect(color: last));
  }
  expect(renderObjects.last, paints..rect(color: last));
  expect(_probeBuilds, 0);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _collapsedNodes(WidgetTester tester) async {
  final signals = List<Signal<Color>>.generate(kSpriteCount, (int i) => Signal<Color>(Colors.blue));
  final boxes = <RBox>[];
  _componentRuns = 0;
  final root = RComponent(() {
    _componentRuns += 1;
    return RStack(
      children: <RNode>[
        for (var i = 0; i < kSpriteCount; i++)
          RPositioned(
            left: 0,
            top: i.toDouble(),
            width: 800,
            height: 1,
            child: () {
              final box = RBox(
                color: () {
                  _effectRuns += 1;
                  return signals[i].value;
                },
              );
              boxes.add(box);
              return box;
            }(),
          ),
      ],
    );
  });
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox(
        width: const .fixed(800),
        height: .fixed(kSpriteCount.toDouble()),
        child: NodeHost(node: root),
      ),
    ),
  );
  expect(boxes, hasLength(kSpriteCount));

  var frame = 0;
  for (var w = 0; w < kWarmup; w++) {
    final Color color = _colorForFrame(frame++);
    batch<void>(() {
      for (final s in signals) {
        s.value = color;
      }
    });
    await tester.pump();
  }
  _effectRuns = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      final Color color = _colorForFrame(frame++);
      batch<void>(() {
        for (final s in signals) {
          s.value = color;
        }
      });
      await tester.pump();
    },
  );
  expect(_effectRuns, kSpriteCount * kTimed);
  final Color last = _colorForFrame(frame - 1);
  for (var idx = 0; idx < kSpriteCount; idx += kSpriteCount ~/ 100) {
    expect(boxes[idx].renderObject.color, last);
  }
  expect(boxes.last.renderObject.color, last);
  expect(_componentRuns, 1);

  await tester.pumpWidget(const SizedBox.shrink());
  root.dispose();
  return median(values);
}

Future<double> _ceilingSingleDrawCall(WidgetTester tester) async {
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
    warmup: kWarmup,
    iterations: kTimed,
    body: () async {
      for (var i = 0; i < positions.length; i++) {
        positions[i] += 0.1;
      }
      generation.value = ++frame;
      await tester.pump();
    },
  );
  // One repaint per write, and no rebuild.
  expect(painter.paints, kWarmup + kTimed);
  expect(_probeBuilds, 0);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
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
  // Not `false`: when a later round hands this render object a new painter,
  // the reads the new painter makes must be re-tracked, which only happens
  // if it repaints once. Inside a timed loop the painter never changes, so
  // this is never consulted there.
  bool shouldRepaint(_PositionsPainter oldDelegate) => !identical(oldDelegate, this);
}

void main() {
  testWidgets('B2 update all 10000 sprites every frame', (WidgetTester tester) async {
    await runInterleaved(tester, 'b2', <BenchVariant>[
      const BenchVariant('vlb_best_practice', _valueListenable),
      const BenchVariant('phase2_signal_build', _signalInBuild),
      const BenchVariant('phase3_leaf', _leafBinding),
      const BenchVariant('phase5_collapsed', _collapsedNodes),
      const BenchVariant('ceiling_one_draw_call', _ceilingSingleDrawCall),
    ]);
  });
}
