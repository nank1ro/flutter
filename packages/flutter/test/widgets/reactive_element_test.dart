// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Every ComponentElement tracks the signals its build reads. These tests cover
// the framework side of that: which elements rebuild, when the effects run
// relative to the frame, and what is disposed.

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
// The graph internals are not exported by foundation.dart, but the tests
// assert on subscription bookkeeping, so they are imported directly.
import 'package:flutter/src/foundation/signals.dart' show Link;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stateless widget that reads [signal] in its build and counts its builds.
class _Reader extends StatelessWidget {
  const _Reader({super.key, required this.signal, this.builds});

  final Signal<int> signal;

  /// Appended to on every build, when the test cares about build counts.
  final List<String>? builds;

  @override
  Widget build(BuildContext context) {
    builds?.add('reader');
    return Text('${signal.value}', textDirection: TextDirection.ltr);
  }
}

void main() {
  testWidgets('a stateless build that reads a signal rebuilds on write, with no setState', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    final builds = <String>[];

    await tester.pumpWidget(
      _Parent(
        builds: builds,
        sibling: _Sibling(builds: builds),
        child: _Reader(signal: count, builds: builds),
      ),
    );
    expect(find.text('0'), findsOneWidget);
    expect(builds, <String>['parent', 'reader', 'sibling']);

    builds.clear();
    count.value = 1;
    // The write happened outside a frame, so nothing has rebuilt yet.
    expect(builds, isEmpty);

    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    // Only the element that read the signal rebuilt.
    expect(builds, <String>['reader']);
  });

  testWidgets('a signal write schedules a frame', (WidgetTester tester) async {
    final count = Signal<int>(0);
    await tester.pumpWidget(_Reader(signal: count));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    count.value = 1;
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('a computed read in build tracks its own dependencies', (WidgetTester tester) async {
    final a = Signal<int>(1);
    final b = Signal<int>(10);
    var computations = 0;
    final sum = Computed<int>(() {
      computations += 1;
      return a.value + b.value;
    });
    addTearDown(sum.dispose);

    final builds = <String>[];
    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          builds.add('reader');
          return Text('${sum.value}', textDirection: TextDirection.ltr);
        },
      ),
    );
    expect(find.text('11'), findsOneWidget);
    expect(computations, 1);

    a.value = 2;
    await tester.pump();
    expect(find.text('12'), findsOneWidget);
    expect(builds.length, 2);
    expect(computations, 2);

    // A write that leaves the computed's value unchanged rebuilds nothing.
    a.value = 3;
    b.value = 9;
    await tester.pump();
    expect(find.text('12'), findsOneWidget);
    expect(builds.length, 2);
  });

  // Deliberate divergence from SolidJS, where a component body runs once and
  // an effect created in it therefore runs once. A Flutter build re-runs, and
  // an effect created in one belongs to that build: it is disposed and
  // re-created every time. For an effect that must run once per element, put
  // it in State.initState, which runs in the element's own scope; see 'an
  // effect created in initState runs once per State, not once per build'.
  testWidgets('an effect created in build is disposed and re-created on every rebuild', (
    WidgetTester tester,
  ) async {
    final observed = Signal<int>(0);
    final shown = Signal<int>(0);
    var runs = 0;

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          Effect(() {
            observed.value;
            runs += 1;
          });
          return Text('${shown.value}', textDirection: TextDirection.ltr);
        },
      ),
    );
    // The effect ran once, when it was created.
    expect(runs, 1);

    observed.value = 1;
    await tester.pump();
    // The effect re-ran; the element did not rebuild, because its build does
    // not read `observed`.
    expect(runs, 2);

    // Force a rebuild. The old effect is disposed and a new one created.
    shown.value = 1;
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    expect(runs, 3);

    // One effect, not two: the effect from the previous build is gone.
    observed.value = 2;
    await tester.pump();
    expect(runs, 4);

    await tester.pumpWidget(const SizedBox());
    observed.value = 3;
    await tester.pump();
    expect(runs, 4);
    expect(observed.subs, isNull);
  });

  testWidgets('unmounting unlinks the element from every signal it read', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    await tester.pumpWidget(_Reader(signal: count));
    final Link? subscribers = count.subs;
    expect(subscribers, isNotNull);
    expect(subscribers!.nextSub, isNull);

    await tester.pumpWidget(const SizedBox());
    expect(count.subs, isNull);

    // A write with nothing listening does not resurrect anything.
    count.value = 1;
    await tester.pump();
    expect(find.text('1'), findsNothing);
  });

  testWidgets('reparenting with a GlobalKey keeps the element reactive', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    final GlobalKey key = GlobalKey();
    final builds = <String>[];
    final Widget reader = _Reader(key: key, signal: count, builds: builds);

    await tester.pumpWidget(_Swap(first: true, child: reader));
    expect(find.text('0'), findsOneWidget);
    final Element element = tester.element(find.byKey(key));

    // Move the subtree to the other parent, and write the signal while the
    // element is between parents.
    await tester.pumpWidget(_Swap(first: false, child: reader));
    expect(identical(tester.element(find.byKey(key)), element), isTrue);

    builds.clear();
    count.value = 1;
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    expect(builds, <String>['reader']);
  });

  testWidgets('an effect that writes a signal is flushed in the same frame', (
    WidgetTester tester,
  ) async {
    final source = Signal<int>(0);
    final derived = Signal<int>(0);
    final effect = Effect(() {
      derived.value = source.value * 2;
    });
    addTearDown(effect.dispose);

    final builds = <String>[];
    await tester.pumpWidget(_Reader(signal: derived, builds: builds));
    expect(find.text('0'), findsOneWidget);

    source.value = 21;
    // One pump: the effect runs before the build, and the build sees its
    // write.
    await tester.pump();
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('a signal written from a transient frame callback lands in that frame', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    await tester.pumpWidget(_Reader(signal: count));

    SchedulerBinding.instance.scheduleFrameCallback((Duration _) {
      count.value = 7;
    });
    await tester.pump();
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('writing a signal during the build that reads it is reported', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          final int value = count.value;
          count.value = value + 1;
          return Text('$value', textDirection: TextDirection.ltr);
        },
      ),
    );

    final Object? exception = tester.takeException();
    expect(exception, isFlutterError);
    expect((exception! as FlutterError).toString(), contains('A signal was written during build'));

    // The write was refused, not applied and then ignored: the build that
    // would have gone stale is the one that is reported, and the value it read
    // is still the value in the signal.
    expect(count.value, 0);
  });

  testWidgets("writing a signal during another element's build is reported", (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);

    await tester.pumpWidget(
      Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          _Reader(signal: count),
          Builder(
            builder: (BuildContext context) {
              // Nothing in this build reads the signal, and the element that
              // does has already been built with the old value.
              count.value = 1;
              return const SizedBox();
            },
          ),
        ],
      ),
    );

    final Object? exception = tester.takeException();
    expect(exception, isFlutterError);
    expect((exception! as FlutterError).toString(), contains('A signal was written during build'));
    expect(count.value, 0);
  });

  testWidgets("writing a signal read by an ancestor's build is reported", (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          // The ancestor reads the signal, and has already been built by the
          // time the descendant below writes it.
          count.value;
          return Builder(
            builder: (BuildContext context) {
              count.value = 1;
              return const SizedBox();
            },
          );
        },
      ),
    );

    final Object? exception = tester.takeException();
    expect(exception, isFlutterError);
    expect((exception! as FlutterError).toString(), contains('A signal was written during build'));
    expect(count.value, 0);
  });

  testWidgets("writing a signal read by a descendant's build is allowed", (
    WidgetTester tester,
  ) async {
    // The framework builds parents before children, so the descendant is still
    // to come and will see the new value. This is the same exemption
    // markNeedsBuild makes for a descendant.
    final rebuild = Signal<int>(0);
    final mirrored = Signal<int>(0);

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          mirrored.value = rebuild.value;
          return Builder(
            builder: (BuildContext context) =>
                Text('${mirrored.value}', textDirection: TextDirection.ltr),
          );
        },
      ),
    );
    expect(find.text('0'), findsOneWidget);

    rebuild.value = 3;
    await tester.pump();
    expect(tester.takeException(), isNull);
    // The invalidation the write queued is drained by the following frame.
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('mirroring a widget field into a signal in initState is allowed', (
    WidgetTester tester,
  ) async {
    // The signal is fresh: nothing has read it, so no build can be left stale.
    final count = Signal<int>(0);

    await tester.pumpWidget(_InitStateWriter(signal: count));

    expect(tester.takeException(), isNull);
    expect(count.value, 1);
  });

  testWidgets('mirroring a widget field into a signal in didUpdateWidget is allowed', (
    WidgetTester tester,
  ) async {
    // didUpdateWidget runs while the parent is the build target, before this
    // element's own build, so the build that reads the signal is still to come.
    final mirrored = Signal<int>(0);

    await tester.pumpWidget(_Mirror(selected: 1, mirrored: mirrored));
    expect(find.text('1'), findsOneWidget);

    await tester.pumpWidget(_Mirror(selected: 2, mirrored: mirrored));
    expect(tester.takeException(), isNull);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('a signal read in didChangeDependencies is not reported as untracked', (
    WidgetTester tester,
  ) async {
    // Reads there are untracked deliberately: didChangeDependencies is not a
    // build, and the build that follows it reads the same values reactively.
    final count = Signal<int>(0);

    await tester.pumpWidget(_DependenciesReader(signal: count));

    expect(tester.takeException(), isNull);
  });

  testWidgets('a signal written from a post-frame callback lands in the next frame', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    final builds = <String>[];
    await tester.pumpWidget(_Reader(signal: count, builds: builds));
    expect(find.text('0'), findsOneWidget);

    builds.clear();
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      count.value = 3;
    });
    // Registering a post-frame callback does not itself ask for a frame.
    tester.binding.scheduleFrame();
    await tester.pump();
    // The callback ran after this frame's build, so the value it wrote is not
    // in it. The frame it needs has been asked for.
    expect(find.text('0'), findsOneWidget);
    expect(builds, isEmpty);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    expect(builds, <String>['reader']);
  });

  testWidgets('a signal written during layout is picked up by the next frame', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);

    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          _Reader(signal: count),
          // LayoutBuilder runs its builder during layout, which is after this
          // frame's flush point.
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              count.value = 1;
              return const SizedBox();
            },
          ),
        ],
      ),
    );

    // Too late for this frame, but the frame it needs has been asked for.
    expect(find.text('0'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pump();
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('hot reload disposes and re-creates the effects created during build', (
    WidgetTester tester,
  ) async {
    final observed = Signal<int>(0);
    var runs = 0;

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          Effect(() {
            observed.value;
            runs += 1;
          });
          return const SizedBox();
        },
      ),
    );
    expect(runs, 1);

    tester.binding.buildOwner!.reassemble(tester.binding.rootElement!);
    await tester.pump();
    // The effect from the previous build was disposed and a new one created,
    // rather than both being left subscribed.
    expect(runs, 2);
    observed.value = 1;
    await tester.pump();
    expect(runs, 3);
  });

  testWidgets('a build subscribes to the signals it reads and to nothing else', (
    WidgetTester tester,
  ) async {
    final read = Signal<int>(0);
    final unread = Signal<int>(0);
    final builds = <String>[];

    await tester.pumpWidget(_Reader(signal: read, builds: builds));
    expect(builds, <String>['reader']);
    expect(read.subs, isNotNull);
    expect(unread.subs, isNull);

    builds.clear();
    unread.value = 1;
    await tester.pump();
    // Writing a signal this build never read rebuilds nothing, and does not
    // even schedule a frame, because nothing is subscribed to it.
    expect(builds, isEmpty);
    expect(unread.subs, isNull);

    read.value = 1;
    await tester.pump();
    expect(builds, <String>['reader']);
  });

  testWidgets('an untracked read in a build does not subscribe', (WidgetTester tester) async {
    final count = Signal<int>(0);
    final builds = <String>[];

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          builds.add('reader');
          return Text('${untracked(() => count.value)}', textDirection: TextDirection.ltr);
        },
      ),
    );
    expect(find.text('0'), findsOneWidget);
    expect(count.subs, isNull);

    builds.clear();
    count.value = 1;
    await tester.pump();
    expect(builds, isEmpty);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('one signal read by two elements rebuilds both, and only both', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    final builds = <String>[];

    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          _Reader(signal: count, builds: builds),
          _Reader(signal: count, builds: builds),
          _Sibling(builds: builds),
        ],
      ),
    );
    expect(builds, <String>['reader', 'reader', 'sibling']);

    builds.clear();
    count.value = 1;
    await tester.pump();
    expect(builds, <String>['reader', 'reader']);
    expect(find.text('1'), findsNWidgets(2));
  });

  testWidgets('a computed chain reaches two elements independently', (WidgetTester tester) async {
    final source = Signal<int>(0);
    final isEven = Computed<bool>(() => source.value.isEven);
    final doubled = Computed<int>(() => source.value * 2);
    addTearDown(isEven.dispose);
    addTearDown(doubled.dispose);

    final builds = <String>[];
    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          Builder(
            builder: (BuildContext context) {
              builds.add('parity');
              return Text('${isEven.value}', textDirection: TextDirection.ltr);
            },
          ),
          Builder(
            builder: (BuildContext context) {
              builds.add('doubled');
              return Text('${doubled.value}', textDirection: TextDirection.ltr);
            },
          ),
        ],
      ),
    );
    expect(builds, <String>['parity', 'doubled']);

    builds.clear();
    source.value = 2;
    await tester.pump();
    // `doubled` changed, `isEven` recomputed to the same value.
    expect(builds, <String>['doubled']);
    expect(find.text('true'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);

    builds.clear();
    source.value = 3;
    await tester.pump();
    expect(builds, <String>['parity', 'doubled']);
    expect(find.text('false'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
  });

  testWidgets('batch in an event handler produces one frame and one rebuild', (
    WidgetTester tester,
  ) async {
    final first = Signal<int>(0);
    final second = Signal<int>(0);
    final builds = <String>[];

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          builds.add('reader');
          return Text('${first.value}/${second.value}', textDirection: TextDirection.ltr);
        },
      ),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);

    builds.clear();
    batch(() {
      first.value = 1;
      // Held back: the batch has not ended, so nothing has been asked for yet.
      expect(tester.binding.hasScheduledFrame, isFalse);
      second.value = 2;
    });
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pump();
    expect(builds, <String>['reader']);
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('an effect that throws during the flush does not stop the rebuilds behind it', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    final effect = Effect(() {
      if (count.value > 0) {
        throw StateError('effect boom');
      }
    });
    addTearDown(effect.dispose);

    final builds = <String>[];
    await tester.pumpWidget(_Reader(signal: count, builds: builds));
    builds.clear();

    count.value = 1;
    await tester.pump();

    expect(tester.takeException(), isStateError);
    // The element behind the failing effect in the queue still rebuilt.
    expect(builds, <String>['reader']);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('an element unmounted while its invalidation is queued is skipped', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          _Reader(signal: count),
          const SizedBox(),
        ],
      ),
    );
    expect(find.text('0'), findsOneWidget);
    expect(hasPendingSignalEffects, isFalse);

    // The reader leaves the tree in the build phase of this frame, and the
    // signal it read is written from a layout callback later in the same
    // frame: the invalidation is queued while the element is inactive, and the
    // element is unmounted before anything drains the queue.
    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          const SizedBox(),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              count.value = 1;
              return const SizedBox();
            },
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(hasPendingSignalEffects, isTrue);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(hasPendingSignalEffects, isFalse);
    expect(count.subs, isNull);
  });

  testWidgets('an invalidation that arrives while an element is inactive is replayed', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    final GlobalKey key = GlobalKey();
    final Widget reader = _Reader(key: key, signal: count);

    Widget tree({required bool moved}) {
      return Column(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          SizedBox(child: moved ? null : reader),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              if (moved) {
                // The reader was deactivated in this frame's build phase and
                // has not been re-adopted yet, so the invalidation this write
                // produces arrives at an inactive element.
                count.value = 1;
                flushSignals();
              }
              return SizedBox(child: moved ? reader : null);
            },
          ),
        ],
      );
    }

    await tester.pumpWidget(tree(moved: false));
    expect(find.text('0'), findsOneWidget);
    final Element element = tester.element(find.byKey(key));

    await tester.pumpWidget(tree(moved: true));
    expect(identical(tester.element(find.byKey(key)), element), isTrue);
    // Replayed on activate: without that, the element keeps the build it made
    // with the old value, and its node stays unarmed for good.
    expect(find.text('1'), findsOneWidget);

    // Still reactive afterwards.
    count.value = 2;
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('a signal read in a LayoutBuilder builder rebuilds it', (WidgetTester tester) async {
    final count = Signal<int>(0);
    var builderRuns = 0;

    await tester.pumpWidget(
      LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          builderRuns += 1;
          return Text('${count.value}', textDirection: TextDirection.ltr);
        },
      ),
    );
    expect(find.text('0'), findsOneWidget);
    expect(builderRuns, 1);

    count.value = 1;
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    expect(builderRuns, 2);

    await tester.pumpWidget(const SizedBox());
    expect(count.subs, isNull);
  });

  testWidgets('a signal read in a ListView.builder item rebuilds the list', (
    WidgetTester tester,
  ) async {
    final labels = List<Signal<String>>.generate(3, (int i) => Signal<String>('item $i'));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ListView.builder(
          itemCount: labels.length,
          itemBuilder: (BuildContext context, int index) {
            return SizedBox(height: const .fixed(100), child: Text(labels[index].value));
          },
        ),
      ),
    );
    expect(find.text('item 1'), findsOneWidget);

    labels[1].value = 'changed';
    await tester.pump();
    expect(find.text('changed'), findsOneWidget);
    expect(find.text('item 1'), findsNothing);
    // The other items are untouched.
    expect(find.text('item 0'), findsOneWidget);
    expect(find.text('item 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    for (final label in labels) {
      expect(label.subs, isNull);
    }
  });

  testWidgets('a signal read while painting is reported as untracked', (WidgetTester tester) async {
    final count = Signal<int>(0);

    await tester.pumpWidget(CustomPaint(size: const Size(10, 10), painter: _SignalPainter(count)));

    final Object? exception = tester.takeException();
    expect(exception, isFlutterError);
    expect(
      (exception! as FlutterError).toString(),
      contains('A signal was read during a frame, outside any tracked scope'),
    );
  });

  testWidgets('a signal read outside a frame is not reported', (WidgetTester tester) async {
    final count = Signal<int>(0);
    await tester.pumpWidget(_Reader(signal: count));

    // An event handler, a timer, a test body: nothing is tracking, and nothing
    // is meant to be.
    expect(count.value, 0);
    count.value = 1;
    expect(count.value, 1);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('an effect created in initState runs once per State, not once per build', (
    WidgetTester tester,
  ) async {
    final observed = Signal<int>(0);
    final rebuildParent = Signal<int>(0);
    final runs = <int>[];

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          rebuildParent.value;
          return _InitStateEffect(signal: observed, runs: runs);
        },
      ),
    );
    expect(runs, <int>[0]);

    // Rebuild the parent, which rebuilds the child. The State survives, so the
    // effect it created in initState is neither disposed nor re-created.
    rebuildParent.value = 1;
    await tester.pump();
    expect(runs, <int>[0]);

    observed.value = 1;
    await tester.pump();
    expect(runs, <int>[0, 1]);

    // Disposed with the element, after State.dispose.
    await tester.pumpWidget(const SizedBox());
    observed.value = 2;
    await tester.pump();
    expect(runs, <int>[0, 1]);
    expect(observed.subs, isNull);
  });

  testWidgets('a computed created in a build still reads correctly after that build is gone', (
    WidgetTester tester,
  ) async {
    final base = Signal<int>(1);
    final rebuild = Signal<int>(0);
    late Computed<int> captured;

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          rebuild.value;
          captured = Computed<int>(() => base.value * 2);
          return Text('${captured.value}', textDirection: TextDirection.ltr);
        },
      ),
    );
    expect(find.text('2'), findsOneWidget);
    final stale = captured;

    rebuild.value = 1;
    await tester.pump();
    // The previous build's scope was disposed, and with it that computed.
    expect(identical(stale, captured), isFalse);

    base.value = 5;
    // A disposed computed is never invalidated, so a cached value would be a
    // lie. It recomputes instead.
    expect(stale.value, 10);
    expect(captured.value, 10);
  });

  testWidgets('a signal read by a stateful build rebuilds it without setState', (
    WidgetTester tester,
  ) async {
    final count = Signal<int>(0);
    await tester.pumpWidget(_StatefulReader(signal: count));
    expect(find.text('0'), findsOneWidget);

    count.value = 5;
    await tester.pump();
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('a signal read by every item builder of a lazy sliver keeps one subscription', (
    WidgetTester tester,
  ) async {
    final shared = Signal<int>(0);
    final perRow = <int, Signal<int>>{};

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ListView.builder(
          itemCount: 200,
          itemExtent: 50,
          itemBuilder: (BuildContext context, int index) {
            // Read from the delegate builder itself, so every one of the
            // materialized rows reads through the sliver's single tracking
            // node. The per-row signal is read first, so the shared read is
            // never the one at the tail of the dependency list, which is what
            // used to make every row append another edge.
            final Signal<int> row = perRow.putIfAbsent(index, () => Signal<int>(index));
            return SizedBox(height: const .fixed(50), child: Text('${row.value}:${shared.value}'));
          },
        ),
      ),
    );
    expect(find.text('0:0'), findsOneWidget);
    expect(_countSubs(shared), 1);

    for (var drag = 0; drag < 20; drag += 1) {
      await tester.drag(find.byType(ListView), const Offset(0, -100));
      await tester.pump();
      // The sliver builds children one at a time across many layout passes,
      // retaining its dependencies. Repeated reads of the same signal must
      // reuse the one link instead of appending a new one per call.
      expect(_countSubs(shared), 1, reason: 'after drag $drag');
    }

    // The subscription is still live: a write rebuilds the visible rows.
    shared.value = 7;
    await tester.pump();
    expect(find.textContaining(':7'), findsWidgets);
    expect(_countSubs(shared), 1);
  });
}

