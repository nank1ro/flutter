// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// @docImport 'reactive_widgets.dart';
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Signature for a fixed-timestep simulation step.
///
/// [dt] is the fixed step, in seconds. It is the same value on every call,
/// which is the point of a fixed timestep: the simulation is deterministic and
/// independent of the display's refresh rate.
typedef SimulationStep = void Function(double dt);

/// Drives a signal-based game loop from a [Ticker].
///
/// A frame clock publishes three signals — [time], [frame] and [alpha] — and
/// runs a fixed-timestep simulation. Every write it makes in one display frame
/// happens inside one [batch], so a step that writes ten thousand signals
/// still produces exactly one effect flush, at the frame's flush point, before
/// layout and paint.
///
/// ```dart
/// final Signal<double> x = Signal<double>(0);
/// final FrameClock clock = FrameClock(simulate: (double dt) => x.value += 60 * dt)..start();
/// // ReactiveOffset(offset: () => Offset(x.value, 0), child: sprite)
/// ```
///
/// The hot path allocates nothing. The tick callback and the batch body are
/// method references stored in fields rather than closures built per frame,
/// the accumulator is integer microseconds rather than [Duration] arithmetic,
/// and no list or map is touched. What is left is the three signal writes per
/// frame, which reuse their graph edges.
///
/// Pause with [paused], which mutes the ticker; the elapsed time that passes
/// while paused is not simulated when it resumes. Time lost some other way —
/// a muted `TickerMode`, a backgrounded app, a breakpoint — is discarded the
/// same way, as long as the gap between two ticks is longer than 250 ms.
///
/// A clock created with the default constructor owns a bare [Ticker] and needs
/// no widget, so a simulation can run under [WidgetsBinding] alone. Use
/// [FrameClock.withVsync] inside a [State] with a [TickerProvider] so that the
/// ticker is muted with the rest of the route.
class FrameClock {
  /// Creates a frame clock driven by its own [Ticker].
  FrameClock({required this.simulate, this.fixedTimestep = const Duration(microseconds: 16667)})
    : assert(fixedTimestep > Duration.zero) {
    _ticker = Ticker(_onTick, debugLabel: 'FrameClock');
  }

  /// Creates a frame clock driven by a [Ticker] from [vsync].
  FrameClock.withVsync({
    required TickerProvider vsync,
    required this.simulate,
    this.fixedTimestep = const Duration(microseconds: 16667),
  }) : assert(fixedTimestep > Duration.zero) {
    _ticker = vsync.createTicker(_onTick);
  }

  /// Runs one step of the simulation. Called inside a [batch], zero or more
  /// times per display frame.
  final SimulationStep simulate;

  /// The simulation step. Defaults to 1/60 s.
  final Duration fixedTimestep;

  /// The elapsed time reported by the ticker for the current frame.
  final Signal<Duration> time = Signal<Duration>(Duration.zero);

  /// The number of display frames this clock has ticked.
  final Signal<int> frame = Signal<int>(0);

  /// How far the current display frame is between the last simulation step and
  /// the next one, in the range 0.0 to 1.0.
  ///
  /// Rendering that interpolates between two simulation states reads this.
  final Signal<double> alpha = Signal<double>(0);

  /// The longest gap between two ticks that is treated as elapsed time.
  ///
  /// A gap longer than this did not come from a slow frame. It came from a
  /// breakpoint, a backgrounded app, or a muted [Ticker] — a route pushed off
  /// the screen, say — whose elapsed time kept running while nothing
  /// ticked. Simulating it would run a burst of catch-up steps for time the
  /// player never saw, so the whole gap is discarded, exactly as it is across
  /// an explicit [paused].
  static const Duration _maxCatchUp = Duration(milliseconds: 250);

  late final Ticker _ticker;
  late final int _fixedMicroseconds = fixedTimestep.inMicroseconds;
  late final double _fixedSeconds = _fixedMicroseconds / Duration.microsecondsPerSecond;

  // Held in a field so that the batch body captures nothing, and is torn off
  // once instead of allocating a closure per frame.
  late final VoidCallback _boundTick = _tick;

  Duration _elapsed = Duration.zero;
  int _lastElapsedMicroseconds = 0;
  int _accumulatorMicroseconds = 0;
  bool _disposed = false;

  /// Whether this clock is ticking.
  bool get isRunning => _ticker.isActive;

  /// Whether the simulation is paused.
  ///
  /// A paused clock stays started but writes nothing, and the time that passes
  /// while it is paused is discarded rather than simulated on resume.
  bool get paused => _ticker.muted;
  set paused(bool value) {
    if (_ticker.muted == value) {
      return;
    }
    _ticker.muted = value;
    if (!value) {
      // Resume from now: the ticker's elapsed time kept running while muted,
      // and that gap was never simulated.
      _lastElapsedMicroseconds = -1;
    }
  }

  /// Starts ticking.
  ///
  /// Returns the future the underlying [Ticker.start] returns, which completes
  /// when the clock is stopped.
  TickerFuture start() {
    assert(!_disposed, 'A disposed FrameClock cannot be started.');
    return _ticker.start();
  }

  /// Stops ticking, and resets the elapsed time so that a later [start] begins
  /// from zero.
  void stop() {
    _ticker.stop();
    _lastElapsedMicroseconds = 0;
    _accumulatorMicroseconds = 0;
  }

  /// Releases the ticker. The clock cannot be used afterwards.
  void dispose() {
    _disposed = true;
    _ticker.dispose();
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    // One batch for the whole frame: every write the simulation and the clock
    // signals make is queued, and drained once, at the frame's flush point.
    batch<void>(_boundTick);
  }

  void _tick() {
    final int elapsedMicroseconds = _elapsed.inMicroseconds;
    if (_lastElapsedMicroseconds < 0) {
      // First tick after a resume: consume the gap without simulating it.
      _lastElapsedMicroseconds = elapsedMicroseconds;
    }
    int delta = elapsedMicroseconds - _lastElapsedMicroseconds;
    _lastElapsedMicroseconds = elapsedMicroseconds;
    if (delta > _maxCatchUp.inMicroseconds) {
      // A gap this long is a pause, not a slow frame. See [_maxCatchUp].
      delta = 0;
    }
    _accumulatorMicroseconds += delta;
    while (_accumulatorMicroseconds >= _fixedMicroseconds) {
      _accumulatorMicroseconds -= _fixedMicroseconds;
      simulate(_fixedSeconds);
    }
    time.value = _elapsed;
    frame.value = frame.peek + 1;
    alpha.value = _accumulatorMicroseconds / _fixedMicroseconds;
  }
}
