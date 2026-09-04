// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B6: wide list, 1,000 rows, one row's colour changes. See
// docs/fine_grained_reactivity/BENCHMARKS.md. Comparison against
// InheritedWidget dependency notification.
//
// Two baselines are measured:
//  - best current practice: a ValueNotifier per row with a
//    ValueListenableBuilder at the leaf, wrapped in a RepaintBoundary (the
//    strongest legacy setup for a leaf that repaints alone), so only the
//    changed row rebuilds.
//  - InheritedWidget: all rows depend on one InheritedWidget at the root;
//    changing one row's colour still notifies (and rebuilds) all 1,000
//    dependents, which is what fine-grained tracking is meant to avoid.
//
// TODO(fork): add a Signal-per-row variant once packages/flutter exposes a
// Signal primitive.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kRowCount = 1000;

class _ColorsInherited extends InheritedWidget {
  const _ColorsInherited(this.colors, {required super.child});
  final List<Color> colors;

  static _ColorsInherited of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ColorsInherited>()!;

  @override
  bool updateShouldNotify(_ColorsInherited oldWidget) => true; // any row change notifies every dependent.
}

class _InheritedRow extends StatelessWidget {
  const _InheritedRow(this.index);
  final int index;

  @override
  Widget build(BuildContext context) => Container(height: 1, color: _ColorsInherited.of(context).colors[index]);
}

void main() {
  testWidgets('B6 ValueListenableBuilder update one of 1000 rows (best practice)', (
    WidgetTester tester,
  ) async {
    final notifiers = List<ValueNotifier<Color>>.generate(kRowCount, (int i) => ValueNotifier<Color>(Colors.blue));
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
                  return Container(height: 1, color: color);
                },
              ),
            ),
        ]),
      ),
    );
    // Every row must be mounted, not just what a viewport would show.
    expect(find.byType(Positioned), findsNWidgets(kRowCount));

    // Distinct colour per write (never repeats the notifier's current
    // value), so ValueNotifier never early-returns and every timed pump
    // does real work -- guards against a silent no-op frame.
    Color colorForIteration(int i) => Color.fromARGB(255, (i * 37) & 0xff, (i * 91) & 0xff, 0);

    var i = 0;
    const warmupIterations = 20;
    const timedIterations = 200;
    for (var w = 0; w < warmupIterations; w++) {
      notifiers[i % kRowCount].value = colorForIteration(i);
      i++;
      await tester.pump();
    }
    buildCount = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        notifiers[i % kRowCount].value = colorForIteration(i);
        i++;
        await tester.pump();
      },
    );
    // Sanity: every timed pump must have rebuilt its leaf, not hit
    // ValueNotifier's identical-value early return.
    expect(buildCount, timedIterations);
    printMedian('b6_value_listenable_update_one_of_1000_rows', values);
  });

  testWidgets('B6 InheritedWidget update one row notifies all 1000 dependents', (WidgetTester tester) async {
    final colors = List<Color>.filled(kRowCount, Colors.blue);
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setState = setter;
            return _ColorsInherited(
              colors,
              child: mountAllInRows([for (var i = 0; i < kRowCount; i++) _InheritedRow(i)]),
            );
          },
        ),
      ),
    );

    expect(find.byType(Positioned), findsNWidgets(kRowCount));

    var i = 0;
    final List<double> values = await timeIterations(
      warmup: 5,
      iterations: 50,
      body: () async {
        colors[i % kRowCount] = i.isEven ? Colors.red : Colors.blue;
        i++;
        setState(() {});
        await tester.pump();
      },
    );
    printMedian('b6_inheritedwidget_update_one_notifies_all_1000', values);
  });
}
