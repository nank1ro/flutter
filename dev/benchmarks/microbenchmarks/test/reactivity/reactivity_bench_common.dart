// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Shared timing harness for the B1-B9 fine-grained-reactivity benchmarks in
// this directory (see docs/fine_grained_reactivity/BENCHMARKS.md). These
// benchmarks run under `flutter test`, so there is no on-screen GPU raster:
// the numbers they produce cover build/layout/paint-record cost only.
//
// Variants of one scenario must never be timed one after another in file
// order. The Dart VM's JIT warms up across a file, so a variant that runs
// third can read up to ~2x faster than an identical variant that ran first,
// which silently turns "measured position in file" into "measured mechanism".
// [runInterleaved] is the fix: every variant runs once per round, the starting
// variant rotates each round, and the first rounds are discarded.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microbenchmarks/common.dart';

/// Runs [body] [warmup] times (untimed), then [iterations] more times,
/// timing each call with a fresh [Stopwatch]. Returns per-iteration wall
/// clock time in microseconds.
Future<List<double>> timeIterations({
  required int warmup,
  required int iterations,
  required Future<void> Function() body,
}) async {
  for (var i = 0; i < warmup; i++) {
    await body();
  }
  final times = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < iterations; i++) {
    watch
      ..reset()
      ..start();
    await body();
    watch.stop();
    times.add(watch.elapsedMicroseconds.toDouble());
  }
  return times;
}

double median(List<double> values) {
  final sorted = List<double>.of(values)..sort();
  final int mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) {
    return sorted[mid];
  }
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

double minOf(List<double> values) => values.reduce((double a, double b) => a < b ? a : b);

double maxOf(List<double> values) => values.reduce((double a, double b) => a > b ? a : b);

/// One named variant of a scenario.
///
/// [run] does the whole of one measurement: it mounts its own tree, runs its
/// own warmup and timed iterations, drops the tree again, and returns the
/// median of the timed iterations in microseconds. Everything a variant needs
/// is created inside [run], so running it a second time measures the same work
/// from the same starting state.
class BenchVariant {
  const BenchVariant(this.name, this.run);

  /// Short, stable identifier, used as the result key.
  final String name;

  /// Sets up, measures, tears down, and returns the median in microseconds.
  final Future<double> Function(WidgetTester tester) run;
}

/// Runs every variant of [scenario] [rounds] times, interleaved.
///
/// Round `r` runs all the variants once, starting at variant `r % n` and
/// wrapping, so no variant ever sits at a fixed position in the warm-up curve.
/// The first [discardRounds] rounds are dropped; what is reported is the
/// median across the remaining rounds, the min across them, and the raw
/// per-round values, so drift that survived the rotation is visible rather
/// than averaged away.
///
/// When [rounds] is omitted it is [discardRounds] plus enough whole rotations
/// to retain at least four rounds.
Future<void> runInterleaved(
  WidgetTester tester,
  String scenario,
  List<BenchVariant> variants, {
  int? rounds,
  int discardRounds = 2,
}) async {
  assert(variants.isNotEmpty);
  // The rotation only cancels ordering and warm-up bias if every variant starts
  // the same number of times among the retained rounds, so the retained count
  // must be a whole number of rotations.
  final int rotations = (4 + variants.length - 1) ~/ variants.length;
  final int totalRounds = rounds ?? discardRounds + rotations * variants.length;
  assert(totalRounds > discardRounds);
  assert((totalRounds - discardRounds) % variants.length == 0);
  final perRound = <String, List<double>>{
    for (final BenchVariant variant in variants) variant.name: <double>[],
  };
  for (var r = 0; r < totalRounds; r++) {
    for (var k = 0; k < variants.length; k++) {
      final BenchVariant variant = variants[(r + k) % variants.length];
      perRound[variant.name]!.add(await variant.run(tester));
    }
  }

  final printer = BenchmarkResultPrinter();
  final table = StringBuffer(
    '\n$scenario: $totalRounds rounds, first $discardRounds discarded, '
    'round r starts at variant r % ${variants.length}\n',
  );
  for (final variant in variants) {
    final List<double> all = perRound[variant.name]!;
    final List<double> kept = all.sublist(discardRounds);
    final double med = median(kept);
    final double lo = minOf(kept);
    final String key = '${scenario}_${variant.name}'
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
        .toLowerCase();
    printer.addResult(
      description: '$scenario / ${variant.name}',
      value: med,
      unit: 'us_per_op',
      name: key,
    );
    printer.addResult(
      description: '$scenario / ${variant.name} (min)',
      value: lo,
      unit: 'us_per_op',
      name: '${key}_min',
    );
    table.writeln(
      '  ${variant.name.padRight(24)} median=${med.toStringAsFixed(0).padLeft(9)} '
      'min=${lo.toStringAsFixed(0).padLeft(9)} '
      'spread=${((maxOf(kept) - lo) / lo * 100).toStringAsFixed(0).padLeft(3)}% '
      'rounds=[${all.map((double d) => d.toStringAsFixed(0)).join(', ')}]',
    );
  }
  printer.printToStdout();
  print(table);
}

/// Lays out and mounts every widget in [children], stacked into rows of
/// height [itemHeight]. Unlike `ListView(children: ...)`, whose `Sliver`
/// machinery only builds/mounts elements that intersect the viewport plus
/// cacheExtent, a `Stack` of `Positioned` children lays out (and mounts) the
/// whole list -- needed for scenarios that must exercise every node, not a
/// sample of ~850.
///
/// Every `Positioned` here is tight in both axes, so a child needs no
/// `SizedBox` of its own to take the row's size: that is what lets the
/// classic variants match the collapsed model's render-object count exactly.
Widget mountAllInRows(List<Widget> children, {double itemHeight = 1, double itemWidth = 800}) {
  return SizedBox(
    width: .fixed(itemWidth),
    height: .fixed(itemHeight * children.length),
    child: Stack(
      children: [
        for (var i = 0; i < children.length; i++)
          Positioned(
            top: itemHeight * i,
            left: 0,
            width: itemWidth,
            height: itemHeight,
            child: children[i],
          ),
      ],
    ),
  );
}
