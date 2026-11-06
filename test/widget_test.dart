import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/main.dart';
import 'package:valmet_field_app/site.dart';

void main() {
  testWidgets('walks to a device, completes service and replays', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final site = Site.fromJson(
      File('test/fixtures/site.json').readAsStringSync(),
    );
    await tester.pumpWidget(ValmetApp(site: site));
    await tester.pumpAndSettle();
    final complete = find.widgetWithText(OutlinedButton, 'Complete service');
    expect(tester.widget<OutlinedButton>(complete).onPressed, isNull);

    await tester.ensureVisible(find.text('Simulate walk'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simulate walk'));
    await tester.pumpAndSettle();
    expect(find.text('Arrived at Boiler B-01.'), findsOneWidget);

    await tester.tap(complete);
    await tester.pumpAndSettle();
    expect(find.text('Service completed in simulation.'), findsOneWidget);

    await tester.tap(find.text('Replay walk'));
    await tester.pumpAndSettle();
    expect(find.text('Arrived at Boiler B-01.'), findsOneWidget);
  });
}
