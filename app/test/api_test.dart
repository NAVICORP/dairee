import 'dart:convert';

import 'package:dairee/core/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('select reads every page, not just the first thousand rows', () async {
    final asked = <String>[];
    Api.instance.client = MockClient((req) async {
      final range = req.headers['Range'] ?? '';
      asked.add(range);
      final from = int.parse(range.split('-').first);
      final count = from < 2000 ? 1000 : 345;
      return http.Response(jsonEncode([for (var i = 0; i < count; i++) {'n': from + i}]), 206, headers: {'content-type': 'application/json'});
    });
    final rows = await Api.instance.select('delivery_records');
    expect(rows.length, 2345);
    expect(asked, ['0-999', '1000-1999', '2000-2999']);
  });

  test('an update the database quietly refuses is reported, never shown as saved', () async {
    Api.instance.client = MockClient((req) async => http.Response('[]', 200, headers: {'content-type': 'application/json'}));
    await expectLater(Api.instance.update('staff', {'is_admin': true}, where: {'id': 'eq.x'}), throwsA(isA<ApiError>()));
  });

  test('no signal is told apart from a refusal', () async {
    Api.instance.client = MockClient((req) async => throw Exception('no route'));
    try {
      await Api.instance.rpc('round');
      fail('should not succeed');
    } on ApiError catch (e) {
      expect(e.offline, isTrue);
    }
    Api.instance.client = MockClient((req) async => http.Response(jsonEncode({'message': 'That day is closed.', 'code': '22023'}), 400));
    try {
      await Api.instance.rpc('set_delivery');
      fail('should not succeed');
    } on ApiError catch (e) {
      expect(e.offline, isFalse);
      expect(e.message, 'That day is closed.');
    }
  });

  test('row security refusals read as plain words', () {
    final e = Api.error(403, {'message': 'new row violates row-level security policy for table "staff"', 'code': '42501'});
    expect(e.message, contains('permission'));
  });
}
