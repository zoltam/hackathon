import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/navigation.dart';
import 'package:valmet_field_app/site.dart';

void main() {
  Site corridor() => Site.fromJson('''
    {"name":"Test corridor","width":5,"depth":1,"cellSize":1,
    "start":[0,0],"objects":[{"name":"Target","x":4,"z":0,
    "width":1,"depth":1,"height":1,"cells":[],"service":[4,0]}]}
  ''');

  test('clearance rejects narrow routes, edges, and unknown floor', () {
    final site = corridor();
    expect(site.route(site.start, (4, 0), clearanceMetres: .5), hasLength(5));
    expect(site.route(site.start, (4, 0), clearanceMetres: .51), isEmpty);
    expect(
      site.route(site.start, (4, 0), additionalBlocked: {(2, 0)}),
      isEmpty,
    );
    expect(
      () => site.route(site.start, (4, 0), clearanceMetres: -1),
      throwsArgumentError,
    );
    final sparse = Site.fromJson('''
      {"name":"Sparse","width":5,"depth":5,"cellSize":1,"start":[2,2],
       "floor":[[2,2]],"objects":[]}
    ''');
    expect(sparse.isWalkable((2, 2), clearanceMetres: .51), isFalse);
  });

  test('playback interpolates at speed, pauses, arrives, and resets', () {
    final site = corridor();
    final journey = NavigationJourney(
      site: site,
      target: site.objects.first,
      speedMetresPerSecond: 1,
    );
    expect(journey.position.x, .5);
    journey.play();
    journey.advance(const Duration(milliseconds: 1250));
    expect(journey.position.x, 1.75);
    expect(journey.remainingMetres, 2.75);
    journey.pause();
    journey.advance(const Duration(seconds: 20));
    expect(journey.position.x, 1.75);
    journey.play();
    journey.advance(const Duration(seconds: 20));
    expect(journey.status, JourneyStatus.arrived);
    expect(journey.position.x, 4.5);
    expect(journey.remainingMetres, 0);
    journey.reset();
    expect(journey.status, JourneyStatus.ready);
    expect(journey.position.x, .5);
  });

  test('cannot start unreachable playback or skip a route corner', () {
    final narrow = corridor();
    final unavailable = NavigationJourney(
      site: narrow,
      target: narrow.objects.first,
      clearanceMetres: .6,
    );
    unavailable.play();
    expect(unavailable.status, JourneyStatus.unreachable);
    final site = Site.fromJson(
      File('test/fixtures/site.json').readAsStringSync(),
    );
    final journey = NavigationJourney(
      site: site,
      target: site.objects.firstWhere((o) => o.service != null),
      speedMetresPerSecond: site.cellSize,
    );
    journey.play();
    for (var i = 0; i < journey.route.length - 1; i++) {
      journey.advance(const Duration(seconds: 1));
      final cell = journey.route[i + 1];
      expect(journey.position.x, closeTo((cell.$1 + .5) * site.cellSize, 1e-8));
      expect(journey.position.y, closeTo((cell.$2 + .5) * site.cellSize, 1e-8));
    }
    expect(journey.status, JourneyStatus.arrived);
  });

  test('same start and service point is already arrived', () {
    final site = Site.fromJson('''
      {"name":"Here","width":1,"depth":1,"cellSize":1,"start":[0,0],
      "objects":[{"name":"Target","x":0,"z":0,"width":1,"depth":1,
      "height":1,"cells":[],"service":[0,0]}]}
    ''');
    final journey = NavigationJourney(site: site, target: site.objects.first);
    expect(journey.status, JourneyStatus.arrived);
    expect(journey.remainingMetres, 0);
  });
}
