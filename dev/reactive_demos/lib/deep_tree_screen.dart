import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'frame_stats_overlay.dart';

const int _treeDepth = 50;

/// Counts how many times a build ran, live. Shared by every [_Level] in one
/// tree; the [ReactiveText] bound to [count] re-renders whenever it changes,
/// so if a regression ever made the ancestors rebuild on every tick, the
/// number on screen would climb instead of sitting on a display that was
/// only ever rendered once.
class _BuildCounter {
  final Signal<int> count = Signal<int>(0);
}

/// One plain, non-reactive level of nesting. Building it increments
/// [counter]; only the deepest level returns the reactive leaf.
class _Level extends StatelessWidget {
  const _Level({required this.remaining, required this.counter, required this.leaf});

  final int remaining;
  final _BuildCounter counter;
  final Widget Function() leaf;

  @override
  Widget build(BuildContext context) {
    counter.count.value++;
    if (remaining == 0) {
      return leaf();
    }
    return _Level(remaining: remaining - 1, counter: counter, leaf: leaf);
  }
}

/// A [ReactiveText] showing [FrameClock.frame], nested 50 levels deep inside
/// plain [StatelessWidget]s. Every tick writes the frame signal, and only the
/// leaf's render object repaints: the 50 ancestors build exactly once.
class DeepTreeScreen extends StatefulWidget {
  const DeepTreeScreen({super.key});

  @override
  State<DeepTreeScreen> createState() => _DeepTreeScreenState();
}

class _DeepTreeScreenState extends State<DeepTreeScreen> with SingleTickerProviderStateMixin {
  late final FrameClock _clock;
  final _BuildCounter _ancestorBuilds = _BuildCounter();

  @override
  void initState() {
    super.initState();
    _clock = FrameClock.withVsync(vsync: this, simulate: (double dt) {});
    _clock.start();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('120 Hz counter, 50 levels deep')),
      body: Stack(
        children: [
          Center(
            child: _Level(
              remaining: _treeDepth,
              counter: _ancestorBuilds,
              leaf: () => ReactiveText(
                () => 'frame ${_clock.frame()}',
                style: () => const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          // Live: proves the ancestors are not rebuilding, rather than just
          // asserting it. If they started rebuilding on every tick, this
          // number would climb instead of staying at 1.
          Positioned(
            left: 16,
            top: 16,
            child: ReactiveText(() => 'ancestor builds: ${_ancestorBuilds.count.value}'),
          ),
          FrameStatsOverlay(clock: _clock),
        ],
      ),
    );
  }
}
