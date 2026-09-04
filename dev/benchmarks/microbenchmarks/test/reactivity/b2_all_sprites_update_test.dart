// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B2: 10,000 sprites, all mutated every frame. See
// docs/fine_grained_reactivity/BENCHMARKS.md. Throughput of the
// propagate/flush path when the dirty set is the whole graph.
//
// Baseline is the same per-sprite ValueListenableBuilder structure as B1,
// but every notifier is written each iteration, so every leaf rebuilds.
//
// TODO(fork): add a Signal-per-sprite variant once packages/flutter exposes
// a Signal primitive and a batched-write API.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kSpriteCount = 10000;

void main() {
  testWidgets('B2 ValueListenableBuilder update all 10000 every frame', (
    WidgetTester tester,
  ) async {
    final notifiers = List<ValueNotifier<Color>>.generate(
      kSpriteCount,
      (int i) => ValueNotifier<Color>(Colors.blue),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: mountAllInRows([
          for (final n in notifiers)
            ValueListenableBuilder<Color>(
              valueListenable: n,
              builder: (BuildContext context, Color color, Widget? child) =>
                  Container(width: 1, height: 1, color: color),
            ),
        ]),
      ),
    );
    // Every sprite must be mounted, not just what a viewport would show.
    expect(find.byType(Positioned), findsNWidgets(kSpriteCount));

    var frame = 0;
    final List<double> values = await timeIterations(
      warmup: 3,
      iterations: 30,
      body: () async {
        final Color color = frame.isEven ? Colors.red : Colors.blue;
        for (final n in notifiers) {
          n.value = color;
        }
        frame++;
        await tester.pump();
      },
    );
    printMedian('b2_value_listenable_update_all_10000', values);
  });
}
