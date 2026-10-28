import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';

enum _R { days, customers, money }

/// Deliveries, revenue, per customer and per period, and the export.
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.farm});
  final FarmRole farm;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  late DateTime from = DateTime(widget.farm.today.year, widget.farm.today.month, 1);
  late DateTime to = widget.farm.today;
  _R tab = _R.days;
  List? days;
  List? customers;
  List? money;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = isoDay(from), b = isoDay(to);
    try {
      final r = await Future.wait([
        Api.instance.rpc('report_days', {'date_from': a, 'date_to': b}),
        Api.instance.rpc('report_customers', {'date_from': a, 'date_to': b}),
        if (widget.farm.seesMoney) Api.instance.rpc('report_money', {'date_from': a, 'date_to': b}),
      ]);
      if (!mounted) return;
      setState(() {
        days = r[0] as List?;
        customers = r[1] as List?;
        money = r.length > 2 ? r[2] as List? : null;
        error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.farm;
    final d = days;
    final total = (d ?? const []).whereType<Map>().fold<num>(0, (a, x) => a + toNum(x['morning']) + toNum(x['evening']));
    final produced = (d ?? const []).whereType<Map>().fold<num>(0, (a, x) => a + toNum(x['produced']));
    final stops = (d ?? const []).whereType<Map>().fold<num>(0, (a, x) => a + toNum(x['stops']));
    return Scaffold(
      appBar: AppBar(title: const Text('Reports'), actions: [
        RoundIcon(Icons.download_rounded, tooltip: 'Export', onTap: () => exportFarm(context, f, from: from, to: to)),
        const SizedBox(width: 8),
      ]),
      body: PageBody(onRefresh: _load, children: [
        KChoice(
          label: 'Period',
          value: periodLabel(from, to),
          icon: Icons.date_range_rounded,
          onTap: () async {
            final p = await pickPeriod(context, from: from, to: to);
            if (p == null) return;
            setState(() {
              from = p.$1;
              to = p.$2;
              days = null;
            });
            _load();
          },
        ),
        const SizedBox(height: Sp.md),
        KSegmented<_R>(
          expand: true,
          items: [(_R.days, 'Deliveries'), (_R.customers, 'Customers'), if (f.seesMoney) (_R.money, 'Money')],
          value: tab,
          onChanged: (v) => setState(() => tab = v),
        ),
        const SizedBox(height: Sp.md),
        if (error != null && d == null)
          LoadFailed(message: error!, onRetry: _load)
        else if (d == null)
          const Padding(padding: EdgeInsets.all(40), child: Loading())
        else if (tab == _R.days) ...[
          Row(children: [
            Expanded(child: StatTile(litres(total), 'Delivered')),
            const SizedBox(width: Sp.sm),
            Expanded(child: StatTile('${stops.toInt()}', 'Stops')),
            const SizedBox(width: Sp.sm),
            Expanded(child: StatTile(litres(produced), 'From the herd')),
          ]),
          const SizedBox(height: Sp.md),
          KCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Litres a day', style: T.h3),
              const SizedBox(height: 4),
              const Row(children: [
                _Key(K.blue, 'Morning'),
                SizedBox(width: 12),
                _Key(K.sky, 'Evening'),
                SizedBox(width: 12),
                _Key(K.deep, 'From the herd', line: true),
              ]),
              const SizedBox(height: Sp.md),
              SizedBox(height: 180, child: _DayChart(days: d.whereType<Map>().toList())),
            ]),
          ),
          const SectionTitle('Day by day'),
          KGroup(children: [
            for (final x in d.reversed.whereType<Map>())
              KRow(
                title: dayLabel(parseDay(x['day'])!),
                sub: '${litres(x['morning'])} morning, ${litres(x['evening'])} evening, ${x['stops']} stops',
                trailing: Text(litres(toNum(x['morning']) + toNum(x['evening'])), style: T.bodyStrong),
              ),
          ]),
        ] else if (tab == _R.customers) ...[
          KGroup(children: [
            for (final c in (customers ?? const []).whereType<Map>())
              KRow(
                title: '${c['name']}',
                sub: '${placeOf(Map<String, dynamic>.from(c))}${placeOf(Map<String, dynamic>.from(c)).isEmpty ? '' : ', '}${c['days']} days',
                trailing: Text(litres(c['liters']), style: T.bodyStrong),
              ),
          ]),
        ] else ...[
          for (final m in (money ?? const []).whereType<Map>())
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.sm),
              child: KCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(monthLabel(parseDay(m['month'])!), style: T.h3),
                  const SizedBox(height: Sp.sm),
                  Wrap(spacing: 22, runSpacing: 10, children: [
                    Stat(f.money(toNum(m['billed'])), 'Billed'),
                    Stat(f.money(toNum(m['collected'])), 'Collected'),
                    Stat(f.money(toNum(m['credit_applied'])), 'Credit used'),
                    Stat(f.money(toNum(m['outstanding'])), 'Still owed'),
                    Stat(f.money(toNum(m['received'])), 'Money received'),
                  ]),
                ]),
              ),
            ),
        ],
      ]),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key(this.color, this.label, {this.line = false});
  final Color color;
  final String label;
  final bool line;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: line ? 14 : 10, height: line ? 3 : 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 5),
        Text(label, style: T.tiny),
      ]);
}

