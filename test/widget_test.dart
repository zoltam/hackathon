import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/main.dart';
import 'package:valmet_field_app/site.dart';

void main() {
  testWidgets('opens with a route and the first-person walkthrough', (
    tester,
  ) async {
    final site = Site.fromJson(
      File('test/fixtures/site.json').readAsStringSync(),
    );
    const channel = MethodChannel('valmet/field');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SiteSimulation(
            site: site,
            loadAssetData: () async => null,
            openNative: (method, [data]) =>
                channel.invokeMethod<void>(method, data),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Walk inside the 3D model'), findsOneWidget);
    expect(
      find.text(
        'Camera height 1.50 m · not a standing-person clearance check.',
      ),
      findsOneWidget,
    );
    final messages = <bool>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'openWorld');
      final request =
          jsonDecode(call.arguments as String) as Map<String, dynamic>;
      messages.add(request['keyControls'] as bool);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final open = find.text('Walk inside the 3D model');
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(messages, [false]);
    await tester.tap(find.text('Forward and backward controls'));
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(messages, [false, true]);
  });

  testWidgets('preview pauses and resets without skipping the journey', (
    tester,
  ) async {
    final site = Site.fromJson(
      File('test/fixtures/site.json').readAsStringSync(),
    );
    await tester.pumpWidget(ValmetApp(site: site));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Play route preview'), 200);
    await tester.tap(find.text('Play route preview'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Pause preview'), findsOneWidget);
    await tester.tap(find.text('Pause preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(find.text('15.8 m remaining'), findsOneWidget);
  });

  testWidgets('blocked start stays explicit and clearance can be reduced', (
    tester,
  ) async {
    final site = Site.fromJson('''{
      "name":"Narrow test","width":5,"depth":1,"cellSize":0.25,"start":[0,0],
      "objects":[{"name":"Target","object_id":"test-target","x":4,"z":0,
      "width":1,"depth":1,"height":1,"cells":[],"service":[4,0]}]}
    ''');
    Map<String, dynamic>? payload;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SiteSimulation(
            site: site,
            loadAssetData: () async => null,
            openNative: (method, [data]) async {
              payload = jsonDecode(data!) as Map<String, dynamic>;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Walk inside the 3D model'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      find.text(
        'Start position lacks the selected clearance. Reduce the radius to move from this start.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Walk inside the 3D model'));
    await tester.pumpAndSettle();
    expect(payload!['walkableFloor'], isEmpty);
    expect(payload!['route'], isEmpty);
    await tester.tap(find.text('0.20 m · camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('0.10 m · virtual camera').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Walk inside the 3D model'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Walk inside the 3D model'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(payload!['clearanceMetres'], .1);
    expect(payload!['arrivalRadiusMetres'], .125);
    expect(payload!['route'], hasLength(5));
    expect(payload!['walkableFloor'], [
      [0, 0],
      [1, 0],
      [2, 0],
      [3, 0],
      [4, 0],
    ]);
    expect((payload!['objects'] as List).first['object_id'], 'test-target');
  });
  testWidgets(
    'opens exploration with no route and sends the same walkable mask',
    (tester) async {
      final site = Site.fromJson(
        jsonEncode({
          'name': 'Disconnected room',
          'width': 5,
          'depth': 3,
          'cellSize': 1,
          'start': [0, 1],
          'floor': [
            for (var x = 0; x < 5; x++)
              for (var z = 0; z < 3; z++) [x, z],
          ],
          'objects': [
            {
              'name': 'Wall',
              'x': 2,
              'z': 0,
              'width': 1,
              'depth': 3,
              'height': 2,
            },
            {
              'name': 'Target',
              'x': 4,
              'z': 1,
              'width': 1,
              'depth': 1,
              'height': 1,
              'cells': [],
              'service': [4, 1],
            },
          ],
        }),
      );
      Map<String, dynamic>? payload;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SiteSimulation(
              site: site,
              loadAssetData: () async => null,
              openNative: (method, [data]) async {
                payload = jsonDecode(data!) as Map<String, dynamic>;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Walk inside the 3D model'));
      await tester.pumpAndSettle();
      expect(payload!['route'], isEmpty);
      expect(payload!['floor'], hasLength(15));
      final allowed = (payload!['walkableFloor'] as List)
          .map((cell) => (cell[0] as int, cell[1] as int))
          .toSet();
      for (var x = 0; x < site.width; x++) {
        for (var z = 0; z < site.depth; z++) {
          expect(
            allowed.contains((x, z)),
            site.isWalkable((x, z), clearanceMetres: .2),
          );
        }
      }
      expect(allowed, contains(site.start));
      expect(allowed, isNot(contains((2, 1))));
      await tester.scrollUntilVisible(find.text('Play route preview'), 200);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Play route preview'),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.text('No route with 0.20 m clearance to this device.'),
        findsOneWidget,
      );
    },
  );
}
