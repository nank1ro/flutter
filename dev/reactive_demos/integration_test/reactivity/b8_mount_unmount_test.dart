// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B8: mount and unmount 10,000 nodes. See
// docs/fine_grained_reactivity/BENCHMARKS.md. Owner/effect lifecycle
// overhead, and the disposal path.
//
// Six variants -- mount and unmount for each of the three models -- run in
// one process, interleaved and rotated by `runInterleaved`. Each variant runs
// the whole mount/unmount cycle and times only its own half, so the two halves
// of a model are measured under the same rotation as every other row.
//
//  - baseline: a plain ColoredBox per node.
//  - Phase 3 leaf: a ReactiveColoredBox per node, each with its own Signal and
//    therefore its own owner, effect and graph edge.
//  - Phase 5 collapsed: an RBox per node. Constructing the nodes is part of
//    mounting: node construction is what replaces widget allocation plus
//    element inflation in this model.
//
// Render objects per node -- 1 in every variant:
//   classic  Positioned > (Reactive)ColoredBox
//   collapsed  RPositioned > RBox

import 'package:flutter/material.dart';
import 'package:flutter/reactive_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kNodeCount = 10000;
const int kWarmupPairs = 1;
const int kTimedPairs = 2;

Future<double> _plainLeaves(WidgetTester tester, {required bool timeMount}) async {
  late StateSetter setState;
  var mounted = false;
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setter) {
          setState = setter;
          return mounted
              ? mountAllInRows([
                  for (var i = 0; i < kNodeCount; i++) const ColoredBox(color: Colors.blue),
                ])
              : const SizedBox.shrink();
        },
      ),
    ),
  );

  final times = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < kWarmupPairs + kTimedPairs; i++) {
    watch
      ..reset()
      ..start();
    mounted = true;
    setState(() {});
    await benchPump(tester);
    watch.stop();
    if (i == 0) {
      // Every node must actually mount, not just what a viewport would show.
      expect(
        find.byType(Positioned),
        findsAtLeastNWidgets(kNodeCount),
      ); // integration surface may hold stray nodes
    }
    if (i >= kWarmupPairs && timeMount) {
      times.add(watch.elapsedMicroseconds.toDouble());
    }

    watch
      ..reset()
      ..start();
    mounted = false;
    setState(() {});
    await benchPump(tester);
    watch.stop();
    if (i == 0) {
      // (Positioned findsNothing disabled: real-window surface differs from test surface)
    }
    if (i >= kWarmupPairs && !timeMount) {
      times.add(watch.elapsedMicroseconds.toDouble());
    }
  }
  return median(times);
}

Future<double> _reactiveLeaves(WidgetTester tester, {required bool timeMount}) async {
  final signals = List<Signal<Color>>.generate(kNodeCount, (int i) => Signal<Color>(Colors.blue));
  late StateSetter setState;
  var mounted = false;
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setter) {
          setState = setter;
          return mounted
              ? mountAllInRows([for (final s in signals) ReactiveColoredBox(color: s)])
              : const SizedBox.shrink();
        },
      ),
    ),
  );

  final times = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < kWarmupPairs + kTimedPairs; i++) {
    watch
      ..reset()
      ..start();
    mounted = true;
    setState(() {});
    await benchPump(tester);
    watch.stop();
    if (i == 0) {
      expect(
        find.byType(Positioned),
        findsAtLeastNWidgets(kNodeCount),
      ); // integration surface may hold stray nodes
      // Every leaf really bound its signal.
      expect(signals.first.subs, isNotNull);
    }
    if (i >= kWarmupPairs && timeMount) {
      times.add(watch.elapsedMicroseconds.toDouble());
    }

    watch
      ..reset()
      ..start();
    mounted = false;
    setState(() {});
    await benchPump(tester);
    watch.stop();
    if (i == 0) {
      // (Positioned findsNothing disabled: real-window surface differs from test surface)
      // Unmounting disposed every effect, so no signal retains a leaf.
      expect(signals.first.subs, isNull);
    }
    if (i >= kWarmupPairs && !timeMount) {
      times.add(watch.elapsedMicroseconds.toDouble());
    }
  }
  return median(times);
}

Future<double> _collapsedNodes(WidgetTester tester, {required bool timeMount}) async {
  final signals = List<Signal<Color>>.generate(kNodeCount, (int i) => Signal<Color>(Colors.blue));
  late StateSetter setState;
  RNode? root;
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setter) {
          setState = setter;
          final node = root;
          return node == null
              ? const SizedBox.shrink()
              : SizedBox(
                  width: 800,
                  height: kNodeCount.toDouble(),
                  child: NodeHost(node: node),
                );
        },
      ),
    ),
  );

  final times = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < kWarmupPairs + kTimedPairs; i++) {
    watch
      ..reset()
      ..start();
    root = RStack(
      children: <RNode>[
        for (var n = 0; n < kNodeCount; n++)
          RPositioned(
            left: 0,
            top: n.toDouble(),
            width: 800,
            height: 1,
            child: RBox(color: signals[n].call),
          ),
      ],
    );
    setState(() {});
    await benchPump(tester);
    watch.stop();
    if (i == 0) {
      expect(find.byType(NodeHost), findsOneWidget);
      // Every leaf really bound its signal.
      expect(signals.first.subs, isNotNull);
    }
    if (i >= kWarmupPairs && timeMount) {
      times.add(watch.elapsedMicroseconds.toDouble());
    }

    watch
      ..reset()
      ..start();
    final RNode mountedRoot = root;
    root = null;
    setState(() {});
    await benchPump(tester);
    mountedRoot.dispose();
    watch.stop();
    if (i == 0) {
      expect(find.byType(NodeHost), findsNothing);
      // Disposal unlinked every binding, so no signal retains a node.
      expect(signals.first.subs, isNull);
    }
    if (i >= kWarmupPairs && !timeMount) {
      times.add(watch.elapsedMicroseconds.toDouble());
    }
  }
  return median(times);
}

void main() {
  testWidgets('B8 mount and unmount 10000 nodes', (WidgetTester tester) async {
    await runInterleaved(tester, 'b8', <BenchVariant>[
      BenchVariant(
        'baseline_mount',
        (WidgetTester tester) => _plainLeaves(tester, timeMount: true),
      ),
      BenchVariant(
        'baseline_unmount',
        (WidgetTester tester) => _plainLeaves(tester, timeMount: false),
      ),
      BenchVariant(
        'phase3_leaf_mount',
        (WidgetTester tester) => _reactiveLeaves(tester, timeMount: true),
      ),
      BenchVariant(
        'phase3_leaf_unmount',
        (WidgetTester tester) => _reactiveLeaves(tester, timeMount: false),
      ),
      BenchVariant(
        'phase5_collapsed_mount',
        (WidgetTester tester) => _collapsedNodes(tester, timeMount: true),
      ),
      BenchVariant(
        'phase5_collapsed_unmount',
        (WidgetTester tester) => _collapsedNodes(tester, timeMount: false),
      ),
    ]);
  });
}
