import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/navigation.dart';
import 'package:valmet_field_app/site.dart';

void main() {
  final scan = File('assets/valmet/site.json');
  test(
    'reviewed scan regions connect without moving equipment or opening obstacles',
    () {
      final source = scan.readAsStringSync();
      final site = Site.fromJson(source);
      final scene = jsonDecode(source) as Map<String, dynamic>;
      final catalog = scene['objects'] as List;
      const clearance = .1;
      expect(site.cellSize, .1);
      expect(site.originShift, [2, 0, 6.25]);
      expect(site.objects, hasLength(33));
      expect(
        site.objects.map((object) => object.objectId).toSet(),
        hasLength(33),
      );
      expect(
        catalog.where((object) => object['detectorEnabled'] != false),
        hasLength(11),
      );
      final pump = site.objects.firstWhere(
        (o) => o.objectId == 'boiler-room:red-circulation-pump',
      );
      expect(pump.bounds, [
        [7.77, 1.045, 8.52],
        [8.1, 1.32, 8.88],
      ]);
      // Entrance, centre, left, upper aisle, lower-left, bottom.
      final starts = <Cell>[
        site.start,
        (69, 65),
        (33, 43),
        (53, 29),
        (69, 28),
        (74, 28),
        (79, 28),
        (84, 28),
        (89, 28),
        (96, 36),
        (42, 83),
        (66, 92),
      ];
      for (final obstacle in <Cell>[(90, 32), (91, 32)]) {
        expect(site.isWalkable(obstacle, clearanceMetres: clearance), isFalse);
      }
      final devices = site.objects.where((object) => object.service != null);
      expect(
        devices.map((object) => object.objectId),
        unorderedEquals([
          'boiler-room:red-circulation-pump',
          'boiler-room:middle-circulation-pump',
          'boiler-room:wall-circulation-pump',
          'boiler-room:far-circulation-pump',
          'boiler-room:black-circulation-pump',
          'boiler-room:blue-inline-valve',
        ]),
      );
      final walkable = site.walkableCells(clearanceMetres: clearance).toSet();
      expect(walkable, contains(site.start));
      final entranceDistance = <Cell, int>{site.start: 0};
      final reachable = <Cell>[site.start];
      for (var i = 0; i < reachable.length; i++) {
        final cell = reachable[i];
        final (x, z) = cell;
        for (final next in [(x - 1, z), (x + 1, z), (x, z - 1), (x, z + 1)]) {
          if (walkable.contains(next) && !entranceDistance.containsKey(next)) {
            entranceDistance[next] = entranceDistance[cell]! + 1;
            reachable.add(next);
          }
        }
      }
      final disconnected = walkable.difference(entranceDistance.keys.toSet());
      expect(reachable, hasLength(2106));
      expect(disconnected, hasLength(24));
      final approaches = <Cell>{};
      for (final device in devices) {
        final approach = device.service!;
        expect(
          approaches.add(approach),
          isTrue,
          reason: '${device.objectId} shares an approach',
        );
        expect(entranceDistance, contains(approach));
        expect(
          site.route(site.start, approach, clearanceMetres: clearance),
          hasLength(entranceDistance[approach]! + 1),
        );
        for (final start in disconnected) {
          expect(
            site.route(start, approach, clearanceMetres: clearance),
            isEmpty,
          );
        }
      }
      for (final start in starts) {
        final layout = Site.fromJson(
          jsonEncode({
            ...scene,
            'start': [start.$1, start.$2],
          }),
        );
        for (final target in devices) {
          final approach = target.service!;
          final reason = '${target.objectId} from $start';
          final journey = NavigationJourney(
            site: layout,
            target: target,
            clearanceMetres: clearance,
          );
          expectRoute(journey.route, start, approach, walkable, reason);
          expect(journey.status, JourneyStatus.ready, reason: reason);
          journey.play();
          journey.advance(const Duration(minutes: 1));
          expect(journey.status, JourneyStatus.arrived, reason: reason);
          expect(journey.remainingMetres, 0, reason: reason);
          expect(journey.position.x, closeTo((approach.$1 + .5) * .1, 1e-9));
          expect(journey.position.y, closeTo((approach.$2 + .5) * .1, 1e-9));
        }
      }
      expect(pump.service, (73, 81));
      expect(
        site.route(site.start, pump.service!, clearanceMetres: clearance),
        hasLength(32),
      );

      const current = (61, 65);
      // The native demo's 0.50 m crate with 0.02 m padding on each side.
      final crate = <Cell>{
        for (var x = 66; x <= 72; x++)
          for (var z = 62; z <= 68; z++) (x, z),
      };
      final detourFloor = site
          .walkableCells(clearanceMetres: clearance, additionalBlocked: crate)
          .toSet();
      final barrier = <Cell>{for (var z = 0; z < site.depth; z++) (70, z)};
      final splitFloor = site
          .walkableCells(clearanceMetres: clearance, additionalBlocked: barrier)
          .toSet();
      for (final target in devices) {
        final goal = target.service!;
        final id = target.objectId;
        List<Cell> route(Cell from, Set<Cell> blocked) => site.route(
          from,
          goal,
          clearanceMetres: clearance,
          additionalBlocked: blocked,
        );

        final original = route(current, {});
        expect(original.any(crate.contains), isTrue, reason: id);
        final detour = route(current, crate);
        expectRoute(detour, current, goal, detourFloor, '$id around crate');
        expect(detour, isNot(original), reason: id);
        expect(route((69, 65), crate), isEmpty, reason: '$id blocked start');
        expect(route(current, {goal}), isEmpty, reason: '$id blocked goal');
        expect(splitFloor, containsAll([current, goal]), reason: id);
        expect(route(current, barrier), isEmpty, reason: '$id cut off');
        expect(route(current, {}), original, reason: '$id cleared');
      }
    },
    skip: !scan.existsSync()
        ? 'Generate the local Equipment Room scan first'
        : false,
  );

  test(
    'larger camera presets preserve the reachable alternate P005 approach',
    () {
      final site = Site.fromJson(scan.readAsStringSync());
      final services = site.objects.where((object) => object.service != null);
      const alternateStart = (69, 65);
      final starts = [site.start, alternateStart, (53, 29), (42, 83)];
      for (final radius in [.2, .3]) {
        final walkable = site.walkableCells(clearanceMetres: radius).toSet();
        for (final start in starts) {
          for (final service in services) {
            final goal = service.service!;
            final reason = '${service.objectId} from $start at $radius m';
            final route = site.route(start, goal, clearanceMetres: radius);
            if (radius == .2 &&
                start == alternateStart &&
                service.objectId == 'boiler-room:red-circulation-pump') {
              expectRoute(route, start, goal, walkable, reason);
              expect(route, hasLength(21), reason: reason);
            } else {
              expect(route, isEmpty, reason: reason);
            }
          }
        }
      }
    },
    skip: !scan.existsSync()
        ? 'Generate the local Equipment Room scan first'
        : false,
  );
}

void expectRoute(
  List<Cell> route,
  Cell start,
  Cell goal,
  Set<Cell> walkable,
  String reason,
) {
  expect(route, isNotEmpty, reason: reason);
  expect(route.first, start, reason: reason);
  expect(route.last, goal, reason: reason);
  expect(route, everyElement(isIn(walkable)), reason: reason);
  expect(route.toSet(), hasLength(route.length), reason: reason);
  for (var i = 1; i < route.length; i++) {
    final (x, z) = route[i];
    final (previousX, previousZ) = route[i - 1];
    expect((x - previousX).abs() + (z - previousZ).abs(), 1, reason: reason);
  }
}
