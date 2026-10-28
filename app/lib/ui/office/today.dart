import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';
import 'round.dart';

/// The farm's day at a glance, like Kuree's list of chits: a card for each
/// round with how far it has got, then the packing, the money still to
/// collect and any requests from customers. Each card opens its page.
class TodayPage extends StatefulWidget {
  const TodayPage({super.key, required this.farm, required this.open});
  final FarmRole farm;
  final void Function(String key) open;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  Map<String, dynamic>? rounds;
  Map<String, dynamic>? packing;
  Map<String, dynamic>? money;
  int requests = 0;
  String? error;
  bool loaded = false;

  FarmRole get f => widget.farm;
  bool get _rounds => f.can('deliveries') || f.canDeliver;

  /// Packing is for today until noon, then for tomorrow, like the Packing page.
  DateTime get _packDay => addDays(f.today, DateTime.now().hour >= 12 ? 1 : 0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait<Object?>([
        _rounds ? Api.instance.rpc('day_summary', {'day': isoDay(f.today)}) : Future.value(null),
        f.can('preparation') ? Api.instance.rpc('preparation', {'day': isoDay(_packDay)}) : Future.value(null),
        f.seesMoney ? Api.instance.rpc('money_summary') : Future.value(null),
        f.can('pauses')
            ? Api.instance.select('temporary_requests', columns: 'id', where: {'status': 'eq.pending'})
            : Future.value(const <Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      setState(() {
        rounds = r[0] is Map ? Map<String, dynamic>.from(r[0] as Map) : null;
        packing = r[1] is Map ? Map<String, dynamic>.from(r[1] as Map) : null;
        money = r[2] is Map ? Map<String, dynamic>.from(r[2] as Map) : null;
        requests = (r[3] as List? ?? const []).length;
        error = null;
        loaded = true;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _openRound(String slot) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RoundView(farm: f, office: f.can('deliveries'), day: f.today, slot: slot),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 980;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: Sp.xl,
        title: wide
            ? const Text('Today')
            : Row(children: [
                const DaireeIcon(size: 30),
                const SizedBox(width: 10),
                Text('Dairee', style: T.h2.copyWith(fontSize: 21)),
              ]),
      ),
      body: !loaded && error != null
          ? LoadFailed(message: error!, onRetry: _load)
          : !loaded
              ? const Loading()
              : PageBody(onRefresh: _load, bottom: 40, children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 4, 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small.copyWith(color: K.blue, fontWeight: FontWeight.w800)),
                      Row(children: [
                        const Expanded(child: Text('Today', style: T.h1)),
                        Pill(dayLabel(f.today), color: K.surface2, fg: K.ink2),
                      ]),
                    ]),
                  ),
                  if (_rounds)
                    for (final slot in const ['morning', 'evening']) ...[
                      _RoundCard(
                        slot: slot,
                        now: slot == (DateTime.now().hour < 13 ? 'morning' : 'evening'),
                        s: Map<String, dynamic>.from((rounds?['slots'] as Map?)?[slot] as Map? ?? const {}),
                        onTap: () => _openRound(slot),
                      ),
                      const SizedBox(height: Sp.md + 2),
                    ],
                  if (packing != null) ...[
                    _packingCard(),
                    const SizedBox(height: Sp.md + 2),
                  ],
                  if (money != null) ...[
                    _moneyCard(),
                    const SizedBox(height: Sp.md + 2),
                  ],
                  if (requests > 0) ...[
                    KCard(
                      onTap: () => widget.open('pauses'),
                      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 12, 14),
                      child: Row(children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(color: K.warnBg, shape: BoxShape.circle),
                          child: const Icon(Icons.mark_email_unread_outlined, size: 20, color: K.warn),
                        ),
                        const SizedBox(width: Sp.md),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(requests == 1 ? '1 request from a customer' : '$requests requests from customers', style: T.bodyStrong),
                            const Text('Changes for a day, waiting for a yes or no', style: T.small),
                          ]),
                        ),
                        const Icon(Icons.chevron_right_rounded, color: K.border2),
                      ]),
                    ),
                    const SizedBox(height: Sp.md + 2),
                  ],
                ]),
    );
  }

  Widget _packingCard() {
    final slots = (packing!['slots'] as Map?) ?? const {};
    Map<String, dynamic> of(String s) => Map<String, dynamic>.from(slots[s] as Map? ?? const {});
    final m = of('morning'), e = of('evening');
    // Every vessel to fill across both rounds, biggest count first.
    final counts = <String, int>{};
    for (final x in [m, e]) {
      for (final v in (x['vessels'] as List? ?? const []).whereType<Map>()) {
        counts['${v['name']}'] = (counts['${v['name']}'] ?? 0) + toNum(v['count']).toInt();
      }
    }
    final vessels = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = toNum(m['litres']) + toNum(e['litres']);
    final noVessel = toNum(m['unassigned_litres']) + toNum(e['unassigned_litres']);
    return KCard(
      onTap: () => widget.open('preparation'),
      padding: const EdgeInsetsDirectional.fromSTEB(18, 16, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Packing for ${dayInSentence(_packDay, f.today)}', style: T.h2),
        const SizedBox(height: Sp.xs),
        Text('Morning ${litres(m['litres'])}, evening ${litres(e['litres'])}', style: T.small),
        const SizedBox(height: Sp.md + 2),
        Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 6, children: [
          Text(litres(total), style: T.h2.merge(T.tabular)),
          Padding(padding: const EdgeInsets.only(bottom: 3), child: Text('to fill for ${(toNum(m['customers']) + toNum(e['customers'])).toInt()} customers', style: T.small)),
        ]),
        const SizedBox(height: Sp.md),
        Row(children: [
          Icon(noVessel > 0 ? Icons.error_outline_rounded : Icons.inventory_2_outlined, size: 17, color: noVessel > 0 ? K.bad : K.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              noVessel > 0
                  ? '${litres(noVessel)} has no vessel set'
                  : vessels.isEmpty
                      ? 'Nothing to fill'
                      : vessels.map((v) => '${v.value} x ${v.key}').join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.small.copyWith(color: noVessel > 0 ? K.bad : K.muted, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _moneyCard() {
    final m = money!;
    final owed = toNum(m['outstanding']);
    final unpaid = toNum(m['unpaid_bills']).toInt();
    return KCard(
      onTap: () => widget.open('payments'),
      padding: const EdgeInsetsDirectional.fromSTEB(18, 16, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('To collect', style: T.h2)),
          if (owed <= 0) const Pill('All paid', icon: Icons.check_rounded),
        ]),
        const SizedBox(height: Sp.xs),
        Text(unpaid == 1 ? '1 unpaid bill' : '$unpaid unpaid bills', style: T.small),
        const SizedBox(height: Sp.md + 2),
        Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 6, children: [
          Text(f.money(owed), style: T.h2.merge(T.tabular)),
          Padding(padding: const EdgeInsets.only(bottom: 3), child: Text('still owed', style: T.small)),
        ]),
        const SizedBox(height: Sp.md),
        Row(children: [
          const Icon(Icons.payments_outlined, size: 17, color: K.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${f.money(toNum(m['collected']))} collected on bills so far',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small.copyWith(color: K.muted, fontWeight: FontWeight.w700)),
          ),
        ]),
      ]),
    );
  }
}

