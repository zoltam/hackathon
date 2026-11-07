import 'dart:collection';
import 'dart:convert';
import 'dart:math';

typedef Cell = (int x, int z);

Cell _cell(Object? value) {
  final coordinates = value as List;
  return (coordinates[0] as int, coordinates[1] as int);
}

class SiteObject {
  SiteObject(Map<String, dynamic> json)
    : name = json['name'] as String,
      equipmentType = json['equipmentType'] as String? ?? '',
      objectId =
          (json['objectId'] ?? json['object_id']) as String? ??
          'grid:${json['x']}:${json['z']}:${json['width']}:${json['depth']}',
      x = json['x'] as int,
      z = json['z'] as int,
      width = json['width'] as int,
      depth = json['depth'] as int,
      height = (json['height'] as num).toDouble(),
      movable = json['movable'] == true,
      geometryOnly = json['geometryOnly'] == true,
      cells = (json['cells'] as List?)?.map(_cell).toList(),
      bounds = json['bounds'] as List?,
      extractionBounds = json['extractionBounds'],
      service = json['service'] == null ? null : _cell(json['service']);

  final String objectId;
  final String name;
  final String equipmentType;
  final int x, z, width, depth;
  final double height;
  final bool movable;
  final bool geometryOnly;
  final Cell? service;
  final List<Cell>? cells;
  final List<dynamic>? bounds;
  final Object? extractionBounds;

  Iterable<Cell> get footprint sync* {
    if (cells case final cells?) {
      yield* cells;
      return;
    }
    for (var i = x; i < x + width; i++) {
      for (var j = z; j < z + depth; j++) {
        yield (i, j);
      }
    }
  }
}

class PersonNavigation {
  PersonNavigation._(Map<String, dynamic> json)
    : radiusMetres = _positive(json['radiusMetres']),
      bodyHeightMetres = _positive(json['bodyHeightMetres']),
      headMarginMetres = _positive(json['headMarginMetres']),
      eyeHeightMetres = _positive(json['eyeHeightMetres']),
      speedMetresPerSecond = _positive(json['speedMetresPerSecond']);

  final double radiusMetres, bodyHeightMetres, headMarginMetres;
  final double eyeHeightMetres, speedMetresPerSecond;

  static double _positive(Object? value) {
    if (value is! num || !value.isFinite || value <= 0) {
      throw const FormatException('Invalid walking-person navigation profile');
    }
    return value.toDouble();
  }

  static PersonNavigation? fromJson(Object? value) =>
      value is Map<String, dynamic> && value['name'] == 'walking-person'
      ? PersonNavigation._(value)
      : null;
}

class Site {
  Site.fromJson(String source)
    : this._(jsonDecode(source) as Map<String, dynamic>);

  Site._(Map<String, dynamic> json)
    : name = json['name'] as String,
      sourceSha256 = json['sourceSha256'] as String?,
      width = json['width'] as int,
      depth = json['depth'] as int,
      cellSize = (json['cellSize'] as num).toDouble(),
      originShift = json['originShift'] as List?,
      shRotation = json['shRotation'] as List?,
      personNavigation = PersonNavigation.fromJson(json['navigationProfile']),
      start = _cell(json['start']),
      floor = (json['floor'] as List?)?.map(_cell).toSet(),
      objects = (json['objects'] as List)
          .map((item) => SiteObject(item as Map<String, dynamic>))
          .toList() {
    if (width <= 0 || depth <= 0 || !cellSize.isFinite || cellSize <= 0) {
      throw const FormatException(
        'Site dimensions and cell size must be positive',
      );
    }
  }

  final String name;
  final String? sourceSha256;
  final int width, depth;
  final double cellSize;
  final List<dynamic>? originShift, shRotation;
  final PersonNavigation? personNavigation;
  final Cell start;
  final Set<Cell>? floor;
  final List<SiteObject> objects;

  Iterable<SiteObject> visibleObjects(bool moved) =>
      objects.where((object) => !(moved && object.movable));

