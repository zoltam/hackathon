import 'dart:convert';
import 'dart:io';

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
    await tester.pumpWidget(ValmetApp(site: site));
    await tester.pumpAndSettle();

    expect(find.text('Walk inside the 3D model'), findsOneWidget);
    const channel = MethodChannel('valmet/field');
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
    await tester.tap(find.text('Forward and backward controls'));
    await tester.pumpAndSettle();
    await tester.tap(open);
    expect(messages, [false, true]);
  });
}
