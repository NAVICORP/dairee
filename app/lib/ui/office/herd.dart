import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';

const kCowStatus = ['milking', 'dry', 'heifer', 'calf', 'sold', 'dead'];
String cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('_', ' ');

/// The herd: each animal, its yield, health, breeding and the rest. A world
/// apart from the round; they meet only in milk produced against delivered.
class HerdPage extends StatefulWidget {
  const HerdPage({super.key, required this.farm});
  final FarmRole farm;

  @override
  State<HerdPage> createState() => _HerdPageState();
}

class _HerdPageState extends State<HerdPage> {
  List<Map<String, dynamic>>? cows;
  List? week;
  String? error;
  String status = 'herd';
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final t = widget.farm.today;
    try {
      final r = await Future.wait([
        Api.instance.select('cows', columns: 'id,tag_number,name,breed,status,pregnancy_status,last_calving_date,date_of_birth,location', order: 'tag_number.asc'),
        Api.instance.rpc('herd_vs_round', {'date_from': isoDay(addDays(t, -6)), 'date_to': isoDay(t)}),
      ]);
      if (!mounted) return;
      setState(() {
        cows = r[0] as List<Map<String, dynamic>>;
        week = r[1] as List?;
        error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _open(Map<String, dynamic> c) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CowPage(farm: widget.farm, cowId: c['id'] as String)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = widget.farm.canCare || widget.farm.can('cows');
    final t = _q.text.trim().toLowerCase();
    final shown = (cows ?? const <Map<String, dynamic>>[]).where((c) {
      final s = '${c['status']}';
      if (status == 'herd' && (s == 'sold' || s == 'dead')) return false;
      if (status == 'milking' && s != 'milking') return false;
      if (status == 'gone' && s != 'sold' && s != 'dead') return false;
      return t.isEmpty || '${c['tag_number']} ${c['name'] ?? ''} ${c['breed'] ?? ''}'.toLowerCase().contains(t);
    }).toList();
    final produced = (week ?? const []).whereType<Map>().fold<num>(0, (a, d) => a + toNum(d['produced']));
    final delivered = (week ?? const []).whereType<Map>().fold<num>(0, (a, d) => a + toNum(d['delivered']));
    return Scaffold(
      appBar: AppBar(title: const Text('Cows'), actions: [
        if (canEdit)
          RoundIcon(Icons.add_rounded, tooltip: 'Add a cow', onTap: () async {
            final made = await editCow(context);
            await _load();
            if (made != null && mounted) _open(made);
          }),
        const SizedBox(width: 8),
      ]),
      body: PageBody(onRefresh: _load, children: [
        if (error != null && cows == null)
          LoadFailed(message: error!, onRetry: _load)
        else if (cows == null)
          const Padding(padding: EdgeInsets.all(40), child: Loading())
        else ...[
          HeroCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Last 7 days', style: T.small.copyWith(color: K.heroText)),
              const SizedBox(height: 8),
              Wrap(spacing: 22, runSpacing: 10, children: [
                Stat(litres(produced), 'From the herd', dark: true, big: true),
                Stat(litres(delivered), 'Delivered', dark: true, big: true),
              ]),
              const SizedBox(height: 10),
              Text('${(cows ?? const []).where((c) => c['status'] == 'milking').length} milking of ${(cows ?? const []).where((c) => c['status'] != 'sold' && c['status'] != 'dead').length} in the herd',
                  style: T.small.copyWith(color: K.heroText)),
            ]),
          ),
          const SizedBox(height: Sp.md),
          if (canEdit)
            KButton(
                label: 'Record today\'s milk',
                icon: Icons.water_drop_outlined,
                kind: KButtonKind.secondary,
                expand: true,
                onPressed: () async {
                  if (await recordYields(context, widget.farm, cows!.where((c) => c['status'] == 'milking').toList())) _load();
                }),
          const SizedBox(height: Sp.md),
          SearchField(controller: _q, hint: 'Search tag, name or breed', onChanged: (_) => setState(() {})),
          const SizedBox(height: Sp.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: KSegmented<String>(
                items: const [('herd', 'Herd'), ('milking', 'Milking'), ('gone', 'Sold or dead')], value: status, onChanged: (v) => setState(() => status = v)),
          ),
          const SizedBox(height: Sp.md),
          if (shown.isEmpty)
            EmptyState(icon: Icons.pets_outlined, text: (cows ?? const []).isEmpty ? 'No cows yet. Add the first one with its tag number.' : 'Nothing matches.')
          else
            KGroup(children: [
              for (final c in shown)
                KRow(
                  leading: Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: K.brand100, borderRadius: BorderRadius.circular(12)),
                    child: Text('${c['tag_number']}'.length > 4 ? '${c['tag_number']}'.substring('${c['tag_number']}'.length - 4) : '${c['tag_number']}',
                        style: T.tiny.copyWith(color: K.brand600, fontWeight: FontWeight.w800)),
                  ),
                  title: [c['tag_number'], c['name']].where((x) => x != null && '$x'.isNotEmpty).join(', '),
                  sub: [cap('${c['status']}'), if (c['breed'] != null) '${c['breed']}', if (c['pregnancy_status'] == 'pregnant') 'pregnant'].join(', '),
                  trailing: const Icon(Icons.chevron_right_rounded, color: K.muted),
                  onTap: () => _open(c),
                ),
            ]),
        ],
      ]),
    );
  }
}

