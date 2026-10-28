import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/format.dart';

/// The printed bill. Every figure on it comes from the bill_balances view,
/// the same answer every screen gives: the paper never does its own
/// subtraction, so it can never ask for money already paid by an advance.
Future<void> shareBillPdf({
  required String farmName,
  required String currency,
  required Map<String, dynamic> balance,
  required Map<String, dynamic> bill,
  required Map<String, dynamic> customer,
}) async {
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Manrope-500.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Manrope-700.ttf'));
  final title = pw.Font.ttf(await rootBundle.load('assets/fonts/BricolageGrotesque-600.ttf'));
  const blue = PdfColor.fromInt(0xFF1064D9);
  const deep = PdfColor.fromInt(0xFF071C42);
  const muted = PdfColor.fromInt(0xFF5A6782);
  const line = PdfColor.fromInt(0xFFE0E6F0);
  String m(Object? v) => money(toNum(v), currency);
  final from = parseDay(balance['period_from'])!;
  final to = parseDay(balance['period_to'])!;

  pw.Widget row(String label, String value, {bool strong = false, PdfColor? color}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 5),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Text(label, style: pw.TextStyle(font: strong ? bold : regular, fontSize: 11, color: strong ? deep : muted))),
          pw.Text(value, style: pw.TextStyle(font: strong ? bold : regular, fontSize: strong ? 13 : 11, color: color ?? deep)),
        ]),
      );

  final doc = pw.Document(title: 'Bill ${balance['bill_number']}', author: farmName);
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a5,
    margin: const pw.EdgeInsets.all(28),
    build: (context) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(farmName, style: pw.TextStyle(font: title, fontSize: 18, color: deep)),
            pw.SizedBox(height: 2),
            pw.Text('Milk bill', style: pw.TextStyle(font: regular, fontSize: 10, color: muted)),
          ]),
        ),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('${balance['bill_number']}', style: pw.TextStyle(font: bold, fontSize: 11, color: blue)),
          pw.Text(dateLabel(parseDay(balance['bill_date'])!), style: pw.TextStyle(font: regular, fontSize: 10, color: muted)),
        ]),
      ]),
      pw.SizedBox(height: 18),
      pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(color: const PdfColor.fromInt(0xFFF0F4FA), borderRadius: pw.BorderRadius.circular(10)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('${customer['name']}', style: pw.TextStyle(font: bold, fontSize: 12, color: deep)),
          if (placeOf(customer).isNotEmpty) pw.Text(placeOf(customer), style: pw.TextStyle(font: regular, fontSize: 10, color: muted)),
          pw.Text(prettyPhone(customer['phone'] as String?), style: pw.TextStyle(font: regular, fontSize: 10, color: muted)),
        ]),
      ),
      pw.SizedBox(height: 14),
      pw.Text(periodLabel(from, to), style: pw.TextStyle(font: bold, fontSize: 11, color: deep)),
      pw.SizedBox(height: 4),
      pw.Text('${bill['delivered_days']} days delivered, ${bill['missed_days']} missed, ${bill['paused_days']} paused',
          style: pw.TextStyle(font: regular, fontSize: 10, color: muted)),
      pw.SizedBox(height: 10),
      pw.Divider(color: line),
      row('Milk', '${litres(bill['total_liters'])} at ${m(bill['milk_price'])} a litre'),
      row('Total', m(balance['total_amount'])),
      if (toNum(balance['discount_amount']) > 0) row('Discount', '- ${m(balance['discount_amount'])}'),
      if (toNum(balance['discount_amount']) > 0) row('After discount', m(balance['net_amount'])),
      if (toNum(balance['credit_applied']) > 0) row('Advance used', '- ${m(balance['credit_applied'])}'),
      row('Amount paid', m(balance['amount_paid'])),
      pw.Divider(color: line),
      row('Balance due', m(balance['balance_due']), strong: true, color: toNum(balance['balance_due']) > 0 ? blue : deep),
      if ((bill['notes'] as String? ?? '').isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Text('${bill['notes']}', style: pw.TextStyle(font: regular, fontSize: 9.5, color: muted)),
      ],
      pw.Spacer(),
      pw.Text(toNum(balance['balance_due']) > 0 ? 'Thank you.' : 'Paid in full. Thank you.', style: pw.TextStyle(font: regular, fontSize: 10, color: muted)),
    ]),
  ));
  final name = 'bill-${balance['bill_number']}.pdf'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
  await Printing.sharePdf(bytes: await doc.save(), filename: name);
}
