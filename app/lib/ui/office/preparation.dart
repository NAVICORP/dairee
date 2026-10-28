import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';

/// What a day needs packed: vessels per round and per building. The screen
/// the farm works from at five in the morning.
class PreparationPage extends StatefulWidget {
  const PreparationPage({super.key, required this.farm});
  final FarmRole farm;

  @override
  State<PreparationPage> createState() => _PreparationPageState();
}

class _PreparationPageState extends State<PreparationPage> {
  late DateTime day = addDays(widget.farm.today, DateTime.now().hour >= 12 ? 1 : 0);
  String slot = 'morning';
  Map<String, dynamic>? data;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = day;
    try {
      final r = await Api.instance.rpc('preparation', {'day': isoDay(d)});
      if (!mounted || d != day) return;
      setState(() {
        data = Map<String, dynamic>.from(r as Map);
        error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slots = data?['slots'] as Map?;
    final s = slots == null ? null : Map<String, dynamic>.from(slots[slot] as Map? ?? const {});
    return Scaffold(
      appBar: AppBar(title: const Text('Packing')),
      body: PageBody(onRefresh: _load, children: [
        DayStrip(
          day: day,
          today: widget.farm.today,
          onChanged: (d) {
            setState(() {
              day = d;
              data = null;
            });
            _load();
          },
        ),
        const SizedBox(height: Sp.sm),
        KSegmented<String>(expand: true, items: const [('morning', 'Morning'), ('evening', 'Evening')], value: slot, onChanged: (v) => setState(() => slot = v)),
        const SizedBox(height: Sp.md),
        if (error != null && data == null)
          LoadFailed(message: error!, onRetry: _load)
        else if (s == null)
          const Padding(padding: EdgeInsets.all(40), child: Loading())
        else ...[
          HeroCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${slotName(slot)} round, ${relativeDay(day, widget.farm.today).toLowerCase()}', style: T.small.copyWith(color: K.heroText)),
              const SizedBox(height: 6),
              Text(litres(s['litres']), style: T.amount),
              const SizedBox(height: 12),
              Wrap(spacing: 22, runSpacing: 10, children: [
                Stat('${s['customers']}', 'Customers', dark: true),
                Stat('${s['paused']}', 'Paused', dark: true),
                Stat('${s['temporary']}', 'Changed for the day', dark: true),
              ]),
            ]),
          ),
          const SectionTitle('Vessels to fill'),
          _vessels(s['vessels'] as List? ?? const []),
          if (toNum(s['unassigned_litres']) > 0) ...[
            const SectionTitle('Milk with no vessel'),
            Notice('${litres(s['unassigned_litres'])} has no vessel set. Give these customers their vessels on the Customers page.'),
            const SizedBox(height: Sp.sm),
            KGroup(children: [
              for (final u in (s['unassigned'] as List? ?? const []).whereType<Map>())
                KRow(title: '${u['name']}', sub: '${u['building'] ?? ''}', trailing: Text(litres(u['litres']), style: T.bodyStrong)),
            ]),
          ],
          const SectionTitle('By building'),
          for (final b in (s['buildings'] as List? ?? const []).whereType<Map>())
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.sm),
              child: KCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${b['building']}'.isEmpty ? 'No building' : '${b['building']}', style: T.bodyStrong)),
                    Text('${litres(b['litres'])}, ${b['customers']} ${toNum(b['customers']) == 1 ? 'customer' : 'customers'}', style: T.small),
                  ]),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final v in (b['vessels'] as List? ?? const []).whereType<Map>()) Pill('${v['count']} x ${v['name']}'),
                    if ((b['vessels'] as List? ?? const []).isEmpty) const Pill.grey('No vessels set'),
                  ]),
                ]),
              ),
            ),
          if ((s['buildings'] as List? ?? const []).isEmpty) const EmptyState(icon: Icons.inventory_2_outlined, text: 'Nothing to pack for this round.'),
        ],
      ]),
    );
  }

  Widget _vessels(List list) {
    if (list.isEmpty) return const KCard(child: Text('No vessels to fill.', style: T.small));
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 560 ? 3 : 2;
      final w = (c.maxWidth - (cols - 1) * Sp.sm) / cols;
      return Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
        for (final v in list.whereType<Map>())
          SizedBox(
            width: w,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(color: K.surface, borderRadius: BorderRadius.circular(K.rMd), border: Border.all(color: K.border)),
              child: Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: K.brand100, borderRadius: BorderRadius.circular(11)),
                  child: Icon(v['category'] == 'can' ? Icons.water_drop_outlined : Icons.local_drink_outlined, size: 19, color: K.blue),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${v['count']}', style: T.h2.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    Text('${v['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
                  ]),
                ),
              ]),
            ),
          ),
      ]);
    });
  }
}
