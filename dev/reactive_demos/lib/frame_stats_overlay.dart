import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A small overlay that reports build and raster time, and FPS, from the
/// engine's own [FrameTiming] reports.
///
/// The stats are held in their own [Signal] and rendered with [ReactiveText],
/// so the busy demo screen around this overlay never has to rebuild just to
/// keep the numbers current. [SchedulerBinding.addTimingsCallback] fires
/// every frame, but the signal is only written at most every 500 ms, so this
/// overlay does not add work to every frame it is measuring.
class FrameStatsOverlay extends StatefulWidget {
  const FrameStatsOverlay({super.key, required this.clock});

  /// Unused by the stats themselves (they come from [FrameTiming]); kept so
  /// callers can scope one overlay to one screen's clock.
  final FrameClock clock;

  @override
  State<FrameStatsOverlay> createState() => _FrameStatsOverlayState();
}

class _FrameStatsOverlayState extends State<FrameStatsOverlay> {
  static const Duration _updateInterval = Duration(milliseconds: 500);

  final Signal<String> _stats = Signal<String>('-- ms  -- ms  -- fps');
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastUpdate) < _updateInterval) {
      return;
    }
    _lastUpdate = now;
    final FrameTiming last = timings.last;
    final double buildMs = last.buildDuration.inMicroseconds / 1000;
    final double rasterMs = last.rasterDuration.inMicroseconds / 1000;
    final double totalMs = last.totalSpan.inMicroseconds / 1000;
    final double fps = totalMs > 0 ? 1000 / totalMs : 0;
    _stats.value =
        'build ${buildMs.toStringAsFixed(1)} ms  '
        'raster ${rasterMs.toStringAsFixed(1)} ms  '
        '${fps.toStringAsFixed(0)} fps';
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 8,
      right: 8,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: ReactiveText(
              _stats,
              style: () => const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}
