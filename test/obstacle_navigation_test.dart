import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/site.dart';

void main() {
  final site = Site.fromJson('''
    {"name":"Open test floor","width":9,"depth":7,"cellSize":0.25,
     "start":[1,3],"objects":[]}
  ''');
  const goal = (7, 3);
  const clearance = 0.20;

  test(
    'a detected obstacle creates a detour and moving it reopens the route',
    () {
      final original = site.route(site.start, goal, clearanceMetres: clearance);
      expect(original, hasLength(7));
      expect(original, contains((4, 3)));

      const blocked = {(4, 3)};
      final mask = site
          .walkableCells(clearanceMetres: clearance, additionalBlocked: blocked)
          .toSet();
      final detour = site.route(
        site.start,
        goal,
        clearanceMetres: clearance,
        additionalBlocked: blocked,
      );

      expect(mask, isNot(contains((4, 3))));
      expect(mask, isNot(contains((3, 3))), reason: 'Keep radius clearance');
      expect(detour, hasLength(11));
      expect(detour.first, site.start);
      expect(detour.last, goal);
      expect(detour, everyElement(isIn(mask)));
      for (var index = 1; index < detour.length; index++) {
        final (previousX, previousZ) = detour[index - 1];
        final (x, z) = detour[index];
        expect((x - previousX).abs() + (z - previousZ).abs(), 1);
      }

      const moved = {(4, 1)};
      final updatedMask = site
          .walkableCells(clearanceMetres: clearance, additionalBlocked: moved)
          .toSet();
      expect(updatedMask, contains((4, 3)));
      expect(updatedMask, isNot(contains((4, 1))));
      expect(
        site.route(
          site.start,
          goal,
          clearanceMetres: clearance,
          additionalBlocked: moved,
        ),
        original,
      );
    },
  );

  test('a crate blocks the current cell but allows a route after retreat', () {
    const current = (4, 3);
    const crate = {current};
    final retreat = site.start;
    final original = site.route(retreat, goal, clearanceMetres: clearance);
    expect(original, contains(current));

    final mask = site
        .walkableCells(clearanceMetres: clearance, additionalBlocked: crate)
        .toSet();
    List<Cell> routeFrom(Cell from) => site.route(
      from,
      goal,
      clearanceMetres: clearance,
      additionalBlocked: crate,
    );

    expect(mask, isNot(contains(current)));
    expect(routeFrom(current), isEmpty);
    final detour = routeFrom(retreat);
    expect(detour.length, greaterThan(original.length));
    expect(detour.first, retreat);
    expect(detour.last, goal);
    expect(detour, everyElement(isIn(mask)));
  });

  test('a blocked crossing reports no route with both ends walkable', () {
    final wall = <Cell>{for (var z = 0; z < site.depth; z++) (4, z)};
    final mask = site
        .walkableCells(clearanceMetres: clearance, additionalBlocked: wall)
        .toSet();
    expect(mask, containsAll([site.start, goal]));
    expect(
      site.route(
        site.start,
        goal,
        clearanceMetres: clearance,
        additionalBlocked: wall,
      ),
      isEmpty,
    );
  });
}
