// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B4: 120 Hz counter, one text leaf updated every frame in a deep tree
// (depth 50). See docs/fine_grained_reactivity/BENCHMARKS.md. Whether tree
// depth still costs anything once reactivity is leaf-level.
//
// Baseline: 50 nested plain widgets that never rebuild, with a
// ValueListenableBuilder<int> at the leaf driving a Text.
//
// The fork variant replaces the leaf builder with a widget that reads a
// Signal<int> in its own build.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kDepth = 50;

Widget _nest(int depth, Widget leaf) {
  var widget = leaf;
  for (var i = 0; i < depth; i++) {
    widget = Padding(padding: EdgeInsets.zero, child: widget);
  }
  return widget;
}

int _counterBuilds = 0;

class _SignalCounter extends StatelessWidget {
  const _SignalCounter(this.counter);

  final Signal<int> counter;

  @override
  Widget build(BuildContext context) {
    _counterBuilds++;
    return Text('${counter.value}');
  }
}

void main() {
  testWidgets('B4 ValueListenableBuilder leaf update at depth 50', (WidgetTester tester) async {
    final counter = ValueNotifier<int>(0);
    var buildCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: _nest(
          kDepth,
          ValueListenableBuilder<int>(
            valueListenable: counter,
            builder: (BuildContext context, int value, Widget? child) {
              buildCount++;
              return Text('$value');
            },
          ),
        ),
      ),
    );

    const warmupIterations = 20;
    const timedIterations = 300;
    for (var w = 0; w < warmupIterations; w++) {
      counter.value++;
      await tester.pump();
    }
    buildCount = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        counter.value++;
        await tester.pump();
      },
    );
    // Sanity: every timed pump must have rebuilt the leaf.
    expect(buildCount, timedIterations);
    printMedian('b4_value_listenable_leaf_update_depth_50', values);
  });

  testWidgets('B4 fork Signal leaf update at depth 50', (WidgetTester tester) async {
    final counter = Signal<int>(0);
    await tester.pumpWidget(MaterialApp(home: _nest(kDepth, _SignalCounter(counter))));

    const warmupIterations = 20;
    const timedIterations = 300;
    for (var w = 0; w < warmupIterations; w++) {
      counter.value++;
      await tester.pump();
    }
    _counterBuilds = 0;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        counter.value++;
        await tester.pump();
      },
    );
    // Sanity: every timed pump must have rebuilt the leaf.
    expect(_counterBuilds, timedIterations);
    printMedian('b4_fork_signal_leaf_update_depth_50', values);
  });
}
