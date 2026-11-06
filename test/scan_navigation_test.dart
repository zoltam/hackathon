import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/navigation.dart';
import 'package:valmet_field_app/site.dart';

void main() {
  final scan = File('assets/valmet/site.json');
  test(
    'reviewed scan regions connect without moving equipment or opening obstacles',
    () {
      final site = Site.fromJson(scan.readAsStringSync());
      expect(site.cellSize, .1);
      expect(site.originShift, [2, 0, 6.25]);
      expect(site.objects, hasLength(11));
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
          site.route(site.start, cell, clearanceMetres: .1),
          isNotEmpty,
          reason: 'Reviewed region $cell must be reachable',
        );
      }
      for (final obstacle in <Cell>[(90, 32), (91, 32)]) {
        expect(site.isWalkable(obstacle, clearanceMetres: .1), isFalse);
      }
      final journey = NavigationJourney(
        site: site,
        target: pump,
        clearanceMetres: .1,
      );
      expect(journey.route, isNotEmpty);
      journey.play();
      journey.advance(const Duration(minutes: 1));
      expect(journey.status, JourneyStatus.arrived);
    },
    skip: !scan.existsSync()
        ? 'Generate the local Equipment Room scan first'
        : false,
  );
}
