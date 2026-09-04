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
// TODO(fork): add a Signal-leaf variant once packages/flutter exposes a
// Signal primitive.

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

void main() {
  testWidgets('B4 ValueListenableBuilder leaf update at depth 50', (WidgetTester tester) async {
    final counter = ValueNotifier<int>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: _nest(
          kDepth,
          ValueListenableBuilder<int>(
            valueListenable: counter,
            builder: (BuildContext context, int value, Widget? child) => Text('$value'),
          ),
        ),
      ),
    );

    final List<double> values = await timeIterations(
      warmup: 20,
      iterations: 300,
      body: () async {
        counter.value++;
        await tester.pump();
      },
    );
    printMedian('b4_value_listenable_leaf_update_depth_50', values);
  });
}
