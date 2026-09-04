// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B5: deep static tree (depth 100), single leaf signal changes. See
// docs/fine_grained_reactivity/BENCHMARKS.md. Regression guard: no
// ancestor may rebuild.
//
// Baseline: 100 nested StatelessWidgets that each count their own builds,
// with a ValueListenableBuilder<int> at the leaf. The main test asserts
// ancestor build counts stay flat while only the leaf's ValueNotifier
// changes (no root rebuild ever happens), then times the leaf-only update
// path. A second, untimed test proves the build-count harness itself is
// capable of detecting an ancestor rebuild: it rebuilds the root via
// setState (unrelated to the leaf) and asserts the same counters *do*
// increase, so the "must not rebuild" assertion above is not vacuous.
//
// The fork variant swaps the leaf for one that reads a Signal<int>; the
// ancestor-build-count assertion has to hold just the same.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kDepth = 100;

class _CountingAncestor extends StatelessWidget {
  const _CountingAncestor(this.buildCounts, this.index, {required this.child});

  final List<int> buildCounts;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    buildCounts[index]++;
    return child;
  }
}

int _leafBuilds = 0;

Widget _buildTree(List<int> buildCounts, ValueNotifier<int> counter) {
  var tree =
      ValueListenableBuilder<int>(
            valueListenable: counter,
            builder: (BuildContext context, int value, Widget? child) {
              _leafBuilds++;
              return Text('$value');
            },
          )
          as Widget;
  for (var i = 0; i < kDepth; i++) {
    tree = _CountingAncestor(buildCounts, i, child: tree);
  }
  return tree;
}

int _signalLeafBuilds = 0;

class _SignalLeaf extends StatelessWidget {
  const _SignalLeaf(this.counter);

  final Signal<int> counter;

  @override
  Widget build(BuildContext context) {
    _signalLeafBuilds++;
    return Text('${counter.value}');
  }
}

Widget _buildSignalTree(List<int> buildCounts, Signal<int> counter) {
  Widget tree = _SignalLeaf(counter);
  for (var i = 0; i < kDepth; i++) {
    tree = _CountingAncestor(buildCounts, i, child: tree);
  }
  return tree;
}

void main() {
  testWidgets('B5 deep static tree, leaf-only update, ancestors must not rebuild', (
    WidgetTester tester,
  ) async {
    final buildCounts = List<int>.filled(kDepth, 0);
    final counter = ValueNotifier<int>(0);
    await tester.pumpWidget(MaterialApp(home: _buildTree(buildCounts, counter)));

    final countsAfterMount = List<int>.of(buildCounts);
    const warmupIterations = 20;
    const timedIterations = 300;
    for (var w = 0; w < warmupIterations; w++) {
      counter.value++;
      await tester.pump();
    }
    _leafBuilds = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        counter.value++;
        await tester.pump();
      },
    );
    // Regression guard: no ancestor rebuilt after the initial mount.
    expect(
      buildCounts,
      countsAfterMount,
      reason: 'ancestors must not rebuild when only the leaf changes',
    );
    // Sanity: every timed pump must have rebuilt the leaf, so the ancestor
    // assertion above isn't vacuously true because the leaf never ran.
    expect(_leafBuilds, timedIterations);
    printMedian('b5_deep_static_tree_leaf_update_depth_100', values);
  });

  testWidgets('B5 negative check: setState at root does rebuild ancestors', (
    WidgetTester tester,
  ) async {
    final buildCounts = List<int>.filled(kDepth, 0);
    final counter = ValueNotifier<int>(0);
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setState = setter;
            return _buildTree(buildCounts, counter);
          },
        ),
      ),
    );

    final countsAfterMount = List<int>.of(buildCounts);
    for (var i = 0; i < 5; i++) {
      setState(() {});
      await tester.pump();
    }
    // Proves the build-count harness actually detects ancestor rebuilds --
    // an unrelated root setState rebuilds every _CountingAncestor -- so the
    // "must not rebuild" assertion in the main test above is meaningful.
    for (var i = 0; i < kDepth; i++) {
      expect(buildCounts[i], greaterThan(countsAfterMount[i]));
    }
  });

  testWidgets('B5 fork deep static tree, Signal leaf update, ancestors must not rebuild', (
    WidgetTester tester,
  ) async {
    final buildCounts = List<int>.filled(kDepth, 0);
    final counter = Signal<int>(0);
    await tester.pumpWidget(MaterialApp(home: _buildSignalTree(buildCounts, counter)));

    final countsAfterMount = List<int>.of(buildCounts);
    const warmupIterations = 20;
    const timedIterations = 300;
    for (var w = 0; w < warmupIterations; w++) {
      counter.value++;
      await tester.pump();
    }
    _signalLeafBuilds = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        counter.value++;
        await tester.pump();
      },
    );
    expect(
      buildCounts,
      countsAfterMount,
      reason: 'ancestors must not rebuild when only the leaf reads the signal',
    );
    // Sanity: every timed pump must have rebuilt the leaf, so the ancestor
    // assertion above isn't vacuously true because the leaf never ran.
    expect(_signalLeafBuilds, timedIterations);
    printMedian('b5_fork_signal_leaf_update_depth_100', values);
  });
}