  /// Radius is measured from each cell centre. Unknown floor and the map
  /// boundary count as obstacles. Zero preserves the original point routing.
  bool isWalkable(
    Cell cell, {
    bool moved = false,
    double clearanceMetres = 0,
    Set<Cell> additionalBlocked = const {},
  }) {
    if (!clearanceMetres.isFinite || clearanceMetres < 0) {
      throw ArgumentError.value(clearanceMetres, 'clearanceMetres');
    }
    final blocked = <Cell>{...additionalBlocked};
    for (final object in visibleObjects(moved)) {
      blocked.addAll(object.footprint);
    }
    return _walkable(cell, blocked, clearanceMetres);
  }

  Iterable<Cell> walkableCells({
    bool moved = false,
    double clearanceMetres = 0,
    Set<Cell> additionalBlocked = const {},
  }) sync* {
    if (!clearanceMetres.isFinite || clearanceMetres < 0) {
      throw ArgumentError.value(clearanceMetres, 'clearanceMetres');
    }
    final blocked = <Cell>{
      ...additionalBlocked,
      for (final object in visibleObjects(moved)) ...object.footprint,
    };
    for (var x = 0; x < width; x++) {
      for (var z = 0; z < depth; z++) {
        if (_walkable((x, z), blocked, clearanceMetres)) yield (x, z);
      }
    }
  }

  bool _walkable(Cell cell, Set<Cell> blocked, double radius) {
    bool allowed(Cell p) =>
        p.$1 >= 0 &&
        p.$1 < width &&
        p.$2 >= 0 &&
        p.$2 < depth &&
        (floor?.contains(p) ?? true) &&
        !blocked.contains(p);
    if (!allowed(cell)) return false;
    if (radius == 0) return true;
    // Reject a radius that cannot fit inside the map before converting it
    // into a grid reach. A finite radius can overflow when divided by cellSize.
    final edgeX = min(cell.$1, width - 1 - cell.$1) + 0.5;
    final edgeZ = min(cell.$2, depth - 1 - cell.$2) + 0.5;
    if (radius > min(edgeX, edgeZ) * cellSize) return false;
    final reach = (radius / cellSize + 0.5).ceil();
    for (var dx = -reach; dx <= reach; dx++) {
      for (var dz = -reach; dz <= reach; dz++) {
        if (allowed((cell.$1 + dx, cell.$2 + dz))) continue;
        final gapX = max(0.0, dx.abs() - 0.5) * cellSize;
        final gapZ = max(0.0, dz.abs() - 0.5) * cellSize;
        if (gapX * gapX + gapZ * gapZ < radius * radius) return false;
      }
    }
    return true;
  }

  List<Cell> route(
    Cell from,
    Cell to, {
    bool moved = false,
    double clearanceMetres = 0,
    Set<Cell> additionalBlocked = const {},
  }) {
    if (!clearanceMetres.isFinite || clearanceMetres < 0) {
      throw ArgumentError.value(clearanceMetres, 'clearanceMetres');
    }
    final blocked = <Cell>{...additionalBlocked};
    for (final object in visibleObjects(moved)) {
      blocked.addAll(object.footprint);
    }
    bool walkable(Cell cell) => _walkable(cell, blocked, clearanceMetres);

    if (!walkable(from) || !walkable(to)) return [];
    // Every legal move has the same distance. Breadth-first search finds
    // the shortest route without crossing a blocked corner diagonally.
    final queue = Queue<Cell>()..add(from);
    final previous = <Cell, Cell?>{from: null};
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      if (current == to) {
        final path = <Cell>[];
        for (Cell? cell = to; cell != null; cell = previous[cell]) {
          path.add(cell);
        }
        return path.reversed.toList();
      }
      final (x, z) = current;
      for (final next in [(x - 1, z), (x + 1, z), (x, z - 1), (x, z + 1)]) {
        if (walkable(next) && !previous.containsKey(next)) {
          previous[next] = current;
          queue.add(next);
        }
      }
    }
    return [];
  }

  double metres(List<Cell> route) => max(0, route.length - 1) * cellSize;
}
