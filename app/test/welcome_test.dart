import 'package:dairee/ui/start/welcome.dart';
import 'package:dairee/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the first screen asks who you are', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: daireeTheme(), home: const Welcome()));
    expect(find.text('Dairee'), findsOneWidget);
    expect(find.text('I work at a farm'), findsOneWidget);
    expect(find.text("I'm a customer"), findsOneWidget);
    await tester.tap(find.text("I'm a customer"));
    await tester.pumpAndSettle();
    expect(find.text('Your mobile number'), findsOneWidget);
  });

  test('a number typed after a country code', () {
    expect(fullPhone('91', '98951 77896'), '919895177896');
    expect(fullPhone('91', '+971501234567'), '971501234567');
    expect(fullPhone('91', '12'), '');
  });
}
