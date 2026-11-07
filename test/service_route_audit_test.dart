import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/site.dart';

import '../tools/audit_service_routes.dart' as audit;

void main() {
  test(
    'reference flood preserves shortest distances and disconnected cells',
    () {
      final floor = <Cell>{
        for (var x = 0; x < 5; x++)
          for (var z = 0; z < 3; z++)
            if (x != 2 || z == 0) (x, z),
        (9, 9),
      };
      final distance = audit.distances(floor, (4, 2));
      expect(distance[(4, 2)], 0);
      expect(distance[(0, 2)], 8);
      expect(distance, isNot(contains((9, 9))));
    },
  );

  test('swept circle rejects an obstacle along a cardinal edge', () {
    final site = Site.fromJson('''
      {"name":"Clearance test","width":9,"depth":9,"cellSize":0.1,
       "start":[2,2],"objects":[]}
    ''');
    final floor = site.walkableCells().toSet()..remove((4, 4));
    expect(
      () => audit.verifySegment(site, floor, (3, 3), (4, 3)),
      throwsStateError,
    );
    expect(
      () => audit.verifySegment(site, floor, (2, 2), (3, 2)),
      returnsNormally,
    );
  });

  test('swept circle treats unknown floor and map edges as blocked', () {
    final site = Site.fromJson('''
      {"name":"Boundary test","width":9,"depth":9,"cellSize":0.1,
       "start":[2,2],"objects":[]}
    ''');
    expect(
      () => audit.verifySegment(
        site,
        site.walkableCells().toSet(),
        (0, 3),
        (0, 4),
      ),
      throwsStateError,
    );
  });
}
