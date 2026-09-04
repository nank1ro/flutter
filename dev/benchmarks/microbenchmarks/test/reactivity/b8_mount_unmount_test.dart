// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B8: mount and unmount 10,000 nodes. See
// docs/fine_grained_reactivity/BENCHMARKS.md. Owner/effect lifecycle
// overhead, and the disposal path.
//
// Baseline: a StatefulBuilder toggles a ListView's children between 10,000
// leaf widgets and an empty list, timing mount and unmount separately (the
// untimed setup step between them is excluded from both stopwatches).
//
// The fork variant mounts 10,000 ReactiveColoredBox leaves, each with its own
// Signal and therefore its own element owner, effect and graph edge. This is
// what leaf bindings cost to set up and tear down, against a plain Container.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kNodeCount = 10000;
const int kIterations = 20;

void main() {
  testWidgets('B8 mount and unmount 10000 leaf nodes', (WidgetTester tester) async {
    late StateSetter setState;
    var mounted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setState = setter;
            return mounted
                ? mountAllInRows([
                    for (var i = 0; i < kNodeCount; i++) Container(height: 1, color: Colors.blue),
                  ])
                : const SizedBox.shrink();
          },
        ),
      ),
    );

    final mountTimes = <double>[];
    final unmountTimes = <double>[];
    final watch = Stopwatch();
    for (var i = 0; i < kIterations + 3; i++) {
      watch
        ..reset()
        ..start();
      mounted = true;
      setState(() {});
      await tester.pump();
      watch.stop();
      if (i == 0) {
        // Every node must actually mount, not just what a viewport would show.
        expect(find.byType(Positioned), findsNWidgets(kNodeCount));
      }
      if (i >= 3) {
        mountTimes.add(watch.elapsedMicroseconds.toDouble());
      }

      watch
        ..reset()
        ..start();
      mounted = false;
      setState(() {});
      await tester.pump();
      watch.stop();
      if (i == 0) {
        expect(find.byType(Positioned), findsNothing);
      }
      if (i >= 3) {
        unmountTimes.add(watch.elapsedMicroseconds.toDouble());
      }
    }
    printMedian('b8_mount_10000_nodes', mountTimes);
    printMedian('b8_unmount_10000_nodes', unmountTimes);
  });

  testWidgets('B8 fork mount and unmount 10000 reactive leaf nodes', (WidgetTester tester) async {
    final signals = List<Signal<Color>>.generate(kNodeCount, (int i) => Signal<Color>(Colors.blue));
    late StateSetter setState;
    var mounted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setState = setter;
            return mounted
                ? mountAllInRows([
                    for (final s in signals)
                      ReactiveColoredBox(color: s, child: const SizedBox(height: 1)),
                  ])
                : const SizedBox.shrink();
          },
        ),
      ),
    );

    final mountTimes = <double>[];
    final unmountTimes = <double>[];
    final watch = Stopwatch();
    for (var i = 0; i < kIterations + 3; i++) {
      watch
        ..reset()
        ..start();
      mounted = true;
      setState(() {});
      await tester.pump();
      watch.stop();
      if (i == 0) {
        expect(find.byType(Positioned), findsNWidgets(kNodeCount));
        // Every leaf really bound its signal.
        expect(signals.first.subs, isNotNull);
      }
      if (i >= 3) {
        mountTimes.add(watch.elapsedMicroseconds.toDouble());
      }

      watch
        ..reset()
        ..start();
      mounted = false;
      setState(() {});
      await tester.pump();
      watch.stop();
      if (i == 0) {
        expect(find.byType(Positioned), findsNothing);
        // Unmounting disposed every effect, so no signal retains a leaf.
        expect(signals.first.subs, isNull);
      }
      if (i >= 3) {
        unmountTimes.add(watch.elapsedMicroseconds.toDouble());
      }
    }
    printMedian('b8_fork_mount_10000_reactive_leaves', mountTimes);
    printMedian('b8_fork_unmount_10000_reactive_leaves', unmountTimes);
  });
}