/// Bars for each day (morning below, evening on top) and a line for what the
/// herd gave.
class _DayChart extends StatelessWidget {
  const _DayChart({required this.days});
  final List<Map> days;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _ChartPainter(days), size: Size.infinite);
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.days);
  final List<Map> days;

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    var top = 0.0;
    for (final d in days) {
      top = [top, (toNum(d['morning']) + toNum(d['evening'])).toDouble(), toNum(d['produced']).toDouble()].reduce((a, b) => a > b ? a : b);
    }
    if (top <= 0) top = 1;
    final grid = Paint()
      ..color = K.border
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final w = size.width / days.length;
    final bar = (w * 0.64).clamp(1.0, 28.0);
    final am = Paint()..color = K.blue;
    final pm = Paint()..color = K.sky;
    final path = Path();
    var joined = false;
    for (var i = 0; i < days.length; i++) {
      final x = w * i + (w - bar) / 2;
      final m = toNum(days[i]['morning']).toDouble() / top * size.height;
      final e = toNum(days[i]['evening']).toDouble() / top * size.height;
      final r = Radius.circular(bar / 3);
      if (m > 0) canvas.drawRRect(RRect.fromRectAndCorners(Rect.fromLTWH(x, size.height - m, bar, m), topLeft: e > 0 ? Radius.zero : r, topRight: e > 0 ? Radius.zero : r), am);
      if (e > 0) canvas.drawRRect(RRect.fromRectAndCorners(Rect.fromLTWH(x, size.height - m - e, bar, e), topLeft: r, topRight: r), pm);
      // A day with no milk recorded from the herd is a gap in the line, not a drop to nothing.
      final produced = toNum(days[i]['produced']).toDouble();
      if (produced <= 0) {
        joined = false;
        continue;
      }
      final py = size.height - produced / top * size.height;
      final px = w * i + w / 2;
      if (joined) {
        path.lineTo(px, py);
      } else {
        path.moveTo(px, py);
        joined = true;
      }
    }
    if (days.any((d) => toNum(d['produced']) > 0)) {
      canvas.drawPath(
          path,
          Paint()
            ..color = K.deep
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => old.days != days;
}

// ---------------------------------------------------------------- export

/// The farm's records as spreadsheets (CSV), each read page after page so
/// nothing is cut off at a thousand rows. The sign-in tables are never part
/// of it: they are keys, not records.
Future<void> exportFarm(BuildContext context, FarmRole farm, {required DateTime from, required DateTime to}) async {
  final what = await showPicker<String>(context, title: 'Export', options: [
    const PickOption('customers', 'Customers', sub: 'Everyone, with their milk and vessels'),
    PickOption('deliveries', 'Deliveries', sub: periodLabel(from, to)),
    if (farm.seesMoney) const PickOption('bills', 'Bills', sub: 'With what is paid and owed'),
    if (farm.seesMoney) const PickOption('payments', 'Payments'),
    const PickOption('pauses', 'Pauses'),
    const PickOption('cows', 'The herd'),
  ]);
  if (what == null || !context.mounted) return;
  toast(context, 'Preparing the file...');
  try {
    final rows = <List<Object?>>[];
    final a = isoDay(from), b = isoDay(to);
    final names = {for (final c in await Api.instance.select('customers', columns: 'id,name')) c['id']: c['name']};
    switch (what.value) {
      case 'customers':
        rows.add(['Name', 'Mobile', 'Type', 'Building', 'Room', 'Address', 'Round', 'Litres a day', 'Morning', 'Evening', 'Status', 'Since', 'Notes']);
        for (final c in await Api.instance.select('customers', order: 'building.asc.nullsfirst,route_order.asc,name.asc',
            columns: 'name,phone,customer_type,building,room,address,delivery_slot,milk_quantity,morning_quantity,evening_quantity,status,start_date,remarks')) {
          rows.add([c['name'], c['phone'], c['customer_type'], c['building'], c['room'], c['address'], c['delivery_slot'], c['milk_quantity'],
            c['morning_quantity'], c['evening_quantity'], c['status'], c['start_date'], c['remarks']]);
        }
      case 'deliveries':
        rows.add(['Date', 'Round', 'Customer', 'Delivered', 'Litres', 'Vessels', 'Bottles back', 'Note', 'By']);
        for (final r in await Api.instance.select('delivery_records',
            columns: 'delivery_date,slot,customer_id,delivered,milk_quantity,containers,bottle_returned,notes,updated_by',
            where: {'and': '(delivery_date.gte.$a,delivery_date.lte.$b)'}, order: 'delivery_date.asc,slot.desc')) {
          rows.add([r['delivery_date'], r['slot'], names[r['customer_id']], r['delivered'] == true ? 'yes' : 'no', r['milk_quantity'],
            vesselsText(r['containers']), r['bottle_returned'] == true ? 'yes' : 'no', r['notes'], r['updated_by']]);
        }
      case 'bills':
        rows.add(['Bill', 'Customer', 'From', 'To', 'Bill date', 'Total', 'Discount', 'Net', 'Credit used', 'Paid', 'Balance due']);
        for (final x in await Api.instance.select('bill_balances', order: 'bill_date.asc')) {
          rows.add([x['bill_number'], names[x['customer_id']], x['period_from'], x['period_to'], x['bill_date'], x['total_amount'], x['discount_amount'],
            x['net_amount'], x['credit_applied'], x['amount_paid'], x['balance_due']]);
        }
      case 'payments':
        rows.add(['Date', 'Customer', 'Amount', 'How', 'Against a bill', 'Receipt', 'Note', 'Recorded by']);
        for (final p in await Api.instance.select('payments',
            columns: 'payment_date,customer_id,amount,payment_method,bill_id,receipt_number,notes,recorded_by', order: 'payment_date.asc')) {
          rows.add([p['payment_date'], names[p['customer_id']], p['amount'], p['payment_method'], p['bill_id'] == null ? 'no (credit)' : 'yes',
            p['receipt_number'], p['notes'], p['recorded_by']]);
        }
      case 'pauses':
        rows.add(['Customer', 'Kind', 'From', 'To', 'Round', 'Set by', 'Reason']);
        for (final p in await Api.instance.select('customer_pauses', columns: 'customer_id,pause_type,from_date,to_date,slot,set_by,reason', order: 'from_date.asc')) {
          rows.add([names[p['customer_id']], p['pause_type'], p['from_date'], p['to_date'], p['slot'], p['set_by'], p['reason']]);
        }
        for (final p in await Api.instance.select('customer_pause_dates', columns: 'customer_id,pause_date,slot,set_by,reason', order: 'pause_date.asc')) {
          rows.add([names[p['customer_id']], 'date', p['pause_date'], p['pause_date'], p['slot'], p['set_by'], p['reason']]);
        }
      case 'cows':
        rows.add(['Tag', 'Name', 'Breed', 'Status', 'Born', 'Pregnancy', 'Last calving', 'Location', 'Notes']);
        for (final c in await Api.instance.select('cows',
            columns: 'tag_number,name,breed,status,date_of_birth,pregnancy_status,last_calving_date,location,notes', order: 'tag_number.asc')) {
          rows.add([c['tag_number'], c['name'], c['breed'], c['status'], c['date_of_birth'], c['pregnancy_status'], c['last_calving_date'], c['location'], c['notes']]);
        }
    }
    final csv = '﻿${rows.map((r) => r.map(csvCell).join(',')).join('\r\n')}\r\n';
    final slug = farm.slug.isEmpty ? 'dairee' : farm.slug;
    final name = '$slug-${what.value}-${isoDay(DateTime.now())}.csv';
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(utf8.encode(csv), mimeType: 'text/csv', name: name)],
      fileNameOverrides: [name],
      title: name,
    ));
  } on ApiError catch (e) {
    if (context.mounted) toast(context, e.message, bad: true);
  }
}
