import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';
import 'customers.dart';

/// Pause / Stop: who is paused, who gets something different on a day, what
/// customers have asked for, and whether customers may pause at all.
class ChangesPage extends StatefulWidget {
  const ChangesPage({super.key, required this.farm});
  final FarmRole farm;

  @override
  State<ChangesPage> createState() => _ChangesPageState();
}

class _ChangesPageState extends State<ChangesPage> {
  Map<String, String> names = {};
  List<Map<String, dynamic>>? pauses;
  List<Map<String, dynamic>> dates = const [];
  List<Map<String, dynamic>> temps = const [];
  List<Map<String, dynamic>> requests = const [];
  bool? customerPause;
  bool? customerRequests;
  String? error;

  DateTime get today => widget.farm.today;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = isoDay(today);
    try {
      final r = await Future.wait([
        Api.instance.select('customers', columns: 'id,name,building,room'),
        Api.instance.select('customer_pauses',
            columns: 'id,customer_id,pause_type,from_date,to_date,slot,reason,set_by,set_by_name',
            where: {'is_active': 'eq.true', 'or': '(to_date.is.null,to_date.gte.$t)'},
            order: 'from_date.asc'),
        Api.instance.select('customer_pause_dates', columns: 'id,customer_id,pause_date,slot,set_by', where: {'pause_date': 'gte.$t'}, order: 'pause_date.asc'),
        Api.instance.select('temporary_deliveries', columns: 'id,customer_id,delivery_date,slot,quantity,containers,note', where: {'delivery_date': 'gte.$t'}, order: 'delivery_date.asc'),
        Api.instance.select('temporary_requests',
            columns: 'id,customer_id,delivery_date,slot,quantity,containers,note,status,requested_at', where: {'status': 'eq.pending'}, order: 'delivery_date.asc'),
        Api.instance.select('farms', columns: 'customer_pause,customer_requests', where: {'id': 'eq.${widget.farm.id}'}),
      ]);
      if (!mounted) return;
      setState(() {
        names = {for (final c in r[0]) c['id'] as String: [c['name'], placeOf(c)].where((x) => '$x'.isNotEmpty).join(', ')};
        pauses = r[1];
        dates = r[2];
        temps = r[3];
        requests = r[4];
        if (r[5].isNotEmpty) {
          customerPause = r[5].first['customer_pause'] == true;
          customerRequests = r[5].first['customer_requests'] == true;
        }
        error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _do(Future<void> Function() job) async {
    try {
      await job();
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _switch({bool? pause, bool? req}) => _do(() async {
        final r = await Api.instance.rpc('set_portal_switches', {'customer_pause': pause, 'customer_requests': req});
        if (r is Map && mounted) {
          setState(() {
            customerPause = r['customer_pause'] == true;
            customerRequests = r['customer_requests'] == true;
          });
        }
      });

  String _when(Map p) {
    final from = parseDay(p['from_date'])!;
    final to = parseDay(p['to_date']);
    final slot = p['slot'] == 'both' ? '' : ', ${p['slot']} only';
    if (to == null) return 'From ${dayInSentence(from, today)} until resumed$slot';
    if (to == from) return '${relativeDay(from, today)}$slot';
    return '${shortDate(from)} to ${shortDate(to)}$slot';
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.farm;
    return Scaffold(
      appBar: AppBar(title: const Text('Pause / Stop')),
      body: PageBody(onRefresh: _load, children: [
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          KButton(
              label: 'Pause someone',
              icon: Icons.pause_rounded,
              small: true,
              onPressed: () async {
                final c = await pickCustomer(context, title: 'Pause whose milk?');
                if (c != null && context.mounted && await showPauseSheet(context, f, c)) _load();
              }),
          KButton(
              label: 'Change a day',
              icon: Icons.swap_horiz_rounded,
              kind: KButtonKind.secondary,
              small: true,
              onPressed: () async {
                final c = await pickCustomer(context, title: 'Whose milk changes?');
                if (c != null && context.mounted && await showTemporarySheet(context, f, c)) _load();
              }),
        ]),
        if (error != null && pauses == null)
          LoadFailed(message: error!, onRetry: _load)
        else if (pauses == null)
          const Padding(padding: EdgeInsets.all(40), child: Loading())
        else ...[
          if (requests.isNotEmpty) ...[
            SectionTitle('Asked for by customers', trailing: Pill('${requests.length}')),
            KGroup(children: [
              for (final r in requests)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(names[r['customer_id']] ?? 'Customer', style: T.bodyStrong),
                    Text('${litres(r['quantity'])} on ${dayLabel(parseDay(r['delivery_date'])!)}, ${r['slot']}${(r['containers'] as List? ?? const []).isEmpty ? '' : ', ${vesselsText(r['containers'])}'}',
                        style: T.small),
                    if ((r['note'] as String? ?? '').isNotEmpty) Text('"${r['note']}"', style: T.small.copyWith(color: K.ink2)),
                    const SizedBox(height: 8),
                    Row(children: [
                      KButton(label: 'Approve', icon: Icons.check_rounded, small: true, onPressed: () => _do(() => Api.instance.rpc('decide_request', {'request_id': r['id'], 'approve': true}))),
                      const SizedBox(width: Sp.sm),
                      KButton(label: 'Refuse', kind: KButtonKind.ghost, small: true, onPressed: () => _do(() => Api.instance.rpc('decide_request', {'request_id': r['id'], 'approve': false}))),
                    ]),
                  ]),
                ),
            ]),
          ],
          SectionTitle('Paused', trailing: Pill('${pauses!.length + dates.length}')),
          if (pauses!.isEmpty && dates.isEmpty)
            const KCard(child: Text('Nobody is paused.', style: T.small))
          else
            KGroup(children: [
              for (final p in pauses!)
                KRow(
                  title: names[p['customer_id']] ?? 'Customer',
                  sub: [_when(p), if (p['set_by'] == 'customer') 'by the customer', if ((p['reason'] as String? ?? '').isNotEmpty) '${p['reason']}'].join(', '),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (p['to_date'] == null)
                      KButton(
                          label: 'Resume',
                          small: true,
                          kind: KButtonKind.secondary,
                          onPressed: () => _do(() => Api.instance.rpc('resume_customer', {'customer_id': p['customer_id']}))),
                    RoundIcon(Icons.delete_outline_rounded, size: 32, tooltip: 'Remove this pause', onTap: () => _do(() => Api.instance.rpc('remove_pause', {'pause_id': p['id']}))),
                  ]),
                ),
              for (final d in dates)
                KRow(
                  title: names[d['customer_id']] ?? 'Customer',
                  sub: '${relativeDay(parseDay(d['pause_date'])!, today)}${d['slot'] == 'both' ? '' : ', ${d['slot']} only'}${d['set_by'] == 'customer' ? ', by the customer' : ''}',
                  trailing: RoundIcon(Icons.delete_outline_rounded, size: 32, tooltip: 'Remove', onTap: () => _do(() => Api.instance.rpc('remove_pause', {'pause_id': d['id']}))),
                ),
            ]),
          SectionTitle('Changed for a day', trailing: Pill('${temps.length}')),
          if (temps.isEmpty)
            const KCard(child: Text('No temporary changes.', style: T.small))
          else
            KGroup(children: [
              for (final t in temps)
                KRow(
                  title: names[t['customer_id']] ?? 'Customer',
                  sub: '${litres(t['quantity'])} ${onDay(parseDay(t['delivery_date'])!, today)}, ${t['slot']}${(t['note'] as String? ?? '').isEmpty ? '' : ', ${t['note']}'}',
                  trailing: RoundIcon(Icons.delete_outline_rounded, size: 32, tooltip: 'Back to the usual', onTap: () => _do(() => Api.instance.rpc('remove_temporary', {'temporary_id': t['id']}))),
                ),
            ]),
          const SectionTitle('Customers in the app'),
          KCard(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Column(children: [
              KSwitchRow(
                title: 'Customers can pause their milk',
                sub: 'Until each round\'s packing starts',
                value: customerPause ?? true,
                onChanged: (v) => _switch(pause: v),
              ),
              const Divider(),
              KSwitchRow(
                title: 'Customers can ask for a different amount',
                sub: 'You approve or refuse each one here',
                value: customerRequests ?? true,
                onChanged: (v) => _switch(req: v),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- pause one customer

enum _Kind { tomorrow, today, range, open, dates }

/// Pauses a customer's milk. A pause never deletes anything: the standing
/// order stays, and the pause is read on the day.
Future<bool> showPauseSheet(BuildContext context, FarmRole farm, Map<String, dynamic> c) async {
  final today = farm.today;
  var kind = _Kind.tomorrow;
  var slot = 'both';
  var from = addDays(today, 1);
  var to = addDays(today, 3);
  final picked = <DateTime>[];
  final reason = TextEditingController();
  final ok = await showKSheet<bool>(context, title: 'Pause ${c['name']}', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (k, label) in [
              (_Kind.tomorrow, 'Tomorrow'),
              (_Kind.today, 'Today'),
              (_Kind.range, 'From and to'),
              (_Kind.open, 'Until resumed'),
              (_Kind.dates, 'Some dates'),
            ])
              ChoiceChip(
                label: Text(label),
                selected: kind == k,
                showCheckmark: false,
                labelStyle: T.label.copyWith(color: kind == k ? Colors.white : K.ink2),
                selectedColor: K.blue,
                backgroundColor: K.surface,
                side: BorderSide(color: kind == k ? K.blue : K.border2),
                shape: const StadiumBorder(),
                onSelected: (_) => set(() => kind = k),
              ),
          ]),
          const SizedBox(height: Sp.md),
          if (kind == _Kind.range || kind == _Kind.open)
            Row(children: [
              Expanded(
                child: KChoice(
                    label: 'From',
                    value: dayLabel(from),
                    onTap: () async {
                      final d = await pickDate(ctx, initial: from, first: today);
                      if (d != null) set(() => from = d);
                    }),
              ),
              if (kind == _Kind.range) ...[
                const SizedBox(width: Sp.md),
                Expanded(
                  child: KChoice(
                      label: 'To',
                      value: dayLabel(to.isBefore(from) ? from : to),
                      onTap: () async {
                        final d = await pickDate(ctx, initial: to.isBefore(from) ? from : to, first: from);
                        if (d != null) set(() => to = d);
                      }),
                ),
              ],
            ]),
          if (kind == _Kind.dates) ...[
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final d in picked) InputChip(label: Text(dayLabel(d)), onDeleted: () => set(() => picked.remove(d))),
              ActionChip(
                avatar: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add a date'),
                onPressed: () async {
                  final d = await pickDate(ctx, initial: picked.isEmpty ? addDays(today, 1) : addDays(picked.last, 1), first: today);
                  if (d != null && !picked.contains(d)) set(() => picked.add(d));
                },
              ),
            ]),
          ],
          const SizedBox(height: Sp.md),
          KSegmented<String>(
              expand: true, items: const [('both', 'Both rounds'), ('morning', 'Morning'), ('evening', 'Evening')], value: slot, onChanged: (v) => set(() => slot = v)),
          const SizedBox(height: Sp.md),
          KField(label: 'Reason (optional)', controller: reason, hint: 'Away for a wedding'),
          const SizedBox(height: Sp.lg),
          KButton(
            label: 'Pause',
            icon: Icons.pause_rounded,
            expand: true,
            onPressed: () async {
              final k = switch (kind) {
                _Kind.tomorrow => 'tomorrow_only',
                _Kind.today => 'today_only',
                _Kind.range => 'custom_range',
                _Kind.open => 'until_resumed',
                _Kind.dates => 'dates',
              };
              try {
                await Api.instance.rpc('pause_customer', {
                  'customer_id': c['id'],
                  'kind': k,
                  'from_date': isoDay(from),
                  'to_date': kind == _Kind.range ? isoDay(to.isBefore(from) ? from : to) : null,
                  'slot': slot,
                  'reason': reason.text.trim(),
                  'dates': kind == _Kind.dates ? [for (final d in picked) isoDay(d)] : null,
                });
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } on ApiError catch (e) {
                if (ctx.mounted) toast(ctx, e.message, bad: true);
              }
            },
          ),
        ]);
      }));
  reason.dispose();
  return ok == true;
}

