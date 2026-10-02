// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B6: wide list, 1,000 rows, one row's colour changes. See
// docs/fine_grained_reactivity/BENCHMARKS.md. Comparison against
// InheritedWidget dependency notification.
//
// All five variants run in one process, interleaved and rotated by
// `runInterleaved`.
//
//  - best practice: a ValueNotifier per row with a ValueListenableBuilder at
//    the leaf, so only the changed row rebuilds.
//  - InheritedWidget: all rows depend on one InheritedWidget at the root;
//    changing one row's colour notifies (and rebuilds) all 1,000 dependents.
//  - Phase 2: each row reads its own Signal<Color> in its own build.
//  - Phase 3 leaf: the row is a ReactiveColoredBox bound to the signal.
//  - Phase 5 collapsed: the row is one RBox in a node tree.
//
// Render objects per row -- 2 in every variant, including the InheritedWidget
// baseline:
//   classic  Positioned > RepaintBoundary > (Reactive)ColoredBox
//   collapsed  RPositioned > RRepaintBoundary > RBox

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/reactive_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kRowCount = 1000;
const int kWarmup = 5;
const int kTimed = 30;

int _rowBuilds = 0;
int _probeBuilds = 0;
int _effectRuns = 0;
int _componentRuns = 0;

Color _colorFor(int i) => Color.fromARGB(255, (i * 37) & 0xff, (i * 91) & 0xff, 0);

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
      ColoredBox(color: _ColorsInherited.of(context).colors[index]);
}

class _SignalRow extends StatelessWidget {
  const _SignalRow(this.color);

  final Signal<Color> color;

  @override
  Widget build(BuildContext context) {
    _rowBuilds++;
    return ColoredBox(color: color.value);
  }
}

/// Counts its own builds, above the rows.
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
    kRowCount,
    (int i) => ValueNotifier<Color>(Colors.blue),
  );
  var buildCount = 0;
  await benchPumpWidget(
    tester,
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
  expect(
    find.byType(Positioned),
    findsAtLeastNWidgets(kRowCount),
  ); // integration surface may hold stray nodes

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    notifiers[i % kRowCount].value = _colorFor(i);
    i++;
    await benchPump(tester);
  }
  buildCount = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      notifiers[i % kRowCount].value = _colorFor(i);
      i++;
      await benchPump(tester);
    },
  );
  // Every timed pump rebuilt its leaf, rather than hitting ValueNotifier's
  // identical-value early return.
  expect(buildCount, kTimed);
  await benchPumpWidget(tester, const SizedBox.shrink());
  return median(values);
}

Future<double> _inheritedWidget(WidgetTester tester) async {
  final colors = List<Color>.filled(kRowCount, Colors.blue);
  late StateSetter setState;
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setter) {
          setState = setter;
          return _ColorsInherited(
            colors,
            child: mountAllInRows([
              for (var i = 0; i < kRowCount; i++) RepaintBoundary(child: _InheritedRow(i)),
            ]),
          );
        },
      ),
    ),
  );
  expect(
    find.byType(Positioned),
    findsAtLeastNWidgets(kRowCount),
  ); // integration surface may hold stray nodes

  var i = 0;
  final List<double> values = await timeIterations(
    warmup: kWarmup,
    iterations: kTimed,
    body: () async {
      colors[i % kRowCount] = _colorFor(i);
      i++;
      setState(() {});
      await benchPump(tester);
    },
  );
  // Liveness: the list really carries the last colour written.
  expect(colors[(i - 1) % kRowCount], _colorFor(i - 1));
  await benchPumpWidget(tester, const SizedBox.shrink());
  return median(values);
}

Future<double> _signalInBuild(WidgetTester tester) async {
  final signals = List<Signal<Color>>.generate(kRowCount, (int i) => Signal<Color>(Colors.blue));
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: mountAllInRows([for (final s in signals) RepaintBoundary(child: _SignalRow(s))]),
    ),
  );
  expect(
    find.byType(Positioned),
    findsAtLeastNWidgets(kRowCount),
  ); // integration surface may hold stray nodes

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    signals[i % kRowCount].value = _colorFor(i);
    i++;
    await benchPump(tester);
  }
  _rowBuilds = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      signals[i % kRowCount].value = _colorFor(i);
      i++;
      await benchPump(tester);
    },
  );
  // One row rebuilt per write, against 1,000 for the InheritedWidget case.
  expect(_rowBuilds, kTimed);
  await benchPumpWidget(tester, const SizedBox.shrink());
  return median(values);
}

Future<double> _leafBinding(WidgetTester tester) async {
  final signals = List<Signal<Color>>.generate(kRowCount, (int i) => Signal<Color>(Colors.blue));
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: _BuildProbe(
        child: mountAllInRows([
          for (final s in signals) RepaintBoundary(child: ReactiveColoredBox(color: s)),
        ]),
      ),
    ),
  );
  expect(
    find.byType(Positioned),
    findsAtLeastNWidgets(kRowCount),
  ); // integration surface may hold stray nodes

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    signals[i % kRowCount].value = _colorFor(i);
    i++;
    await benchPump(tester);
  }
  _probeBuilds = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      signals[i % kRowCount].value = _colorFor(i);
      i++;
      await benchPump(tester);
    },
  );
  expect(
    tester
        .renderObjectList<RenderReactiveColoredBox>(find.byType(ReactiveColoredBox))
        .elementAt((i - 1) % kRowCount)
        .color,
    _colorFor(i - 1),
  );
  expect(_probeBuilds, 0);
  await benchPumpWidget(tester, const SizedBox.shrink());
  return median(values);
}

Future<double> _collapsedNodes(WidgetTester tester) async {
  final signals = List<Signal<Color>>.generate(kRowCount, (int i) => Signal<Color>(Colors.blue));
  final boxes = <RBox>[];
  _componentRuns = 0;
  final root = RComponent(() {
    _componentRuns += 1;
    return RStack(
      children: <RNode>[
        for (var i = 0; i < kRowCount; i++)
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
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: SizedBox(
        width: 800,
        height: kRowCount.toDouble(),
        child: NodeHost(node: root),
      ),
    ),
  );
  expect(boxes, hasLength(kRowCount));

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    signals[i % kRowCount].value = _colorFor(i);
    i++;
    await benchPump(tester);
  }
  _effectRuns = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      signals[i % kRowCount].value = _colorFor(i);
      i++;
      await benchPump(tester);
    },
  );
  expect(boxes[(i - 1) % kRowCount].renderObject.color, _colorFor(i - 1));
  expect(_effectRuns, kTimed);
  expect(_componentRuns, 1);

  await benchPumpWidget(tester, const SizedBox.shrink());
  root.dispose();
  return median(values);
}

void main() {
  testWidgets('B6 update one of 1000 rows', (WidgetTester tester) async {
    await runInterleaved(tester, 'b6', <BenchVariant>[
      const BenchVariant('vlb_best_practice', _valueListenable),
      const BenchVariant('inheritedwidget_naive', _inheritedWidget),
      const BenchVariant('phase2_signal_build', _signalInBuild),
      const BenchVariant('phase3_leaf', _leafBinding),
      const BenchVariant('phase5_collapsed', _collapsedNodes),
    ]);
  });
}
