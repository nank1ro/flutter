// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B5: deep static tree (depth 100), single leaf signal changes. See
// docs/fine_grained_reactivity/BENCHMARKS.md. Regression guard: no
// ancestor may rebuild.
//
// All four variants run in one process, interleaved and rotated by
// `runInterleaved`.
//
// Render objects -- 101 in every variant: 100 RenderPadding plus one
// RenderParagraph. The three classic variants get their padding from a
// counting StatelessWidget wrapping a Padding, so an ancestor rebuild is
// observable; the collapsed variant gets it from an RPadding whose padding
// binding counts its own runs, which is the same guard with the only counter
// that model has. Element counts therefore differ between the models by
// design: the point of the collapsed model is that there are none.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/reactive_nodes.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kDepth = 100;
const int kWarmup = 5;
const int kTimed = 40;

int _leafBuilds = 0;
int _probeBuilds = 0;
int _effectRuns = 0;
int _componentRuns = 0;
int _ancestorEffectRuns = 0;

/// One level of the deep tree: counts its own builds and contributes exactly
/// one render object, so the classic variants and the collapsed one lay out
/// and paint the same number of nodes.
class _CountingAncestor extends StatelessWidget {
  const _CountingAncestor(this.buildCounts, this.index, {required this.child});

  final List<int> buildCounts;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    buildCounts[index]++;
    return Padding(padding: EdgeInsets.zero, child: child);
  }
}

class _SignalLeaf extends StatelessWidget {
  const _SignalLeaf(this.counter);

  final Signal<int> counter;

  @override
  Widget build(BuildContext context) {
    _leafBuilds++;
    return Text('${counter.value}');
  }
}

/// Counts its own builds, above the 100 ancestors.
class _BuildProbe extends StatelessWidget {
  const _BuildProbe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    _probeBuilds++;
    return child;
  }
}

Widget _nest(List<int> buildCounts, Widget leaf) {
  var tree = leaf;
  for (var i = 0; i < kDepth; i++) {
    tree = _CountingAncestor(buildCounts, i, child: tree);
  }
  return tree;
}

Future<double> _valueListenable(WidgetTester tester) async {
  final buildCounts = List<int>.filled(kDepth, 0);
  final counter = ValueNotifier<int>(0);
  var buildCount = 0;
  await tester.pumpWidget(
    MaterialApp(
      home: _nest(
        buildCounts,
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

  final countsAfterMount = List<int>.of(buildCounts);
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
  expect(
    buildCounts,
    countsAfterMount,
    reason: 'ancestors must not rebuild when only the leaf changes',
  );
  // Sanity, so the assertion above is not vacuous: the leaf really did run.
  expect(buildCount, kTimed);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _signalInBuild(WidgetTester tester) async {
  final buildCounts = List<int>.filled(kDepth, 0);
  final counter = Signal<int>(0);
  await tester.pumpWidget(MaterialApp(home: _nest(buildCounts, _SignalLeaf(counter))));

  final countsAfterMount = List<int>.of(buildCounts);
  for (var w = 0; w < kWarmup; w++) {
    counter.value++;
    await tester.pump();
  }
  _leafBuilds = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kTimed,
    body: () async {
      counter.value++;
      await tester.pump();
    },
  );
  expect(
    buildCounts,
    countsAfterMount,
    reason: 'ancestors must not rebuild when only the leaf reads the signal',
  );
  expect(_leafBuilds, kTimed);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _leafBinding(WidgetTester tester) async {
  final buildCounts = List<int>.filled(kDepth, 0);
  final counter = Signal<String>('0');
  await tester.pumpWidget(
    MaterialApp(home: _BuildProbe(child: _nest(buildCounts, ReactiveText(counter)))),
  );

  final countsAfterMount = List<int>.of(buildCounts);
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
  expect(buildCounts, countsAfterMount, reason: 'ancestors must not rebuild');
  // Liveness: the paragraph really shows the last value written, and nothing
  // on the path from the root to the leaf rebuilt either.
  expect(tester.renderObject<RenderParagraph>(find.byType(ReactiveText)).text.toPlainText(), '$i');
  expect(_probeBuilds, 0);
  await tester.pumpWidget(const SizedBox.shrink());
  return median(values);
}

Future<double> _collapsedNodes(WidgetTester tester) async {
  final counter = Signal<String>('0');
  // One real reactive dependency per ancestor, never written: an ancestor
  // effect that re-ran would show up in _ancestorEffectRuns.
  final paddings = List<Signal<EdgeInsetsGeometry>>.generate(
    kDepth,
    (int i) => Signal<EdgeInsetsGeometry>(EdgeInsets.zero),
  );
  _componentRuns = 0;
  _ancestorEffectRuns = 0;
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
              final Signal<EdgeInsetsGeometry> padding = paddings[i];
              node = RPadding(
                padding: () {
                  _ancestorEffectRuns += 1;
                  return padding.value;
                },
                child: node,
              );
            }
            return node;
          });
          return NodeHost(node: root!);
        },
      ),
    ),
  );
  expect(_ancestorEffectRuns, kDepth, reason: 'one binding run per ancestor at creation');
  final int runsAfterMount = _ancestorEffectRuns;

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
  expect(
    _ancestorEffectRuns,
    runsAfterMount,
    reason: 'no ancestor binding may re-run when only the leaf changes',
  );
  expect(leaf.renderObject.text.toPlainText(), '$i');
  expect(_effectRuns, kTimed);
  expect(_componentRuns, 1);

  await tester.pumpWidget(const SizedBox.shrink());
  root!.dispose();
  return median(values);
}

