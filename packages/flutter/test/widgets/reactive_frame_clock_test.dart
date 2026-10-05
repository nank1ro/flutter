// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The fixed-timestep game loop: how many simulation steps a display frame
// runs, that pausing stops them, and that a frame's worth of writes produces
// exactly one effect flush.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the fixed timestep runs one step per timestep of elapsed time', (
    WidgetTester tester,
  ) async {
    var steps = 0;
    final clock = FrameClock(
      simulate: (double dt) {
        expect(dt, closeTo(0.01, 1e-9));
        steps += 1;
      },
      fixedTimestep: const Duration(milliseconds: 10),
    );
    addTearDown(clock.dispose);

    await tester.pumpWidget(const SizedBox());
    clock.start();

    // The first tick establishes the ticker's zero, so no time has elapsed
    // and nothing is simulated.
    await tester.pump(const Duration(milliseconds: 100));
    expect(steps, 0);
    expect(clock.frame.peek, 1);

    await tester.pump(const Duration(milliseconds: 100));
    expect(steps, 10);
    expect(clock.frame.peek, 2);
    expect(clock.time.peek, const Duration(milliseconds: 100));
    expect(clock.alpha.peek, 0);

    // A partial step is left in the accumulator and shows up in alpha.
    await tester.pump(const Duration(milliseconds: 25));
    expect(steps, 12);
    expect(clock.alpha.peek, closeTo(0.5, 1e-9));

    clock.stop();
  });

  testWidgets('pausing stops the simulation and discards the paused time', (
    WidgetTester tester,
  ) async {
    var steps = 0;
    final clock = FrameClock(
      simulate: (double dt) => steps += 1,
      fixedTimestep: const Duration(milliseconds: 10),
    );
    addTearDown(clock.dispose);

    await tester.pumpWidget(const SizedBox());
    clock.start();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 100));
    expect(steps, 10);

    clock.paused = true;
    final int frameAtPause = clock.frame.peek;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(steps, 10);
    expect(clock.frame.peek, frameAtPause);

    clock.paused = false;
    // The first tick after resuming re-establishes the baseline; the 200ms
    // spent paused is never simulated.
    await tester.pump(const Duration(milliseconds: 10));
    expect(steps, 10);
    await tester.pump(const Duration(milliseconds: 50));
    expect(steps, 15);

    clock.stop();
  });

  testWidgets('a gap longer than the catch-up limit is discarded, not simulated', (
    WidgetTester tester,
  ) async {
    var steps = 0;
    final clock = FrameClock(
      simulate: (double dt) => steps += 1,
      fixedTimestep: const Duration(milliseconds: 10),
    );
    addTearDown(clock.dispose);

    await tester.pumpWidget(const SizedBox());
    clock.start();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 100));
    expect(steps, 10);

    // Five seconds between two ticks is a pause — a muted ticker, a
    // backgrounded app — not five seconds of simulation to catch up on.
    await tester.pump(const Duration(seconds: 5));
    expect(steps, 10);
    expect(clock.alpha.peek, 0);

    // Time carries on from there.
    await tester.pump(const Duration(milliseconds: 50));
    expect(steps, 15);

    clock.stop();
  });

  testWidgets('a frame of simulation writes produces exactly one effect run', (
    WidgetTester tester,
  ) async {
    final x = Signal<double>(0);
    final y = Signal<double>(0);
    var effectRuns = 0;
    final effect = Effect(() {
      x.value;
      y.value;
      effectRuns += 1;
    });
    addTearDown(effect.dispose);
    expect(effectRuns, 1);

    final clock = FrameClock(
      simulate: (double dt) {
        x.value += 1;
        y.value += 1;
      },
      fixedTimestep: const Duration(milliseconds: 10),
    );
    addTearDown(clock.dispose);

    await tester.pumpWidget(const SizedBox());
    clock.start();
    await tester.pump(const Duration(milliseconds: 10));
    effectRuns = 0;

    // 100ms of elapsed time is ten simulation steps, twenty signal writes.
    await tester.pump(const Duration(milliseconds: 100));
    expect(x.peek, 10);
    expect(effectRuns, 1);

    await tester.pump(const Duration(milliseconds: 100));
    expect(x.peek, 20);
    expect(effectRuns, 2);

    clock.stop();
  });

  testWidgets('pumping frames moves a bound render object and rebuilds nothing', (
    WidgetTester tester,
  ) async {
    final position = Signal<Offset>(Offset.zero);
    var builds = 0;

    final clock = FrameClock(
      simulate: (double dt) => position.value = position.peek + Offset(dt * 100, 0),
      fixedTimestep: const Duration(milliseconds: 10),
    );
    addTearDown(clock.dispose);

    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          builds += 1;
          return ReactiveOffset(
            offset: position,
            child: const SizedBox(width: .fixed(10), height: .fixed(10)),
          );
        },
      ),
    );
    final RenderReactiveOffset renderObject = tester.renderObject<RenderReactiveOffset>(
      find.byType(ReactiveOffset),
    );
    expect(builds, 1);

    clock.start();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 100));

    // Ten steps of 10ms at 100 logical pixels per second.
    expect(renderObject.offset.dx, closeTo(10, 1e-9));
    expect(builds, 1);

    clock.stop();
  });

  testWidgets('a clock can be driven by a TickerProvider', (WidgetTester tester) async {
    var steps = 0;
    late FrameClock clock;

    await tester.pumpWidget(
      _VsyncHost(
        onCreate: (TickerProvider vsync) {
          clock = FrameClock.withVsync(
            vsync: vsync,
            simulate: (double dt) => steps += 1,
            fixedTimestep: const Duration(milliseconds: 10),
          )..start();
          return clock;
        },
      ),
    );

    // The ticker's first tick lands in the frame that mounted the host, so
    // 110ms of elapsed time is eleven steps.
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 100));
    expect(steps, 11);

    // Unmounting the host disposes the ticker with the State.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
    expect(steps, 11);
  });
}

/// Hosts a [FrameClock] built from a [State]'s [TickerProvider].
class _VsyncHost extends StatefulWidget {
  const _VsyncHost({required this.onCreate});

  final FrameClock Function(TickerProvider vsync) onCreate;

  @override
  State<_VsyncHost> createState() => _VsyncHostState();
}

class _VsyncHostState extends State<_VsyncHost> with SingleTickerProviderStateMixin {
  late final FrameClock _clock;

  @override
  void initState() {
    super.initState();
    _clock = widget.onCreate(this);
  }

  @override
  void dispose() {
    _clock
      ..stop()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