/// Today's milk from each milking cow, for one round, in one go.
Future<bool> recordYields(BuildContext context, FarmRole farm, List<Map<String, dynamic>> milking) async {
  if (milking.isEmpty) {
    toast(context, 'No cows are marked as milking.', bad: true);
    return false;
  }
  var slot = DateTime.now().hour < 13 ? 'morning' : 'evening';
  var day = farm.today;
  final ctl = {for (final c in milking) c['id'] as String: TextEditingController()};
  final ok = await showKSheet<bool>(context, title: 'Milk from the herd', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
                child: KChoice(
                    label: 'Day',
                    value: relativeDay(day, farm.today),
                    onTap: () async {
                      final d = await pickDate(ctx, initial: day, last: farm.today);
                      if (d != null) set(() => day = d);
                    })),
            const SizedBox(width: Sp.md),
            KSegmented<String>(items: const [('morning', 'Morning'), ('evening', 'Evening')], value: slot, onChanged: (v) => set(() => slot = v)),
          ]),
          const SizedBox(height: Sp.md),
          KGroup(children: [
            for (final c in milking)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
                child: Row(children: [
                  Expanded(child: Text([c['tag_number'], c['name']].where((x) => x != null && '$x'.isNotEmpty).join(', '), style: T.bodyStrong)),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: ctl[c['id']],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      textAlign: TextAlign.end,
                      style: T.bodyStrong,
                      decoration: const InputDecoration(hintText: '0', suffixText: ' L'),
                    ),
                  ),
                ]),
              ),
          ]),
          const SizedBox(height: Sp.lg),
          KButton(
            label: 'Save',
            icon: Icons.check_rounded,
            expand: true,
            onPressed: () async {
              try {
                for (final c in milking) {
                  final v = num.tryParse(ctl[c['id']]!.text.trim());
                  if (v == null) continue;
                  final existing = await Api.instance.select('milk_yield',
                      columns: 'id', where: {'cow_id': 'eq.${c['id']}', 'yield_date': 'eq.${isoDay(day)}', 'slot': 'eq.$slot'});
                  if (existing.isEmpty) {
                    await Api.instance.insert('milk_yield', {'cow_id': c['id'], 'yield_date': isoDay(day), 'slot': slot, 'litres': v, 'recorded_by': farm.staffName},
                        columns: 'id');
                  } else {
                    await Api.instance.update('milk_yield', {'litres': v}, where: {'id': 'eq.${existing.first['id']}'}, columns: 'id');
                  }
                }
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } on ApiError catch (e) {
                if (ctx.mounted) toast(ctx, e.message, bad: true);
              }
            },
          ),
        ]);
      }));
  for (final c in ctl.values) {
    c.dispose();
  }
  return ok == true;
}

// ---------------------------------------------------------------- one cow

