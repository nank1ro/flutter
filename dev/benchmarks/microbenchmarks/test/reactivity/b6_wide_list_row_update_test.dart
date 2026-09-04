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
// The fork variant gives each row its own Signal<Color>, read in the row's
// own build, so one row's change reaches one element instead of all 1,000
// dependents.

import 'package:flutter/foundation.dart';
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
  Widget build(BuildContext context) =>
      Container(height: 1, color: _ColorsInherited.of(context).colors[index]);
}

int _rowBuilds = 0;

class _SignalRow extends StatelessWidget {
  const _SignalRow(this.color);

  final Signal<Color> color;

  @override
  Widget build(BuildContext context) {
    _rowBuilds++;
    return Container(height: 1, color: color.value);
  }
}

void main() {
  testWidgets('B6 ValueListenableBuilder update one of 1000 rows (best practice)', (
    WidgetTester tester,
  ) async {
    final notifiers = List<ValueNotifier<Color>>.generate(
      kRowCount,
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

  testWidgets('B6 InheritedWidget update one row notifies all 1000 dependents', (
    WidgetTester tester,
  ) async {
    // No RepaintBoundary here, unlike the two variants above: this is the
    // naive InheritedWidget baseline, and every dependent rebuilds anyway,
    // so isolating repaint wouldn't isolate build cost.
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

  testWidgets('B6 fork Signal update one of 1000 rows', (WidgetTester tester) async {
    final signals = List<Signal<Color>>.generate(kRowCount, (int i) => Signal<Color>(Colors.blue));
    await tester.pumpWidget(
      MaterialApp(
        home: mountAllInRows([for (final s in signals) RepaintBoundary(child: _SignalRow(s))]),
      ),
    );
    expect(find.byType(Positioned), findsNWidgets(kRowCount));

    Color colorForIteration(int i) => Color.fromARGB(255, (i * 37) & 0xff, (i * 91) & 0xff, 0);

    var i = 0;
    const warmupIterations = 20;
    const timedIterations = 200;
    for (var w = 0; w < warmupIterations; w++) {
      signals[i % kRowCount].value = colorForIteration(i);
      i++;
      await tester.pump();
    }
    _rowBuilds = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        signals[i % kRowCount].value = colorForIteration(i);
        i++;
        await tester.pump();
      },
    );
    // One row rebuilt per write, against 1,000 for the InheritedWidget case.
    expect(_rowBuilds, timedIterations);
    printMedian('b6_fork_signal_update_one_of_1000_rows', values);
  });
}
