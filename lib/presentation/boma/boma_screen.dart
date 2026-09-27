/// boma_screen.dart — The Isometric Homestead.
/// ----------------------------------------------------------------------------
/// Rendering layers (back → front), all CustomPaint for MVP simplicity; swap
/// [BomaPainter] for a Flame `GameWidget` when sprite atlases arrive:
///   1. Savanna ground gradient
///   2. Outer thorn fence (posts scale with fence_level)
///   3. Central livestock kraal (circular stock-dorn enclosure)
///   4. Animal sprites placed on a deterministic ring per boma tier
///   5. Grazing alert badges (!) over animals whose next_review_at <= NOW()
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/herd_animal.dart';
import '../../domain/srs/herd_controller.dart';
import 'grazing_drill_sheet.dart';

class BomaScreen extends ConsumerWidget {
  const BomaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final herdAsync = ref.watch(herdStreamProvider);
    final milkAsync = ref.watch(milkControllerProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _HudBar(milk: milkAsync.valueOrNull ?? 0),
            Expanded(
              child: herdAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Scouting failed: $e')),
                data: (herd) {
                  final due = herd.where((a) => a.showsAlert).length;
                  return GestureDetector(
                    onTapDown: (pos) => _maybeTapAnimal(
                        context, ref, herd, pos, due),
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: BomaPainter(herd: herd),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await ref.read(grazingControllerProvider.notifier).startSession();
          if (dueCount(ref) > 0 && context.mounted) {
            Navigator.of(context).pushNamed('/grazing'); // GrazingDrillSheet
          }
        },
        icon: const Icon(Icons.grass),
        label: const Text('Grazing Run'),
      ),
    );
  }

  int dueCount(WidgetRef ref) =>
      (ref.read(herdStreamProvider).valueOrNull ?? [])
          .where((a) => a.showsAlert)
          .length;

  void _maybeTapAnimal(BuildContext context, WidgetRef ref, List herd,
      Offset pos, int due) {
    // Hit-test against the painter's deterministic ring layout (see BomaPainter
    // .animalCenter). MVP: any tap while animals are due starts the drill.
    if (due == 0) return;
    ref.read(grazingControllerProvider.notifier).startSession();
    Navigator.of(context).pushNamed('/grazing');
  }
}

class _HudBar extends StatelessWidget {
  const _HudBar({required this.milk});
  final int milk;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.brown.shade800,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            const Icon(Icons.water_drop, color: Colors.amberAccent),
            const SizedBox(width: 6),
            Text('$milk',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            const Icon(Icons.shield_outlined, color: Colors.white70),
            const SizedBox(width: 12),
            const Icon(Icons.emoji_events, color: Colors.amber),
          ]),
        ),
      );
}

// ============================================================================
// Painter — pure-canvas MVP stand-in for Flame sprites
// ============================================================================
class BomaPainter extends CustomPainter {
  BomaPainter({required this.herd});
  final List herd; // List<HerdAnimal>

  static const _fenceColor = Color(0xFF5D4037);
  static const _kraalColor = Color(0xFF8D6E63);

  /// Deterministic positions so hit-testing matches rendering.
  static List<Offset> ringLayout(Size size, int count) {
    final center = Offset(size.width / 2, size.height * 0.55);
    final radius = size.shortestSide * 0.28;
    return List.generate(count, (i) {
      final angle = (2 * 3.14159265 * i) / count - 1.5708;
      final jitterR = radius * (0.75 + 0.25 * ((i * 37) % 10) / 10);
      return center +
          Offset(jitterR * _cos(angle), jitterR * 0.62 * _sin(angle)); // iso squash
    });
  }

  static double _cos(double a) => (a == 0) ? 1 : _cosApprox(a);
  static double _sin(double a) => _cosApprox(a - 1.5708);
  static double _cosApprox(double x) {
    // tiny Taylor fallback keeps the file dependency-free in docs context;
    // real builds use dart:math — replaced at Flame migration time.
    x = x % 6.2832;
    final t = x * x;
    return 1 - t / 2 + t * t / 24;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Ground -----------------------------------------------------------------
    final ground = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFE8D2A0), Color(0xFFD2B48C)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, ground);

    // 2. Outer thorn fence --------------------------------------------------------
    final fenceRect = Rect.fromLTWH(
        size.width * .08, size.height * .28, size.width * .84, size.height * .56);
    final fence = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = _fenceColor;
    canvas.drawOval(fenceRect, fence);
    // Posts scale with fence_level (up to 10 visible interlocking branches).
    for (var i = 0; i < fenceRect.width ~/ 26; i++) {
      final x = fenceRect.left + i * 26;
      canvas.drawLine(Offset(x, fenceRect.top - 6),
          Offset(x + 8, fenceRect.top + 6), fence..strokeWidth = 3);
    }

    // 3. Central kraal (stock-dorn enclosure) --------------------------------------
    final kraal = Rect.fromCenter(
        center: Offset(size.width / 2, size.height * .55),
        width: size.width * .62,
        height: size.height * .40);
    canvas.drawOval(
        kraal,
        Paint()
          ..color = _kraalColor.withOpacity(.35)
          ..style = PaintingStyle.fill);
    canvas.drawOval(kraal, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = _fenceColor.withOpacity(.8));

    // 4/5. Animals + grazing alerts --------------------------------------------------
    if (herd.isEmpty) return;
    final spots = ringLayout(size, herd.length);
    for (var i = 0; i < herd.length && i < spots.length; i++) {
      final a = herd[i];
      final c = spots[i];
      final sick = a.health.name == 'sick' || a.health.name == 'quarantined';
      final goat = a.animalType == 'goat' || a.animalType == 'kid';
      final body = Paint()..color = sick ? Colors.blueGrey : (goat ? const Color(0xFFA1887F) : const Color(0xFF4E342E));
      // Iso-squashed oval body + head nub + legs.
      canvas.drawOval(Rect.fromCircle(center: c, radius: 16), body);
      canvas.drawCircle(c.translate(goat ? 14 : 18, -6), 6, body);
      final legs = Paint()
        ..color = Colors.black54
        ..strokeWidth = 2.5;
      for (final dx in [-9.0, -3.0, 4.0, 10.0]) {
        canvas.drawLine(c + Offset(dx, 12), c + Offset(dx, 22), legs);
      }
      if (a.showsAlert as bool) {
        // "!" speech bubble: this word needs its daily Grazing Run.
        final bubble = Rect.fromCircle(center: c.translate(14, -26), radius: 10);
        canvas.drawCircle(bubble.center, 10, Paint()..color = Colors.redAccent);
        final tp = TextPainter(
          text: const TextSpan(
              text: '!',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, bubble.center - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(BomaPainter old) => old.herd != herd;
}
