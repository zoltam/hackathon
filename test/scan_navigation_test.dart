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
      final catalog =
          (jsonDecode(source) as Map<String, dynamic>)['objects'] as List;
      const clearance = .1;
      expect(site.cellSize, .1);
      expect(site.originShift, [2, 0, 6.25]);
      expect(site.objects, hasLength(17));
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
      // Centre, left, upper-left, upper-middle, upper-right, lower-left, bottom.
      for (final cell in <Cell>[
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
      ]) {
        expect(
          site.route(site.start, cell, clearanceMetres: clearance),
          isNotEmpty,
          reason: 'Reviewed region $cell must be reachable',
        );
      }
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
      final approaches = <Cell>{};
      for (final device in devices) {
        final approach = device.service!;
        final id = device.objectId;
        expect(
          approaches.add(approach),
          isTrue,
          reason: '$id shares an approach',
        );
        final route = NavigationJourney(
          site: site,
          target: device,
          clearanceMetres: clearance,
        ).route;
        expect(route, isNotEmpty, reason: id);
        expect(route.first, site.start, reason: id);
        expect(route.last, approach, reason: id);
        expect(
          route.where((cell) => !walkable.contains(cell)),
          isEmpty,
          reason: id,
        );
        for (var i = 1; i < route.length; i++) {
          final (x, z) = route[i];
          final (previousX, previousZ) = route[i - 1];
          expect((x - previousX).abs() + (z - previousZ).abs(), 1, reason: id);
        }
      }
      final journey = NavigationJourney(
        site: site,
        target: pump,
        clearanceMetres: clearance,
      );
      expect(pump.service, (73, 81));
      expect(journey.route, hasLength(32));
      journey.play();
      journey.advance(const Duration(minutes: 1));
      expect(journey.status, JourneyStatus.arrived);
    },
    skip: !scan.existsSync()
        ? 'Generate the local Equipment Room scan first'
        : false,
  );
}
