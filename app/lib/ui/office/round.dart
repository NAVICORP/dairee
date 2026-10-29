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
  String get room => (j['room'] as String? ?? '').trim();
  String get address => (j['address'] as String? ?? '').trim();
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
  String get notes => (j['notes'] as String? ?? '').trim();
  num? get deliveredQty => j['delivered_qty'] == null ? null : toNum(j['delivered_qty']);
  String? get staffId => j['delivery_staff_id'] as String?;
  String get staffName => (j['staff_name'] as String? ?? '').trim();
  DateTime? get deliveredAt => DateTime.tryParse('${j['delivered_at'] ?? ''}')?.toLocal();
  bool get hasBottles => vessels.whereType<Map>().any((v) => v['category'] == 'bottle');
  bool get due => !paused && qty > 0;

  /// Bottles that went out on earlier rounds and have not come back, and
  /// the rounds they went on, oldest first.
  int get bottlesOut => toNum(j['bottles_out']).toInt();
  List<Map<String, dynamic>> get bottleDays =>
      [for (final d in (j['bottle_days'] as List? ?? const []).whereType<Map>()) Map<String, dynamic>.from(d)];

  /// One round's bottle out is a house that had milk yesterday: it comes back
  /// with the next. Bottles from two rounds or more is a house behind.
  bool get behind => bottleDays.length > 1;

  /// Where the stop is, for the row: the room, or the address.
  String get spot => room.isNotEmpty ? room : address;

  static Stop of(Map<String, dynamic> j) => Stop(j)
    ..delivered = j['delivered'] == true
    ..returned = j['bottle_returned'] == true;
}

/// Delivery staff with no office pages: the round and nothing else on screen.
/// Their account is in the round's menu.
class RoundOnly extends StatelessWidget {
  const RoundOnly({super.key, required this.farm});
  final FarmRole farm;

  @override
  Widget build(BuildContext context) => RoundView(farm: farm, office: false, alone: true);
}

// ---------------------------------------------------------------- colours of the delivery screen

/// The colours the delivery screen shares with Mazra: green for done, blue
/// for a bottle back, amber for something to look at, red for a closed day.
class _C {
  static const green = Color(0xFF22C55E);
  static const green50 = Color(0xFFF0FDF4);
  static const greenRow = Color(0xFFF6FDF8);
  static const green100 = Color(0xFFDCFCE7);
  static const green600 = Color(0xFF16A34A);
  static const green700 = Color(0xFF15803D);
  static const green800 = Color(0xFF166534);
  static const back = Color(0xFF2563EB);
  static const amber = Color(0xFFD97706);
  static const amber700 = Color(0xFFB45309);
  static const amber800 = Color(0xFF92400E);
  static const amber50 = Color(0xFFFFFBEB);
  static const amber200 = Color(0xFFFDE68A);
  static const red = Color(0xFFDC2626);
  static const red500 = Color(0xFFEF4444);
  static const red200 = Color(0xFFFECACA);
  static const grey100 = Color(0xFFEEF2F7);
  static const grey400 = Color(0xFF94A3B8);
  static const line = Color(0xFFF1F4F9);
}

/// A building's own tint, so the eye finds it on a long round.
class _Tone {
  const _Tone(this.bg, this.fg, this.badge);
  final Color bg;
  final Color fg;
  final Color badge;
}

const _tones = [
  _Tone(Color(0xFFEFF6FF), Color(0xFF1D4ED8), Color(0xFFDBEAFE)), // blue
  _Tone(Color(0xFFECFEFF), Color(0xFF0E7490), Color(0xFFCFFAFE)), // cyan
  _Tone(Color(0xFFFAF5FF), Color(0xFF7E22CE), Color(0xFFF3E8FF)), // violet
  _Tone(Color(0xFFF0FDF4), Color(0xFF15803D), Color(0xFFDCFCE7)), // green
  _Tone(Color(0xFFF0FDFA), Color(0xFF0F766E), Color(0xFFCCFBF1)), // teal
  _Tone(Color(0xFFEEF2FF), Color(0xFF4338CA), Color(0xFFE0E7FF)), // indigo
];
const _noBuildingTone = _Tone(Color(0xFFFFFBEB), Color(0xFFB45309), Color(0xFFFEF3C7)); // amber

const _noBuilding = 'No building';

TextStyle _m(double size, FontWeight w, [Color c = K.ink]) =>
    TextStyle(fontFamily: 'Manrope', fontSize: size, fontWeight: w, height: 1.3, letterSpacing: 0, color: c);

// ---------------------------------------------------------------- the screen

/// The delivery screen, like Mazra's: the day and the round on top with the
/// Filter, whether the day is open, how far the round has got, then the
/// stops building by building, each with Done and the bottle beside it.
/// It is the farm's Today page, and the whole app for delivery staff.
class RoundView extends StatefulWidget {
  const RoundView({super.key, required this.farm, required this.office, this.alone = false, this.home = false, this.open, this.day, this.slot});
  final FarmRole farm;

  /// The office: closes days, corrects litres and who takes a stop.
  final bool office;

  /// The only screen this person has: their account lives in the menu.
  final bool alone;

  /// Shown as the Today page: the Dairee name on top, packing and requests
  /// a tap away.
  final bool home;
  final void Function(String key)? open;
  final DateTime? day;
  final String? slot;

  @override
  State<RoundView> createState() => _RoundViewState();
}

class _RoundViewState extends State<RoundView> {
  late DateTime day = widget.day ?? widget.farm.today;

  /// Morning is always where the page starts: the evening is one tap away.
  late String slot = widget.slot ?? 'morning';
  List<Stop>? stops;
  List<Map<String, dynamic>> staff = const [];
  bool locked = false;
  String? error;
  int requests = 0;

  bool filters = false;
  final _q = TextEditingController();
  String building = 'all';
  String person = 'all';
  String quantity = 'all';
  bool onlyPending = false;
  bool myDefaultSet = false;

  /// Buildings opened by hand, and those showing every stop.
  final Set<String> opened = {};
  final Set<String> showAll = {};

  /// Stops opened for their details.
  final Set<String> details = {};

