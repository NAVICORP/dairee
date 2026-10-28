import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/config.dart';
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
/// Their account is in the round's menu.
class RoundOnly extends StatelessWidget {
  const RoundOnly({super.key, required this.farm});
  final FarmRole farm;

  @override
  Widget build(BuildContext context) => RoundView(farm: farm, office: false, alone: true);
}

enum _Show { all, todo, done, paused }

/// One round (a day and morning or evening), like a month of a chit in
/// Kuree: the big card on top steps from round to round, the stops below.
class RoundView extends StatefulWidget {
  const RoundView({super.key, required this.farm, required this.office, this.alone = false, this.day, this.slot});
  final FarmRole farm;
  final bool office;

  /// The only screen this person has: their account lives in the menu.
  final bool alone;
  final DateTime? day;
  final String? slot;

  @override
  State<RoundView> createState() => _RoundViewState();
}

class _RoundViewState extends State<RoundView> {
  late DateTime day = widget.day ?? widget.farm.today;
  late String slot = widget.slot ?? (DateTime.now().hour < 13 ? 'morning' : 'evening');
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

  void _go(DateTime d, String sl) {
    setState(() {
      day = dayOnly(d);
      slot = sl;
      stops = null;
      open.clear();
    });
    _load();
  }

  String _roundLabel(DateTime d, String sl) => roundLabel(d, sl, widget.farm.today);

  Future<void> _pickRound() async {
    final r = await pickRound(context, day: day, slot: slot, today: widget.farm.today);
    if (r != null && mounted) _go(r.$1, r.$2);
  }

