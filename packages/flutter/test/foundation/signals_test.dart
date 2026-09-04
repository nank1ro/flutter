// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';
// `Link` is intentionally not exported from `foundation.dart`; the graph
// internals these tests inspect come from the source file directly.
import 'package:flutter/src/foundation/signals.dart' show Link, ReactiveNode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    // No test may leave a scheduler installed, or a queue undrained.
    signalFlushScheduler = null;
    flushSignals();
  });

  test('signal reads and writes', () {
    final count = Signal<int>(0);
    expect(count.value, 0);
    expect(count(), 0);
    expect(count.peek, 0);
    count.value = 1;
    expect(count.value, 1);
    count.value += 1;
    expect(count.value, 2);
  });

  test('computed derives and caches', () {
    final count = Signal<int>(2);
    var computations = 0;
    final doubled = Computed<int>((int? previous) {
      computations += 1;
      return count.value * 2;
    });
    expect(doubled.value, 4);
    expect(doubled.value, 4);
    expect(computations, 1);
    count.value = 3;
    expect(doubled(), 6);
    expect(computations, 2);
  });

  test('computed receives the previous value', () {
    final count = Signal<int>(1);
    final seen = <int?>[];
    final sum = Computed<int>((int? previous) {
      seen.add(previous);
      return (previous ?? 0) + count.value;
    });
    expect(sum.value, 1);
    count.value = 10;
    expect(sum.value, 11);
    expect(seen, <int?>[null, 1]);
  });

  test('effect runs immediately and on change, and stops when disposed', () {
    final count = Signal<int>(0);
    final seen = <int>[];
    final effect = Effect(() => seen.add(count.value));
    expect(seen, <int>[0]);
    count.value = 1;
    expect(seen, <int>[0, 1]);
    effect.dispose();
    count.value = 2;
    expect(seen, <int>[0, 1]);
    expect(count.subs, isNull);
  });

  test('writing an identical value does not run effects', () {
    final count = Signal<int>(0);
    var runs = 0;
    Effect(() {
      count.value;
      runs += 1;
    });
    expect(runs, 1);
    count.value = 0;
    expect(runs, 1);
  });

  test('diamond dependency is glitch-free', () {
    final source = Signal<int>(1);
    final left = Computed<int>((int? _) => source.value * 2);
    final right = Computed<int>((int? _) => source.value + 10);
    final seen = <int>[];
    Effect(() => seen.add(left.value + right.value));
    expect(seen, <int>[13]);
    source.value = 2;
    // One run per write, with both branches already consistent.
    expect(seen, <int>[13, 16]);
    source.value = 3;
    expect(seen, <int>[13, 16, 19]);
  });

  test('an unchanged computed does not re-run its subscribers', () {
    final count = Signal<int>(1);
    final isPositive = Computed<bool>((bool? _) => count.value > 0);
    var runs = 0;
    Effect(() {
      isPositive.value;
      runs += 1;
    });
    expect(runs, 1);
    count.value = 2; // Still positive, so the effect must not re-run.
    expect(runs, 1);
    count.value = -1;
    expect(runs, 2);
  });

  test('batch defers effects until the outermost batch ends', () {
    final a = Signal<int>(0);
    final b = Signal<int>(0);
    final seen = <String>[];
    Effect(() => seen.add('${a.value}:${b.value}'));
    expect(seen, <String>['0:0']);
    batch(() {
      a.value = 1;
      b.value = 1;
      expect(a.value, 1); // Reads stay immediately consistent inside a batch.
      expect(seen, <String>['0:0']);
      batch(() {
        a.value = 2;
      });
      expect(seen, <String>['0:0']);
    });
    expect(seen, <String>['0:0', '2:1']);
  });

  test('batch returns the value of its body', () {
    expect(batch<int>(() => 42), 42);
  });

  test('untracked reads do not subscribe', () {
    final tracked = Signal<int>(0);
    final hidden = Signal<int>(0);
    var runs = 0;
    Effect(() {
      tracked.value;
      untracked(() => hidden.value);
      runs += 1;
    });
    expect(runs, 1);
    hidden.value = 1;
    expect(runs, 1);
    tracked.value = 1;
    expect(runs, 2);
  });

  test('peek does not subscribe', () {
    final tracked = Signal<int>(0);
    final hidden = Signal<int>(0);
    final hiddenPlusOne = Computed<int>((int? _) => hidden.value + 1);
    var runs = 0;
    Effect(() {
      tracked.value;
      hidden.peek;
      hiddenPlusOne.peek;
      runs += 1;
    });
    expect(runs, 1);
    hidden.value = 1;
    expect(runs, 1);
    expect(hiddenPlusOne.peek, 2);
  });

  test('owner disposes the effects created inside it, and nested owners', () {
    final count = Signal<int>(0);
    final seen = <String>[];
    final outer = Owner();
    late Owner inner;
    outer.run(() {
      expect(Owner.current, outer);
      Effect(() => seen.add('outer ${count.value}'));
      inner = Owner();
      inner.run(() {
        expect(Owner.current, inner);
        Effect(() => seen.add('inner ${count.value}'));
      });
    });
    expect(Owner.current, isNull);
    expect(seen, <String>['outer 0', 'inner 0']);

    seen.clear();
    count.value = 1;
    expect(seen, <String>['outer 1', 'inner 1']);

    seen.clear();
    inner.dispose();
    count.value = 2;
    expect(seen, <String>['outer 2']);

    seen.clear();
    outer.dispose();
    count.value = 3;
    expect(seen, isEmpty);
    expect(count.subs, isNull);
  });

  test('disposing an owner disposes nested owners', () {
    final count = Signal<int>(0);
    var runs = 0;
    final outer = Owner();
    outer.run(() {
      Owner().run(() {
        Effect(() {
          count.value;
          runs += 1;
        });
      });
    });
    expect(runs, 1);
    outer.dispose();
    count.value = 1;
    expect(runs, 1);
    expect(count.subs, isNull);
  });

  test('an effect nested in another effect is disposed with it', () {
    final outerSignal = Signal<int>(0);
    final innerSignal = Signal<int>(0);
    var innerRuns = 0;
    final outer = Effect(() {
      outerSignal.value;
      Effect(() {
        innerSignal.value;
        innerRuns += 1;
      });
    });
    expect(innerRuns, 1);
    innerSignal.value = 1;
    expect(innerRuns, 2);
    outer.dispose();
    innerSignal.value = 2;
    expect(innerRuns, 2);
    expect(innerSignal.subs, isNull);
  });

  test('a nested effect and a sibling effect both run in one batch', () {
    final a = Signal<int>(0);
    final b = Signal<int>(0);
    final c = Signal<int>(0);
    final seen = <String>[];
    Effect(() {
      b.value;
      Effect(() {
        a.value;
        seen.add('nested');
      });
    });
    Effect(() {
      c.value;
      seen.add('sibling');
    });
    seen.clear();
    batch(() {
      a.value = 1;
      c.value = 1;
    });
    expect(seen, <String>['nested', 'sibling']);
  });

  test('an effect that writes a signal it reads terminates', () {
    final count = Signal<int>(0);
    var runs = 0;
    Effect(() {
      runs += 1;
      count.value = count.value + 1;
    });
    expect(runs, 1);
    expect(count.value, 1);
    // A write from outside still reaches the effect, and still terminates.
    count.value = 10;
    expect(runs, 2);
    expect(count.value, 11);
  });

  test('a computed is not recomputed while nothing observes it', () {
    final count = Signal<int>(0);
    var computations = 0;
    final doubled = Computed<int>((int? _) {
      computations += 1;
      return count.value * 2;
    });
    expect(computations, 0); // Lazy: no read yet.
    expect(doubled.value, 0);
    expect(computations, 1);
    for (var i = 1; i <= 5; i += 1) {
      count.value = i;
    }
    expect(computations, 1); // Nothing observed it, so nothing recomputed.
    expect(doubled.value, 10);
    expect(computations, 2);
  });

  test('dependencies change with what was actually read', () {
    final useFirst = Signal<bool>(true);
    final first = Signal<int>(1);
    final second = Signal<int>(2);
    final seen = <int>[];
    Effect(() => seen.add(useFirst.value ? first.value : second.value));
    expect(seen, <int>[1]);

    second.value = 20; // Not a dependency yet.
    expect(seen, <int>[1]);

    useFirst.value = false;
    expect(seen, <int>[1, 20]);

    first.value = 10; // No longer a dependency.
    expect(seen, <int>[1, 20]);
    expect(first.subs, isNull);

    second.value = 21;
    expect(seen, <int>[1, 20, 21]);
  });

  test('the flush scheduler hook defers effects until flushSignals', () {
    var scheduled = 0;
    signalFlushScheduler = () => scheduled += 1;

    final count = Signal<int>(0);
    final seen = <int>[];
    Effect(() => seen.add(count.value));
    expect(seen, <int>[0]); // The first run is always immediate.
    expect(scheduled, 0);

    count.value = 1;
    expect(scheduled, 1);
    expect(seen, <int>[0]); // Deferred.
    count.value = 2;
    expect(seen, <int>[0]);
    expect(count.value, 2); // Reads stay immediately consistent.

    flushSignals();
    expect(seen, <int>[0, 2]); // Coalesced into one run.

    flushSignals(); // Draining an empty queue is a no-op.
    expect(seen, <int>[0, 2]);

    // A write that queues nothing schedules nothing.
    scheduled = 0;
    final unobserved = Signal<int>(0);
    unobserved.value = 1;
    expect(unobserved.value, 1);
    expect(scheduled, 0);
  });

  test('a tracking node reports invalidation instead of re-running', () {
    final count = Signal<int>(0);
    var invalidations = 0;
    final node = TrackingNode(() => invalidations += 1);

    int tracked = node.track<int>(() => count.value);
    expect(tracked, 0);
    expect(invalidations, 0);

    count.value = 1;
    expect(invalidations, 1);

    // A tracking node is re-armed by tracking again, not by being invalidated.
    count.value = 2;
    expect(invalidations, 1);

    tracked = node.track<int>(() => count.value);
    expect(tracked, 2);
    count.value = 3;
    expect(invalidations, 2);

    node.dispose();
    count.value = 4;
    expect(invalidations, 2);
    expect(count.subs, isNull);
  });

  test('steady state writes reuse the graph and allocate nothing', () {
    // The Dart VM exposes no allocation counter to `flutter test`, so this
    // asserts the property that matters instead: in steady state the graph
    // reuses the very same Link objects, so a signal written every frame
    // allocates nothing per write.
    final count = Signal<int>(0);
    var runs = 0;
    final effect = Effect(() {
      count.value;
      runs += 1;
    });
    final Link link = count.subs!;
    expect(identical(effect.deps, link), isTrue);

    for (var i = 1; i <= 10000; i += 1) {
      count.value = i;
    }

    expect(runs, 10001);
    expect(identical(count.subs, link), isTrue);
    expect(identical(count.subsTail, link), isTrue);
    expect(link.nextSub, isNull);
    expect(identical(effect.deps, link), isTrue);
    expect(identical(effect.depsTail, link), isTrue);
    expect(link.nextDep, isNull);
    effect.dispose();
  });

  test('a computed whose computation throws is retried on the next read', () {
    final source = Signal<int>(1);
    var fail = true;
    var computations = 0;
    final derived = Computed<int>((int? _) {
      computations += 1;
      if (fail) {
        throw StateError('compute failed');
      }
      return source.value * 2;
    });

    expect(() => derived.value, throwsStateError);
    expect(computations, 1);

    // The failed run must not be cached: the next read recomputes.
    fail = false;
    expect(derived.value, 2);
    expect(computations, 2);

    // And the retried run wired up its dependencies properly.
    source.value = 5;
    expect(derived.value, 10);
    expect(computations, 3);
    derived.dispose();
  });

  test('an effect that throws does not drop the rest of the queue', () {
    final count = Signal<int>(0);
    final seen = <String>[];
    Effect(() {
      if (count.value > 0) {
        throw StateError('effect failed');
      }
      seen.add('first ${count.value}');
    });
    final second = Effect(() => seen.add('second ${count.value}'));
    expect(seen, <String>['first 0', 'second 0']);

    seen.clear();
    final List<FlutterErrorDetails> errors = _collectErrors(() => count.value = 1);
    expect(errors, hasLength(1));
    expect(errors.single.exception, isStateError);
    expect(errors.single.library, 'foundation library');
    // The effect queued behind the failing one still ran.
    expect(seen, <String>['second 1']);

    // The failing effect stays armed and recovers.
    seen.clear();
    count.value = 0;
    expect(seen, <String>['first 0', 'second 0']);
    second.dispose();
  });

  test('an effect whose first run throws is still returned and disposable', () {
    final count = Signal<int>(0);
    late final Effect effect;
    final List<FlutterErrorDetails> errors = _collectErrors(() {
      effect = Effect(() {
        count.value;
        throw StateError('first run failed');
      });
    });
    expect(errors, hasLength(1));
    expect(errors.single.exception, isStateError);
    expect(count.subs, isNotNull);
    effect.dispose();
    expect(count.subs, isNull);
  });

  test('batch does not replace the body exception with an effect exception', () {
    final count = Signal<int>(0);
    final effect = Effect(() {
      if (count.value > 0) {
        throw StateError('effect failed');
      }
    });
    final List<FlutterErrorDetails> errors = _collectErrors(() {
      expect(
        () => batch<void>(() {
          count.value = 1;
          throw ArgumentError('body failed');
        }),
        throwsArgumentError,
      );
    });
    expect(errors.single.exception, isStateError);
    effect.dispose();
  });

  test('Owner.run does not subscribe the owner to what its body reads', () {
    final count = Signal<int>(0);
    final owner = Owner();
    for (var i = 0; i < 3; i += 1) {
      expect(owner.run<int>(() => count.value), 0);
    }
    expect(count.subs, isNull);
    expect(owner.deps, isNull);
    owner.dispose();
  });

  test('Owner.current is the same on an effect re-run as on the first run', () {
    final count = Signal<int>(0);
    final owner = Owner();
    final seen = <Owner?>[];
    owner.run(() {
      Effect(() {
        count.value;
        seen.add(Owner.current);
      });
    });
    expect(seen, <Owner?>[owner]);
    count.value = 1;
    expect(seen, <Owner?>[owner, owner]);
    owner.dispose();
  });

  test('an effect created inside untracked is still owned by the scope', () {
    final count = Signal<int>(0);
    var runs = 0;
    final owner = Owner();
    owner.run(() {
      untracked(() {
        expect(Owner.current, owner);
        Effect(() {
          count.value;
          runs += 1;
        });
      });
    });
    expect(runs, 1);
    count.value = 1;
    expect(runs, 2);
    owner.dispose();
    count.value = 2;
    expect(runs, 2);
    expect(count.subs, isNull);
  });

  test('a computed is disposed with the owner that created it', () {
    final count = Signal<int>(0);
    final owner = Owner();
    late final Computed<int> doubled;
    final seen = <int>[];
    owner.run(() {
      doubled = Computed<int>((int? _) => count.value * 2);
      Effect(() => seen.add(doubled.value));
    });
    expect(seen, <int>[0]);
    count.value = 1;
    expect(seen, <int>[0, 2]);

    owner.dispose();
    expect(doubled.deps, isNull);
    expect(doubled.subs, isNull);
    expect(count.subs, isNull);
  });

  test('disposing a computed releases the long-lived signal it reads', () {
    final count = Signal<int>(0);
    final doubled = Computed<int>((int? _) => count.value * 2);
    expect(doubled.peek, 0);
    expect(count.subs, isNotNull);

    doubled.dispose();
    expect(count.subs, isNull);
    expect(doubled.deps, isNull);
  });

  test('a retaining run reads the same signal from several calls through one link', () {
    // A lazy sliver tracks one logical run as many separate calls, one per
    // child. All of them share a version, so a signal several of them read is
    // linked once rather than once per call.
    final shared = Signal<int>(0);
    final perCall = <Signal<int>>[Signal<int>(0), Signal<int>(1), Signal<int>(2)];
    var invalidations = 0;
    final node = TrackingNode(() => invalidations += 1);

    for (final own in perCall) {
      // Reading the per-call signal first moves the tail off the shared one,
      // which is what a plain append would grow the subscriber list on.
      node.track<void>(() {
        own.value;
        shared.value;
      }, retainDeps: true);
    }
    expect(_countSubs(shared), 1);
    for (final own in perCall) {
      expect(_countSubs(own), 1);
    }

    // Still subscribed: the retained link is a live edge, not a leftover.
    shared.value = 1;
    flushSignals();
    expect(invalidations, 1);

    // A full run starts over: the dependencies of the retaining run are gone.
    node.track<void>(() {});
    expect(shared.subs, isNull);
    for (final own in perCall) {
      expect(own.subs, isNull);
    }
    node.dispose();
  });

  test('tracking through a disposed subscriber does not revive it', () {
    final count = Signal<int>(0);
    var invalidations = 0;
    final node = TrackingNode(() => invalidations += 1);
    node.track<int>(() => count.value);
    node.dispose();

    expect(() => node.track<int>(() => count.value), throwsAssertionError);
    expect(count.subs, isNull);
    count.value = 1;
    expect(invalidations, 0);
  });

  test('a subscriber that disposes itself mid-run does not relink', () {
    final a = Signal<int>(0);
    final b = Signal<int>(0);
    var stop = false;
    late final Effect effect;
    effect = Effect(() {
      a.value;
      if (stop) {
        effect.dispose();
        b.value;
      }
    });
    expect(a.subs, isNotNull);

    stop = true;
    a.value = 1;
    expect(a.subs, isNull);
    expect(b.subs, isNull);
    expect(effect.deps, isNull);
  });

  test('a disposed computed still reads the current value, uncached', () {
    final count = Signal<int>(1);
    var computations = 0;
    final doubled = Computed<int>((int? _) {
      computations += 1;
      return count.value * 2;
    });
    expect(doubled.value, 2);
    expect(computations, 1);

    doubled.dispose();
    count.value = 5;
    // Disposed, so nothing invalidated it; the cached 2 would be a lie.
    expect(doubled.value, 10);
    expect(computations, 2);
    // Recomputed on every read now, and still not subscribed to anything.
    expect(doubled.value, 10);
    expect(computations, 3);
    expect(count.subs, isNull);
    expect(doubled.deps, isNull);
  });

  test('the flush scheduler is called on every write that queues something', () {
    // Deliberately once per write, not once per queue: the scheduler is
    // idempotent, and a latch that remembered "already asked" would stick shut
    // for good the first time a binding declined to schedule the frame.
    var scheduled = 0;
    signalFlushScheduler = () => scheduled += 1;

    final count = Signal<int>(0);
    final effect = Effect(() => count.value);
    count.value = 1;
    count.value = 2;
    count.value = 3;
    expect(scheduled, 3);

    flushSignals();
    count.value = 4;
    expect(scheduled, 4);

    flushSignals();
    // A write with nothing subscribed queues nothing, so schedules nothing.
    final unobserved = Signal<int>(0);
    unobserved.value = 1;
    expect(scheduled, 4);

    effect.dispose();
  });

  test('the flush scheduler is not called for writes made during a flush', () {
    var scheduled = 0;
    final source = Signal<int>(0);
    final derived = Signal<int>(0);
    var scheduledDuringFlush = 0;
    final writer = Effect(() {
      derived.value = source.value * 2;
      scheduledDuringFlush = scheduled;
    });
    final reader = Effect(() => derived.value);
    signalFlushScheduler = () => scheduled += 1;

    source.value = 21;
    expect(scheduled, 1); // The write itself asked for a drain.
    flushSignals();
    // `writer` wrote `derived` while the queue was draining. That write was
    // picked up by the running drain, and asked for nothing.
    expect(scheduled, 1);
    expect(scheduledDuringFlush, 1);
    expect(derived.value, 42);

    writer.dispose();
    reader.dispose();
  });

  test('a write from inside a flush does not start a nested flush', () {
    final a = Signal<int>(0);
    final b = Signal<int>(0);
    final seen = <String>[];
    Effect(() => seen.add('a${a.value}'));
    final writer = Effect(() {
      b.value;
      a.value = a.peek + 1;
    });
    seen.clear();

    b.value = 1;
    // `writer` bumped `a` from 1 to 2 while the flush was already draining.
    // That write was picked up by the running drain rather than starting a
    // nested one, so the observing effect ran exactly once, with the final
    // value.
    expect(seen, <String>['a2']);
    writer.dispose();
  });

  test('signal writes compare with == , not identity', () {
    final equalButNew = String.fromCharCodes(<int>[104, 105]);
    expect(equalButNew, 'hi');
    expect(identical(equalButNew, 'hi'), isFalse);

    final label = Signal<String>('hi');
    var runs = 0;
    final effect = Effect(() {
      label.value;
      runs += 1;
    });
    expect(runs, 1);

    label.value = equalButNew;
    expect(runs, 1); // Equal, so nothing propagated.
    label.value = 'bye';
    expect(runs, 2);
    effect.dispose();
  });

  test('a computed that recomputes to an equal value does not propagate', () {
    final count = Signal<int>(1);
    // Interpolation builds a new string every run, equal but never identical.
    final label = Computed<String>((String? _) => 'positive=${count.value > 0}');
    var runs = 0;
    final effect = Effect(() {
      label.value;
      runs += 1;
    });
    expect(runs, 1);

    count.value = 2;
    expect(label.value, 'positive=true');
    expect(runs, 1); // Equal result, so the effect did not re-run.

    count.value = -1;
    expect(runs, 2);
    effect.dispose();
  });

  test('rerun runs an effect again', () {
    final count = Signal<int>(0);
    var runs = 0;
    final effect = Effect(() {
      count.value;
      runs += 1;
    });
    expect(runs, 1);

    effect.rerun();
    expect(runs, 2);

    effect.dispose();
    effect.rerun(); // A disposed subscriber is ignored.
    expect(runs, 2);
  });

  test('rerun leaves a queued effect alone, so the queue is not corrupted', () {
    final a = Signal<int>(0);
    final b = Signal<int>(0);
    var aRuns = 0;
    var bRuns = 0;
    final ea = Effect(() {
      a.value;
      aRuns += 1;
    });
    final eb = Effect(() {
      b.value;
      bRuns += 1;
    });
    expect(<int>[aRuns, bRuns], <int>[1, 1]);

    batch<void>(() {
      a.value = 1; // queues ea
      b.value = 1; // queues eb behind it
      // ea is waiting in the queue. Running it here would re-arm it, and the
      // write below would then queue it a second time, overwriting its link
      // to eb and dropping eb from the queue for good.
      ea.rerun();
      a.value = 2;
    });
    expect(<int>[aRuns, bRuns], <int>[2, 2]);

    // eb is still watching its signal.
    b.value = 2;
    expect(bRuns, 3);

    ea.dispose();
    eb.dispose();
  });
}

/// The number of edges in [node]'s subscriber list.
int _countSubs(ReactiveNode node) {
  var count = 0;
  for (Link? link = node.subs; link != null; link = link.nextSub) {
    count += 1;
  }
  return count;
}

/// Runs [body] with [FlutterError.onError] capturing instead of failing the
/// test, and returns whatever was reported.
List<FlutterErrorDetails> _collectErrors(VoidCallback body) {
  final errors = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    body();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}
