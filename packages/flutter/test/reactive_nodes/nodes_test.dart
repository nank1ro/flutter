// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/reactive_nodes.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const Color _red = Color(0xFFFF0000);
const Color _blue = Color(0xFF0000FF);

void main() {
  testWidgets('a component body runs once, and a property write does not re-run it', (
    WidgetTester tester,
  ) async {
    var bodyRuns = 0;
    final color = Signal<Color>(_blue);
    final node = RComponent(() {
      bodyRuns += 1;
      return RBox(color: color.call);
    });
    addTearDown(node.dispose);

    expect(bodyRuns, 1);
    expect((node.renderObject as RenderReactiveColoredBox).color, _blue);

    color.value = _red;
    await tester.pump();

    // The render object took the new value, and nothing re-executed to do it.
    expect((node.renderObject as RenderReactiveColoredBox).color, _red);
    expect(bodyRuns, 1);
  });

  testWidgets('an effect created in a component body runs once per instance', (
    WidgetTester tester,
  ) async {
    // This is the Phase 2 divergence disappearing: in the classic tree an
    // effect created in `build` is disposed and re-created on every rebuild,
    // so it is per-build. Here the body runs once, so the effect is
    // per-instance, which is what SolidJS's createEffect means.
    var effectRuns = 0;
    final tick = Signal<int>(0);
    RNode makeInstance() {
      return RComponent(() {
        Effect(() {
          tick.value;
          effectRuns += 1;
        });
        return RBox(color: () => _blue);
      });
    }

    final RNode first = makeInstance();
    final RNode second = makeInstance();
    expect(effectRuns, 2, reason: 'one immediate run per instance');

    tick.value = 1;
    await tester.pump();
    expect(effectRuns, 4, reason: 'one run per instance, not per build');

    first.dispose();
    tick.value = 2;
    await tester.pump();
    expect(effectRuns, 5, reason: 'the disposed instance stopped observing');

    second.dispose();
    tick.value = 3;
    await tester.pump();
    expect(effectRuns, 5);
    expect(tick.subs, isNull);
  });

  testWidgets('RShow mounts and unmounts a subtree, disposing its owner', (
    WidgetTester tester,
  ) async {
    var branchBuilds = 0;
    final visible = Signal<bool>(true);
    final color = Signal<Color>(_blue);
    final show = RShow(
      when: visible.call,
      child: () {
        branchBuilds += 1;
        return RBox(color: color.call);
      },
    );
    addTearDown(show.dispose);

    expect(branchBuilds, 1);
    expect(show.renderObject.child, isNotNull);
    expect(color.subs, isNotNull);

    visible.value = false;
    await tester.pump();
    expect(show.renderObject.child, isNull);
    expect(show.mounted, isNull);
    expect(color.subs, isNull, reason: 'the unmounted subtree disposed its bindings');

    visible.value = true;
    await tester.pump();
    expect(branchBuilds, 2);
    expect(show.renderObject.child, isNotNull);
    expect(color.subs, isNotNull);
  });

  testWidgets('RFor touches only the children that changed', (WidgetTester tester) async {
    final colors = <int, Signal<Color>>{
      for (var id = 1; id <= 4; id += 1) id: Signal<Color>(_blue),
    };
    final items = Signal<List<int>>(<int>[1, 2, 3]);
    final built = <int>[];
    final list = RFor<int>(
      each: items.call,
      keyOf: (int id) => id,
      builder: (int id) {
        built.add(id);
        return RBox(color: colors[id]!.call);
      },
    );
    addTearDown(list.dispose);

    expect(built, <int>[1, 2, 3]);
    final List<RenderBox> before = list.renderObject.getChildrenAsList();
    expect(before, hasLength(3));

    // Remove 2, add 4, and reorder the survivors.
    items.value = <int>[3, 1, 4];
    await tester.pump();

    expect(built, <int>[1, 2, 3, 4], reason: 'only the new key was built');
    final List<RenderBox> after = list.renderObject.getChildrenAsList();
    expect(after, hasLength(3));
    // Untouched children keep their identity, in the new order.
    expect(after[0], same(before[2]));
    expect(after[1], same(before[0]));
    expect(after[2], isNot(anyOf(same(before[0]), same(before[1]), same(before[2]))));
    // The removed child was disposed, so its signal has no subscriber left.
    expect(colors[2]!.subs, isNull);
    expect(colors[1]!.subs, isNotNull);
    expect(colors[3]!.subs, isNotNull);
  });

  testWidgets('a hosted node tree lays out, paints and hit-tests', (WidgetTester tester) async {
    final color = Signal<Color>(_blue);
    final box = RBox(color: color.call);
    final RNode root = RComponent(
      () => RStack(
        children: <RNode>[RPositioned(left: 0, top: 0, width: 100, height: 50, child: box)],
      ),
    );

    await tester.pumpWidget(
      Center(
        child: SizedBox(width: 100, height: 50, child: NodeHost(node: root)),
      ),
    );

    expect(tester.getSize(find.byType(NodeHost)), const Size(100, 50));
    expect(find.byType(NodeHost), paints..rect(color: _blue));

    final HitTestResult result = tester.hitTestOnBinding(tester.getCenter(find.byType(NodeHost)));
    expect(result.path.map((HitTestEntry entry) => entry.target), contains(box.renderObject));

    // A write repaints through the host without rebuilding anything.
    color.value = _red;
    await tester.pump();
    expect(find.byType(NodeHost), paints..rect(color: _red));

    // Unmounting the host hands the root render object back, un-parented.
    await tester.pumpWidget(const SizedBox());
    expect(root.renderObject.parent, isNull);
    root.dispose();
    expect(color.subs, isNull);
  });

  testWidgets('disposing a tree unlinks every signal subscription', (WidgetTester tester) async {
    final color = Signal<Color>(_blue);
    final opacity = Signal<double>(1);
    final offset = Signal<Offset>(Offset.zero);
    final padding = Signal<EdgeInsetsGeometry>(EdgeInsets.zero);
    final text = Signal<String>('a');

    final RNode root = RComponent(
      () => ROpacity(
        opacity: opacity.call,
        child: ROffset(
          offset: offset.call,
          child: RPadding(
            padding: padding.call,
            child: RBox(color: color.call, child: RText(text.call)),
          ),
        ),
      ),
    );

    final subscribed = <bool Function()>[
      () => color.subs != null,
      () => opacity.subs != null,
      () => offset.subs != null,
      () => padding.subs != null,
      () => text.subs != null,
    ];
    expect(subscribed.map((bool Function() has) => has()), everyElement(isTrue));

    root.dispose();

    expect(subscribed.map((bool Function() has) => has()), everyElement(isFalse));
  });

  testWidgets('disposing a node while its render object is still hosted asserts', (
    WidgetTester tester,
  ) async {
    final RNode root = RBox(color: () => _blue);
    await tester.pumpWidget(NodeHost(node: root));

    expect(root.dispose, throwsAssertionError);

    await tester.pumpWidget(const SizedBox());
    root.dispose();
  });

  testWidgets('disposing a container un-parents its children first', (WidgetTester tester) async {
    final RNode inner = RBox(color: () => _blue);
    final RNode padded = RPadding(padding: () => EdgeInsets.zero, child: inner);
    final RNode sibling = RBox(color: () => _red);
    final stack = RStack(children: <RNode>[padded, sibling]);
    expect(inner.renderObject.parent, isNotNull);
    expect(padded.renderObject.parent, isNotNull);

    stack.dispose();

    // Nothing is left pointing at a disposed render object, in either direction.
    expect(inner.renderObject.parent, isNull);
    expect(padded.renderObject.parent, isNull);
    expect(sibling.renderObject.parent, isNull);
    expect(stack.renderObject.childCount, 0);
  });

  testWidgets('disposing a node twice asserts', (WidgetTester tester) async {
    final RNode node = RBox(color: () => _blue);
    node.dispose();
    expect(node.dispose, throwsAssertionError);
  });

  testWidgets('a NodeHost refuses a node that is already hosted', (WidgetTester tester) async {
    final RNode root = RBox(color: () => _blue);
    addTearDown(root.dispose);
    await tester.pumpWidget(NodeHost(node: root));

    await tester.pumpWidget(
      Row(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          NodeHost(node: root),
          NodeHost(node: root),
        ],
      ),
    );
    expect(tester.takeException(), isAssertionError);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('RPositioned outside a stack fails with a clear error', (WidgetTester tester) async {
    expect(
      () => RPadding(
        padding: () => EdgeInsets.zero,
        child: RPositioned(child: RBox(color: () => _blue)),
      ),
      throwsA(
        isA<FlutterError>().having(
          (FlutterError error) => error.toString(),
          'message',
          contains('only legal directly under an RStack or an RFor'),
        ),
      ),
    );
  });

  testWidgets('RPositioned under an RShow reports rather than being swallowed', (
    WidgetTester tester,
  ) async {
    RShow(
      when: () => true,
      child: () => RPositioned(child: RBox(color: () => _blue)),
    );
    expect(tester.takeException(), isFlutterError);
  });

  testWidgets('RFor reports a duplicate key and skips the duplicate', (WidgetTester tester) async {
    final items = Signal<List<int>>(<int>[1, 2, 2, 3]);
    final list = RFor<int>(
      each: items.call,
      keyOf: (int id) => id,
      builder: (int id) => RBox(color: () => _blue),
    );
    addTearDown(list.dispose);

    expect(
      tester.takeException(),
      isA<FlutterError>().having(
        (FlutterError error) => error.toString(),
        'message',
        contains('duplicate key 2'),
      ),
    );
    expect(list.renderObject.childCount, 3, reason: 'the duplicate was skipped, not mounted');
  });

  testWidgets('an Effect created in an RFor builder lives with its item', (
    WidgetTester tester,
  ) async {
    final tick = Signal<int>(0);
    final runs = <int, int>{};
    final items = Signal<List<int>>(<int>[1]);
    final list = RFor<int>(
      each: items.call,
      keyOf: (int id) => id,
      builder: (int id) {
        Effect(() {
          tick.value;
          runs[id] = (runs[id] ?? 0) + 1;
        });
        return RBox(color: () => _blue);
      },
    );
    addTearDown(list.dispose);
    expect(runs, <int, int>{1: 1});

    // Reconciling for an unrelated key must not take item 1's effect with it.
    items.value = <int>[1, 2];
    await tester.pump();
    expect(runs, <int, int>{1: 1, 2: 1});

    tick.value = 1;
    await tester.pump();
    expect(runs, <int, int>{1: 2, 2: 2});

    items.value = <int>[2];
    await tester.pump();
    tick.value = 2;
    await tester.pump();
    expect(runs, <int, int>{1: 2, 2: 3}, reason: 'the removed item stopped observing');
  });
}
