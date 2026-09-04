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
// TODO(fork): add a Signal-per-sprite variant once packages/flutter exposes
// a Signal primitive; it should land close to the ValueListenableBuilder
// numbers below without the per-leaf Element/BuildContext overhead.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kSpriteCount = 10000;

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

  testWidgets('B1 setState on root rebuilds all 10000 (naive baseline)', (WidgetTester tester) async {
    final colors = List<Color>.filled(kSpriteCount, Colors.blue);
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setState = setter;
            return mountAllInRows([for (final c in colors) Container(width: 1, height: 1, color: c)]);
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
}
