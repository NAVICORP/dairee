import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';
import 'reports.dart';
import 'shell.dart';
import 'staff_gate.dart' show copyText;

const kZones = [
  'Asia/Kolkata', 'Asia/Dubai', 'Asia/Riyadh', 'Asia/Qatar', 'Asia/Kuwait', 'Asia/Muscat', 'Asia/Bahrain', 'Asia/Colombo',
  'Asia/Kathmandu', 'Asia/Dhaka', 'Asia/Karachi', 'Africa/Nairobi', 'Europe/London', 'America/New_York', 'Australia/Sydney',
];

/// Price, vessels, packing windows, the farm's details, export and the log.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.farm});
  final FarmRole farm;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic>? farm;
  List<Map<String, dynamic>> prices = const [];
  List<Map<String, dynamic>> vessels = const [];
  String? error;

  FarmRole get f => widget.farm;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        Api.instance.select('farms', where: {'id': 'eq.${f.id}'}),
        Api.instance.select('milk_prices', columns: 'id,price_per_liter,effective_from,effective_to,is_active,notes', order: 'effective_from.desc'),
        Api.instance.select('containers', columns: 'id,name,category,capacity_ml,active,sort_order', order: 'sort_order.asc,capacity_ml.asc'),
      ]);
      if (!mounted) return;
      setState(() {
        farm = r[0].isEmpty ? null : r[0].first;
        prices = r[1];
        vessels = r[2];
        error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _saveFarm(Map<String, dynamic> patch, [String said = 'Saved']) async {
    try {
      await Api.instance.update('farms', patch, where: {'id': 'eq.${f.id}'}, columns: 'id');
      await _load();
      await Me.instance.load();
      if (mounted) toast(context, said);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _text(String key, String label, {TextInputType? keyboard, String? hint}) async {
    final ctl = TextEditingController(text: '${farm?[key] ?? ''}');
    final v = await showKSheet<String>(context, title: label, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KField(label: label, controller: ctl, keyboard: keyboard, hint: hint, autofocus: true),
          const SizedBox(height: Sp.lg),
          KButton(label: 'Save', icon: Icons.check_rounded, expand: true, onPressed: () => Navigator.of(ctx).pop(ctl.text.trim())),
        ]));
    ctl.dispose();
    if (v == null) return;
    await _saveFarm({key: v.isEmpty ? null : (key == 'bill_prefix' ? v.toUpperCase() : v)});
  }

  Future<void> _time(String key, String label) async {
    final now = '${farm?[key] ?? '06:00:00'}'.substring(0, 5);
    final p = await showPicker<String>(context, title: label, selected: now, options: [
      for (var h = 0; h < 24; h++)
        for (final m in [0, 30]) PickOption('${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}', timeOfDay('$h:$m')),
    ]);
    if (p != null) await _saveFarm({key: p.value});
  }

  Future<void> _addPrice() async {
    final ctl = TextEditingController();
    var from = f.today;
    final r = await showKSheet<bool>(context, title: 'New milk price', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Bills use the price of each day, so a new price never changes bills for earlier days.', style: T.small),
            const SizedBox(height: Sp.md),
            KField(
                label: 'Price a litre',
                controller: ctl,
                autofocus: true,
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                prefix: '${currencyOf(f.currency).symbol} ',
                formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
            const SizedBox(height: Sp.md),
            KChoice(
                label: 'From',
                value: dateLabel(from),
                icon: Icons.event_outlined,
                onTap: () async {
                  final d = await pickDate(ctx, initial: from);
                  if (d != null) set(() => from = d);
                }),
            const SizedBox(height: Sp.lg),
            KButton(
              label: 'Save price',
              icon: Icons.check_rounded,
              expand: true,
              onPressed: () async {
                final p = num.tryParse(ctl.text.trim());
                if (p == null) {
                  toast(ctx, 'Give the price.', bad: true);
                  return;
                }
                try {
                  await Api.instance.insert('milk_prices', {'price_per_liter': p, 'effective_from': isoDay(from)}, columns: 'id');
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } on ApiError catch (e) {
                  if (ctx.mounted) toast(ctx, e.message, bad: true);
                }
              },
            ),
          ]);
        }));
    ctl.dispose();
    if (r == true) _load();
  }

  Future<void> _editVessel([Map<String, dynamic>? v]) async {
    final name = TextEditingController(text: v?['name'] as String? ?? '');
    final ml = TextEditingController(text: v == null ? '' : '${v['capacity_ml']}');
    var cat = (v?['category'] as String?) ?? 'bottle';
    var active = v?['active'] != false;
    final r = await showKSheet<bool>(context, title: v == null ? 'New vessel' : 'Edit ${v['name']}', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KField(label: 'Name', controller: name, hint: '1 litre bottle', autofocus: v == null),
            const SizedBox(height: Sp.md),
            KField(label: 'Holds (ml)', controller: ml, keyboard: TextInputType.number, formatters: [FilteringTextInputFormatter.digitsOnly], hint: '1000'),
            const SizedBox(height: Sp.md),
            KSegmented<String>(
                expand: true,
                items: const [('bottle', 'Bottle'), ('can', 'Can'), ('packet', 'Packet'), ('other', 'Other')],
                value: cat,
                onChanged: (x) => set(() => cat = x)),
            if (v != null) ...[
              const SizedBox(height: Sp.sm),
              KSwitchRow(title: 'In use', sub: 'Retired vessels stay on old records', value: active, onChanged: (x) => set(() => active = x)),
            ],
            const SizedBox(height: Sp.lg),
            KButton(
              label: 'Save',
              icon: Icons.check_rounded,
              expand: true,
              onPressed: () async {
                final n = int.tryParse(ml.text.trim());
                if (name.text.trim().isEmpty || n == null) {
                  toast(ctx, 'Give a name and how many ml it holds.', bad: true);
                  return;
                }
                final row = {'name': name.text.trim(), 'capacity_ml': n, 'category': cat, 'active': active};
                try {
                  if (v == null) {
                    await Api.instance.insert('containers', {...row, 'sort_order': vessels.length * 10 + 10}, columns: 'id');
                  } else {
                    await Api.instance.update('containers', row, where: {'id': 'eq.${v['id']}'}, columns: 'id');
                  }
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } on ApiError catch (e) {
                  if (ctx.mounted) toast(ctx, e.message, bad: true);
                }
              },
            ),
            if (v != null) ...[
              const SizedBox(height: Sp.sm),
              KButton(
                label: 'Delete this vessel',
                kind: KButtonKind.danger,
                expand: true,
                onPressed: () async {
                  try {
                    await Api.instance.delete('containers', where: {'id': 'eq.${v['id']}'});
                    if (ctx.mounted) Navigator.of(ctx).pop(true);
                  } on ApiError catch (e) {
                    if (ctx.mounted) toast(ctx, e.message.contains('Other records') ? 'Customers still use it. Switch off "In use" instead.' : e.message, bad: true);
                  }
                },
              ),
            ],
          ]);
        }));
    name.dispose();
    ml.dispose();
    if (r == true) _load();
  }

  Future<void> _deleteFarm() async {
    final ctl = TextEditingController();
    final ok = await showKSheet<bool>(context, title: 'Delete ${f.name}?', builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Every customer, delivery, bill, payment and cow on this farm is deleted, for everyone. This cannot be undone. Type the farm\'s name to confirm.',
              style: T.body.copyWith(color: K.bad)),
          const SizedBox(height: Sp.md),
          KField(label: 'Farm name', controller: ctl, hint: f.name),
          const SizedBox(height: Sp.lg),
          KButton(label: 'Delete the farm', kind: KButtonKind.danger, expand: true, onPressed: () => Navigator.of(ctx).pop(true)),
        ]));
    final typed = ctl.text;
    ctl.dispose();
    if (ok != true) return;
    try {
      await Api.instance.rpc('delete_farm', {'confirm_name': typed});
      await Api.instance.chooseFarm(null);
      await Me.instance.load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final x = farm;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: x == null
          ? (error != null ? LoadFailed(message: error!, onRetry: _load) : const Loading())
          : PageBody(onRefresh: _load, children: [
              const SectionTitle('Milk price', top: 4),
              KGroup(children: [
                if (prices.isEmpty) const KRow(title: 'No price yet', sub: 'Bills need a price for every day they cover'),
                for (final p in prices)
                  KRow(
                    title: '${f.money(toNum(p['price_per_liter']))} a litre',
                    sub: 'From ${dateLabel(parseDay(p['effective_from'])!)}${p['effective_to'] == null ? '' : ' to ${dateLabel(parseDay(p['effective_to'])!)}'}',
                    trailing: RoundIcon(Icons.delete_outline_rounded, size: 32, tooltip: 'Delete this price', onTap: () async {
                      if (!await confirm(context, title: 'Delete this price?', text: 'Bills already made keep their figures.', yes: 'Delete', danger: true)) return;
                      try {
                        await Api.instance.delete('milk_prices', where: {'id': 'eq.${p['id']}'});
                        _load();
                      } on ApiError catch (e) {
                        if (context.mounted) toast(context, e.message, bad: true);
                      }
                    }),
                  ),
                KRow(leading: const Icon(Icons.add_rounded, color: K.blue, size: 20), title: 'New price', onTap: _addPrice),
              ]),
              const SectionTitle('Vessels'),
              KGroup(children: [
                for (final v in vessels)
                  KRow(
                    title: '${v['name']}',
                    sub: '${capacity(toNum(v['capacity_ml']).toInt())}, ${v['category']}${v['active'] == true ? '' : ', retired'}',
                    trailing: const Icon(Icons.chevron_right_rounded, color: K.muted),
                    onTap: () => _editVessel(v),
                  ),
                KRow(leading: const Icon(Icons.add_rounded, color: K.blue, size: 20), title: 'New vessel', onTap: () => _editVessel()),
              ]),
              const SectionTitle('Packing windows'),
              KGroup(children: [
                KRow(
                  title: 'Morning: ${timeOfDay(x['morning_start'])} to ${timeOfDay(x['morning_end'])}',
                  sub: 'Customers cannot change the morning round while it is packed',
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    KButton(label: 'Start', kind: KButtonKind.ghost, small: true, onPressed: () => _time('morning_start', 'Morning packing starts')),
                    KButton(label: 'End', kind: KButtonKind.ghost, small: true, onPressed: () => _time('morning_end', 'Morning packing ends')),
                  ]),
                ),
                KRow(
                  title: 'Evening: ${timeOfDay(x['evening_start'])} to ${timeOfDay(x['evening_end'])}',
                  sub: 'The same for the evening round',
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    KButton(label: 'Start', kind: KButtonKind.ghost, small: true, onPressed: () => _time('evening_start', 'Evening packing starts')),
                    KButton(label: 'End', kind: KButtonKind.ghost, small: true, onPressed: () => _time('evening_end', 'Evening packing ends')),
                  ]),
                ),
              ]),
              const SectionTitle('The farm'),
              KGroup(children: [
                KRow(title: 'Name', sub: '${x['name']}', onTap: () => _text('name', 'Farm name')),
                KRow(title: 'Phone', sub: x['phone'] == null ? 'Not set' : prettyPhone(x['phone'] as String?), onTap: () => _text('phone', 'Farm phone', keyboard: TextInputType.phone)),
                KRow(title: 'Address', sub: '${x['address'] ?? 'Not set'}', onTap: () => _text('address', 'Address')),
                KRow(
                  title: 'Time zone',
                  sub: '${x['timezone']}',
                  onTap: () async {
                    final p = await showPicker<String>(context, title: 'Time zone', selected: '${x['timezone']}', options: [for (final z in kZones) PickOption(z, z.replaceAll('_', ' '))]);
                    if (p != null) await _saveFarm({'timezone': p.value});
                  },
                ),
                KRow(
                  title: 'Currency',
                  sub: '${x['currency']}',
                  onTap: () async {
                    final p = await showPicker<String>(context,
                        title: 'Currency', selected: '${x['currency']}', options: [for (final c in kCurrencies) PickOption(c.code, c.code, trailing: c.symbol)]);
                    if (p != null) await _saveFarm({'currency': p.value});
                  },
                ),
                KRow(title: 'Bill numbers start with', sub: '${x['bill_prefix']}', onTap: () => _text('bill_prefix', 'Bill prefix', hint: 'B')),
                KRow(
                  title: 'Link for customers',
                  sub: customerUrl('${x['slug']}'),
                  trailing: const Icon(Icons.copy_rounded, color: K.muted, size: 18),
                  onTap: () => copyText(context, customerUrl('${x['slug']}'), 'Link copied'),
                ),
              ]),
              const SectionTitle('Records'),
              KGroup(children: [
                KRow(
                  leading: const Icon(Icons.download_rounded, color: K.ink2, size: 20),
                  title: 'Export',
                  sub: 'Customers, deliveries, bills, payments, the herd',
                  onTap: () => exportFarm(context, f, from: DateTime(f.today.year, f.today.month - 1, 1), to: f.today),
                ),
                KRow(
                  leading: const Icon(Icons.history_rounded, color: K.ink2, size: 20),
                  title: 'What happened',
                  sub: 'Every change, who made it and when',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AuditLog())),
                ),
                if (f.seesMoney)
                  KRow(
                    leading: const Icon(Icons.fact_check_outlined, color: K.ink2, size: 20),
                    title: 'Check the money',
                    sub: 'Payments = collected + credit held + credit used',
                    onTap: () async {
                      try {
                        final r = await Api.instance.rpc('money_invariant');
                        if (!context.mounted || r is! Map) return;
                        final ok = r['ok'] == true;
                        await confirm(context,
                            title: ok ? 'The money adds up' : 'The money does not add up',
                            text: 'Payments ${f.money(toNum(r['payments']))}\nCollected ${f.money(toNum(r['collected']))}\nCredit held ${f.money(toNum(r['credit_held']))}\n'
                                'Credit used ${f.money(toNum(r['credit_applied']))}${ok ? '' : '\n\nPlease tell support.'}',
                            yes: 'OK',
                            no: 'Close');
                      } on ApiError catch (e) {
                        if (context.mounted) toast(context, e.message, bad: true);
                      }
                    },
                  ),
              ]),
              const SectionTitle('Account'),
              KGroup(children: [
                KRow(
                  leading: const Icon(Icons.logout_rounded, color: K.ink2, size: 20),
                  title: 'Sign out',
                  onTap: () async {
                    Me.instance.clear();
                    await Api.instance.signOut();
                  },
                ),
                KRow(leading: const Icon(Icons.person_remove_outlined, color: K.bad, size: 20), title: 'Delete my account', onTap: () => deleteMyAccount(context)),
                if (f.isAdmin)
                  KRow(leading: const Icon(Icons.delete_forever_outlined, color: K.bad, size: 20), title: 'Delete this farm', onTap: _deleteFarm),
              ]),
            ]),
    );
  }
}