// ---------------------------------------------------------------- a different amount on one day

/// "Guests on Saturday, send 5 litres": changes nothing permanent.
Future<bool> showTemporarySheet(BuildContext context, FarmRole farm, Map<String, dynamic> c) async {
  List<Map<String, dynamic>> kinds;
  try {
    kinds = await Api.instance.select('containers', columns: 'id,name,category,capacity_ml', where: {'active': 'eq.true'}, order: 'sort_order.asc,capacity_ml.asc');
  } on ApiError catch (e) {
    if (context.mounted) toast(context, e.message, bad: true);
    return false;
  }
  if (!context.mounted) return false;
  var day = addDays(farm.today, 1);
  var slot = c['delivery_slot'] == 'evening' ? 'evening' : 'morning';
  final qty = TextEditingController();
  final note = TextEditingController();
  final counts = <String, int>{};
  final ok = await showKSheet<bool>(context, title: 'Change a day for ${c['name']}', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final holds = kinds.fold<num>(0, (a, k) => a + (counts[k['id']] ?? 0) * toNum(k['capacity_ml']) / 1000);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KChoice(
              label: 'Day',
              value: relativeDay(day, farm.today),
              icon: Icons.event_outlined,
              onTap: () async {
                final d = await pickDate(ctx, initial: day, first: farm.today);
                if (d != null) set(() => day = d);
              }),
          const SizedBox(height: Sp.md),
          KSegmented<String>(expand: true, items: const [('morning', 'Morning'), ('evening', 'Evening')], value: slot, onChanged: (v) => set(() => slot = v)),
          const SizedBox(height: Sp.md),
          KField(
              label: 'Litres that day',
              controller: qty,
              hint: '0 for none',
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))]),
          SectionTitle('Vessels', top: 14, trailing: Pill('Holds ${litres(holds)}')),
          KGroup(children: [
            for (final k in kinds)
              KRow(
                title: '${k['name']}',
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  RoundIcon(Icons.remove_rounded, size: 30, onTap: (counts[k['id']] ?? 0) > 0 ? () => set(() => counts[k['id'] as String] = (counts[k['id']] ?? 0) - 1) : null),
                  SizedBox(width: 24, child: Text('${counts[k['id']] ?? 0}', textAlign: TextAlign.center, style: T.bodyStrong)),
                  RoundIcon(Icons.add_rounded, size: 30, onTap: () => set(() => counts[k['id'] as String] = (counts[k['id']] ?? 0) + 1)),
                ]),
              ),
          ]),
          const SizedBox(height: Sp.md),
          KField(label: 'Note (optional)', controller: note, hint: 'Guests coming'),
          const SizedBox(height: Sp.lg),
          KButton(
            label: 'Save the change',
            icon: Icons.check_rounded,
            expand: true,
            onPressed: () async {
              final q = num.tryParse(qty.text.trim().replaceAll(',', '.'));
              if (q == null) {
                toast(ctx, 'Give the litres for that day.', bad: true);
                return;
              }
              try {
                await Api.instance.rpc('set_temporary', {
                  'customer_id': c['id'],
                  'day': isoDay(day),
                  'slot': slot,
                  'quantity': q,
                  'vessels': [
                    for (final e in counts.entries)
                      if (e.value > 0) {'container_id': e.key, 'quantity': e.value}
                  ],
                  'note': note.text.trim(),
                });
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } on ApiError catch (e) {
                if (ctx.mounted) toast(ctx, e.message, bad: true);
              }
            },
          ),
        ]);
      }));
  qty.dispose();
  note.dispose();
  return ok == true;
}
