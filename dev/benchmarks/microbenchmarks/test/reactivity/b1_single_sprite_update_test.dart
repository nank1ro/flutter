// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B1: 10,000 sprites, one signal per sprite, one sprite mutated per frame.
// See docs/fine_grained_reactivity/BENCHMARKS.md.
//
// Two baselines are measured:
//  - best current practice: a ValueNotifier per sprite with a
//    ValueListenableBuilder at the leaf, wrapped in a RepaintBoundary (the
//    strongest legacy setup for a leaf that repaints alone), so only the
//    mutated leaf rebuilds.
//  - naive: setState on the root, rebuilding all 10,000 children. This is
//    the number the doc calls out explicitly as what a single render-object
//    setter (the fork's target) must beat.
//
// The fork variant gives each sprite its own Signal<Color>, read directly in
// the sprite's own build. There is no builder widget and no BuildContext
// dependency: the sprite's element subscribes to the signal because it read
// it, and writing the signal marks that one element dirty.
//
// The fork *leaf* variant (Phase 3) removes the rebuild as well: the sprite is
// a ReactiveColoredBox whose colour is bound straight to the signal, so a
// write runs one effect, calls one render-object setter, and rebuilds nothing
// at all.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kSpriteCount = 10000;

int _spriteBuilds = 0;

/// A sprite that reads its own colour signal. No wrapper, no builder.
class _SignalSprite extends StatelessWidget {
  const _SignalSprite(this.color);

  final Signal<Color> color;

  @override
  Widget build(BuildContext context) {
    _spriteBuilds++;
    return Container(width: 1, height: 1, color: color.value);
  }
}

void main() {
  testWidgets('B1 ValueListenableBuilder update one of 10000 (best practice)', (
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
            RepaintBoundary(
              child: ValueListenableBuilder<Color>(
                valueListenable: n,
                builder: (BuildContext context, Color color, Widget? child) {
                  buildCount++;
                  return Container(width: 1, height: 1, color: color);
                },
              ),
            ),
        ]),
      ),
    );
    // Every sprite must be mounted, not just what a viewport would show.
    expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

    // Distinct colour per write (never repeats the notifier's current
    // value), so ValueNotifier never early-returns and every timed pump
    // does real work -- guards against a silent no-op frame.
    Color colorForIteration(int i) => Color.fromARGB(255, (i * 37) & 0xff, (i * 91) & 0xff, 0);

    var i = 0;
    const warmupIterations = 20;
    const timedIterations = 200;
    for (var w = 0; w < warmupIterations; w++) {
      notifiers[i % kSpriteCount].value = colorForIteration(i);
      i++;
      await tester.pump();
    }
    buildCount = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        notifiers[i % kSpriteCount].value = colorForIteration(i);
        i++;
        await tester.pump();
      },
    );
    // Sanity: every timed pump must have rebuilt its leaf, not hit
    // ValueNotifier's identical-value early return.
    expect(buildCount, timedIterations);
    printMedian('b1_value_listenable_update_one_of_10000', values);
  });

  testWidgets('B1 setState on root rebuilds all 10000 (naive baseline)', (
    WidgetTester tester,
  ) async {
    // No RepaintBoundary here, unlike the two variants above: this is the
    // naive baseline the doc calls out explicitly, and a real root setState
    // doesn't isolate per-sprite repaints either.
    final colors = List<Color>.filled(kSpriteCount, Colors.blue);
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setState = setter;
            return mountAllInRows([
              for (final c in colors) Container(width: 1, height: 1, color: c),
            ]);
          },
        ),
      ),
    );
    expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

    var i = 0;
    final List<double> values = await timeIterations(
      warmup: 5,
      iterations: 50,
      body: () async {
        colors[i % kSpriteCount] = i.isEven ? Colors.red : Colors.blue;
        i++;
        setState(() {});
        await tester.pump();
      },
    );
    printMedian('b1_setstate_root_rebuild_all_10000', values);
  });

  testWidgets('B1 fork Signal update one of 10000', (WidgetTester tester) async {
    final signals = List<Signal<Color>>.generate(
      kSpriteCount,
      (int i) => Signal<Color>(Colors.blue),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: mountAllInRows([for (final s in signals) RepaintBoundary(child: _SignalSprite(s))]),
      ),
    );
    expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

    Color colorForIteration(int i) => Color.fromARGB(255, (i * 37) & 0xff, (i * 91) & 0xff, 0);

    var i = 0;
    const warmupIterations = 20;
    const timedIterations = 200;
    for (var w = 0; w < warmupIterations; w++) {
      signals[i % kSpriteCount].value = colorForIteration(i);
      i++;
      await tester.pump();
    }
    _spriteBuilds = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        signals[i % kSpriteCount].value = colorForIteration(i);
        i++;
        await tester.pump();
      },
    );
    // Exactly one sprite rebuilt per write: no ancestor, no sibling.
    expect(_spriteBuilds, timedIterations);
    printMedian('b1_fork_signal_update_one_of_10000', values);
  });

  testWidgets('B1 fork leaf ReactiveColoredBox update one of 10000', (WidgetTester tester) async {
    final signals = List<Signal<Color>>.generate(
      kSpriteCount,
      (int i) => Signal<Color>(Colors.blue),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: _BuildProbe(
          child: mountAllInRows([
            for (final s in signals)
              RepaintBoundary(
                child: ReactiveColoredBox(
                  color: s,
                  child: const SizedBox(width: 1, height: 1),
                ),
              ),
          ]),
        ),
      ),
    );
    expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

    Color colorForIteration(int i) => Color.fromARGB(255, (i * 37) & 0xff, (i * 91) & 0xff, 0);

    var i = 0;
    const warmupIterations = 20;
    const timedIterations = 200;
    for (var w = 0; w < warmupIterations; w++) {
      signals[i % kSpriteCount].value = colorForIteration(i);
      i++;
      await tester.pump();
    }
    _probeBuilds = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        signals[i % kSpriteCount].value = colorForIteration(i);
        i++;
        await tester.pump();
      },
    );
    // Liveness: the render object really took the last colour written.
    final int lastIndex = (i - 1) % kSpriteCount;
    expect(
      tester
          .renderObjectList<RenderReactiveColoredBox>(find.byType(ReactiveColoredBox))
          .elementAt(lastIndex)
          .color,
      colorForIteration(i - 1),
    );
    // Nothing rebuilt: the update never entered the build pipeline.
    expect(_probeBuilds, 0);
    printMedian('b1_fork_leaf_reactive_colored_box_update_one_of_10000', values);
  });
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

int _probeBuilds = 0;
