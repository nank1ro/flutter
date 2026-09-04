// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B7: rebuild of an ordinary Material screen -- a 10x10 grid of tristate
// checkboxes, mirroring dev/benchmarks/macrobenchmarks's
// bench_build_material_checkbox. See
// docs/fine_grained_reactivity/BENCHMARKS.md. This is the guard that
// matters most politically inside the fork: per-element tracking must not
// slow down ordinary Material builds that read no signal at all.
//
// No signals variant is meaningful here: this scenario reads no signal by
// design. It is re-run unmodified against the fork as a pure regression
// check, which is what makes it the test of assumption A1.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

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

void main() {
  testWidgets('B7 rebuild 10x10 Material checkbox grid', (WidgetTester tester) async {
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setState = setter;
            return _buildGrid();
          },
        ),
      ),
    );

    final List<double> values = await timeIterations(
      warmup: 20,
      iterations: 300,
      body: () async {
        setState(() {});
        await tester.pump();
      },
    );
    printMedian('b7_material_checkbox_grid_rebuild', values);
  });
}
