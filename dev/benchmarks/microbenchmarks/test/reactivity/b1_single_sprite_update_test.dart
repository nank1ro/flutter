// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B1: 10,000 sprites, one signal per sprite, one sprite mutated per frame.
// See docs/fine_grained_reactivity/BENCHMARKS.md.
//
// All five variants run in one process, interleaved and rotated by
// `runInterleaved`, so no variant is compared against another from a
// different position in the JIT warm-up curve or from a different process.
//
//  - best current practice: a ValueNotifier per sprite with a
//    ValueListenableBuilder at the leaf, so only the mutated leaf rebuilds.
//  - naive: setState on the root, rebuilding all 10,000 children.
//  - Phase 2: each sprite reads its own Signal<Color> in its own build. No
//    builder widget and no BuildContext dependency.
//  - Phase 3 leaf: the sprite is a ReactiveColoredBox whose colour is bound
//    straight to the signal, so a write runs one effect, calls one
//    render-object setter, and rebuilds nothing.
//  - Phase 5 collapsed: the same sprite as one RBox in a node tree, where
//    Widget and Element are one retained object.
//
// Render objects per sprite -- 2 in every variant:
//   classic  Positioned > RepaintBoundary > (Reactive)ColoredBox
//   collapsed  RPositioned > RRepaintBoundary > RBox
// `Positioned`/`RPositioned` carry parent data and own no render object, and
// the tight rows of `mountAllInRows` mean no variant needs a SizedBox to take
// the row's size. Element counts cannot be matched and are the mechanism, not
// the shape: the best-practice baseline adds a StatefulElement per sprite,
// Phase 2 a StatelessElement, Phase 3 and Phase 5 none.

import 'package:flutter/material.dart';
import 'package:flutter/reactive_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kSpriteCount = 10000;
const int kWarmup = 3;
const int kTimed = 12;

int _spriteBuilds = 0;
int _probeBuilds = 0;
int _effectRuns = 0;
int _componentRuns = 0;

/// Distinct colour per write, so a `ValueNotifier` never early-returns on an
/// identical value and every timed pump does real work.
Color _colorFor(int i) => Color.fromARGB(255, (i * 37) & 0xff, (i * 91) & 0xff, 0);

/// A sprite that reads its own colour signal. No wrapper, no builder.
class _SignalSprite extends StatelessWidget {
  const _SignalSprite(this.color);

  final Signal<Color> color;

  @override
  Widget build(BuildContext context) {
    _spriteBuilds++;
    return ColoredBox(color: color.value);
  }
}

/// Counts its own builds, so a benchmark can assert that a signal write
/// rebuilt nothing. It sits above the sprites, and the only elements between
/// it and them are render-object elements, which cannot be marked dirty on
/// their own: if this counter stays at zero, nothing on the path from the root
/// to the leaf rebuilt.
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
          RepaintBoundary(
            child: ValueListenableBuilder<Color>(
              valueListenable: n,
              builder: (BuildContext context, Color color, Widget? child) {
                buildCount++;
                return ColoredBox(color: color);
              },
            ),
          ),
      ]),
    ),
  );
  // Every sprite must be mounted, not just what a viewport would show.
  expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    notifiers[i % kSpriteCount].value = _colorFor(i);
    i++;
    await tester.pump();
  }
  buildCount = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      notifiers[i % kSpriteCount].value = _colorFor(i);
      i++;
      await tester.pump();
    },
  );
  // Every timed pump rebuilt its leaf, rather than hitting ValueNotifier's
  // identical-value early return.
  expect(buildCount, kTimed);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _setStateRoot(WidgetTester tester) async {
  final colors = List<Color>.filled(kSpriteCount, Colors.blue);
  late StateSetter setState;
  await tester.pumpWidget(
    MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setter) {
          setState = setter;
          return mountAllInRows([
            for (final c in colors) RepaintBoundary(child: ColoredBox(color: c)),
          ]);
        },
      ),
    ),
  );
  expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

  var i = 0;
  final List<double> values = await timeIterations(
    warmup: kWarmup,
    iterations: kTimed,
    body: () async {
      colors[i % kSpriteCount] = _colorFor(i);
      i++;
      setState(() {});
      await tester.pump();
    },
  );
  // Liveness: the whole list really carries the last colour written.
  expect(colors[(i - 1) % kSpriteCount], _colorFor(i - 1));
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _signalInBuild(WidgetTester tester) async {
  final signals = List<Signal<Color>>.generate(kSpriteCount, (int i) => Signal<Color>(Colors.blue));
  await tester.pumpWidget(
    MaterialApp(
      home: mountAllInRows([for (final s in signals) RepaintBoundary(child: _SignalSprite(s))]),
    ),
  );
  expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    signals[i % kSpriteCount].value = _colorFor(i);
    i++;
    await tester.pump();
  }
  _spriteBuilds = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      signals[i % kSpriteCount].value = _colorFor(i);
      i++;
      await tester.pump();
    },
  );
  // Exactly one sprite rebuilt per write: no ancestor, no sibling.
  expect(_spriteBuilds, kTimed);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _leafBinding(WidgetTester tester) async {
  final signals = List<Signal<Color>>.generate(kSpriteCount, (int i) => Signal<Color>(Colors.blue));
  await tester.pumpWidget(
    MaterialApp(
      home: _BuildProbe(
        child: mountAllInRows([
          for (final s in signals) RepaintBoundary(child: ReactiveColoredBox(color: s)),
        ]),
      ),
    ),
  );
  expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    signals[i % kSpriteCount].value = _colorFor(i);
    i++;
    await tester.pump();
  }
  _probeBuilds = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      signals[i % kSpriteCount].value = _colorFor(i);
      i++;
      await tester.pump();
    },
  );
  // Liveness: the render object really took the last colour written.
  expect(
    tester
        .renderObjectList<RenderReactiveColoredBox>(find.byType(ReactiveColoredBox))
        .elementAt((i - 1) % kSpriteCount)
        .color,
    _colorFor(i - 1),
  );
  // Nothing rebuilt: the update never entered the build pipeline.
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
            child: RRepaintBoundary(
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
          ),
      ],
    );
  });
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox(
        width: 800,
        height: kSpriteCount.toDouble(),
        child: NodeHost(node: root),
      ),
    ),
  );
  expect(boxes, hasLength(kSpriteCount));

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    signals[i % kSpriteCount].value = _colorFor(i);
    i++;
    await tester.pump();
  }
  _effectRuns = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      signals[i % kSpriteCount].value = _colorFor(i);
      i++;
      await tester.pump();
    },
  );
  // Liveness: the render object really took the last colour written.
  expect(boxes[(i - 1) % kSpriteCount].renderObject.color, _colorFor(i - 1));
  // One effect run per write, and the component body never ran again.
  expect(_effectRuns, kTimed);
  expect(_componentRuns, 1);

  await tester.pumpWidget(const SizedBox.shrink());
  root.dispose();
  return median(values);
}

void main() {
  testWidgets('B1 update one of 10000 sprites', (WidgetTester tester) async {
    await runInterleaved(tester, 'b1', <BenchVariant>[
      const BenchVariant('vlb_best_practice', _valueListenable),
      const BenchVariant('setstate_naive', _setStateRoot),
      const BenchVariant('phase2_signal_build', _signalInBuild),
      const BenchVariant('phase3_leaf', _leafBinding),
      const BenchVariant('phase5_collapsed', _collapsedNodes),
    ]);
  });
}
