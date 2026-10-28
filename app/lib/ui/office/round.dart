import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../../core/outbox.dart';
import '../theme.dart';
import '../widgets.dart';
import 'shell.dart';
import 'wallboard.dart';

/// One stop on a round, as the server decided it, plus anything ticked here
/// that is still waiting for a signal.
class Stop {
  Stop(this.j);
  final Map<String, dynamic> j;

  String get customerId => j['customer_id'] as String;
  String get name => '${j['name'] ?? ''}';
  String get phone => '${j['phone'] ?? ''}';
  String get building => (j['building'] as String? ?? '').trim();
  String get place => placeOf(j);
  num get qty => toNum(j['qty']);
  num get standing => toNum(j['standing_qty']);
  List get vessels => j['vessels'] as List? ?? const [];
  bool get paused => j['paused'] == true;
  String? get pausedBy => j['paused_by'] as String?;
  bool get temporary => j['temporary'] == true;
  bool get expected => j['expected'] == true;
  bool delivered = false;
  bool returned = false;
  bool waiting = false;
  String? get notes => j['notes'] as String?;
  num? get deliveredQty => j['delivered_qty'] == null ? null : toNum(j['delivered_qty']);
  String? get staffId => j['delivery_staff_id'] as String?;
  bool get hasBottles => vessels.whereType<Map>().any((v) => v['category'] == 'bottle');
  bool get due => !paused && qty > 0;

  static Stop of(Map<String, dynamic> j) => Stop(j)
    ..delivered = j['delivered'] == true
    ..returned = j['bottle_returned'] == true;
}

/// The Round page in the farm: the office sees every day and can correct;
/// delivery staff see the same list to tick.
class RoundPage extends StatelessWidget {
  const RoundPage({super.key, required this.farm, required this.office});
  final FarmRole farm;
  final bool office;

  @override
  Widget build(BuildContext context) => RoundView(farm: farm, office: office);
}

/// Delivery staff with no office pages: the round and nothing else on screen.
class RoundOnly extends StatelessWidget {
  const RoundOnly({super.key, required this.farm});
  final FarmRole farm;

  @override
  Widget build(BuildContext context) {
    return RoundView(
      farm: farm,
      office: false,
      account: () => showKSheet<void>(context, title: farm.staffName, builder: (ctx) {
        final me = Me.instance;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(farm.name, style: T.small),
          const SizedBox(height: Sp.md),
          if (me.farms.length > 1)
            for (final f in me.farms.where((f) => f.id != farm.id))
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.sm),
                child: KButton(label: 'Switch to ${f.name}', kind: KButtonKind.secondary, expand: true, onPressed: () {
                  Navigator.of(ctx).pop();
                  me.switchTo(f);
                }),
              ),
          KButton(
              label: 'Sign out',
              icon: Icons.logout_rounded,
              kind: KButtonKind.secondary,
              expand: true,
              onPressed: () async {
                Navigator.of(ctx).pop();
                Me.instance.clear();
                await Api.instance.signOut();
              }),
          const SizedBox(height: Sp.sm),
          KButton(label: 'Delete my account', kind: KButtonKind.ghost, expand: true, onPressed: () {
            Navigator.of(ctx).pop();
            deleteMyAccount(context);
          }),
        ]);
      }),
    );
  }
}

enum _Show { all, todo, done, paused }

class RoundView extends StatefulWidget {
  const RoundView({super.key, required this.farm, required this.office, this.account});
  final FarmRole farm;
  final bool office;
  final VoidCallback? account;

  @override
  State<RoundView> createState() => _RoundViewState();
}

class _RoundViewState extends State<RoundView> {
  late DateTime day = widget.farm.today;
  late String slot = DateTime.now().hour < 13 ? 'morning' : 'evening';
  List<Stop>? stops;
  bool locked = false;
  String? error;
  _Show show = _Show.all;
  bool mine = true;
  final _q = TextEditingController();
  final Set<String> open = {};