void main() {
  testWidgets('B5 deep static tree, leaf-only update at depth 100', (WidgetTester tester) async {
    await runInterleaved(tester, 'b5', <BenchVariant>[
      const BenchVariant('vlb_best_practice', _valueListenable),
      const BenchVariant('phase2_signal_build', _signalInBuild),
      const BenchVariant('phase3_leaf', _leafBinding),
      const BenchVariant('phase5_collapsed', _collapsedNodes),
    ]);
  });

  testWidgets('B5 negative check: setState at root does rebuild ancestors', (
    WidgetTester tester,
  ) async {
    // Proves the build-count harness actually detects ancestor rebuilds -- an
    // unrelated root setState rebuilds every _CountingAncestor -- so the "must
    // not rebuild" assertions above are meaningful.
    final buildCounts = List<int>.filled(kDepth, 0);
    final counter = ValueNotifier<int>(0);
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setState = setter;
            return _nest(
              buildCounts,
              ValueListenableBuilder<int>(
                valueListenable: counter,
                builder: (BuildContext context, int value, Widget? child) => Text('$value'),
              ),
            );
          },
        ),
      ),
    );

    final countsAfterMount = List<int>.of(buildCounts);
    for (var i = 0; i < 5; i++) {
      setState(() {});
      await tester.pump();
    }
    for (var i = 0; i < kDepth; i++) {
      expect(buildCounts[i], greaterThan(countsAfterMount[i]));
    }
  });

  testWidgets('B5 negative check: writing an ancestor node property runs its effect', (
    WidgetTester tester,
  ) async {
    // The collapsed-model twin of the check above: proves _ancestorEffectRuns
    // can detect ancestor work.
    final padding = Signal<EdgeInsetsGeometry>(EdgeInsets.zero);
    _ancestorEffectRuns = 0;
    final root = RComponent(
      () => RPadding(
        padding: () {
          _ancestorEffectRuns += 1;
          return padding.value;
        },
        child: RText(() => 'x'),
      ),
    );
    await tester.pumpWidget(MaterialApp(home: NodeHost(node: root)));
    expect(_ancestorEffectRuns, 1);
    for (var i = 1; i <= 5; i++) {
      padding.value = EdgeInsets.all(i.toDouble());
      await tester.pump();
    }
    expect(_ancestorEffectRuns, 6);
    await tester.pumpWidget(const SizedBox.shrink());
    root.dispose();
  });
}