/// The number of edges in [signal]'s subscriber list.
int _countSubs(Signal<Object?> signal) {
  var count = 0;
  for (Link? link = signal.subs; link != null; link = link.nextSub) {
    count += 1;
  }
  return count;
}

class _Parent extends StatelessWidget {
  const _Parent({required this.builds, required this.sibling, required this.child});

  final List<String> builds;
  final Widget child;
  final Widget sibling;

  @override
  Widget build(BuildContext context) {
    builds.add('parent');
    return Column(textDirection: TextDirection.ltr, children: <Widget>[child, sibling]);
  }
}

class _Sibling extends StatelessWidget {
  const _Sibling({required this.builds});

  final List<String> builds;

  @override
  Widget build(BuildContext context) {
    builds.add('sibling');
    return const SizedBox();
  }
}

class _Swap extends StatelessWidget {
  const _Swap({required this.first, required this.child});

  final bool first;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      textDirection: TextDirection.ltr,
      children: <Widget>[
        SizedBox(child: first ? child : null),
        SizedBox(child: first ? null : child),
      ],
    );
  }
}

class _SignalPainter extends CustomPainter {
  const _SignalPainter(this.count);

  final Signal<int> count;

  @override
  void paint(Canvas canvas, Size size) {
    // Nothing tracks a painter, so this read is a trap: the painting is right
    // once and stale from then on.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, count.value.toDouble(), 1),
      Paint()..color = const Color(0xFF000000),
    );
  }

  @override
  bool shouldRepaint(_SignalPainter oldDelegate) => true;
}