  @override
  void initState() {
    super.initState();
    Outbox.instance.addListener(_outbox);
    _load();
  }

  @override
  void dispose() {
    Outbox.instance.removeListener(_outbox);
    _q.dispose();
    super.dispose();
  }

  void _outbox() {
    final r = Outbox.instance.lastRefusal;
    if (r != null && mounted) {
      Outbox.instance.lastRefusal = null;
      toast(context, 'A tick made offline was refused: $r', bad: true);
      _load();
    } else if (mounted) {
      setState(() {
        for (final s in stops ?? const <Stop>[]) {
          s.waiting = Outbox.instance.pendingFor(s.customerId, isoDay(day), slot).isNotEmpty;
        }
      });
    }
  }

  Future<void> _load() async {
    final d = day, sl = slot;
    try {
      final r = await Api.instance.rpc('round', {'day': isoDay(d), 'slot': sl});
      if (!mounted || d != day || sl != slot) return;
      final m = Map<String, dynamic>.from(r as Map);
      final list = (m['stops'] as List? ?? const []).whereType<Map>().map((e) => Stop.of(Map<String, dynamic>.from(e))).toList();
      // What was ticked here and not sent yet still shows as ticked.
      for (final s in list) {
        final pending = Outbox.instance.pendingFor(s.customerId, isoDay(d), sl);
        for (final p in pending) {
          final a = p['args'] as Map;
          if (p['fn'] == 'set_delivery') s.delivered = a['delivered'] == true;
          if (p['fn'] == 'set_bottle_returned') s.returned = a['returned'] == true;
        }
        s.waiting = pending.isNotEmpty;
      }
      setState(() {
        stops = list;
        locked = m['locked'] == true;
        error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  void _move(DateTime d) {
    setState(() {
      day = d;
      stops = null;
    });
    _load();
  }

  Future<void> _tick(Stop s, bool on) async {
    if (locked) {
      toast(context, 'This day is closed. Open it first.', bad: true);
      return;
    }
    setState(() => s.delivered = on);
    try {
      final sent = await Outbox.instance.send('set_delivery', {
        'customer_id': s.customerId,
        'day': isoDay(day),
        'slot': slot,
        'delivered': on,
      });
      if (!mounted) return;
      setState(() => s.waiting = !sent);
      if (!sent) toast(context, 'No signal. Saved on this phone; it goes as soon as there is a connection.');
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => s.delivered = !on);
      toast(context, e.message, bad: true);
    }
  }

  Future<void> _bottle(Stop s, bool on) async {
    setState(() => s.returned = on);
    try {
      final sent = await Outbox.instance.send('set_bottle_returned', {'customer_id': s.customerId, 'day': isoDay(day), 'slot': slot, 'returned': on});
      if (mounted) setState(() => s.waiting = !sent);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => s.returned = !on);
      toast(context, e.message, bad: true);
    }
  }

  Future<void> _lock() async {
    final close = !locked;
    final ok = await confirm(context,
        title: close ? 'Close ${dateLabel(day)}?' : 'Open ${dateLabel(day)} again?',
        text: close ? 'Nothing on this day can be ticked or changed until it is opened again.' : 'Ticks and changes on this day will be allowed again.',
        yes: close ? 'Close the day' : 'Open it');
    if (!ok) return;
    try {
      await Api.instance.rpc('lock_day', {'day': isoDay(day), 'locked': close});
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  List<Stop> get _shown {
    final t = _q.text.trim().toLowerCase();
    final me = widget.farm.staffId;
    final anyMine = (stops ?? const []).any((s) => s.staffId == me);
    return (stops ?? const <Stop>[]).where((s) {
      if (!widget.office && mine && anyMine && s.staffId != me) return false;
      if (t.isNotEmpty && !'${s.name} ${s.place} ${s.phone}'.toLowerCase().contains(t)) return false;
      return switch (show) {
        _Show.all => true,
        _Show.todo => s.due && !s.delivered,
        _Show.done => s.delivered,
        _Show.paused => s.paused,
      };
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = stops;
    final narrowing = _q.text.trim().isNotEmpty || show != _Show.all;
    final anyMine = (list ?? const <Stop>[]).any((s) => s.staffId == widget.farm.staffId);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.office ? 'Round' : widget.farm.name),
        actions: [
          if (Outbox.instance.waiting > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: Pill.warn('${Outbox.instance.waiting} waiting', icon: Icons.cloud_off_rounded)),
            ),
          if (widget.office) ...[
            RoundIcon(locked ? Icons.lock_rounded : Icons.lock_open_rounded, tooltip: locked ? 'Open this day' : 'Close this day', onTap: _lock),
            RoundIcon(Icons.tv_rounded,
                tooltip: 'Wall board',
                onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => WallBoard(farm: widget.farm)))),
          ],
          if (widget.account != null) RoundIcon(Icons.person_outline_rounded, tooltip: 'Account', onTap: widget.account),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        color: K.blue,
        onRefresh: () async {
          await Outbox.instance.flush();
          await _load();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Sp.page, 0, Sp.page, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  DayStrip(day: day, today: widget.farm.today, onChanged: _move),
                  const SizedBox(height: Sp.sm),
                  KSegmented<String>(
                    expand: true,
                    items: const [('morning', 'Morning'), ('evening', 'Evening')],
                    value: slot,
                    onChanged: (v) {
                      setState(() {
                        slot = v;
                        stops = null;
                      });
                      _load();
                    },
                  ),
                  const SizedBox(height: Sp.md),
                  if (error != null && list == null)
                    LoadFailed(message: error!, onRetry: _load)
                  else if (list == null)
                    const Padding(padding: EdgeInsets.all(40), child: Loading())
                  else ...[
                    _summary(list),
                    const SizedBox(height: Sp.md),
                    if (locked) ...[const Notice('This day is closed. Nothing can be ticked or changed.', bad: false), const SizedBox(height: Sp.md)],
                    SearchField(controller: _q, hint: 'Search name, room or number', onChanged: (_) => setState(() {})),
                    const SizedBox(height: Sp.sm),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        KSegmented<_Show>(
                          items: [
                            (_Show.all, 'All'),
                            (_Show.todo, 'To do ${list.where((s) => s.due && !s.delivered).length}'),
                            (_Show.done, 'Done ${list.where((s) => s.delivered).length}'),
                            (_Show.paused, 'Paused ${list.where((s) => s.paused).length}'),
                          ],
                          value: show,
                          onChanged: (v) => setState(() => show = v),
                        ),
                        if (!widget.office && anyMine) ...[
                          const SizedBox(width: Sp.sm),
                          KSegmented<bool>(items: const [(true, 'Mine'), (false, 'Everyone')], value: mine, onChanged: (v) => setState(() => mine = v)),
                        ],
                      ]),
                    ),
                    const SizedBox(height: Sp.md),
                    ..._groups(_shown, open: narrowing || !widget.office),
                    if (list.isEmpty)
                      const EmptyState(icon: Icons.local_shipping_outlined, text: 'Nobody is on this round. Add customers, or check the day and round.'),
                  ],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary(List<Stop> list) {
    final due = list.where((s) => s.due).toList();
    final done = due.where((s) => s.delivered).length;
    final total = due.fold<num>(0, (a, s) => a + s.qty);
    final litresDone = due.where((s) => s.delivered).fold<num>(0, (a, s) => a + (s.deliveredQty ?? s.qty));
    final bottles = list.where((s) => s.delivered && s.hasBottles && !s.returned).length;
    final paused = list.where((s) => s.paused).length;
    return HeroCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${slotName(slot)} round, ${relativeDay(day, widget.farm.today).toLowerCase()}', style: T.small.copyWith(color: K.heroText)),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$done', style: T.amount),
          Padding(padding: const EdgeInsets.only(bottom: 3, left: 6), child: Text('of ${due.length} delivered', style: T.body.copyWith(color: K.heroText))),
        ]),
        const SizedBox(height: 12),
        ProgressLine(due.isEmpty ? 0 : done / due.length),
        const SizedBox(height: 14),
        Wrap(spacing: 22, runSpacing: 10, children: [
          Stat('${litres(litresDone)} of ${litres(total)}', 'Milk out', dark: true),
          Stat('$bottles', 'Bottles to collect', dark: true),
          Stat('$paused', 'Paused', dark: true),
        ]),
      ]),
    );
  }

  /// Stops by building. In the office the groups start closed (a full round is
  /// a hundred stops; the question is how far along and which building next)
  /// and open while a search or filter narrows the list.
  List<Widget> _groups(List<Stop> shown, {required bool open}) {
    final groups = <String, List<Stop>>{};
    for (final s in shown) {
      groups.putIfAbsent(s.building.isEmpty ? 'No building' : s.building, () => []).add(s);
    }
    return [
      for (final e in groups.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: Sp.sm),
          child: _Group(
            title: e.key,
            stops: e.value,
            open: open || this.open.contains(e.key),
            onToggle: () => setState(() => this.open.contains(e.key) ? this.open.remove(e.key) : this.open.add(e.key)),
            row: (s) => _StopRow(stop: s, onTick: (v) => _tick(s, v), onOpen: () => _details(s), locked: locked),
          ),
        ),
    ];
  }

  Future<void> _details(Stop s) async {
    final note = TextEditingController(text: s.notes ?? '');
    final qty = TextEditingController(text: s.deliveredQty == null ? '' : '${s.deliveredQty}');
    await showKSheet<void>(context, title: s.name, builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text([s.place, prettyPhone(s.phone)].where((x) => x.isNotEmpty).join(', '), style: T.small),
        const SizedBox(height: Sp.md),
        KGroup(children: [
          KRow(title: s.paused ? 'Paused' : litres(s.qty), sub: s.paused ? 'Paused by ${s.pausedBy ?? 'the office'}' : vesselsText(s.vessels)),
          if (s.temporary) KRow(title: 'Temporary change', sub: 'Usually ${litres(s.standing)}'),
        ]),
        const SizedBox(height: Sp.md),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          if (s.phone.isNotEmpty)
            KButton(label: 'Call', icon: Icons.call_rounded, kind: KButtonKind.secondary, small: true, onPressed: () => launchUrl(Uri.parse('tel:+${s.phone}'))),
          if (s.delivered && s.hasBottles)
            KButton(
              label: s.returned ? 'Bottles collected' : 'Bottles not back yet',
              icon: s.returned ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              kind: KButtonKind.secondary,
              small: true,
              onPressed: locked
                  ? null
                  : () async {
                      await _bottle(s, !s.returned);
                      set(() {});
                    },
            ),
        ]),
        const SizedBox(height: Sp.lg),
        KField(label: 'What the doorstep said', controller: note, hint: 'Gate locked, left with the guard...', maxLines: 3),
        if (widget.office && s.delivered) ...[
          const SizedBox(height: Sp.md),
          KField(label: 'Litres that went (if not ${litres(s.qty)})', controller: qty, keyboard: const TextInputType.numberWithOptions(decimal: true)),
        ],
        const SizedBox(height: Sp.lg),
        KButton(
          label: 'Save',
          icon: Icons.check_rounded,
          expand: true,
          onPressed: locked
              ? null
              : () async {
                  final n = note.text.trim();
                  final q = num.tryParse(qty.text.trim());
                  try {
                    if (n != (s.notes ?? '')) {
                      await Outbox.instance.send('set_note', {'customer_id': s.customerId, 'day': isoDay(day), 'slot': slot, 'notes': n});
                    }
                    if (widget.office && s.delivered && q != null && q != s.deliveredQty) {
                      await Api.instance.rpc('set_delivery', {'customer_id': s.customerId, 'day': isoDay(day), 'slot': slot, 'delivered': true, 'quantity': q});
                    }
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    await _load();
                  } on ApiError catch (e) {
                    if (ctx.mounted) toast(ctx, e.message, bad: true);
                  }
                },
        ),
      ]);
    }));
    note.dispose();
    qty.dispose();
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.stops, required this.open, required this.onToggle, required this.row});
  final String title;
  final List<Stop> stops;
  final bool open;
  final VoidCallback onToggle;
  final Widget Function(Stop) row;

  @override
  Widget build(BuildContext context) {
    final due = stops.where((s) => s.due).length;
    final done = stops.where((s) => s.due && s.delivered).length;
    final litres0 = stops.where((s) => s.due).fold<num>(0, (a, s) => a + s.qty);
    final finished = due > 0 && done == due;
    return Container(
      decoration: BoxDecoration(color: K.surface, borderRadius: BorderRadius.circular(K.r), border: Border.all(color: K.border)),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 11, 10, 11),
              child: Row(children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: finished ? K.blue : K.brand100, borderRadius: BorderRadius.circular(11)),
                  child: Icon(finished ? Icons.check_rounded : Icons.apartment_rounded, size: 18, color: finished ? Colors.white : K.blue),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: T.bodyStrong),
                    Text('$done of $due done, ${litres(litres0)}', style: T.small),
                  ]),
                ),
                Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: K.muted),
              ]),
            ),
          ),
          if (open)
            for (final s in stops) ...[const Divider(height: 1), row(s)],
        ]),
      ),
    );
  }
}

