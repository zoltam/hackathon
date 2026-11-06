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
    final messages = <bool>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/assets', (_) async => null);
    addTearDown(() => messenger.setMockMessageHandler('flutter/assets', null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'openWorld');
      final request =
          jsonDecode(call.arguments as String) as Map<String, dynamic>;
      messages.add(request['keyControls'] as bool);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ValmetApp(site: site));
    await tester.pumpAndSettle();

    final open = find.text('Walk inside the 3D model');
    expect(open, findsOneWidget);
    await tester.tap(open);
    await tester.tap(find.text('Forward and backward controls'));
    await tester.pumpAndSettle();
    await tester.tap(open);
    expect(messages, [false, true]);
  });

  testWidgets('shows route distance without playback controls', (tester) async {
    final site = Site.fromJson(
      File('test/fixtures/site.json').readAsStringSync(),
    );
    await tester.pumpWidget(ValmetApp(site: site));
    await tester.pumpAndSettle();
    expect(find.text('15.8 m · route with 0.20 m clearance'), findsOneWidget);
    expect(find.text('Play route preview'), findsNothing);
    expect(find.text('Pause preview'), findsNothing);
    expect(find.text('Reset'), findsNothing);
  });

  testWidgets('clearance blocks native launch and can be explicitly reduced', (
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
      isNull,
    );
    await tester.tap(find.text('0.20 m · avatar'));
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
    expect((payload!['objects'] as List).first['object_id'], 'test-target');
  });
}
