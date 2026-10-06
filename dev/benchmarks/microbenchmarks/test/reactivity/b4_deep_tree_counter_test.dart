// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B4: 120 Hz counter, one text leaf updated every frame in a deep tree
// (depth 50). See docs/fine_grained_reactivity/BENCHMARKS.md. Whether tree
// depth still costs anything once reactivity is leaf-level.
//
// All four variants run in one process, interleaved and rotated by
// `runInterleaved`. This scenario is the one the old sequential harness got
// most wrong: three near-identical workloads read 545 / 408 / 291 us purely
// in file order, which is why the ordering is rotated here.
//
//  - best practice: 50 nested Padding widgets that never rebuild, with a
//    ValueListenableBuilder<int> at the leaf driving a Text.
//  - Phase 2: the leaf reads a Signal<int> in its own build.
//  - Phase 3 leaf: the leaf is a ReactiveText bound to a Signal<String>, so a
//    write runs one effect and one RenderParagraph.text setter.
//  - Phase 5 collapsed: 50 RPadding nodes and an RText.
//
// Render objects -- 51 in every variant: 50 RenderPadding plus one
// RenderParagraph. The ambient text style is handed to RText explicitly,
// because a node has no BuildContext to read a DefaultTextStyle from; the
// other three variants merge the same ambient style.

import 'package:flutter/material.dart';
import 'package:flutter/reactive_nodes.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kDepth = 50;
const int kWarmup = 5;
const int kTimed = 40;

int _counterBuilds = 0;
int _probeBuilds = 0;
int _effectRuns = 0;
int _componentRuns = 0;

Widget _nest(int depth, Widget leaf) {
  var widget = leaf;
  for (var i = 0; i < depth; i++) {
    widget = Padding(padding: const .fixed(EdgeInsets.zero), child: widget);
  }
  return widget;
}

class _SignalCounter extends StatelessWidget {
  const _SignalCounter(this.counter);

  final Signal<int> counter;

  @override
  Widget build(BuildContext context) {
    _counterBuilds++;
    return Text('${counter.value}');
  }
}

/// Counts its own builds, above the 50 nested widgets, so the benchmark can
/// assert that the update never entered the build pipeline.
class _BuildProbe extends StatelessWidget {
  const _BuildProbe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    _probeBuilds++;
    return child;
  }
}

Future<double> _valueListenable(WidgetTester tester) async {
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

  for (var w = 0; w < kWarmup; w++) {
    counter.value++;
    await tester.pump();
  }
  buildCount = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      counter.value++;
      await tester.pump();
    },
  );
  // Every timed pump rebuilt the leaf.
  expect(buildCount, kTimed);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _signalInBuild(WidgetTester tester) async {
  final counter = Signal<int>(0);
  await tester.pumpWidget(MaterialApp(home: _nest(kDepth, _SignalCounter(counter))));

  for (var w = 0; w < kWarmup; w++) {
    counter.value++;
    await tester.pump();
  }
  _counterBuilds = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      counter.value++;
      await tester.pump();
    },
  );
  expect(_counterBuilds, kTimed);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _leafBinding(WidgetTester tester) async {
  final counter = Signal<String>('0');
  await tester.pumpWidget(
    MaterialApp(home: _BuildProbe(child: _nest(kDepth, ReactiveText(counter)))),
  );

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    counter.value = '${++i}';
    await tester.pump();
  }
  _probeBuilds = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      counter.value = '${++i}';
      await tester.pump();
    },
  );
  // Liveness: the paragraph really shows the last value written.
  expect(tester.renderObject<RenderParagraph>(find.byType(ReactiveText)).text.toPlainText(), '$i');
  // Nothing in the 50-deep tree rebuilt.
  expect(_probeBuilds, 0);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _collapsedNodes(WidgetTester tester) async {
  final counter = Signal<String>('0');
  _componentRuns = 0;
  _effectRuns = 0;
  late RText leaf;
  RNode? root;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) {
          final TextStyle ambient = DefaultTextStyle.of(context).style;
          root ??= RComponent(() {
            _componentRuns += 1;
            leaf = RText(() {
              _effectRuns += 1;
              return counter.value;
            }, style: () => ambient);
            var node = leaf as RNode;
            for (var i = 0; i < kDepth; i++) {
              node = RPadding(padding: () => EdgeInsets.zero, child: node);
            }
            return node;
          });
          return NodeHost(node: root!);
        },
      ),
    ),
  );

  var i = 0;
  for (var w = 0; w < kWarmup; w++) {
    counter.value = '${++i}';
    await tester.pump();
  }
  _effectRuns = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      counter.value = '${++i}';
      await tester.pump();
    },
  );
  // Liveness: the paragraph really shows the last value written, one effect
  // ran per write, and the component body never ran again.
  expect(leaf.renderObject.text.toPlainText(), '$i');
  expect(_effectRuns, kTimed);
  expect(_componentRuns, 1);

  await tester.pumpWidget(const SizedBox.shrink());
  root!.dispose();
  return median(values);
}

void main() {
  testWidgets('B4 text leaf update at depth 50', (WidgetTester tester) async {
    await runInterleaved(tester, 'b4', <BenchVariant>[
      const BenchVariant('vlb_best_practice', _valueListenable),
      const BenchVariant('phase2_signal_build', _signalInBuild),
      const BenchVariant('phase3_leaf', _leafBinding),
      const BenchVariant('phase5_collapsed', _collapsedNodes),
    ]);
  });
}