class CowPage extends StatefulWidget {
  const CowPage({super.key, required this.farm, required this.cowId});
  final FarmRole farm;
  final String cowId;

  @override
  State<CowPage> createState() => _CowPageState();
}

class _CowPageState extends State<CowPage> {
  Map<String, dynamic>? cow;
  List<Map<String, dynamic>> events = const [];
  List<Map<String, dynamic>> yields = const [];

  bool get canEdit => widget.farm.canCare || widget.farm.can('cows');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        Api.instance.select('cows', where: {'id': 'eq.${widget.cowId}'}),
        Api.instance.select('cow_events', columns: 'id,kind,summary,actor,occurred_at', where: {'cow_id': 'eq.${widget.cowId}'}, order: 'occurred_at.desc', limit: 200),
        Api.instance.select('milk_yield', columns: 'yield_date,slot,litres', where: {'cow_id': 'eq.${widget.cowId}'}, order: 'yield_date.desc', limit: 28),
      ]);
      if (r[0].isEmpty) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (!mounted) return;
      setState(() {
        cow = r[0].first;
        events = r[1];
        yields = r[2];
      });
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _log(String table, String title, List<_F> fields, {Map<String, dynamic> extra = const {}}) async {
    if (await _logSheet(context, widget.farm, title: title, table: table, fields: fields, base: {'cow_id': widget.cowId, ...extra})) _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = cow;
    return Scaffold(
      appBar: AppBar(title: Text(c == null ? 'Cow' : '${c['tag_number']}${(c['name'] ?? '') == '' ? '' : ', ${c['name']}'}'), actions: [
        if (canEdit && c != null)
          RoundIcon(Icons.edit_outlined, tooltip: 'Edit', onTap: () async {
            await editCow(context, cow: c);
            _load();
          }),
        const SizedBox(width: 8),
      ]),
      body: c == null
          ? const Loading()
          : PageBody(onRefresh: _load, children: [
              KCard(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${c['tag_number']}', style: T.h2),
                      if ((c['name'] ?? '') != '') Text('${c['name']}', style: T.body),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        Pill(cap('${c['status']}')),
                        if (c['pregnancy_status'] != 'unknown') Pill.grey(cap('${c['pregnancy_status']}')),
                        if (c['breed'] != null) Pill.grey('${c['breed']}'),
                      ]),
                      const SizedBox(height: 8),
                      if (c['date_of_birth'] != null) Text('Born ${dateLabel(parseDay(c['date_of_birth'])!)}', style: T.small),
                      if (c['last_calving_date'] != null) Text('Last calved ${dateLabel(parseDay(c['last_calving_date'])!)}', style: T.small),
                      if (c['location'] != null) Text('${c['location']}', style: T.small),
                    ]),
                  ),
                  QrImageView(data: 'dairee-cow:${c['qr_token']}', size: 84, padding: EdgeInsets.zero, eyeStyle: const QrEyeStyle(color: K.deep, eyeShape: QrEyeShape.square),
                      dataModuleStyle: const QrDataModuleStyle(color: K.deep, dataModuleShape: QrDataModuleShape.square)),
                ]),
              ),
              if (canEdit) ...[
                const SectionTitle('Add a record'),
                Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
                  _chip(Icons.water_drop_outlined, 'Milk', () => _log('milk_yield', 'Milk', [
                        _F.date('yield_date', 'Day', widget.farm.today),
                        _F.slot('slot'),
                        _F.number('litres', 'Litres', required: true),
                      ], extra: {'recorded_by': widget.farm.staffName})),
                  _chip(Icons.healing_outlined, 'Health', () => _log('cow_health_logs', 'Health', [
                        _F.date('observed_on', 'Seen on', widget.farm.today),
                        _F.list('signs', 'Signs', hint: 'Fever, off feed, limping'),
                        _F.pick('severity', 'How bad', ['mild', 'moderate', 'severe']),
                        _F.number('temperature_c', 'Temperature (C)'),
                        _F.text('treatment', 'Treatment'),
                        _F.text('remarks', 'Notes'),
                      ], extra: {'recorded_by': widget.farm.staffName})),
                  _chip(Icons.medical_services_outlined, 'Vaccine', () => _log('cow_vaccinations', 'Vaccination', [
                        _F.text('vaccine', 'Vaccine', required: true),
                        _F.date('given_on', 'Given on', widget.farm.today),
                        _F.date('next_due_on', 'Next due', null),
                        _F.text('batch', 'Batch'),
                        _F.text('given_by', 'Given by'),
                      ])),
                  _chip(Icons.favorite_border_rounded, 'Heat', () => _log('cow_heat_logs', 'Heat', [
                        _F.date('observed_on', 'Seen on', widget.farm.today),
                        _F.toggle('detected', 'In heat', true),
                        _F.pick('intensity', 'How strong', ['weak', 'medium', 'strong']),
                        _F.list('signs', 'Signs', hint: 'Mounting, restless'),
                      ])),
                  _chip(Icons.event_note_outlined, 'Breeding', () => _log('cow_breeding_events', 'Breeding', [
                        _F.pick('kind', 'What', ['ai', 'natural', 'pregnancy_check', 'calving', 'abortion', 'dry_off'], required: true),
                        _F.date('event_date', 'On', widget.farm.today),
                        _F.text('bull', 'Bull'),
                        _F.text('technician', 'Technician'),
                        _F.text('result', 'Result'),
                      ])),
                  _chip(Icons.fitness_center_rounded, 'Weight', () => _log('cow_weights', 'Weight', [
                        _F.date('weighed_on', 'Weighed on', widget.farm.today),
                        _F.number('weight_kg', 'Weight (kg)', required: true),
                        _F.number('body_condition_score', 'Body condition (1 to 5)'),
                      ])),
                ]),
              ],
              if (yields.isNotEmpty) ...[
                const SectionTitle('Recent milk'),
                KGroup(children: [
                  for (final y in yields.take(10))
                    KRow(title: '${dayLabel(parseDay(y['yield_date'])!)}, ${y['slot']}', trailing: Text(litres(y['litres']), style: T.bodyStrong)),
                ]),
              ],
              const SectionTitle('Timeline'),
              if (events.isEmpty)
                const KCard(child: Text('Nothing recorded yet.', style: T.small))
              else
                KGroup(children: [
                  for (final e in events)
                    KRow(
                      title: '${e['summary']}',
                      sub: '${stamp(DateTime.parse('${e['occurred_at']}'))}${e['actor'] == null ? '' : ', ${e['actor']}'}',
                    ),
                ]),
              if (canEdit) ...[
                const SectionTitle('Manage'),
                KGroup(children: [
                  KRow(
                    leading: const Icon(Icons.delete_outline_rounded, color: K.bad, size: 20),
                    title: 'Delete this cow',
                    sub: 'With all its records. To keep its history, mark it sold or dead instead.',
                    onTap: () async {
                      if (!await confirm(context, title: 'Delete ${c['tag_number']}?', text: 'Every record for this cow goes too.', yes: 'Delete', danger: true)) return;
                      try {
                        await Api.instance.delete('cows', where: {'id': 'eq.${widget.cowId}'});
                        if (context.mounted) Navigator.of(context).pop();
                      } on ApiError catch (e) {
                        if (context.mounted) toast(context, e.message, bad: true);
                      }
                    },
                  ),
                ]),
              ],
            ]),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) => KButton(label: label, icon: icon, kind: KButtonKind.secondary, small: true, onPressed: onTap);
}

