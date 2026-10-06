// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B11: mount, rebuild and unmount 2,000 cards of static stock widgets. See
// docs/fine_grained_reactivity/BENCHMARKS.md.
//
// An absolute-cost guard rather than an A/B: run it on two commits to compare
// builds. On a commit before the ReadonlySignal props, drop the `.fixed(...)`
// wrappers. Cross-build numbers are only as good as the machine's quiet; B10
// is the in-process comparison.
//
//  - const: `Padding > Opacity > ColoredBox > SizedBox`, all const literals.
//  - dynamic: `Padding > Container > Opacity > Transform.rotate > SizedBox`,
//    values varying per card and per tick.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kCards = 2000;
const int kWarmup = 3;
const int kTimed = 10;

Widget _constCard(int i) => const Padding(
  padding: .fixed(EdgeInsets.all(2)),
  child: Opacity(
    opacity: .fixed(0.9),
    child: ColoredBox(
      color: .fixed(Colors.blue),
      child: SizedBox(width: .fixed(100), height: .fixed(18)),
    ),
  ),
);

Widget _dynamicCard(int i, int tick) => Padding(
  padding: .fixed(EdgeInsets.all(1.0 + (i + tick) % 3)),
  child: Container(
    width: 100.0 + (i + tick) % 7,
    height: 18,
    color: Color(0xFF000000 | (i * 31 + tick)),
    padding: EdgeInsets.only(left: ((i + tick) % 4).toDouble()),
    child: Opacity(
      opacity: .fixed(0.5 + ((i + tick) % 5) / 10),
      child: Transform.rotate(
        angle: .fixed(((i + tick) % 3) / 100),
        child: SizedBox(width: .fixed(10.0 + (i + tick) % 5), height: const .fixed(8)),
      ),
    ),
  ),
);

/// Times mounting, rebuilding with changed values, and unmounting [kCards]
/// cards built by [card]. Returns the median of [phase] in microseconds.
Future<double> _measure(
  WidgetTester tester,
  Widget Function(int i, int tick) card,
  String phase,
) async {
  late StateSetter setState;
  var mounted = false;
  var tick = 0;
  await tester.pumpWidget(
    StatefulBuilder(
      builder: (BuildContext context, StateSetter setter) {
        setState = setter;
        return Directionality(
          textDirection: TextDirection.ltr,
          child: mounted
              ? mountAllInRows([for (var i = 0; i < kCards; i++) card(i, tick)], itemHeight: 22)
              : const SizedBox.shrink(),
        );
      },
    ),
  );

  final times = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < kWarmup + kTimed; i++) {
    final bool keep = i >= kWarmup;
    watch
      ..reset()
      ..start();
    mounted = true;
    setState(() {});
    await tester.pump();
    watch.stop();
    if (keep && phase == 'mount') {
      times.add(watch.elapsedMicroseconds.toDouble());
    }

    watch
      ..reset()
      ..start();
    tick += 1;
    setState(() {});
    await tester.pump();
    watch.stop();
    if (keep && phase == 'rebuild') {
      times.add(watch.elapsedMicroseconds.toDouble());
    }

    watch
      ..reset()
      ..start();
    mounted = false;
    setState(() {});
    await tester.pump();
    watch.stop();
    if (keep && phase == 'unmount') {
      times.add(watch.elapsedMicroseconds.toDouble());
    }
  }
  return median(times);
}

void main() {
  testWidgets('B11 static stock widgets: mount, rebuild, unmount', (WidgetTester tester) async {
    await runInterleaved(tester, 'b11', <BenchVariant>[
      for (final String phase in <String>['mount', 'rebuild', 'unmount']) ...<BenchVariant>[
        BenchVariant(
          'const_$phase',
          (WidgetTester t) => _measure(t, (int i, int _) => _constCard(i), phase),
        ),
        BenchVariant('dynamic_$phase', (WidgetTester t) => _measure(t, _dynamicCard, phase)),
      ],
    ]);
  });
}
