import 'package:flutter_test/flutter_test.dart';
import 'package:local_widgets/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const StillApp());
    await tester.pump();
    expect(find.text('Still'), findsOneWidget);
    expect(find.text('Loading your offline library...'), findsOneWidget);
  });
}