  FarmRole get f => widget.farm;

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
        staff = [for (final s in (m['staff'] as List? ?? const []).whereType<Map>()) Map<String, dynamic>.from(s)];
        locked = m['locked'] == true;
        error = null;
        // Delivery staff open on their own stops; Filter shows everyone's.
        if (!widget.office && !myDefaultSet) {
          myDefaultSet = true;
          if (list.any((s) => s.staffId == f.staffId)) person = f.staffId;
        }
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
    if (widget.home && f.can('pauses')) {
      try {
        final rows = await Api.instance.select('temporary_requests', columns: 'id', where: {'status': 'eq.pending'});
        if (mounted) setState(() => requests = rows.length);
      } on ApiError {
        // The bell just stays quiet.
      }
    }
  }

  void _go(DateTime d, String sl) {
    setState(() {
      day = dayOnly(d);
      slot = sl;
      stops = null;
      opened.clear();
      showAll.clear();
      details.clear();
    });
    _load();
  }

  Future<void> _pickDay() async {
    final d = await pickDate(context, initial: day, last: addDays(f.today, 7), title: 'Which day');
    if (d != null && mounted) _go(d, slot);
  }

  Future<void> _menu() async {
    final waiting = Outbox.instance.waiting;
    final pick = await showPicker<String>(context, title: '${slotName(slot)} round, ${dateLabel(day)}', options: [
      if (waiting > 0) PickOption('send', 'Send waiting ticks', sub: '$waiting made with no signal', icon: Icons.cloud_upload_outlined),
      if (widget.office) const PickOption('wall', 'Wall board', sub: 'Today\'s rounds, full screen, for the office', icon: Icons.tv_rounded),
      if (widget.alone) ...[
        if (Me.instance.farms.length > 1) PickOption('farm', 'Switch farm', sub: f.name, icon: Icons.swap_horiz_rounded),
        const PickOption('help', 'Help and support', icon: Icons.support_agent_rounded),
        PickOption('out', 'Sign out', sub: f.staffName, icon: Icons.logout_rounded),
        const PickOption('delete', 'Delete my account', icon: Icons.delete_outline_rounded),
      ],
    ]);
    if (pick == null || !mounted) return;
    switch (pick.value) {
      case 'send':
        await Outbox.instance.flush();
        await _load();
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

  // ---------------------------------------------------------------- what a press does

  Future<void> _tick(Stop s) async {
    if (locked) {
      toast(context, 'This day is closed. Open it first.', bad: true);
      return;
    }
    final on = !s.delivered;
    final was = s.j['delivered_at'];
    setState(() {
      s.delivered = on;
      s.j['delivered_at'] = on ? DateTime.now().toUtc().toIso8601String() : null;
      if (!on) s.returned = false;
    });
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
      setState(() {
        s.delivered = !on;
        s.j['delivered_at'] = was;
      });
      toast(context, e.message, bad: true);
    }
  }

  /// Today's bottle, handed back at the door just now.
  Future<void> _bottle(Stop s) async {
    if (locked) {
      toast(context, 'This day is closed. Open it first.', bad: true);
      return;
    }
    if (!s.delivered) {
      toast(context, 'Mark the delivery first.');
      return;
    }
    final on = !s.returned;
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

  /// A bottle from an earlier round, closed on purpose, one round at a time.
  Future<void> _oldBottle(Stop s, Map<String, dynamic> b) async {
    final d = parseDay(b['day']);
    if (d == null) return;
    final sl = '${b['slot']}';
    final ok = await confirm(context,
        title: 'Bottle back?',
        text: 'The ${bottleWords(toNum(b['bottles']).toInt())} from ${dateLabel(d)}, ${slotName(sl).toLowerCase()} came back from ${s.name}.',
        yes: 'Yes, it is back');
    if (!ok || !mounted) return;
    try {
      await Api.instance.rpc('set_bottle_returned', {'customer_id': s.customerId, 'day': isoDay(d), 'slot': sl, 'returned': true});
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _note(Stop s, String text) async {
    try {
      await Outbox.instance.send('set_note', {'customer_id': s.customerId, 'day': isoDay(day), 'slot': slot, 'notes': text});
      if (mounted) setState(() => s.j['notes'] = text);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _litres(Stop s, num q) async {
    if (q == (s.deliveredQty ?? s.qty)) return;
    try {
      await Api.instance.rpc('set_delivery', {'customer_id': s.customerId, 'day': isoDay(day), 'slot': slot, 'delivered': true, 'quantity': q});
      if (!mounted) return;
      setState(() => s.j['delivered_qty'] = q);
      toast(context, '${s.name}: ${litres(q)} saved');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _person(Stop s) async {
    final pick = await showPicker<String>(context, title: 'Who takes ${s.name}\'s milk', selected: s.staffId ?? '', options: [
      const PickOption('', 'Nobody yet', icon: Icons.person_off_outlined),
      for (final p in staff) PickOption('${p['id']}', '${p['name']}', icon: Icons.person_outline_rounded),
    ]);
    if (pick == null || !mounted || pick.value == (s.staffId ?? '')) return;
    try {
      await Api.instance.update('customers', {'delivery_staff_id': pick.value.isEmpty ? null : pick.value}, where: {'id': 'eq.${s.customerId}'}, columns: 'id');
      if (!mounted) return;
      setState(() {
        s.j['delivery_staff_id'] = pick.value.isEmpty ? null : pick.value;
        s.j['staff_name'] = pick.value.isEmpty ? null : pick.label;
      });
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _lock() async {
    final close = !locked;
    final ok = await confirm(context,
        title: close ? 'Close ${dateLabel(day)}?' : 'Open ${dateLabel(day)} again?',
        text: close
            ? 'Both rounds on this day stop taking ticks and changes until it is opened again.'
            : 'Ticks and changes on this day will be allowed again.',
        yes: close ? 'Close the day' : 'Open it');
    if (!ok) return;
    try {
      await Api.instance.rpc('lock_day', {'day': isoDay(day), 'locked': close});
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  // ---------------------------------------------------------------- what is shown

  /// The round's stops: paused ones are not on it today.
  List<Stop> get _round => (stops ?? const <Stop>[]).where((s) => !s.paused || s.delivered).toList();

  bool get _narrowed => _q.text.trim().isNotEmpty || building != 'all' || (widget.office ? person != 'all' : false) || quantity != 'all' || onlyPending;

  String _groupOf(Stop s) => s.building.isEmpty ? _noBuilding : s.building;

  List<Stop> get _shown {
    final t = _q.text.trim().toLowerCase();
    return _round.where((s) {
      if (t.isNotEmpty && !'${s.name} ${s.room} ${s.address} ${s.phone}'.toLowerCase().contains(t)) return false;
      if (building != 'all' && _groupOf(s) != building) return false;
      if (person == 'none' && s.staffId != null) return false;
      if (person != 'all' && person != 'none' && s.staffId != person) return false;
      if (quantity != 'all' && litres(s.qty) != quantity) return false;
      if (onlyPending && s.delivered) return false;
      return true;
    }).toList();
  }

  /// The stops this person is working through, for the numbers on top.
  List<Stop> get _scope => (!widget.office && person != 'all') ? _round.where((s) => person == 'none' ? s.staffId == null : s.staffId == person).toList() : _round;

  List<String> _buildings(List<Stop> list) {
    final names = <String>[];
    for (final s in list) {
      final g = _groupOf(s);
      if (!names.contains(g)) names.add(g);
    }
    // Stops with no building last, like the streets after the towers.
    if (names.remove(_noBuilding)) names.add(_noBuilding);
    return names;
  }

  _Tone _tone(String g, List<String> all) {
    if (g == _noBuilding) return _noBuildingTone;
    final i = all.where((x) => x != _noBuilding).toList().indexOf(g);
    return _tones[(i < 0 ? 0 : i) % _tones.length];
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final list = stops;
    final top = <Widget>[
      _controls(),
      const SizedBox(height: Sp.lg),
      if (list != null && _scope.isNotEmpty) ...[
        _progress(_scope),
        ..._stillToGo(_scope),
        ..._problems(_scope),
      ],
    ];
    final Widget below;
    if (error != null && list == null) {
      below = LoadFailed(message: error!, onRetry: _load);
    } else if (list == null) {
      below = const Padding(padding: EdgeInsets.all(40), child: Loading());
    } else if (_round.isEmpty) {
      below = _nobody(list);
    } else if (_shown.isEmpty) {
      below = const EmptyState(icon: Icons.search_off_rounded, text: 'Nobody matches. Change or clear the filter.');
    } else {
      below = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _groups(_shown));
    }

    Widget scroll(List<Widget> children, {EdgeInsets? pad}) => RefreshIndicator(
          color: K.blue,
          onRefresh: () async {
            await Outbox.instance.flush();
            await _load();
          },
          child: ListView(
            padding: pad ?? const EdgeInsets.fromLTRB(Sp.page, Sp.xs, Sp.page, 120),
            children: children,
          ),
        );

    return Scaffold(
      appBar: _appBar(wide),
      body: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 380, child: scroll(top, pad: const EdgeInsets.fromLTRB(Sp.xl, Sp.xs, 0, 40))),
              const SizedBox(width: Sp.xl),
              Expanded(child: scroll([below], pad: const EdgeInsets.fromLTRB(0, Sp.xs, Sp.xl, 60))),
            ])
          : scroll([
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...top, const SizedBox(height: Sp.lg), below]),
                ),
              ),
            ]),
    );
  }

  PreferredSizeWidget _appBar(bool wide) {
    final waiting = Outbox.instance.waiting;
    final more = waiting > 0 || widget.office || widget.alone;
    final pushed = ModalRoute.of(context)?.canPop ?? false;
    return AppBar(
      titleSpacing: pushed ? Sp.xs : Sp.xl,
      title: widget.home && !wide
          ? Row(children: [
              const DaireeIcon(size: 30),
              const SizedBox(width: 10),
              Text('Dairee', style: T.h2.copyWith(fontSize: 21)),
            ])
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small.copyWith(color: K.blue, fontWeight: FontWeight.w800)),
              Text(widget.home ? 'Deliveries' : 'Your round', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.h3.copyWith(fontSize: 17)),
            ]),
      actions: [
        if (waiting > 0)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Center(child: Pill.warn('$waiting waiting', icon: Icons.cloud_off_rounded)),
          ),
        if (widget.home && widget.open != null && f.can('preparation'))
          IconButton(tooltip: 'Packing', icon: const Icon(Icons.inventory_2_outlined, size: 22), onPressed: () => widget.open!('preparation')),
        if (widget.home && widget.open != null && f.can('pauses'))
          IconButton(
            tooltip: 'Requests',
            onPressed: () => widget.open!('pauses'),
            icon: Badge(
              isLabelVisible: requests > 0,
              label: Text('$requests'),
              backgroundColor: _C.red500,
              child: const Icon(Icons.notifications_none_rounded, size: 24),
            ),
          ),
        if (more) IconButton(tooltip: 'More', icon: const Icon(Icons.more_horiz_rounded), onPressed: _menu),
        const SizedBox(width: Sp.xs),
      ],
    );
  }

  // ---------------------------------------------------------------- the controls: day, Filter, round, open or closed

  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: K.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFEDF1F7)),
          boxShadow: const [
            BoxShadow(color: Color(0x0A101828), blurRadius: 2, offset: Offset(0, 1)),
            BoxShadow(color: Color(0x0F101828), blurRadius: 12, spreadRadius: -2, offset: Offset(0, 4)),
          ],
        ),
        child: child,
      );

  Widget _controls() {
    final dayWord = day == f.today ? 'Today' : dateLabel(day).replaceAll(' ${day.year}', '');
    return _card(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: _Press(
              onTap: _pickDay,
              color: const Color(0xFFEEF5FF),
              border: K.brand200,
              radius: 12,
              child: SizedBox(
                height: 44,
                child: Row(children: [
                  const SizedBox(width: 12),
                  const Icon(Icons.calendar_month_outlined, size: 18, color: K.blue),
                  const SizedBox(width: 8),
                  Expanded(child: Text(dateLabel(day), maxLines: 1, overflow: TextOverflow.ellipsis, style: _m(14, FontWeight.w700))),
                  const Icon(Icons.expand_more_rounded, size: 20, color: K.ink2),
                  const SizedBox(width: 10),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            selected: filters,
            child: _Press(
              onTap: () => setState(() => filters = !filters),
              color: filters ? K.blue : K.surface,
              border: filters ? K.blue : K.brand200,
              radius: 12,
              child: SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.tune_rounded, size: 17, color: filters ? Colors.white : K.blue),
                    const SizedBox(width: 6),
                    Text('Filter', style: _m(12.5, FontWeight.w700, filters ? Colors.white : K.blue)),
                    if (_narrowed && !filters) ...[
                      const SizedBox(width: 6),
                      Container(width: 7, height: 7, decoration: const BoxDecoration(color: K.blue, shape: BoxShape.circle)),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        // Which round is being worked. A twice-a-day customer is on each.
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: _C.grey100, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            for (final (sl, icon) in const [('morning', Icons.wb_twilight_rounded), ('evening', Icons.bedtime_outlined)])
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (sl != slot) _go(day, sl);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: sl == slot ? K.surface : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                      boxShadow: sl == slot ? const [BoxShadow(color: Color(0x14101828), blurRadius: 3, offset: Offset(0, 1))] : null,
                    ),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(icon, size: 16, color: sl == slot ? K.blue : K.muted),
                      const SizedBox(width: 6),
                      Text('${slotName(sl)} round', style: _m(12, FontWeight.w700, sl == slot ? K.blue : K.muted)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        // Open or closed, said in one line, and the button beside it.
        Row(children: [
          Icon(locked ? Icons.lock_outline_rounded : Icons.lock_open_rounded, size: 18, color: locked ? _C.red : _C.green600),
          const SizedBox(width: 8),
          Expanded(
            child: Text(locked ? '$dayWord is closed' : '$dayWord is open',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: _m(12, FontWeight.w700, locked ? _C.red : _C.green700)),
          ),
          if (widget.office)
            _Press(
              onTap: _lock,
              color: locked ? _C.red500 : _C.green600,
              radius: 8,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Text(locked ? 'Reopen' : 'Close day', style: _m(11.5, FontWeight.w700, Colors.white)),
              ),
            )
          else
            Text('The office closes this', style: _m(11, FontWeight.w600, K.muted)),
        ]),
        if (filters) _filterPanel(),
      ]),
    );
  }

  Widget _filterPanel() {
    final all = _round;
    final qtys = <String>{for (final s in all) litres(s.qty)}.toList()..sort((a, b) => toNum(a.split(' ').first).compareTo(toNum(b.split(' ').first)));
    String personLabel(String v) => switch (v) {
          'all' => 'Everyone',
          'none' => 'Nobody assigned',
          _ => '${staff.firstWhere((p) => '${p['id']}' == v, orElse: () => {'name': v == f.staffId ? f.staffName : 'Someone'})['name']}',
        };
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFF6F8FB), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SearchField(controller: _q, hint: 'Name, room or phone', onChanged: (_) => setState(() {})),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: _Bubble(
              label: building == 'all' ? 'All buildings' : building,
              on: building != 'all',
              onTap: () async {
                final p = await showPicker<String>(context, title: 'Building', selected: building, options: [
                  const PickOption('all', 'All buildings'),
                  for (final b in _buildings(all)) PickOption(b, b),
                ]);
                if (p != null) setState(() => building = p.value);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Bubble(
              label: personLabel(person),
              on: person != 'all',
              onTap: () async {
                final p = await showPicker<String>(context, title: 'Delivery person', selected: person, options: [
                  const PickOption('all', 'Everyone'),
                  for (final s in staff) PickOption('${s['id']}', '${s['name']}'),
                  const PickOption('none', 'Nobody assigned'),
                ]);
                if (p != null) setState(() => person = p.value);
              },
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: _Bubble(
              label: quantity == 'all' ? 'All quantities' : quantity,
              on: quantity != 'all',
              onTap: () async {
                final p = await showPicker<String>(context, title: 'Quantity', selected: quantity, options: [
                  const PickOption('all', 'All quantities'),
                  for (final q in qtys) PickOption(q, q),
                ]);
                if (p != null) setState(() => quantity = p.value);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Press(
              onTap: () => setState(() {
                _q.clear();
                building = 'all';
                person = 'all';
                quantity = 'all';
                onlyPending = false;
              }),
              color: K.surface,
              border: _C.red200,
              radius: 12,
              child: SizedBox(
                height: 40,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.close_rounded, size: 15, color: _C.red500),
                  const SizedBox(width: 4),
                  Text('Clear', style: _m(12, FontWeight.w700, _C.red500)),
                ]),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  // ---------------------------------------------------------------- how far the round has got

  Widget _progress(List<Stop> list) {
    final due = list.where((s) => s.due || s.delivered).toList();
    final done = due.where((s) => s.delivered).length;
    final total = due.length;
    final complete = total > 0 && done == total;
    final litresTotal = due.fold<num>(0, (a, s) => a + s.qty);
    final litresDone = due.where((s) => s.delivered).fold<num>(0, (a, s) => a + (s.deliveredQty ?? s.qty));
    final bottles = due.fold<int>(0, (a, s) => a + s.bottlesOut);
    final paused = (stops ?? const <Stop>[]).where((s) => s.paused && !s.delivered).length;
    final pct = total == 0 ? 0 : (done * 100 / total).round();
    final names = _buildings(due);
    final buildingsDone = names.where((g) {
      final inG = due.where((s) => _groupOf(s) == g);
      return inG.every((s) => s.delivered);
    }).length;
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '$done', style: _m(16.5, FontWeight.w800)),
                TextSpan(text: ' of ', style: _m(16.5, FontWeight.w600, _C.grey400)),
                TextSpan(text: '$total', style: _m(16.5, FontWeight.w800)),
                TextSpan(text: ' delivered', style: _m(16.5, FontWeight.w600)),
              ]),
              style: T.tabular,
            ),
          ),
          Text('$pct%', style: _m(14, FontWeight.w700, K.muted).merge(T.tabular)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: Container(
            height: 12,
            color: _C.grey100,
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: total == 0 || done == 0 ? 0 : (done / total).clamp(0.03, 1.0).toDouble(),
              heightFactor: 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                decoration: BoxDecoration(color: complete ? _C.green : K.blue, borderRadius: BorderRadius.circular(99)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: '${litres(litresDone)} out of ${litres(litresTotal)}'),
            if (complete) TextSpan(text: ', round finished', style: _m(12, FontWeight.w700, _C.green600)),
          ]),
          style: _m(12, FontWeight.w500, K.muted).merge(T.tabular),
        ),
        if (bottles > 0) ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.local_drink_outlined, size: 15, color: _C.amber700),
            const SizedBox(width: 6),
            Expanded(
              child: Text('${bottleWords(bottles)} still to collect, marked on the stops below', style: _m(12, FontWeight.w600, _C.amber700)),
            ),
          ]),
        ],
        if (paused > 0) ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.pause_circle_outline_rounded, size: 15, color: K.muted),
            const SizedBox(width: 6),
            Expanded(child: Text('$paused paused, not on this round', style: _m(12, FontWeight.w600, K.muted))),
          ]),
        ],
        if (names.length > 1) _whereTheRoundIs(due, names, buildingsDone),
      ]),
    );
  }

  bool whereOpen = false;

  /// Building by building, the order the round is walked. Pressing one
  /// narrows the stops below to it.
  Widget _whereTheRoundIs(List<Stop> due, List<String> names, int buildingsDone) {
    final open = whereOpen || building != 'all';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => whereOpen = !whereOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more_rounded, size: 16, color: _C.grey400),
                ),
                const SizedBox(width: 2),
                Text('WHERE THE ROUND IS', style: _m(10.5, FontWeight.w800, _C.grey400)),
                if (!open) Text('  ($buildingsDone/${names.length} buildings done)', style: _m(10.5, FontWeight.w600, _C.grey400)),
              ]),
            ),
          ),
          const Spacer(),
          if (building != 'all')
            GestureDetector(
              onTap: () => setState(() => building = 'all'),
              child: Text('Show every building', style: _m(11.5, FontWeight.w700, K.blue)),
            ),
        ]),
        if (open)
          for (final g in names) _buildingLine(g, due.where((s) => _groupOf(s) == g).toList()),
      ]),
    );
  }

  Widget _buildingLine(String g, List<Stop> list) {
    final done = list.where((s) => s.delivered).length;
    final finished = done == list.length;
    final chosen = building == g;
    final nobody = list.where((s) => s.staffId == null).length;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: _Press(
        onTap: () => setState(() => building = chosen ? 'all' : g),
        color: chosen ? K.brand100 : Colors.transparent,
        border: chosen ? K.brand300 : null,
        radius: 12,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(g, maxLines: 1, overflow: TextOverflow.ellipsis, style: _m(12, FontWeight.w700, K.ink2))),
              if (finished) ...[const Icon(Icons.check_circle_rounded, size: 15, color: _C.green600), const SizedBox(width: 6)],
              Text('$done/${list.length}', style: _m(11.5, FontWeight.w700, K.muted).merge(T.tabular)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: Container(
                height: 6,
                color: _C.grey100,
                alignment: AlignmentDirectional.centerStart,
                child: FractionallySizedBox(
                  widthFactor: list.isEmpty || done == 0 ? 0 : (done / list.length).clamp(0.04, 1.0).toDouble(),
                  heightFactor: 1,
                  child: Container(decoration: BoxDecoration(color: finished ? _C.green : K.blue, borderRadius: BorderRadius.circular(99))),
                ),
              ),
            ),
            if (nobody > 0) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.person_off_outlined, size: 13, color: _C.amber700),
                const SizedBox(width: 4),
                Text('$nobody with nobody assigned', style: _m(11, FontWeight.w600, _C.amber700)),
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  /// Still to go, and the milk that is: pressing it shows only those.
  List<Widget> _stillToGo(List<Stop> list) {
    final due = list.where((s) => s.due || s.delivered).toList();
    final pending = due.where((s) => !s.delivered).toList();
    final done = due.length - pending.length;
    if ((pending.isEmpty || done == 0) && !onlyPending) return const [];
    final left = pending.fold<num>(0, (a, s) => a + s.qty);
    final on = onlyPending;
    return [
      const SizedBox(height: 12),
      _Press(
        onTap: () => setState(() => onlyPending = !onlyPending),
        color: on ? K.blue : K.surface,
        border: on ? K.blue : const Color(0xFFEDF1F7),
        radius: 16,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 54),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Icon(on ? Icons.filter_alt_rounded : Icons.pending_actions_rounded, size: 20, color: on ? Colors.white : _C.grey400),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('${pending.length} still to go', style: _m(14, FontWeight.w700, on ? Colors.white : K.ink)),
                  Text('${litres(left)} left to carry', style: _m(11.5, FontWeight.w500, on ? const Color(0xCCFFFFFF) : K.muted)),
                ]),
              ),
              Text(on ? 'Showing these' : 'Show only these', style: _m(11.5, FontWeight.w700, on ? Colors.white : K.blue)),
            ]),
          ),
        ),
      ),
    ];
  }

  /// What was reported at the doors on this round.
  List<Widget> _problems(List<Stop> list) {
    final r = list.where((s) => s.notes.isNotEmpty).toList();
    if (r.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(color: _C.amber50, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.amber200)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.report_problem_outlined, size: 16, color: _C.amber800),
            const SizedBox(width: 6),
            Text('${r.length} ${r.length == 1 ? 'problem' : 'problems'} reported on this round', style: _m(13.5, FontWeight.w700, _C.amber800)),
          ]),
          const SizedBox(height: 6),
          for (final s in r.take(4))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text.rich(TextSpan(children: [
                TextSpan(text: '${s.name}: ', style: _m(12, FontWeight.w700, _C.amber700)),
                TextSpan(text: s.notes, style: _m(12, FontWeight.w500, _C.amber700)),
              ])),
            ),
          if (r.length > 4) Text('and ${r.length - 4} more, shown on their rows below', style: _m(12, FontWeight.w500, _C.amber700)),
        ]),
      ),
    ];
  }

  Widget _nobody(List<Stop> list) {
    final other = slot == 'morning' ? 'evening' : 'morning';
    final paused = list.where((s) => s.paused).length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(children: [
        Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(color: K.brand100, shape: BoxShape.circle),
          child: const Icon(Icons.schedule_rounded, color: K.blue, size: 26),
        ),
        const SizedBox(height: 12),
        Text('Nobody is on the $slot round', style: _m(15, FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          paused > 0 ? '$paused paused on ${dateLabel(day)}, and nobody else takes milk on this round.' : 'Nobody takes milk on this round on ${dateLabel(day)}.',
          textAlign: TextAlign.center,
          style: _m(12.5, FontWeight.w500, K.muted),
        ),
        const SizedBox(height: 14),
        KButton(label: 'Switch to the $other round', icon: Icons.swap_horiz_rounded, small: true, onPressed: () => _go(day, other)),
      ]),
    );
  }

  // ---------------------------------------------------------------- the stops, building by building

  List<Widget> _groups(List<Stop> shown) {
    final names = _buildings(_round);
    final groups = <String, List<Stop>>{};
    for (final g in _buildings(shown)) {
      groups[g] = shown.where((s) => _groupOf(s) == g).toList();
    }
    // In the office every building starts shut: on opening, the question is
    // how far the round has got and which building next. Delivery staff, and
    // anyone narrowing the list, see the stops.
    final allOpen = !widget.office || _narrowed;
    return [
      for (final e in groups.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _Building(
            title: e.key,
            tone: _tone(e.key, names),
            icon: e.key == _noBuilding ? Icons.near_me_outlined : Icons.apartment_rounded,
            stops: e.value,
            open: allOpen || opened.contains(e.key),
            all: showAll.contains(e.key),
            onToggle: () => setState(() => opened.contains(e.key) ? opened.remove(e.key) : opened.add(e.key)),
            onAll: () => setState(() => showAll.contains(e.key) ? showAll.remove(e.key) : showAll.add(e.key)),
            row: (s, i) => _StopRow(
              index: i,
              stop: s,
              locked: locked,
              open: details.contains(s.customerId),
              office: widget.office,
              canPick: f.can('customers'),
              onOpen: () => setState(() => details.contains(s.customerId) ? details.remove(s.customerId) : details.add(s.customerId)),
              onTick: () => _tick(s),
              onBottle: () => _bottle(s),
              onOldBottle: (b) => _oldBottle(s, b),
              onNote: (t) => _note(s, t),
              onLitres: (q) => _litres(s, q),
              onPerson: () => _person(s),
            ),
          ),
        ),
    ];
  }
}

