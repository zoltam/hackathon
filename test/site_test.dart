import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/site.dart';

void main() {
  final site = Site.fromJson(
    File('test/fixtures/site.json').readAsStringSync(),
  );

  test('finds the shortest legal detour around the partition and pallet', () {
    final goal = site.objects
        .firstWhere((o) => o.name == 'Boiler B-01')
        .service!;
    final route = site.route(site.start, goal);
    expect(route.first, site.start);
    expect(route.last, goal);
    expect(route.length - 1, 21);
    expect(route, isNot(contains((5, 7))));
    expect(site.route(site.start, goal, moved: true).length - 1, 19);
  });

  test('keeps the model inside observed floor and rejects blocked goals', () {
    expect(site.route(site.start, (5, 1)), isEmpty);
    final sparse = Site.fromJson('''
      {"name":"Scan","width":3,"depth":1,"cellSize":0.5,
       "start":[0,0],"floor":[[0,0],[2,0]],"objects":[]}
    ''');
    expect(sparse.route(sparse.start, (2, 0)), isEmpty);
  });

  test('clearance measures Euclidean distance to a diagonal obstacle', () {
    final grid = Site.fromJson('''
      {"name":"Diagonal","width":5,"depth":5,"cellSize":0.1,
       "start":[2,2],"objects":[]}
    ''');
    const obstacle = {(3, 3)};
    const start = (2, 2);
    const goal = (1, 2);
    expect(
      grid.route(
        start,
        goal,
        clearanceMetres: .070,
        additionalBlocked: obstacle,
      ),
      [start, goal],
    );
    expect(
      grid.route(
        start,
        goal,
        clearanceMetres: .071,
        additionalBlocked: obstacle,
      ),
      isEmpty,
    );
  });

  test('finite clearance wider than the site returns no walkable cells', () {
    const radius = double.maxFinite;
    expect(site.isWalkable(site.start, clearanceMetres: radius), isFalse);
    expect(site.walkableCells(clearanceMetres: radius), isEmpty);
    expect(
      site.route(site.start, site.start, clearanceMetres: radius),
      isEmpty,
    );
  });
}