class _InitStateWriter extends StatefulWidget {
  const _InitStateWriter({required this.signal});

  final Signal<int> signal;

  @override
  State<_InitStateWriter> createState() => _InitStateWriterState();
}

class _InitStateWriterState extends State<_InitStateWriter> {
  @override
  void initState() {
    super.initState();
    widget.signal.value = 1;
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _InitStateEffect extends StatefulWidget {
  const _InitStateEffect({required this.signal, required this.runs});

  final Signal<int> signal;
  final List<int> runs;

  @override
  State<_InitStateEffect> createState() => _InitStateEffectState();
}

class _InitStateEffectState extends State<_InitStateEffect> {
  @override
  void initState() {
    super.initState();
    // Owned by the element, not by a build: created once, disposed on unmount.
    Effect(() => widget.runs.add(widget.signal.value));
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _Mirror extends StatefulWidget {
  const _Mirror({required this.selected, required this.mirrored});

  final int selected;
  final Signal<int> mirrored;

  @override
  State<_Mirror> createState() => _MirrorState();
}

class _MirrorState extends State<_Mirror> {
  @override
  void initState() {
    super.initState();
    widget.mirrored.value = widget.selected;
  }

  @override
  void didUpdateWidget(_Mirror oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.mirrored.value = widget.selected;
  }

  @override
  Widget build(BuildContext context) {
    return Text('${widget.mirrored.value}', textDirection: TextDirection.ltr);
  }
}

class _DependenciesReader extends StatefulWidget {
  const _DependenciesReader({required this.signal});

  final Signal<int> signal;

  @override
  State<_DependenciesReader> createState() => _DependenciesReaderState();
}

class _DependenciesReaderState extends State<_DependenciesReader> {
  int _seen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _seen = widget.signal.value;
  }

  @override
  Widget build(BuildContext context) => Text('$_seen', textDirection: TextDirection.ltr);
}

class _StatefulReader extends StatefulWidget {
  const _StatefulReader({required this.signal});

  final Signal<int> signal;

  @override
  State<_StatefulReader> createState() => _StatefulReaderState();
}

class _StatefulReaderState extends State<_StatefulReader> {
  @override
  Widget build(BuildContext context) {
    return Text('${widget.signal.value}', textDirection: TextDirection.ltr);
  }
}
