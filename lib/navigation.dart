import 'dart:math';

import 'site.dart';

enum JourneyStatus { unreachable, ready, playing, paused, arrived }

/// Frame-rate independent playback of the same grid route sent to the viewer.
/// Position is in model metres, at floor height; recognition is independent.
class NavigationJourney {
  NavigationJourney({
    required this.site,
    required this.target,
    this.clearanceMetres = 0.2,
    this.speedMetresPerSecond = 0.7,
    this.moved = false,
  }) {
    if (!speedMetresPerSecond.isFinite || speedMetresPerSecond <= 0) {
      throw ArgumentError.value(speedMetresPerSecond, 'speedMetresPerSecond');
    }
    reset();
  }

  final Site site;
  final SiteObject target;
  final double clearanceMetres;
  final double speedMetresPerSecond;
  final bool moved;
  late List<Cell> _route;
  late JourneyStatus status;
  double _travelled = 0;

  List<Cell> get route => List.unmodifiable(_route);
  double get lengthMetres => site.metres(_route);
  double get remainingMetres => max(0, lengthMetres - _travelled);

  Point<double> get position {
    if (_route.isEmpty) return _center(site.start);
    final step = _travelled / site.cellSize;
    final index = min(step.floor(), _route.length - 1);
    final a = _center(_route[index]);
    final b = _center(_route[min(index + 1, _route.length - 1)]);
    final fraction = step - index;
    return Point(a.x + (b.x - a.x) * fraction, a.y + (b.y - a.y) * fraction);
  }

  Point<double> _center(Cell p) =>
      Point((p.$1 + 0.5) * site.cellSize, (p.$2 + 0.5) * site.cellSize);

  void reset() {
    _travelled = 0;
    final goal = target.service;
    _route = goal == null
        ? []
        : site.route(
            site.start,
            goal,
            moved: moved,
            clearanceMetres: clearanceMetres,
          );
    status = _route.isEmpty
        ? JourneyStatus.unreachable
        : _route.length == 1
        ? JourneyStatus.arrived
        : JourneyStatus.ready;
  }

  void play() {
    if (status == JourneyStatus.ready || status == JourneyStatus.paused) {
      status = JourneyStatus.playing;
    }
  }

  void pause() {
    if (status == JourneyStatus.playing) status = JourneyStatus.paused;
  }

  void advance(Duration elapsed) {
    if (elapsed.isNegative) throw ArgumentError.value(elapsed, 'elapsed');
    if (status != JourneyStatus.playing) return;
    _travelled = min(
      lengthMetres,
      _travelled + elapsed.inMicroseconds / 1000000 * speedMetresPerSecond,
    );
    if (_travelled >= lengthMetres) status = JourneyStatus.arrived;
  }
}