/// The farm's log: sentences a person can read.
class AuditLog extends StatefulWidget {
  const AuditLog({super.key});

  @override
  State<AuditLog> createState() => _AuditLogState();
}

class _AuditLogState extends State<AuditLog> {
  List<Map<String, dynamic>>? rows;
  int shown = 200;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.instance.select('audit_logs', columns: 'id,action_type,notes,performed_by,created_at', order: 'created_at.desc', limit: shown);
      if (mounted) setState(() => rows = r);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = rows;
    return Scaffold(
      appBar: AppBar(title: const Text('What happened')),
      body: r == null
          ? const Loading()
          : PageBody(onRefresh: _load, children: [
              if (r.isEmpty) const EmptyState(icon: Icons.history_rounded, text: 'Nothing yet.'),
              if (r.isNotEmpty)
                KGroup(children: [
                  for (final a in r)
                    KRow(title: '${a['notes'] ?? a['action_type']}', sub: '${a['performed_by']}, ${stamp(DateTime.parse('${a['created_at']}'))}'),
                ]),
              if (r.length >= shown) ...[
                const SizedBox(height: Sp.md),
                KButton(label: 'Show more', kind: KButtonKind.secondary, onPressed: () {
                  shown += 400;
                  _load();
                }),
              ],
            ]),
    );
  }
}
