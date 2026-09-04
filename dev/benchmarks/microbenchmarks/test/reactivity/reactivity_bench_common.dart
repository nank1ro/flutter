// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Shared timing helper for the B1-B9 fine-grained-reactivity baselines in
// this directory (see docs/fine_grained_reactivity/BENCHMARKS.md). These
// benchmarks run under `flutter test`, so there is no on-screen GPU raster:
// the numbers they produce cover build/layout/paint-record cost only.

import 'package:flutter/widgets.dart';
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

/// Prints the median and min of [values] using the standard
/// [BenchmarkResultPrinter], so results are captured the same way as the
/// rest of the microbenchmarks suite.
void printMedian(String name, List<double> values) {
  final printer = BenchmarkResultPrinter();
  final String key = name.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_').toLowerCase();
  printer.addResult(description: name, value: median(values), unit: 'us_per_op', name: key);
  printer.addResult(
    description: '$name (min)',
    value: minOf(values),
    unit: 'us_per_op',
    name: '${key}_min',
  );
  printer.printToStdout();
}

/// Lays out and mounts every widget in [children], stacked into rows of
/// height [itemHeight]. Unlike `ListView(children: ...)`, whose `Sliver`
/// machinery only builds/mounts elements that intersect the viewport plus
/// cacheExtent, a `Stack` of `Positioned` children lays out (and mounts) the
/// whole list -- needed for scenarios that must exercise every node, not a
/// sample of ~850.
Widget mountAllInRows(List<Widget> children, {double itemHeight = 1, double itemWidth = 800}) {
  return SizedBox(
    width: itemWidth,
    height: itemHeight * children.length,
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
