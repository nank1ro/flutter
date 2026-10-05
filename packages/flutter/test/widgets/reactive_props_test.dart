// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// A stock widget whose property is a ReadonlySignal. `Opacity` is the
// prototype: `opacity` takes a Signal, a Computed, or a const `.fixed(value)`,
// and only the reactive forms create a binding.

import 'package:flutter/rendering.dart';
// The graph internals these tests inspect are not exported from
// `foundation.dart`; they come from the source file directly.
import 'package:flutter/src/foundation/signals.dart' show ReactiveNode;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts its own builds, so a test can assert a signal write rebuilt nothing.
class _Counter extends StatelessWidget {
  const _Counter({required this.counts, required this.child});

  final List<int> counts;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    counts[0] += 1;
    return child;
  }
}

double _opacityOf(WidgetTester tester) =>
    tester.renderObject<RenderOpacity>(find.byType(Opacity)).opacity;

void main() {
  testWidgets('a fixed value behaves exactly as a plain double did', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Opacity(
        opacity: .fixed(0.5),
        child: SizedBox(width: .fixed(10)),
      ),
    );
    expect(_opacityOf(tester), 0.5);

    // A rebuild with a new value copies it across, which is the classic path.
    await tester.pumpWidget(
      const Opacity(
        opacity: .fixed(0.25),
        child: SizedBox(width: .fixed(10)),
      ),
    );
    expect(_opacityOf(tester), 0.25);
  });

  test('a fixed value keeps the widget const', () {
    // Rebuilding a const widget yields the same instance, which is what lets
    // the framework skip an unchanged subtree by identity. Two const widgets
    // written on different lines are not compared: in debug builds the
    // widget-creation tracker gives each a distinct source location.
    Widget build() => const Opacity(
      opacity: .fixed(0.5),
      child: SizedBox(width: .fixed(10)),
    );
    expect(identical(build(), build()), isTrue);
  });

  test('an integer literal widens through the context type', () {
    const opacity = Opacity(opacity: .fixed(1));
    expect(opacity.opacity.value, isA<double>());
  });

  test('fixed values compare by value, signals by identity', () {
    // A property read back from the tree compares equal to one built fresh.
    expect(
      Transform.rotate(angle: const .fixed(0.0)).transform,
      Transform.rotate(angle: const .fixed(0.0)).transform,
    );
    expect(
      Transform.rotate(angle: const .fixed(0.0)).transform,
      isNot(Transform.rotate(angle: const .fixed(1.0)).transform),
    );
    // Two signals holding the same value are still two signals.
    expect(Signal<double>(1) == Signal<double>(1), isFalse);
  });

  testWidgets('a fixed value creates no effect', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Opacity(
        opacity: .fixed(0.5),
        child: SizedBox(width: .fixed(10)),
      ),
    );

    final Element element = tester.element(find.byType(Opacity));
    // The stock element, not a reactive subclass.
    expect(element.runtimeType, SingleChildRenderObjectElement);
    // An effect created under an element's owner is linked into it, so an
    // owner with nothing linked is an element that bound nothing. A fixed
    // value short-circuits before `bindProps`, so there is no binder either.
    // ignore: invalid_use_of_protected_member
    expect((element.reactiveOwner as ReactiveNode).deps, isNull);
  });

  testWidgets('a bound widget keeps its stock element type', (WidgetTester tester) async {
    final fade = Signal<double>(1);
    await tester.pumpWidget(
      Opacity(
        opacity: fade,
        child: const SizedBox(width: .fixed(10)),
      ),
    );

    // Binding lives in RenderObjectElement itself, so finders and diagnostics
    // that name the element type keep working.
    expect(tester.element(find.byType(Opacity)).runtimeType, SingleChildRenderObjectElement);
    expect(find.byElementType(SingleChildRenderObjectElement), findsWidgets);
    expect(fade.subs, isNotNull);
  });

  testWidgets('a signal write repaints without rebuilding anything', (WidgetTester tester) async {
    final fade = Signal<double>(1);
    final counts = <int>[0];

    await tester.pumpWidget(
      _Counter(
        counts: counts,
        child: Opacity(
          opacity: fade,
          child: const SizedBox(width: .fixed(10)),
        ),
      ),
    );
    expect(_opacityOf(tester), 1.0);
    expect(counts[0], 1);
    expect(fade.subs, isNotNull, reason: 'the binding subscribed to the signal');

    fade.value = 0.25;
    await tester.pump();

    expect(_opacityOf(tester), 0.25);
    expect(counts[0], 1, reason: 'no element rebuilt');
  });

  testWidgets('a computed works the same way', (WidgetTester tester) async {
    final fade = Signal<double>(1);
    final half = Computed<double>(() => fade.value / 2);

    await tester.pumpWidget(
      Opacity(
        opacity: half,
        child: const SizedBox(width: .fixed(10)),
      ),
    );
    expect(_opacityOf(tester), 0.5);

    fade.value = 0.4;
    await tester.pump();
    expect(_opacityOf(tester), closeTo(0.2, 1e-9));
  });

  testWidgets('a property may switch between fixed and reactive', (WidgetTester tester) async {
    final fade = Signal<double>(1);

    await tester.pumpWidget(
      const Opacity(
        opacity: .fixed(0.5),
        child: SizedBox(width: .fixed(10)),
      ),
    );
    expect(_opacityOf(tester), 0.5);
    expect(fade.subs, isNull);

    // Becomes reactive: the binding is created on update, not just on mount.
    await tester.pumpWidget(
      Opacity(
        opacity: fade,
        child: const SizedBox(width: .fixed(10)),
      ),
    );
    expect(_opacityOf(tester), 1.0);
    expect(fade.subs, isNotNull);

    fade.value = 0.75;
    await tester.pump();
    expect(_opacityOf(tester), 0.75);

    // Back to fixed: the effect is disposed, so later writes reach nothing.
    await tester.pumpWidget(
      const Opacity(
        opacity: .fixed(0.1),
        child: SizedBox(width: .fixed(10)),
      ),
    );
    expect(_opacityOf(tester), 0.1);
    expect(fade.subs, isNull, reason: 'the binding was disposed');

    fade.value = 0.9;
    await tester.pump();
    expect(_opacityOf(tester), 0.1, reason: 'the stale signal no longer drives anything');
  });

  testWidgets('swapping one signal for another rebinds', (WidgetTester tester) async {
    final a = Signal<double>(1);
    final b = Signal<double>(0.5);

    await tester.pumpWidget(
      Opacity(
        opacity: a,
        child: const SizedBox(width: .fixed(10)),
      ),
    );
    expect(_opacityOf(tester), 1.0);

    await tester.pumpWidget(
      Opacity(
        opacity: b,
        child: const SizedBox(width: .fixed(10)),
      ),
    );
    expect(_opacityOf(tester), 0.5);
    expect(a.subs, isNull);
    expect(b.subs, isNotNull);

    a.value = 0.2;
    await tester.pump();
    expect(_opacityOf(tester), 0.5, reason: 'the old signal was unbound');

    b.value = 0.3;
    await tester.pump();
    expect(_opacityOf(tester), 0.3);
  });

  testWidgets('the render object is never recreated by a rebind', (WidgetTester tester) async {
    final fade = Signal<double>(1);
    await tester.pumpWidget(
      Opacity(
        opacity: fade,
        child: const SizedBox(width: .fixed(10)),
      ),
    );
    final RenderOpacity renderObject = tester.renderObject<RenderOpacity>(find.byType(Opacity));

    await tester.pumpWidget(
      const Opacity(
        opacity: .fixed(0.5),
        child: SizedBox(width: .fixed(10)),
      ),
    );
    expect(tester.renderObject<RenderOpacity>(find.byType(Opacity)), same(renderObject));
  });

  testWidgets('disposing the element disposes the binding', (WidgetTester tester) async {
    final fade = Signal<double>(1);
    await tester.pumpWidget(
      Opacity(
        opacity: fade,
        child: const SizedBox(width: .fixed(10)),
      ),
    );
    expect(fade.subs, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(fade.subs, isNull);
  });

  testWidgets('a signal written out of range is caught', (WidgetTester tester) async {
    // The widget used to assert the range in its constructor, which could only
    // ever see the first value. The render object's setter asserts on every
    // write, so a bound signal is checked too.
    final fade = Signal<double>(1);
    await tester.pumpWidget(
      Opacity(
        opacity: fade,
        child: const SizedBox(width: .fixed(10)),
      ),
    );

    fade.value = 1.5;
    await tester.pump();
    expect(tester.takeException(), isAssertionError);
  });

  testWidgets('a value read in build still updates, one element coarser', (
    WidgetTester tester,
  ) async {
    // Reading the signal during build and passing the result as a fixed value
    // is legal: the tracked build subscribes the element that read it, so the
    // update is still correct. It rebuilds that one element instead of writing
    // the render object directly.
    final fade = Signal<double>(1);
    final counts = <int>[0];

    await tester.pumpWidget(
      _Counter(
        counts: counts,
        child: Builder(
          builder: (BuildContext context) {
            return Opacity(
              opacity: .fixed(fade.value),
              child: const SizedBox(width: .fixed(10)),
            );
          },
        ),
      ),
    );
    expect(_opacityOf(tester), 1.0);

    fade.value = 0.25;
    await tester.pump();

    expect(_opacityOf(tester), 0.25, reason: 'still correct');
    expect(counts[0], 1, reason: 'only the Builder that read it rebuilt, not its ancestors');
  });
}
