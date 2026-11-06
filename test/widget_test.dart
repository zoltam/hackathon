import 'dart:io';

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
    expect(find.text('Simulate walk'), findsNothing);
    expect(find.text('Record or replay a camera route'), findsNothing);
  });
}