/// 1 bottle, 6 bottles.
String bottleWords(int n) => n == 1 ? '1 bottle' : '$n bottles';

// ---------------------------------------------------------------- pieces

/// A rounded surface that answers a press.
class _Press extends StatelessWidget {
  const _Press({required this.onTap, required this.child, this.color = K.surface, this.border, this.radius = 12});
  final VoidCallback? onTap;
  final Widget child;
  final Color color;
  final Color? border;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: border == null ? BorderSide.none : BorderSide(color: border!),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: child),
    );
  }
}

/// A choice in the filter: shows what is picked and opens the list.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Press(
      onTap: onTap,
      color: on ? K.brand100 : K.surface,
      border: on ? K.brand300 : K.border,
      radius: 12,
      child: SizedBox(
        height: 40,
        child: Row(children: [
          const SizedBox(width: 12),
          Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _m(12, FontWeight.w600, on ? K.brand600 : K.ink2))),
          Icon(Icons.expand_more_rounded, size: 18, color: on ? K.brand600 : K.muted),
          const SizedBox(width: 8),
        ]),
      ),
    );
  }
}

/// One building on the round: its tinted header with how many are done, then
/// the first five stops and the rest a press away.
class _Building extends StatelessWidget {
  const _Building({
    required this.title,
    required this.tone,
    required this.icon,
    required this.stops,
    required this.open,
    required this.all,
    required this.onToggle,
    required this.onAll,
    required this.row,
  });
  final String title;
  final _Tone tone;
  final IconData icon;
  final List<Stop> stops;
  final bool open;
  final bool all;
  final VoidCallback onToggle;
  final VoidCallback onAll;
  final Widget Function(Stop s, int index) row;

