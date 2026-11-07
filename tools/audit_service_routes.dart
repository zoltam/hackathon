// Run from hackathon/: dart run tools/audit_service_routes.dart [site.json]
// Writes a private, reproducible route-distance fixture to stdout.
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:valmet_field_app/site.dart';

const clearance = .10;

Never fail(String message) => throw StateError(message);

Map<Cell, int> distances(Set<Cell> floor, Cell goal) {
  final result = <Cell, int>{goal: 0};
  final queue = Queue<Cell>()..add(goal);
  while (queue.isNotEmpty) {
    final p = queue.removeFirst();
    for (final next in [
      (p.$1 - 1, p.$2),
      (p.$1 + 1, p.$2),
      (p.$1, p.$2 - 1),
      (p.$1, p.$2 + 1),
    ]) {
      if (floor.contains(next) && !result.containsKey(next)) {
        result[next] = result[p]! + 1;
        queue.add(next);
      }
    }
  }
  return result;
}

// Exact distance between an axis-aligned centre-to-centre route segment and
// each nearby blocked cell square. This checks the swept circle, not samples.
void verifySegment(Site site, Set<Cell> allowed, Cell a, Cell b) {
  final size = site.cellSize;
  final minX = (min(a.$1, b.$1) + .5) * size;
  final maxX = (max(a.$1, b.$1) + .5) * size;
  final minZ = (min(a.$2, b.$2) + .5) * size;
  final maxZ = (max(a.$2, b.$2) + .5) * size;
  final reach = (clearance / size).ceil() + 1;
  for (var x = min(a.$1, b.$1) - reach; x <= max(a.$1, b.$1) + reach; x++) {
    for (var z = min(a.$2, b.$2) - reach; z <= max(a.$2, b.$2) + reach; z++) {
      if (allowed.contains((x, z))) continue;
      final dx = max(0.0, max(x * size - maxX, minX - (x + 1) * size));
      final dz = max(0.0, max(z * size - maxZ, minZ - (z + 1) * size));
      if (dx * dx + dz * dz < clearance * clearance - 1e-12) {
        fail('Continuous clearance violation: $a to $b beside ($x, $z)');
      }
    }
  }
}

void main(List<String> args) {
  if (args.length > 1) {
    throw ArgumentError(
      'Usage: dart run tools/audit_service_routes.dart [site.json]',
    );
  }
  final path = args.isEmpty ? 'assets/valmet/site.json' : args.single;
  final source = File(path).readAsStringSync();
  final site = Site.fromJson(source);
  final catalog =
      (jsonDecode(source) as Map<String, dynamic>)['objects'] as List;
  if (site.floor == null) fail('Observed scan floor is required');
  if (site.objects.length != 33 ||
      site.objects.map((o) => o.objectId).toSet().length != 33) {
    fail('Expected 33 unique registered catalog objects');
  }
  for (final object in catalog.cast<Map<String, dynamic>>()) {
    final bounds = (object['bounds'] as List).cast<List>();
    if ((object['supportingSplats'] as int) < 50 ||
        bounds.length != 2 ||
        bounds.any((b) => b.length != 3)) {
      fail('Missing registered scan support: ${object['objectId']}');
    }
    for (var axis = 0; axis < 3; axis++) {
      final lo = bounds[0][axis] as num;
      final hi = bounds[1][axis] as num;
      if (!lo.isFinite || !hi.isFinite || lo >= hi) {
        fail('Invalid registered bounds: ${object['objectId']}');
      }
    }
  }
  final targets = site.objects.where((o) => o.service != null).toList();
  if (targets.length != 6) fail('Expected six service targets');
  final walkable = site.walkableCells(clearanceMetres: clearance).toSet();
  final rawFloor = site.walkableCells().toSet();
  var checkedEdges = 0;
  for (final p in walkable) {
    for (final q in [(p.$1 + 1, p.$2), (p.$1, p.$2 + 1)]) {
      if (!walkable.contains(q)) continue;
      verifySegment(site, rawFloor, p, q);
      checkedEdges++;
    }
  }
  final matrix = <List<Object?>>[];
  final reference = <Map<Cell, int>>[];
  for (final target in targets) {
    if (!walkable.contains(target.service)) {
      fail('Blocked service: ${target.objectId}');
    }
    reference.add(distances(walkable, target.service!));
    if (site
            .route(
              site.start,
              target.service!,
              clearanceMetres: clearance,
              additionalBlocked: {site.start},
            )
            .isNotEmpty ||
        site
            .route(
              site.start,
              target.service!,
              clearanceMetres: clearance,
              additionalBlocked: {target.service!},
            )
            .isNotEmpty) {
      fail('Blocked start or goal accepted: ${target.objectId}');
    }
  }
  var successful = 0;
  var unreachable = 0;
  for (final start in walkable) {
    final row = <Object?>[start.$1, start.$2];
    for (var i = 0; i < targets.length; i++) {
      final goal = targets[i].service!;
      final expected = reference[i][start];
      final route = site.route(start, goal, clearanceMetres: clearance);
      if (expected == null) {
        if (route.isNotEmpty) {
          fail('Disconnected start accepted: $start to $goal');
        }
        unreachable++;
      } else {
        if (route.length != expected + 1 ||
            route.first != start ||
            route.last != goal) {
          fail(
            'Incorrect shortest route: $start to $goal, expected $expected steps',
          );
        }
        for (var j = 0; j < route.length; j++) {
          if (!walkable.contains(route[j])) fail('Route leaves safe floor');
          if (j == 0) continue;
          final a = route[j - 1], b = route[j];
          if ((a.$1 - b.$1).abs() + (a.$2 - b.$2).abs() != 1) {
            fail('Route skips a floor edge');
          }
        }
        successful++;
      }
      row.add(expected);
    }
    matrix.add(row);
  }
  stdout.writeln(
    jsonEncode({
      'schemaVersion': 1,
      'sourceSha256': site.sourceSha256,
      'clearanceMetres': clearance,
      'catalogObjects': site.objects.length,
      'detectorEnabledObjects': catalog
          .where((o) => o['detectorEnabled'] != false)
          .length,
      'observedFloorCells': site.floor!.length,
      'walkableStarts': walkable.length,
      'supportedStarts': reference.first.length,
      'continuouslyClearEdges': checkedEdges,
      'successfulRoutes': successful,
      'unreachableRoutes': unreachable,
      'blockedEndpointChecks': targets.length * 2,
      'targets': [
        for (final target in targets)
          {
            'objectId': target.objectId,
            'service': [target.service!.$1, target.service!.$2],
            'entranceSteps': reference[targets.indexOf(target)][site.start],
          },
      ],
      'matrixColumns': ['startX', 'startZ', ...targets.map((t) => t.objectId)],
      'matrixUnit': 'cardinal 0.10 m steps; null means unreachable',
      'matrix': matrix,
    }),
  );
}
