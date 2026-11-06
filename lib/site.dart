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
      x = json['x'] as int,
      z = json['z'] as int,
      width = json['width'] as int,
      depth = json['depth'] as int,
      height = (json['height'] as num).toDouble(),
      movable = json['movable'] == true,
      cells = (json['cells'] as List?)?.map(_cell).toList(),
      service = json['service'] == null ? null : _cell(json['service']);

  final String name;
  final int x, z, width, depth;
  final double height;
  final bool movable;
  final Cell? service;
  final List<Cell>? cells;

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

class Site {
  Site.fromJson(String source)
    : this._(jsonDecode(source) as Map<String, dynamic>);

  Site._(Map<String, dynamic> json)
    : name = json['name'] as String,
      width = json['width'] as int,
      depth = json['depth'] as int,
      cellSize = (json['cellSize'] as num).toDouble(),
      start = _cell(json['start']),
      floor = (json['floor'] as List?)?.map(_cell).toSet(),
      objects = (json['objects'] as List)
          .map((item) => SiteObject(item as Map<String, dynamic>))
          .toList();

  final String name;
  final int width, depth;
  final double cellSize;
  final Cell start;
  final Set<Cell>? floor;
  final List<SiteObject> objects;

  Iterable<SiteObject> visibleObjects(bool moved) =>
      objects.where((object) => !(moved && object.movable));

  List<Cell> route(Cell from, Cell to, {bool moved = false}) {
    final blocked = <Cell>{};
    for (final object in visibleObjects(moved)) {
      blocked.addAll(object.footprint);
    }

    bool walkable(Cell cell) {
      final (x, z) = cell;
      return x >= 0 &&
          x < width &&
          z >= 0 &&
          z < depth &&
          (floor?.contains(cell) ?? true) &&
          !blocked.contains(cell);
    }

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
