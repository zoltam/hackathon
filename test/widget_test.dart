import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/main.dart';
import 'package:valmet_field_app/site.dart';

void main() {
  testWidgets('passes the selected frame rate to the 3D viewer', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/assets', (_) async => null);
    addTearDown(() => messenger.setMockMessageHandler('flutter/assets', null));
    rootBundle.evict('assets/valmet/asset-data.json');
    addTearDown(() => rootBundle.evict('assets/valmet/asset-data.json'));
    final roomJson =
        jsonDecode(File('test/fixtures/site.json').readAsStringSync())
            as Map<String, dynamic>;
    roomJson['sourceSha256'] = 'test-scan-sha256';
    final room = Site.fromJson(jsonEncode(roomJson));
    final rates = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SiteSimulation(
            site: room,
            loadAssetData: () async => null,
            openNative: (_, [data]) async {
              expect(
                (jsonDecode(data!) as Map<String, dynamic>)['sourceSha256'],
                'test-scan-sha256',
              );
              rates.add(
                (jsonDecode(data) as Map<String, dynamic>)['framesPerSecond']
                    as int,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final open = find.text('Walk inside the 3D model');
    await tester.scrollUntilVisible(open, 200);
    await tester.tap(open);
    await tester.pumpAndSettle();
    for (final rate in [15, 30]) {
      final dropdown = find.byType(DropdownButtonFormField<int>);
      await tester.scrollUntilVisible(dropdown, -200);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('$rate FPS').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(open, 200);
      await tester.tap(open);
      await tester.pumpAndSettle();
    }
    expect(rates, [60, 15, 30]);
  });

  testWidgets('opens with a route and the first-person walkthrough', (
    tester,
  ) async {
    final site = Site.fromJson(
      File('test/fixtures/site.json').readAsStringSync(),
    );
    const channel = MethodChannel('valmet/field');

    final messages = <bool>[];
    rootBundle.evict('assets/valmet/asset-data.json');
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
    expect(
      find.text(
        'Camera height 1.50 m · not a standing-person clearance check.',
      ),
      findsOneWidget,
    );
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(messages, [false]);
    await tester.tap(find.text('Forward and backward controls'));
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(messages, [false, true]);
  });

  testWidgets('shows route distance without a preview map or playback', (
    tester,
  ) async {
    final site = Site.fromJson(
      File('test/fixtures/site.json').readAsStringSync(),
    );
    await tester.pumpWidget(ValmetApp(site: site));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('15.8 m · route with 0.20 m clearance'),
      200,
    );
    await tester.pumpAndSettle();
    expect(find.text('15.8 m · route with 0.20 m clearance'), findsOneWidget);
    expect(find.byKey(const ValueKey('site-minimap')), findsNothing);
    expect(tester.takeException(), isNull);
    expect(find.text('Play route preview'), findsNothing);
    expect(find.text('Pause preview'), findsNothing);
    expect(find.text('Reset'), findsNothing);
  });

  testWidgets('shows and sends workbook tags only for compatible equipment', (
    tester,
  ) async {
    final site = Site.fromJson('''{
      "name":"Workshop","width":6,"depth":4,"cellSize":1,"start":[0,0],
      "sourceSha256":"scene-hash",
      "objects":[
        {"name":"Feed pump","object_id":"pump","equipmentType":"pump",
         "x":4,"z":1,"width":2,"depth":1,"height":1.5,"service":[3,1]},
        {"name":"Inlet valve","object_id":"valve","equipmentType":"valve",
         "x":2,"z":3,"width":1,"depth":1,"height":1,"service":[2,2]}
      ]
    }''');
    const workbook = '''{
      "schemaVersion":1,"synthetic":true,
      "sourceSha256":"workbook-hash",
      "mappings":{"pump":"asset-1","valve":"asset-2"},
      "tables":{
        "Asset_Master":[
          {"asset_id":"asset-1","tag":"P-005","asset_class":"PROCESS_PUMP"},
          {"asset_id":"asset-2","tag":"P-006","asset_class":"PROCESS_PUMP"}
        ],
        "Current_State":[
          {"asset_id":"asset-1","condition_state":"attention_required",
           "recommended_next_check":"Inspect coupling","_source":"Current_State!2"}
        ],"Telemetry_Sample_3d":[],"Alarms_Events":[],
        "Maintenance_History":[],"Historical_Service_Cases":[],
        "Knowledge_Docs":[],"Data_Quality":[]
      }
    }''';
    const asset = 'assets/valmet/asset-data.json';
    const associations = 'assets/valmet/associations.json';
    const diagnostics = 'assets/valmet/diagnostics.json';
    const channel = MethodChannel('valmet/field');
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final name in [asset, associations, diagnostics]) {
      rootBundle.evict(name);
    }
    var diagnosticSceneHash = 'scene-hash';
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final name = const StringCodec().decodeMessage(message);
      final data = switch (name) {
        asset => workbook,
        associations =>
          '''
          {"schemaVersion":1,"sourceSha256":"workbook-hash",
           "sceneSourceSha256":"scene-hash","synthetic":true,
           "associations":[{"sceneObjectId":"pump","workbookAssetId":"asset-1","synthetic":true}]}
        ''',
        diagnostics =>
          '''
          {"schemaVersion":1,"sourceSha256":"workbook-hash",
           "sceneSourceSha256":"$diagnosticSceneHash",
           "reports":{"pump":{"sceneObjectId":"pump","workbookAssetId":"asset-1",
           "sourceSha256":"workbook-hash","synthetic":true,"tag":"P-005",
           "condition":"attention_required","summary":"Check the coupling.",
           "mappingNotice":"Synthetic association","reportText":"Evidence [Current_State!2]",
           "engine":"ollama","modelStatus":"validated","llmSummary":"Validated local explanation.",
           "llmReferences":["Current_State!2"],"citations":[{"reference":"Current_State!2"}]}}}
        ''',
        _ => null,
      };
      return data == null ? null : const StringCodec().encodeMessage(data);
    });
    Map<String, dynamic>? payload;
    String? openedMethod;
    messenger.setMockMethodCallHandler(channel, (call) async {
      openedMethod = call.method;
      payload = jsonDecode(call.arguments as String) as Map<String, dynamic>;
      return null;
    });
    addTearDown(() {
      for (final name in [asset, associations, diagnostics]) {
        rootBundle.evict(name);
      }
      messenger.setMockMessageHandler('flutter/assets', null);
      messenger.setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(ValmetApp(site: site));
    await tester.pumpAndSettle();
    expect(find.text('P-005 · Feed pump'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(find.byType(Card, skipOffstage: false), findsNothing);
    final open = find.text('Walk inside the 3D model');
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(openedMethod, 'openWorld');
    expect(payload!['hasWorkbook'], isTrue);
    expect(payload!['inspectionSummary'], contains('Inspect coupling'));
    expect(payload!['inspectionReport'], contains('Current_State!2'));
    expect(
      payload!['inspectionReport'],
      contains('Validated local explanation'),
    );
    final objects = (payload!['objects'] as List).cast<Map<String, dynamic>>();
    expect(objects, hasLength(2));
    for (final object in site.objects) {
      final sent = objects.singleWhere(
        (row) => row['object_id'] == object.objectId,
      );
      expect(sent['name'], object.name);
      expect(sent['x'], object.x);
      expect(sent['z'], object.z);
      expect(sent['width'], object.width);
      expect(sent['depth'], object.depth);
      expect(sent['height'], object.height);
      expect(sent['service'], [object.service!.$1, object.service!.$2]);
      expect(sent['workbookTag'], object.objectId == 'pump' ? 'P-005' : null);
    }

    final pump = find.text('P-005 · Feed pump');
    await tester.scrollUntilVisible(pump, -200);
    await tester.tap(pump);
    await tester.pumpAndSettle();
    expect(find.text('Inlet valve'), findsOneWidget);
    expect(find.textContaining('P-006'), findsNothing);
    await tester.tap(find.text('Inlet valve'));
    await tester.pumpAndSettle();
    final simulate = find.text('Simulate service visit');
    await tester.scrollUntilVisible(simulate, 200);
    await tester.tap(simulate);
    await tester.pumpAndSettle();
    expect(openedMethod, 'openServiceSimulation');
    expect(payload!['target'], 1);
    expect((payload!['route'] as List).last, [2, 2]);
    expect(payload!['keyControls'], isFalse);
    expect(payload!['obstacleDemo'], isFalse);

    diagnosticSceneHash = 'unrelated-scene';
    rootBundle.evict(diagnostics);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(ValmetApp(site: site));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pumpAndSettle();
    await tester.tap(simulate);
    await tester.pumpAndSettle();
    expect(payload!['inspectionReport'], contains('Inspect coupling'));
    expect(
      payload!['inspectionReport'],
      isNot(contains('Validated local explanation')),
    );
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
    expect(payload!['arrivalRadiusMetres'], .3);
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

  testWidgets('uses the registered person export and retains legacy AR', (
    tester,
  ) async {
    const baseAsset = 'assets/valmet/site.json';
    const personAsset = 'assets/valmet/person-site.json';
    final room = <String, dynamic>{
      'name': 'Workshop',
      'sourceSha256': 'same-scan',
      'width': 6,
      'depth': 4,
      'cellSize': 1,
      'start': [0, 0],
      'floor': [
        for (var x = 0; x < 6; x++)
          for (var z = 0; z < 4; z++) [x, z],
      ],
      'objects': [
        {
          'name': 'Feed pump',
          'objectId': 'pump',
          'x': 4,
          'z': 1,
          'width': 1,
          'depth': 1,
          'height': 1,
          'service': [3, 1],
        },
      ],
    };
    final person = {
      ...room,
      'start': [1, 1],
      'objects': [
        {
          ...(room['objects'] as List).single as Map<String, Object>,
          'extractionBounds': [
            [4, 0, 1],
            [5, 1, 2],
          ],
        },
      ],
      'navigationProfile': {
        'name': 'walking-person',
        'radiusMetres': 0.30,
        'bodyHeightMetres': 1.80,
        'headMarginMetres': 0.05,
        'eyeHeightMetres': 1.65,
        'speedMetresPerSecond': 0.7,
      },
    };
    const channel = MethodChannel('valmet/field');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final site = switch (const StringCodec().decodeMessage(message)) {
        baseAsset => room,
        personAsset => person,
        _ => null,
      };
      return site == null
          ? null
          : const StringCodec().encodeMessage(jsonEncode(site));
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      rootBundle.evict(baseAsset);
      rootBundle.evict(personAsset);
      messenger.setMockMessageHandler('flutter/assets', null);
      messenger.setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(const ValmetApp());
    await tester.pumpAndSettle();
    final simulate = find.text('Simulate service visit');
    await tester.scrollUntilVisible(simulate, 200);
    await tester.tap(simulate);
    await tester.pumpAndSettle();
    expect(calls.single.method, 'openServiceSimulation');
    final payload = jsonDecode(calls.single.arguments as String);
    expect(payload['route'], [
      [1, 1],
      [2, 1],
      [3, 1],
    ]);
    expect(payload['clearanceMetres'], 0.30);
    expect(payload['eyeHeightMetres'], 1.65);
    expect(payload['walkingSpeedMetresPerSecond'], 0.7);
    expect(payload['objects'].single['extractionBounds'], [
      [4, 0, 1],
      [5, 1, 2],
    ]);
    expect(find.text('Walk inside the 3D model'), findsNothing);

    await tester.tap(find.text('Walking-person simulation'));
    await tester.pumpAndSettle();
    final walk = find.text('Walk inside the 3D model');
    await tester.scrollUntilVisible(walk, 200);
    await tester.tap(walk);
    await tester.pumpAndSettle();
    expect(calls.last.method, 'openWorld');
    final legacyPayload = jsonDecode(calls.last.arguments as String);
    expect(legacyPayload['start'], [0, 0]);
    expect(legacyPayload['objects'].single['extractionBounds'], [
      [4, 0, 1],
      [5, 1, 2],
    ]);
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
      expect(find.text('Play route preview'), findsNothing);
      expect(
        find.text('No route with 0.20 m clearance to this device.'),
        findsOneWidget,
      );
    },
  );
}