  static const preview = 5;

  @override
  Widget build(BuildContext context) {
    final done = stops.where((s) => s.delivered).length;
    final shown = all ? stops : stops.take(preview).toList();
    return Container(
      decoration: BoxDecoration(
        color: K.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Color(0x0A101828), blurRadius: 2, offset: Offset(0, 1)),
          BoxShadow(color: Color(0x0F101828), blurRadius: 12, spreadRadius: -2, offset: Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            onTap: onToggle,
            child: Container(
              color: tone.bg,
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
              child: Row(children: [
                Icon(icon, size: 20, color: tone.fg),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(title.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: _m(14, FontWeight.w800, tone.fg)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(color: tone.badge, borderRadius: BorderRadius.circular(99)),
                  child: Text('$done/${stops.length}', style: _m(12, FontWeight.w700, tone.fg).merge(T.tabular)),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more_rounded, size: 22, color: _C.grey400),
                ),
              ]),
            ),
          ),
          if (open) ...[
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) const Divider(height: 1, thickness: 1, color: _C.line),
              row(shown[i], i + 1),
            ],
            if (stops.length > preview)
              InkWell(
                onTap: onAll,
                child: Container(
                  color: const Color(0xFFF3F8FF),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(all ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 16, color: K.blue),
                    const SizedBox(width: 4),
                    Text(all ? 'Show less' : 'View all ${stops.length} customers', style: _m(12, FontWeight.w600, K.blue)),
                  ]),
                ),
              ),
          ],
        ]),
      ),
    );
  }
}

