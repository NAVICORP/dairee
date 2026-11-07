import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'glass.dart';
import 'theme.dart';

/// The first load after opening the app: the bottle logo floating in liquid
/// glass. A band of light sweeps across it; tilting the phone leans the
/// glass and moves its highlight; a finger drags the light around, and a tap
/// makes the tile give a little and send out a ring.
class SplashLoader extends StatefulWidget {
  const SplashLoader({super.key, this.label = 'Getting your farm ready'});
  final String label;

  /// Off in tests, where the phone has no motion sensors to ask.
  static bool sensors = true;

  @override
  State<SplashLoader> createState() => _SplashLoaderState();
}

class _SplashLoaderState extends State<SplashLoader> with TickerProviderStateMixin {
  late final AnimationController sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));
  late final AnimationController press = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final AnimationController ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final AnimationController breathe = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));
  StreamSubscription<AccelerometerEvent>? _tilt;

  /// Where the light comes from, -1..1 on each axis (tilt or finger).
  Offset light = const Offset(-0.4, -0.6);
  Offset _target = const Offset(-0.4, -0.6);
  bool _finger = false;
  Ticker? _ease;

  @override
  void initState() {
    super.initState();
    _ease = createTicker((_) {
      final next = Offset.lerp(light, _target, 0.12)!;
      if ((next - light).distance > 0.0005) setState(() => light = next);
    })
      ..start();
    if (SplashLoader.sensors && !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)) {
      try {
        _tilt = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) {
          if (_finger) return;
          // Upright phone: gravity mostly on y. Lean left/right and forward/back.
          _target = Offset((-e.x / 6).clamp(-1.0, 1.0), ((e.y - 7) / 5).clamp(-1.0, 1.0));
        }, onError: (_) {}, cancelOnError: true);
      } catch (_) {
        // No sensors here; the light drifts by itself.
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still) {
      sweep.stop();
      breathe.stop();
    } else {
      if (!sweep.isAnimating) sweep.repeat();
      if (!breathe.isAnimating) breathe.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _tilt?.cancel();
    _ease?.dispose();
    sweep.dispose();
    press.dispose();
    ring.dispose();
    breathe.dispose();
    super.dispose();
  }

  void _point(Offset local, Size size) {
    _finger = true;
    _target = Offset(
      ((local.dx / size.width) * 2 - 1).clamp(-1.0, 1.0),
      ((local.dy / size.height) * 2 - 1).clamp(-1.0, 1.0),
    );
  }

  void _tap() {
    HapticFeedback.lightImpact();
    press.forward(from: 0);
    ring.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading Dairee',
      liveRegion: true,
      child: AmbientLight(
        child: LayoutBuilder(builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => _point(d.localPosition, size),
            onPanUpdate: (d) => _point(d.localPosition, size),
            onPanEnd: (_) => _finger = false,
            onTapDown: (d) => _point(d.localPosition, size),
            onTapUp: (_) => _finger = false,
            onTap: _tap,
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                AnimatedBuilder(
                  animation: Listenable.merge([sweep, press, ring, breathe]),
                  builder: (context, _) => _tile(),
                ),
                const SizedBox(height: 28),
                Text('Dairee', style: T.display.copyWith(fontSize: 30)),
                const SizedBox(height: 6),
                Text(widget.label, style: T.body.copyWith(color: K.muted)),
                const SizedBox(height: 22),
                _Progress(sweep: sweep),
              ]),
            ),
          );
        }),
      ),
    );
  }

  Widget _tile() {
    const s = 128.0;
    // A soft give on tap, and a slow float the rest of the time.
    final give = press.isAnimating || press.value > 0
        ? 1 - 0.08 * math.sin(math.pi * Curves.easeOut.transform(press.value)) * (1 - press.value)
        : 1.0;
    final float = math.sin(breathe.value * math.pi) * 6;
    final lean = Matrix4.identity()
      ..setEntry(3, 2, 0.0012)
      ..rotateX(-light.dy * 0.22)
      ..rotateY(light.dx * 0.22);
    final glare = Alignment(light.dx, light.dy);

    return SizedBox(
      width: s + 80,
      height: s + 80,
      child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
        // The ring a tap sends out.
        if (ring.isAnimating)
          Opacity(
            opacity: (1 - ring.value).clamp(0.0, 1.0) * 0.5,
            child: Container(
              width: s + ring.value * 90,
              height: s + ring.value * 90,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular((s + ring.value * 90) * 0.28),
                border: Border.all(color: K.blue, width: 2),
              ),
            ),
          ),
        Transform.translate(
          offset: Offset(0, -float),
          child: Transform(
            alignment: Alignment.center,
            transform: lean,
            child: Transform.scale(
              scale: give,
              child: Glass(
              borderRadius: BorderRadius.circular(s * 0.28),
              tone: GlassTone.light,
              blur: 0,
              child: SizedBox(
                width: s,
                height: s,
                child: Stack(fit: StackFit.expand, children: [
                  // The glass catching the light where it comes from.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: glare,
                        radius: 0.9,
                        colors: const [Color(0x99FFFFFF), Color(0x00FFFFFF)],
                      ),
                    ),
                  ),
                  Center(
                    child: ShaderMask(
                      blendMode: BlendMode.srcATop,
                      shaderCallback: (r) {
                        final t = sweep.value * 2.6 - 0.8;
                        return LinearGradient(
                          begin: Alignment(-1 + t * 2, -1),
                          end: Alignment(t * 2, 1),
                          colors: const [Color(0x00FFFFFF), Color(0x88FFFFFF), Color(0x00FFFFFF)],
                          stops: const [0.35, 0.5, 0.65],
                        ).createShader(r);
                      },
                      child: Image.asset('assets/brand/mark.png', width: s * 0.66, height: s * 0.66, filterQuality: FilterQuality.high),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          ),
        ),
      ]),
    );
  }
}

/// A thin glass capsule with light running along it.
class _Progress extends StatelessWidget {
  const _Progress({required this.sweep});
  final Animation<double> sweep;

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 999,
      child: SizedBox(
        width: 120,
        height: 6,
        child: AnimatedBuilder(
          animation: sweep,
          builder: (context, _) => FractionallySizedBox(
            alignment: Alignment(sweep.value * 2.4 - 1.2, 0),
            widthFactor: 0.4,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(999)),
                gradient: LinearGradient(colors: [Color(0x001064D9), K.blue, Color(0x001064D9)]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading inside a page: the bottle with light passing over it.
class MiniLoader extends StatefulWidget {
  const MiniLoader({super.key, this.size = 34});
  final double size;

  @override
  State<MiniLoader> createState() => _MiniLoaderState();
}

class _MiniLoaderState extends State<MiniLoader> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      c.stop();
    } else if (!c.isAnimating) {
      c.repeat();
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return Semantics(
      label: 'Loading',
      child: AnimatedBuilder(
        animation: c,
        builder: (context, child) {
          final t = c.value;
          final bob = math.sin(t * math.pi * 2) * 2;
          return Transform.translate(
            offset: Offset(0, -bob),
            child: ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (r) => LinearGradient(
                begin: Alignment(-3 + t * 5, -1),
                end: Alignment(-1 + t * 5, 1),
                colors: const [Color(0x00FFFFFF), Color(0xAAFFFFFF), Color(0x00FFFFFF)],
                stops: const [0.3, 0.5, 0.7],
              ).createShader(r),
              child: child,
            ),
          );
        },
        child: Image.asset('assets/brand/mark.png', width: s, height: s, filterQuality: FilterQuality.medium),
      ),
    );
  }
}
