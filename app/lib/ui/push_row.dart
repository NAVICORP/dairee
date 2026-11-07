import 'package:flutter/material.dart';

import '../core/push.dart';
import 'theme.dart';

/// Notifications on or off for this phone, in Profile. Hidden on the web.
class PushSwitchRow extends StatefulWidget {
  const PushSwitchRow({super.key, required this.sub});
  final String sub;

  @override
  State<PushSwitchRow> createState() => _PushSwitchRowState();
}

class _PushSwitchRowState extends State<PushSwitchRow> {
  bool busy = false;

  Future<void> _set(bool v) async {
    setState(() => busy = true);
    await Push.instance.setOn(v);
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final on = Push.instance.on;
    return MergeSemantics(
      child: InkWell(
        onTap: busy ? null : () => _set(!on),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 10, 8),
            child: Row(children: [
              Icon(on ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, color: K.blue, size: 20),
              const SizedBox(width: Sp.md + 2),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Notifications', style: T.body.copyWith(color: K.ink)),
                  Text(widget.sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.small),
                ]),
              ),
              Switch.adaptive(value: on, onChanged: busy ? null : _set),
            ]),
          ),
        ),
      ),
    );
  }
}