/// One stop: the tick and the bottle always in the same place on every row,
/// so a thumb can run down the round without aiming. The row opens what is
/// needed now and then: the phone, the litres, who takes it, old bottles
/// and a problem at the door.
class _StopRow extends StatefulWidget {
  const _StopRow({
    required this.index,
    required this.stop,
    required this.locked,
    required this.open,
    required this.office,
    required this.canPick,
    required this.onOpen,
    required this.onTick,
    required this.onBottle,
    required this.onOldBottle,
    required this.onNote,
    required this.onLitres,
    required this.onPerson,
  });
  final int index;
  final Stop stop;
  final bool locked;
  final bool open;
  final bool office;
  final bool canPick;
  final VoidCallback onOpen;
  final VoidCallback onTick;
  final VoidCallback onBottle;
  final ValueChanged<Map<String, dynamic>> onOldBottle;
  final Future<void> Function(String) onNote;
  final ValueChanged<num> onLitres;
  final VoidCallback onPerson;

  @override
  State<_StopRow> createState() => _StopRowState();
}

class _StopRowState extends State<_StopRow> {
  bool noteOpen = false;
  bool saving = false;
  late final note = TextEditingController(text: widget.stop.notes);
  late final qty = TextEditingController(text: _q(widget.stop));

  static String _q(Stop s) {
    final v = s.deliveredQty ?? s.qty;
    return v == v.roundToDouble() ? '${v.toInt()}' : '$v';
  }

