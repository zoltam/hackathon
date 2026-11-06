import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/main.dart';

void main() {
  testWidgets('opens the Valmet home screen', (tester) async {
    await tester.pumpWidget(const ValmetApp());
    expect(find.text('Valmet Field App'), findsOneWidget);
  });
}