/// Adds or edits a cow. Returns the saved row.
Future<Map<String, dynamic>?> editCow(BuildContext context, {Map<String, dynamic>? cow}) async {
  final c = cow ?? const <String, dynamic>{};
  final tag = TextEditingController(text: c['tag_number'] as String? ?? '');
  final name = TextEditingController(text: c['name'] as String? ?? '');
  final breed = TextEditingController(text: c['breed'] as String? ?? '');
  final location = TextEditingController(text: c['location'] as String? ?? '');
  final notes = TextEditingController(text: c['notes'] as String? ?? '');
  var status = (c['status'] as String?) ?? 'milking';
  var preg = (c['pregnancy_status'] as String?) ?? 'unknown';
  DateTime? born = parseDay(c['date_of_birth']);
  DateTime? calved = parseDay(c['last_calving_date']);
  final r = await showKSheet<Map<String, dynamic>>(context, title: cow == null ? 'New cow' : 'Edit ${c['tag_number']}', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: KField(label: 'Tag number', controller: tag, autofocus: cow == null, caps: TextCapitalization.characters)),
            const SizedBox(width: Sp.md),
            Expanded(child: KField(label: 'Name', controller: name, caps: TextCapitalization.words)),
          ]),
          const SizedBox(height: Sp.md),
          Row(children: [
            Expanded(child: KField(label: 'Breed', controller: breed, caps: TextCapitalization.words)),
            const SizedBox(width: Sp.md),
            Expanded(child: KField(label: 'Shed or place', controller: location)),
          ]),
          const SizedBox(height: Sp.md),
          Row(children: [
            Expanded(
                child: KChoice(
                    label: 'Status',
                    value: cap(status),
                    onTap: () async {
                      final p = await showPicker<String>(ctx, title: 'Status', selected: status, options: [for (final s in kCowStatus) PickOption(s, cap(s))]);
                      if (p != null) set(() => status = p.value);
                    })),
            const SizedBox(width: Sp.md),
            Expanded(
                child: KChoice(
                    label: 'Pregnancy',
                    value: cap(preg),
                    onTap: () async {
                      final p = await showPicker<String>(ctx,
                          title: 'Pregnancy', selected: preg, options: [for (final s in ['unknown', 'open', 'inseminated', 'pregnant']) PickOption(s, cap(s))]);
                      if (p != null) set(() => preg = p.value);
                    })),
          ]),
          const SizedBox(height: Sp.md),
          Row(children: [
            Expanded(
                child: KChoice(
                    label: 'Born',
                    value: born == null ? 'Not known' : dateLabel(born!),
                    onTap: () async {
                      final d = await pickDate(ctx, initial: born ?? DateTime.now());
                      if (d != null) set(() => born = d);
                    })),
            const SizedBox(width: Sp.md),
            Expanded(
                child: KChoice(
                    label: 'Last calved',
                    value: calved == null ? 'Not known' : dateLabel(calved!),
                    onTap: () async {
                      final d = await pickDate(ctx, initial: calved ?? DateTime.now());
                      if (d != null) set(() => calved = d);
                    })),
          ]),
          const SizedBox(height: Sp.md),
          KField(label: 'Notes', controller: notes, maxLines: 3),
          const SizedBox(height: Sp.lg),
          KButton(
            label: cow == null ? 'Add cow' : 'Save',
            icon: Icons.check_rounded,
            expand: true,
            onPressed: () async {
              if (tag.text.trim().isEmpty) {
                toast(ctx, 'Give the tag number.', bad: true);
                return;
              }
              final row = {
                'tag_number': tag.text.trim(),
                'name': name.text.trim().isEmpty ? null : name.text.trim(),
                'breed': breed.text.trim().isEmpty ? null : breed.text.trim(),
                'location': location.text.trim().isEmpty ? null : location.text.trim(),
                'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
                'status': status,
                'pregnancy_status': preg,
                'date_of_birth': born == null ? null : isoDay(born!),
                'last_calving_date': calved == null ? null : isoDay(calved!),
              };
              try {
                final saved = cow == null
                    ? await Api.instance.insert('cows', row)
                    : (await Api.instance.update('cows', row, where: {'id': 'eq.${c['id']}'})).first;
                if (ctx.mounted) Navigator.of(ctx).pop(saved);
              } on ApiError catch (e) {
                if (ctx.mounted) toast(ctx, e.message, bad: true);
              }
            },
          ),
        ]);
      }));
  for (final t in [tag, name, breed, location, notes]) {
    t.dispose();
  }
  return r;
}

