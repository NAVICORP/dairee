import 'package:dairee/core/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('money in rupees groups the Indian way', () {
    expect(money(150000, 'INR'), '₹1,50,000');
    expect(money(1750, 'INR'), '₹1,750');
    expect(money(35.5, 'INR'), '₹35.50');
    expect(money(1750, 'AED'), 'AED 1,750');
  });

  test('litres read as people say them', () {
    expect(litres(1), '1 L');
    expect(litres(0.5), '0.5 L');
    expect(litres('2.250'), '2.25 L');
    expect(capacity(500), '500 ml');
    expect(capacity(5000), '5 L');
  });

  test('phone numbers keep the country code', () {
    expect(phoneDigits('98951 77896'), '919895177896');
    expect(phoneDigits('+971 50 123 4567'), '971501234567');
    expect(prettyPhone('919895177896'), '+91 98951 77896');
    expect(localPhone('919895177896'), '9895177896');
  });

  test('days', () {
    final d = DateTime(2026, 10, 28);
    expect(isoDay(d), '2026-10-28');
    expect(dayLabel(d), 'Wed 28 Oct');
    expect(relativeDay(d, d), 'Today');
    expect(relativeDay(DateTime(2026, 10, 29), d), 'Tomorrow');
    expect(parseDay('2026-10-28'), d);
    expect(timeOfDay('06:30:00'), '6:30 am');
  });

  test('a CSV cell is quoted only when it has to be', () {
    expect(csvCell('plain'), 'plain');
    expect(csvCell('a, b'), '"a, b"');
    expect(csvCell('say "hi"'), '"say ""hi"""');
    expect(csvCell(null), '');
  });

  test('where a customer lives', () {
    expect(placeOf({'building': 'Tower 1', 'room': '101'}), 'Tower 1, 101');
    expect(placeOf({'address': 'MG Road'}), 'MG Road');
    expect(vesselsText([{'name': '1 litre bottle', 'quantity': 2}]), '2 x 1 litre bottle');
  });
}
