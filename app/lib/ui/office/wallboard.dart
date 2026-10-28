import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';

/// For a screen on the office wall: today's rounds, large, refreshing by
/// itself every half minute. Nothing to press.
class WallBoard extends StatefulWidget {
  const WallBoard({super.key, required this.farm});
  final FarmRole farm;

  @override
  State<WallBoard> createState() => _WallBoardState();
}

class _WallBoardState extends State<WallBoard> {
  Map<String, dynamic>? today;
  Map<String, dynamic>? prep;
  DateTime? at;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.rpc('day_summary', {'day': isoDay(widget.farm.today)});
      final p = await Api.instance.rpc('preparation', {'day': isoDay(addDays(widget.farm.today, 1))});
      if (!mounted) return;
      setState(() {
        today = Map<String, dynamic>.from(d as Map);
        prep = Map<String, dynamic>.from(p as Map);
        at = DateTime.now();
      });
    } on ApiError {
      // The wall keeps the last picture and tries again in half a minute.
    }
  }

  @override
  Widget build(BuildContext context) {
    final slots = (today?['slots'] as Map?) ?? const {};
    return Scaffold(
      backgroundColor: K.deep,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: today == null
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: Text(widget.farm.name, style: T.display.copyWith(color: Colors.white, fontSize: 34))),
                    Text(at == null ? '' : 'Updated ${clock(at!)}', style: T.body.copyWith(color: K.heroText)),
                    const SizedBox(width: 8),
                    IconButton(onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.close_rounded, color: Color(0x66FFFFFF))),
                  ]),
                  Text(dateLabel(widget.farm.today), style: T.h2.copyWith(color: K.heroText)),
                  const SizedBox(height: 24),
                  Expanded(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final s in ['morning', 'evening']) ...[
                        Expanded(child: _round(s, Map<String, dynamic>.from(slots[s] as Map? ?? const {}))),
                        if (s == 'morning') const SizedBox(width: 20),
                      ],
                    ]),
                  ),
                  const SizedBox(height: 20),
                  _tomorrow(),
                ]),
        ),
      ),
    );
  }

  Widget _round(String slot, Map<String, dynamic> s) {
    final stops = toNum(s['stops']).toInt();
    final done = toNum(s['delivered']).toInt();
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(28)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${slotName(slot)} round', style: T.h1.copyWith(color: K.heroText)),
        const Spacer(),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('$done / $stops', style: T.amount.copyWith(fontSize: 96)),
        ),
        Text('delivered', style: T.h2.copyWith(color: K.heroText)),
        const SizedBox(height: 18),
        ProgressLine(stops == 0 ? 0 : done / stops, height: 14),
        const Spacer(),
        Wrap(spacing: 36, runSpacing: 12, children: [
          _big(litres(s['litres_delivered']), 'out of ${litres(s['litres'])}'),
          _big('${s['bottles_out']}', 'bottles to collect'),
          _big('${s['paused']}', 'paused'),
        ]),
      ]),
    );
  }

  Widget _big(String v, String label) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(v, style: T.amount.copyWith(fontSize: 34)),
        Text(label, style: T.body.copyWith(color: K.heroText)),
      ]);

  Widget _tomorrow() {
    final slots = (prep?['slots'] as Map?) ?? const {};
    String line(String s) {
      final m = Map<String, dynamic>.from(slots[s] as Map? ?? const {});
      final v = (m['vessels'] as List? ?? const []).whereType<Map>().map((x) => '${x['count']} x ${x['name']}').join(', ');
      return '${slotName(s)}: ${litres(m['litres'])}${v.isEmpty ? '' : ', $v'}';
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: const Color(0x0FFFFFFF), borderRadius: BorderRadius.circular(22)),
      child: Row(children: [
        Text('Tomorrow', style: T.h2.copyWith(color: Colors.white)),
        const SizedBox(width: 24),
        Expanded(child: Text('${line('morning')}      ${line('evening')}', style: T.body.copyWith(color: K.heroText, fontSize: 16))),
      ]),
    );
  }
}
