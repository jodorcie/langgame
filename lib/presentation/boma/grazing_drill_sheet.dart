/// grazing_drill_sheet.dart — The Daily Grazing Run UI.
/// ----------------------------------------------------------------------------
/// A full-screen flashcard drill over every animal whose `next_review_at`
/// has lapsed. Front shows the source word (+ native audio); revealing the
/// back exposes four SM-2 grading buttons mapped to quality scores:
///   Again = 1 · Hard = 3 · Good = 4 · Easy = 5
/// Grading flows through GrazingController -> apply_srs_review RPC, which
/// re-schedules the animal and flips its health (q < 3 => sick).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audioplayers/audioplayers.dart';

import '../../domain/srs/herd_controller.dart';
import '../../domain/srs/sm2_engine.dart';

class GrazingDrillSheet extends ConsumerStatefulWidget {
  static const routeName = '/grazing';
  const GrazingDrillSheet({super.key});

  @override
  ConsumerState<GrazingDrillSheet> createState() => _GrazingDrillSheetState();
}

class _GrazingDrillSheetState extends ConsumerState<GrazingDrillSheet> {
  final _player = AudioPlayer();
  bool _submitting = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _grade(int q) async {
    setState(() => _submitting = true);
    final applied =
        await ref.read(grazingControllerProvider.notifier).gradeCurrent(q);
    if (!mounted) return;
    setState(() => _submitting = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 1),
      content: Text(applied.health == AnimalHealth.sick
          ? 'The herd looks thin tonight... this beast is sick.'
          : 'Well grazed - next visit in ${applied.intervalDays.toStringAsFixed(0)} days.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(grazingControllerProvider);

    if (session == null || session.queue.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Daily Grazing Run')),
        body: const Center(child: Text('Nothing is hungry today.')),
      );
    }
    if (session.finished) {
      return Scaffold(
        appBar: AppBar(title: const Text('Daily Grazing Run')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.check_circle, size: 72, color: Colors.green),
            const SizedBox(height: 12),
            Text('All ${session.queue.length} beasts tended!',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () {
                ref.invalidate(milkControllerProvider);
                Navigator.pop(context);
              },
              child: const Text('Return to the Boma'),
            ),
          ]),
        ),
      );
    }

    final animal = session.current!;
    return Scaffold(
      appBar: AppBar(
        title: Text('Grazing ${session.index + 1}/${session.queue.length}'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            LinearProgressIndicator(value: session.progress),
            const Spacer(),
            Card(
              elevation: 6,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              child: AspectRatio(
                aspectRatio: 1.35,
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: session.revealed
                      ? null
                      : () => ref
                          .read(grazingControllerProvider.notifier)
                          .revealAnswer(),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(animal.animalType.toUpperCase(),
                            style: Theme.of(context).textTheme.labelSmall),
                        const SizedBox(height: 8),
                        Text(animal.sourceText,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        if (animal.audioUrl != null)
                          IconButton(
                            icon: const Icon(Icons.play_circle_outline),
                            onPressed: () => _player
                                .play(UrlSource(animal.audioUrl!)),
                          ),
                        const SizedBox(height: 16),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: session.revealed
                              ? Text(animal.translatedText,
                                  key: const ValueKey('back'),
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(color: Colors.brown))
                              : const Text('tap to reveal',
                                  key: ValueKey('front'),
                                  style: TextStyle(color: Colors.black38)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const Spacer(),
            if (session.revealed && !_submitting)
              Row(
                children: [
                  _GradeButton(
                      label: 'Again', q: 1, color: Colors.red.shade300, onTap: _grade),
                  _GradeButton(
                      label: 'Hard', q: 3, color: Colors.orange.shade300, onTap: _grade),
                  _GradeButton(
                      label: 'Good', q: 4, color: Colors.lightGreen.shade400, onTap: _grade),
                  _GradeButton(
                      label: 'Easy', q: 5, color: Colors.green.shade600, onTap: _grade),
                ],
              )
            else if (!_submitting)
              FilledButton.icon(
                onPressed: () => ref
                    .read(grazingControllerProvider.notifier)
                    .revealAnswer(),
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Reveal translation'),
              )
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _GradeButton extends StatelessWidget {
  const _GradeButton({
    required this.label,
    required this.q,
    required this.color,
    required this.onTap,
  });

  final String label;
  final int q; // SM-2 quality score sent to apply_srs_review
  final Color color;
  final Future<void> Function(int) onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: color),
            onPressed: () => onTap(q),
            child: Text(label),
          ),
        ),
      );
}