class _StopRow extends StatelessWidget {
  const _StopRow({required this.stop, required this.onTick, required this.onOpen, required this.locked});
  final Stop stop;
  final ValueChanged<bool> onTick;
  final VoidCallback onOpen;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final s = stop;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 9, 8, 9),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if ((s.j['room'] as String? ?? '').isNotEmpty) ...[
                  Text('${s.j['room']}', style: T.bodyStrong.copyWith(color: K.blue)),
                  const SizedBox(width: 8),
                ],
                Flexible(child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.bodyStrong)),
              ]),
              const SizedBox(height: 2),
              Text(s.paused ? 'Paused' : '${litres(s.qty)}, ${vesselsText(s.vessels)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
              if (s.temporary || (s.notes ?? '').isNotEmpty || s.waiting || (s.delivered && s.hasBottles && !s.returned))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 6, runSpacing: 4, children: [
                    if (s.temporary) Pill('Today ${litres(s.qty)}, usually ${litres(s.standing)}', icon: Icons.swap_horiz_rounded),
                    if ((s.notes ?? '').isNotEmpty) Pill.grey(s.notes!, icon: Icons.sticky_note_2_outlined),
                    if (s.waiting) const Pill.warn('Waiting for signal', icon: Icons.cloud_off_rounded),
                    if (s.delivered && s.hasBottles && !s.returned) const Pill.grey('Bottles out', icon: Icons.local_drink_outlined),
                  ]),
                ),
            ]),
          ),
          const SizedBox(width: 8),
          if (s.paused && !s.delivered)
            const Padding(padding: EdgeInsets.all(10), child: Pill.warn('Paused'))
          else
            Semantics(
              button: true,
              label: s.delivered ? 'Delivered. Tap to undo' : 'Mark delivered',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: locked ? null : () => onTick(!s.delivered),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: s.delivered ? K.blue : K.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: s.delivered ? K.blue : K.border2, width: 1.6),
                    ),
                    child: Icon(Icons.check_rounded, size: 24, color: s.delivered ? Colors.white : K.border2),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
