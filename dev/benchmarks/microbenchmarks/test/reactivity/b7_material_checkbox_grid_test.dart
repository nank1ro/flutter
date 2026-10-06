// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B7: rebuild of an ordinary Material screen -- a 10x10 grid of tristate
// checkboxes, mirroring dev/benchmarks/macrobenchmarks's
// bench_build_material_checkbox. See
// docs/fine_grained_reactivity/BENCHMARKS.md. This is the guard on assumption
// A1: per-element tracking must not slow down ordinary Material builds that
// read no signal at all.
//
// The A/B is the framework's own debug toggle, `debugTrackSignalReadsInBuild`,
// flipped per variant. Both variants are the identical tree and the identical
// workload; the only difference is whether `ComponentElement.performRebuild`
// wraps `build()` in a tracking scope. They are interleaved and rotated by
// `runInterleaved`, which matters more here than anywhere else in the suite:
// the effect being looked for is a percent or two, and the sequential harness
// this replaces could move a variant by 2x on position alone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kWarmup = 5;
const int kTimed = 40;

bool? _isChecked = true;

Row _buildRow() {
  _isChecked = switch (_isChecked) {
    null => true,
    true => false,
    false => null,
  };
  return Row(
    children: List<Widget>.generate(
      10,
      (int i) => Expanded(
        child: Checkbox(value: _isChecked, tristate: true, onChanged: (bool? newValue) {}),
      ),
    ),
  );
}

Widget _buildGrid() => Directionality(
  textDirection: TextDirection.ltr,
  child: Material(child: Column(children: List<Widget>.generate(10, (int i) => _buildRow()))),
);

Future<double> _grid(WidgetTester tester, {required bool tracking}) async {
  final bool previous = debugTrackSignalReadsInBuild;
  debugTrackSignalReadsInBuild = tracking;
  try {
    late StateSetter setState;
    var rebuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setState = setter;
            rebuilds++;
            return _buildGrid();
          },
        ),
      ),
    );

    rebuilds = 0;
    final List<double> values = await timeIterations(
      warmup: kWarmup,
      iterations: kTimed,
      body: () async {
        setState(() {});
        await tester.pump();
      },
    );
    // Liveness: every timed pump really rebuilt the grid.
    expect(rebuilds, kWarmup + kTimed);
    return median(values);
  } finally {
    debugTrackSignalReadsInBuild = previous;
  }
}

void main() {
  testWidgets('B7 rebuild 10x10 Material checkbox grid', (WidgetTester tester) async {
    await runInterleaved(tester, 'b7', <BenchVariant>[
      BenchVariant('tracking_off', (WidgetTester tester) => _grid(tester, tracking: false)),
      BenchVariant('tracking_on', (WidgetTester tester) => _grid(tester, tracking: true)),
    ]);
  });
}