/// One round today: how many stops are done, the milk out, and what is left.
class _RoundCard extends StatelessWidget {
  const _RoundCard({required this.slot, required this.now, required this.s, required this.onTap});
  final String slot;
  final bool now;
  final Map<String, dynamic> s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final stops = toNum(s['stops']).toInt();
    final done = toNum(s['delivered']).toInt();
    final paused = toNum(s['paused']).toInt();
    final bottles = toNum(s['bottles_out']).toInt();
    final finished = stops > 0 && done >= stops;
    final String note;
    if (stops == 0) {
      note = 'Nobody on this round today';
    } else if (finished) {
      note = bottles > 0 ? 'Every stop delivered, $bottles ${bottles == 1 ? 'bottle' : 'bottles'} to collect' : 'Every stop delivered';
    } else {
      note = '${stops - done} ${stops - done == 1 ? 'stop' : 'stops'} to go${bottles > 0 ? ', $bottles ${bottles == 1 ? 'bottle' : 'bottles'} to collect' : ''}';
    }
    return KCard(
      onTap: onTap,
      padding: const EdgeInsetsDirectional.fromSTEB(18, 16, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (now && !finished) Text('On now', style: T.small.copyWith(color: K.blue, fontWeight: FontWeight.w800)),
              Text('${slotName(slot)} round', style: T.h2),
            ]),
          ),
          if (finished) ...[const SizedBox(width: Sp.sm), const Pill('Done', icon: Icons.check_rounded)],
        ]),
        const SizedBox(height: Sp.xs),
        Text(paused > 0 ? '$stops stops, $paused paused' : '$stops stops', style: T.small),
        const SizedBox(height: Sp.md + 2),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 6, children: [
              Text(litres(s['litres_delivered']), style: T.h2.merge(T.tabular)),
              Padding(padding: const EdgeInsets.only(bottom: 3), child: Text('of ${litres(s['litres'])}', style: T.small)),
            ]),
          ),
          const SizedBox(width: Sp.sm),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text('$done of $stops delivered', style: T.small.copyWith(color: K.ink2, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: Sp.sm),
        ProgressLine(stops == 0 ? 0 : done / stops, color: K.sky, track: K.surface2),
        const SizedBox(height: Sp.md),
        Row(children: [
          Icon(finished ? Icons.check_circle_outline_rounded : Icons.schedule_rounded, size: 17, color: finished ? K.blue : K.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(note,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small.copyWith(color: finished ? K.blue : K.muted, fontWeight: FontWeight.w700)),
          ),
        ]),
      ]),
    );
  }
}