  Future<void> _menu() async {
    final f = widget.farm;
    final waiting = Outbox.instance.waiting;
    final pick = await showPicker<String>(context, title: _roundLabel(day, slot), options: [
      const PickOption('round', 'Another round', sub: 'Morning or evening, any day', icon: Icons.event_outlined),
      if (waiting > 0) PickOption('send', 'Send waiting ticks', sub: '$waiting made with no signal', icon: Icons.cloud_upload_outlined),
      if (widget.office) ...[
        PickOption('lock', locked ? 'Open this day' : 'Close this day',
            sub: locked ? 'Allow ticks and changes again' : 'No more ticks or changes on ${dayInSentence(day, f.today)}',
            icon: locked ? Icons.lock_open_rounded : Icons.lock_outline_rounded),
        const PickOption('wall', 'Wall board', sub: 'Today\'s rounds, full screen, for the office', icon: Icons.tv_rounded),
      ],
      if (widget.alone) ...[
        if (Me.instance.farms.length > 1) PickOption('farm', 'Switch farm', sub: f.name, icon: Icons.swap_horiz_rounded),
        const PickOption('help', 'Help and support', icon: Icons.support_agent_rounded),
        PickOption('out', 'Sign out', sub: f.staffName, icon: Icons.logout_rounded),
        const PickOption('delete', 'Delete my account', icon: Icons.delete_outline_rounded),
      ],
    ]);
    if (pick == null || !mounted) return;
    switch (pick.value) {
      case 'round':
        await _pickRound();
      case 'send':
        await Outbox.instance.flush();
        await _load();
      case 'lock':
        await _lock();
      case 'wall':
        await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => WallBoard(farm: f)));
      case 'farm':
        await switchFarm(context, f);
      case 'help':
        await launchUrl(Uri.parse(kSupportUrl), mode: LaunchMode.externalApplication);
      case 'out':
        await signOut(context);
      case 'delete':
        await deleteMyAccount(context);
    }
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
    // Delivery staff see their own stops by default: the numbers follow.
    final mineOnly = !widget.office && mine && anyMine;
    final scope = mineOnly ? (list ?? const <Stop>[]).where((s) => s.staffId == widget.farm.staffId).toList() : (list ?? const <Stop>[]);
    final pushed = ModalRoute.of(context)?.canPop ?? false;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: pushed ? Sp.xs : Sp.xl,
        title: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.farm.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small.copyWith(color: K.blue, fontWeight: FontWeight.w800)),
          Text('${slotName(slot)} round', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.h3.copyWith(fontSize: 17)),
        ]),
        actions: [
          if (Outbox.instance.waiting > 0)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Center(child: Pill.warn('${Outbox.instance.waiting} waiting', icon: Icons.cloud_off_rounded)),
            ),
          if (locked) const Padding(padding: EdgeInsets.only(right: 2), child: Center(child: Pill.grey('Closed', icon: Icons.lock_rounded))),
          IconButton(tooltip: 'More', icon: const Icon(Icons.more_horiz_rounded), onPressed: _menu),
          const SizedBox(width: Sp.xs),
        ],
      ),
      body: RefreshIndicator(
        color: K.blue,
        onRefresh: () async {
          await Outbox.instance.flush();
          await _load();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Sp.page, Sp.xs, Sp.page, 120),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _hero(scope),
                  const SizedBox(height: Sp.md + 2),
                  if (error != null && list == null)
                    LoadFailed(message: error!, onRetry: _load)
                  else if (list == null)
                    const Padding(padding: EdgeInsets.all(40), child: Loading())
                  else ...[
                    if (!widget.office && anyMine) ...[
                      KSegmented<bool>(expand: true, items: const [(true, 'My stops'), (false, 'Everyone')], value: mine, onChanged: (v) => setState(() => mine = v)),
                      const SizedBox(height: Sp.md),
                    ],
                    if (locked) ...[const Notice('This day is closed. Nothing can be ticked or changed.', bad: false), const SizedBox(height: Sp.md)],
                    SearchField(controller: _q, hint: 'Search name, room or number', onChanged: (_) => setState(() {})),
                    const SizedBox(height: Sp.sm + 2),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: KSegmented<_Show>(
                        items: [
                          (_Show.all, 'All ${scope.length}'),
                          (_Show.todo, 'To do ${scope.where((s) => s.due && !s.delivered).length}'),
                          (_Show.done, 'Done ${scope.where((s) => s.delivered).length}'),
                          (_Show.paused, 'Paused ${scope.where((s) => s.paused).length}'),
                        ],
                        value: show,
                        onChanged: (v) => setState(() => show = v),
                      ),
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

  /// The big card: which round, stepping back and forth like Kuree's months,
  /// then the milk out, how many stops are done and what is left.
  Widget _hero(List<Stop> list) {
    final due = list.where((s) => s.due).toList();
    final done = due.where((s) => s.delivered).length;
    final total = due.fold<num>(0, (a, s) => a + s.qty);
    final litresDone = due.where((s) => s.delivered).fold<num>(0, (a, s) => a + (s.deliveredQty ?? s.qty));
    final bottles = list.where((s) => s.delivered && s.hasBottles && !s.returned).length;
    final paused = list.where((s) => s.paused).length;
    final loaded = stops != null;
    final notes = [
      if (bottles > 0) '$bottles ${bottles == 1 ? 'bottle' : 'bottles'} to collect',
      if (paused > 0) '$paused paused',
      if (bottles == 0 && paused == 0) loaded && due.isNotEmpty && done == due.length ? 'Every stop delivered' : 'No bottles out, nobody paused',
    ];
    return HeroCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        RoundNav(day: day, slot: slot, today: widget.farm.today, onChanged: _go),
        const SizedBox(height: Sp.lg),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(loaded ? litres(litresDone) : '...', style: T.amount),
        ),
        const SizedBox(height: Sp.xs),
        Text(loaded ? 'of ${litres(total)} delivered on ${dateLabel(day)}' : dateLabel(day),
            style: T.small.copyWith(color: K.heroText, fontWeight: FontWeight.w600)),
        const SizedBox(height: Sp.md + 2),
        ProgressLine(due.isEmpty ? 0 : done / due.length),
        const SizedBox(height: Sp.md),
        Row(children: [
          Expanded(
            child: Text('$done of ${due.length} delivered', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label.copyWith(color: Colors.white)),
          ),
          const SizedBox(width: Sp.sm),
          Text(due.length - done > 0 ? '${due.length - done} to go' : (due.isEmpty ? 'No stops' : 'All done'), style: T.small.copyWith(color: K.heroText)),
        ]),
        const SizedBox(height: Sp.md),
        Container(height: 1, color: const Color(0x1FFFFFFF)),
        const SizedBox(height: Sp.md),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.local_drink_outlined, size: 15, color: K.heroText)),
          const SizedBox(width: Sp.sm),
          Expanded(child: Text(loaded ? notes.join(', ') : 'Loading the stops', style: T.small.copyWith(color: K.heroText))),
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