// ---------------------------------------------------------------- a small form for each kind of record

enum _K { text, number, date, slot, pick, list, toggle }

class _F {
  _F._(this.kind, this.key, this.label, {this.required = false, this.hint, this.options = const [], this.initial});
  factory _F.text(String key, String label, {bool required = false, String? hint}) => _F._(_K.text, key, label, required: required, hint: hint);
  factory _F.number(String key, String label, {bool required = false}) => _F._(_K.number, key, label, required: required);
  factory _F.date(String key, String label, DateTime? initial) => _F._(_K.date, key, label, initial: initial);
  factory _F.slot(String key) => _F._(_K.slot, key, 'Round', initial: DateTime.now().hour < 13 ? 'morning' : 'evening');
  factory _F.pick(String key, String label, List<String> options, {bool required = false}) =>
      _F._(_K.pick, key, label, options: options, required: required, initial: required ? options.first : null);
  factory _F.list(String key, String label, {String? hint}) => _F._(_K.list, key, label, hint: hint);
  factory _F.toggle(String key, String label, bool initial) => _F._(_K.toggle, key, label, initial: initial);
  final _K kind;
  final String key;
  final String label;
  final bool required;
  final String? hint;
  final List<String> options;
  final Object? initial;
}

Future<bool> _logSheet(BuildContext context, FarmRole farm,
    {required String title, required String table, required List<_F> fields, required Map<String, dynamic> base}) async {
  final values = <String, Object?>{for (final f in fields) f.key: f.initial};
  final ctl = {for (final f in fields) if (f.kind == _K.text || f.kind == _K.number || f.kind == _K.list) f.key: TextEditingController()};
  final ok = await showKSheet<bool>(context, title: title, builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final f in fields) ...[
            switch (f.kind) {
              _K.text || _K.list => KField(label: f.label, controller: ctl[f.key]!, hint: f.hint),
              _K.number => KField(
                  label: f.label,
                  controller: ctl[f.key]!,
                  keyboard: const TextInputType.numberWithOptions(decimal: true),
                  formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
              _K.date => KChoice(
                  label: f.label,
                  value: values[f.key] == null ? 'Not set' : dateLabel(values[f.key] as DateTime),
                  onTap: () async {
                    final d = await pickDate(ctx, initial: (values[f.key] as DateTime?) ?? farm.today);
                    if (d != null) set(() => values[f.key] = d);
                  }),
              _K.slot => KSegmented<String>(
                  expand: true, items: const [('morning', 'Morning'), ('evening', 'Evening')], value: '${values[f.key]}', onChanged: (v) => set(() => values[f.key] = v)),
              _K.pick => KChoice(
                  label: f.label,
                  value: values[f.key] == null ? 'Not set' : cap('${values[f.key]}'),
                  onTap: () async {
                    final p = await showPicker<String?>(ctx, title: f.label, selected: values[f.key] as String?, options: [
                      if (!f.required) const PickOption<String?>(null, 'Not set'),
                      for (final o in f.options) PickOption<String?>(o, cap(o)),
                    ]);
                    if (p != null) set(() => values[f.key] = p.value);
                  }),
              _K.toggle => KSwitchRow(title: f.label, value: values[f.key] == true, onChanged: (v) => set(() => values[f.key] = v)),
            },
            const SizedBox(height: Sp.md),
          ],
          KButton(
            label: 'Save',
            icon: Icons.check_rounded,
            expand: true,
            onPressed: () async {
              final row = <String, dynamic>{...base};
              for (final f in fields) {
                final v = switch (f.kind) {
                  _K.text => ctl[f.key]!.text.trim().isEmpty ? null : ctl[f.key]!.text.trim(),
                  _K.number => num.tryParse(ctl[f.key]!.text.trim()),
                  _K.list => ctl[f.key]!.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
                  _K.date => values[f.key] == null ? null : isoDay(values[f.key] as DateTime),
                  _ => values[f.key],
                };
                if (f.required && (v == null || v == '')) {
                  toast(ctx, 'Fill in ${f.label.toLowerCase()}.', bad: true);
                  return;
                }
                row[f.key] = v;
              }
              try {
                await Api.instance.insert(table, row, columns: 'id');
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } on ApiError catch (e) {
                if (ctx.mounted) toast(ctx, e.message, bad: true);
              }
            },
          ),
        ]);
      }));
  for (final c in ctl.values) {
    c.dispose();
  }
  return ok == true;
}