  @override
  void dispose() {
    note.dispose();
    qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stop;
    final flagged = s.behind || s.notes.isNotEmpty || s.staffId == null;
    final time = s.delivered && s.deliveredAt != null ? clock(s.deliveredAt!) : null;
    final info = <String>[
      s.spot.isEmpty ? 'No room' : s.spot,
      litres(s.qty),
      if (s.staffName.isNotEmpty) s.staffName,
    ];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: s.delivered ? _C.greenRow : K.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: InkWell(
                onTap: widget.onOpen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                  child: Row(children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: s.delivered ? _C.green100 : _C.grey100, shape: BoxShape.circle),
                      child: s.delivered
                          ? const Icon(Icons.check_rounded, size: 15, color: _C.green700)
                          : Text('${widget.index}', style: _m(11, FontWeight.w700, K.muted)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Row(children: [
                          Flexible(
                            child: Text(s.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: _m(14, FontWeight.w700, s.delivered ? _C.green800 : K.ink)),
                          ),
                          if (s.temporary) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(color: const Color(0xFFE0F2FE), borderRadius: BorderRadius.circular(99)),
                              child: Text('Today only', style: _m(10, FontWeight.w700, const Color(0xFF0369A1))),
                            ),
                          ],
                          if (flagged) ...[const SizedBox(width: 5), const Icon(Icons.error_outline_rounded, size: 15, color: _C.amber)],
                          if (s.waiting) ...[const SizedBox(width: 5), const Icon(Icons.cloud_off_rounded, size: 14, color: K.warn)],
                        ]),
                        const SizedBox(height: 2),
                        // Where it is, how much, who takes it, and when it went.
                        Row(children: [
                          Flexible(
                            child: Text(info.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: _m(11.5, FontWeight.w500, K.muted)),
                          ),
                          if (time != null) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.schedule_rounded, size: 13, color: _C.green700),
                            const SizedBox(width: 2),
                            Text(time, style: _m(11.5, FontWeight.w700, _C.green700)),
                          ],
                        ]),
                        if (flagged)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(spacing: 10, runSpacing: 2, children: [
                              if (s.behind) _flag(Icons.local_drink_outlined, '${bottleWords(s.bottlesOut)} to collect'),
                              if (s.staffId == null) _flag(Icons.person_off_outlined, 'Nobody assigned'),
                              if (s.notes.isNotEmpty) _flag(Icons.report_problem_outlined, s.notes),
                            ]),
                          ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
            _side(
              on: s.delivered,
              onColor: _C.green,
              offFg: _C.green700,
              icon: s.delivered ? Icons.check_circle_outline_rounded : Icons.radio_button_unchecked_rounded,
              label: s.delivered ? 'Done' : 'Deliver',
              enabled: !widget.locked && !(s.paused && !s.delivered),
              semantics: s.delivered ? 'Undo delivery for ${s.name}' : 'Mark ${s.name} delivered',
              onTap: widget.onTick,
            ),
            _side(
              on: s.returned,
              onColor: _C.back,
              offFg: _C.back,
              icon: s.returned ? Icons.local_drink_outlined : Icons.no_drinks_outlined,
              label: s.returned ? 'Back' : 'Collect',
              enabled: !widget.locked && s.delivered && s.hasBottles,
              semantics: s.returned ? 'Undo today\'s bottle for ${s.name}' : 'Today\'s bottle came back from ${s.name}',
              onTap: widget.onBottle,
            ),
          ]),
        ),
        if (widget.open) _details(s),
      ]),
    );
  }

  Widget _flag(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: _C.amber700),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: _m(11.5, FontWeight.w600, _C.amber700)),
        ),
      ]);

  Widget _side({
    required bool on,
    required Color onColor,
    required Color offFg,
    required IconData icon,
    required String label,
    required bool enabled,
    required String semantics,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: semantics,
      child: Opacity(
        opacity: enabled || on ? 1 : 0.35,
        child: Material(
          color: on ? onColor : Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Container(
              width: 56,
              decoration: on ? null : const BoxDecoration(border: BorderDirectional(start: BorderSide(color: _C.line))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 22, color: on ? Colors.white : offFg),
                const SizedBox(height: 2),
                Text(label, style: _m(10, FontWeight.w700, on ? Colors.white : offFg)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _details(Stop s) {
    final locked = widget.locked;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: _C.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (s.phone.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: InkWell(
              onTap: () => launchUrl(Uri.parse('tel:+${s.phone}')),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.call_outlined, size: 16, color: K.blue),
                  const SizedBox(width: 6),
                  Text(prettyPhone(s.phone), style: _m(14, FontWeight.w600, K.blue)),
                ]),
              ),
            ),
          ),
        const SizedBox(height: 8),
        _line(s.room.isNotEmpty || s.address.isEmpty ? Icons.door_back_door_outlined : Icons.location_on_outlined,
            s.room.isNotEmpty ? 'Room: ${[s.building, s.room].where((x) => x.isNotEmpty).join(', ')}' : 'Address: ${s.address.isEmpty ? '-' : s.address}'),
        const SizedBox(height: 10),
        // The milk: the office corrects what went, once it has gone.
        Row(children: [
          const Icon(Icons.water_drop_outlined, size: 16, color: K.sky),
          const SizedBox(width: 8),
          Text('Milk:', style: _m(13.5, FontWeight.w500, K.muted)),
          const SizedBox(width: 8),
          if (widget.office && s.delivered && !locked) ...[
            SizedBox(
              width: 70,
              height: 36,
              child: TextField(
                controller: qty,
                textAlign: TextAlign.center,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: _m(13.5, FontWeight.w700),
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0xFFF6F8FB),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: K.border)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: K.border)),
                ),
                onSubmitted: (v) {
                  final q = num.tryParse(v.trim());
                  if (q != null && q >= 0) widget.onLitres(q);
                },
                onTapOutside: (_) {
                  FocusManager.instance.primaryFocus?.unfocus();
                  final q = num.tryParse(qty.text.trim());
                  if (q != null && q >= 0) widget.onLitres(q);
                },
              ),
            ),
            const SizedBox(width: 6),
            Text('L', style: _m(13.5, FontWeight.w600, K.ink2)),
          ] else
            Text(litres(s.deliveredQty ?? s.qty), style: _m(13.5, FontWeight.w700)),
          const SizedBox(width: 10),
          Expanded(child: Text(vesselsText(s.vessels), maxLines: 1, overflow: TextOverflow.ellipsis, style: _m(12, FontWeight.w500, K.muted))),
        ]),
        const SizedBox(height: 10),
        // Who takes it.
        Row(children: [
          const Icon(Icons.person_outline_rounded, size: 16, color: K.muted),
          const SizedBox(width: 8),
          Expanded(
            child: widget.canPick && !locked
                ? _Bubble(label: s.staffName.isEmpty ? 'Nobody yet' : s.staffName, on: false, onTap: widget.onPerson)
                : Text(s.staffName.isEmpty ? 'Nobody assigned' : s.staffName, style: _m(13.5, FontWeight.w600, K.ink2)),
          ),
        ]),
        if (s.temporary) ...[
          const SizedBox(height: 10),
          _line(Icons.swap_horiz_rounded, 'Today only: ${litres(s.qty)}, usually ${litres(s.standing)}'),
        ],
        if (s.bottleDays.isNotEmpty) ...[const SizedBox(height: 12), _bottles(s)],
        const SizedBox(height: 12),
        _problem(s),
        if (s.hasBottles) ...[
          const SizedBox(height: 12),
          _Press(
            onTap: locked || !s.delivered ? null : widget.onBottle,
            color: s.returned ? _C.green : K.surface,
            border: _C.green,
            radius: 12,
            child: Opacity(
              opacity: locked || !s.delivered ? 0.5 : 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.move_to_inbox_outlined, size: 18, color: s.returned ? Colors.white : _C.green600),
                  const SizedBox(width: 6),
                  Text(s.returned ? 'Today\'s bottle returned' : 'Today\'s bottle returned?', style: _m(13.5, FontWeight.w700, s.returned ? Colors.white : _C.green600)),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _line(IconData icon, String text) => Row(children: [
        Icon(icon, size: 16, color: K.muted),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: _m(13.5, FontWeight.w600, K.ink2))),
      ]);

  /// Bottles still out from earlier rounds: each round closed on purpose.
  Widget _bottles(Stop s) {
    final behind = s.behind;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: behind ? _C.amber50 : const Color(0xFFF6F8FB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: behind ? _C.amber200 : K.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.local_drink_outlined, size: 15, color: behind ? _C.amber800 : K.ink2),
          const SizedBox(width: 6),
          Text('${bottleWords(s.bottlesOut)} still out', style: _m(12.5, FontWeight.w700, behind ? _C.amber800 : K.ink2)),
        ]),
        const SizedBox(height: 4),
        Text('Tap a round once its bottles come back.', style: _m(11.5, FontWeight.w500, K.muted)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final b in s.bottleDays)
            _Press(
              onTap: widget.locked ? null : () => widget.onOldBottle(b),
              color: K.surface,
              border: behind ? _C.amber200 : K.border,
              radius: 8,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_outline_rounded, size: 15, color: behind ? _C.amber800 : K.ink2),
                  const SizedBox(width: 6),
                  Text(_roundShort(b), style: _m(12, FontWeight.w600, behind ? _C.amber800 : K.ink2)),
                ]),
              ),
            ),
        ]),
      ]),
    );
  }

  static String _roundShort(Map<String, dynamic> b) {
    final d = parseDay(b['day']);
    final when = d == null ? '${b['day']}' : '${d.day} ${kMonthsShort[d.month - 1]}';
    final n = toNum(b['bottles']).toInt();
    return '$when ${b['slot'] == 'evening' ? 'evening' : 'morning'}${n > 1 ? ', $n' : ''}';
  }

  /// What happened at the door: folded away, open when something is written.
  Widget _problem(Stop s) {
    final locked = widget.locked;
    if (!noteOpen && s.notes.isEmpty) {
      return _Dashed(
        onTap: locked ? null : () => setState(() => noteOpen = true),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.report_problem_outlined, size: 17, color: K.muted),
          const SizedBox(width: 6),
          Text('Report a problem', style: _m(12.5, FontWeight.w600, K.muted)),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: _C.amber50, borderRadius: BorderRadius.circular(12), border: Border.all(color: _C.amber200)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('What happened at ${s.name}\'s door?', style: _m(11.5, FontWeight.w700, _C.amber800)),
        const SizedBox(height: 6),
        TextField(
          controller: note,
          enabled: !locked,
          maxLines: 2,
          maxLength: 300,
          style: _m(13.5, FontWeight.w500),
          decoration: InputDecoration(
            hintText: 'Gate locked, left with the watchman',
            counterText: '',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _C.amber200)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _C.amber200)),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: _Press(
              onTap: locked || saving
                  ? null
                  : () async {
                      if (s.notes.isNotEmpty) {
                        setState(() => saving = true);
                        await widget.onNote('');
                        note.clear();
                      }
                      if (mounted) setState(() {
                        saving = false;
                        noteOpen = false;
                      });
                    },
              color: K.surface,
              border: K.border,
              radius: 10,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(child: Text(s.notes.isNotEmpty ? 'Clear it' : 'Cancel', style: _m(12.5, FontWeight.w700, K.ink2))),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Press(
              onTap: locked || saving
                  ? null
                  : () async {
                      setState(() => saving = true);
                      await widget.onNote(note.text.trim());
                      if (mounted) setState(() {
                        saving = false;
                        noteOpen = false;
                      });
                    },
              color: _C.amber,
              radius: 10,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(child: Text(saving ? 'Saving' : 'Save', style: _m(12.5, FontWeight.w700, Colors.white))),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// A dashed outline button, for the quiet "Report a problem".
class _Dashed extends StatelessWidget {
  const _Dashed({required this.onTap, required this.child});
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: CustomPaint(
        painter: _DashPainter(),
        child: SizedBox(height: 42, child: child),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = K.border2
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)));
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 9) {
        canvas.drawPath(m.extractPath(d, d + 5 > m.length ? m.length : d + 5), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
