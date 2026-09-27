/// council_screen.dart — The "Council of Elders" review queue.
/// ----------------------------------------------------------------------------
/// Card-swipe adjudication of pending vocabulary:
///   ▶ play the contributor's native recording
///   ✓ swipe RIGHT (Approve)  ✗ swipe LEFT (Reject)
/// Each verdict POSTs to the `review_submission` Edge Function which owns the
/// consensus math (≥3 approvals & ≥75% ratio ⇒ verified + calf mint).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audioplayers/audioplayers.dart';

import '../../data/models/vocabulary_card.dart';
import '../../data/repositories/vocabulary_repository.dart';
import '../../domain/srs/herd_controller.dart' show supabaseProvider;

final reviewQueueProvider =
    FutureProvider.autoDispose<List<VocabularyCard>>((ref) async {
  final db = ref.watch(supabaseProvider);
  final uid = db.auth.currentUser?.id ?? '';
  return ref.watch(vocabularyRepositoryProvider).fetchReviewQueue(uid);
});

class CouncilScreen extends ConsumerStatefulWidget {
  const CouncilScreen({super.key});

  @override
  ConsumerState<CouncilScreen> createState() => _CouncilScreenState();
}

class _CouncilScreenState extends ConsumerState<CouncilScreen> {
  final _player = AudioPlayer();
  int _index = 0;
  bool _busy = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _verdict(VocabularyCard card, bool accurate) async {
    setState(() => _busy = true);
    try {
      final tipped = await ref
          .read(vocabularyRepositoryProvider)
          .review(phraseId: card.id, isAccurate: accurate);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tipped
            ? 'Consensus reached — a calf was born into the clan!'
            : 'Verdict recorded with the elders.'),
        backgroundColor: tipped ? Colors.green.shade700 : null,
      ));
      setState(() {
        _busy = false;
        _index++;
      });
      ref.invalidate(reviewQueueProvider);
    } catch (e) {
      setState(() => _busy = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Council error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(reviewQueueProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Council of Elders')),
      body: queue.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Queue unavailable: $e')),
        data: (cards) {
          if (_index >= cards.length) {
            return const Center(
                child: Text('The Council is silent.\nNo phrases await judgement.',
                    textAlign: TextAlign.center));
          }
          final top = cards[_index];
          final next =
              _index + 1 < cards.length ? cards[_index + 1] : null;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (next != null) _card(next, behind: true),
              Dismissible(
                key: ValueKey(top.id),
                direction: _busy
                    ? DismissDirection.none
                    : DismissDirection.horizontal,
                background: _swipeHint(Colors.green, Icons.thumb_up),
                secondaryBackground: _swipeHint(Colors.red, Icons.thumb_down),
                confirmDismiss: (dir) async {
                  if (dir == DismissDirection.startToEnd) {
                    await _verdict(top, true);
                  } else {
                    await _verdict(top, false);
                  }
                  return true;
                },
                child: _card(top, behind: false),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _swipeHint(Color c, IconData i) => Container(
        color: c.withOpacity(.25),
        alignment: c == Colors.green
            ? Alignment.centerLeft
            : Alignment.centerRight,
        padding: const EdgeInsets.all(28),
        child: Icon(i, color: c, size: 40),
      );

  Widget _card(VocabularyCard c, {required bool behind}) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: EdgeInsets.only(top: behind ? 24 : 0),
        transformAlignment: Alignment.topCenter,
        child: Container(
          width: MediaQuery.of(context).size.width * .88,
          height: MediaQuery.of(context).size.height * .52,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [BoxShadow(blurRadius: 14, color: Colors.black26)],
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Chip(label: Text(c.category), visualDensity: VisualDensity.compact),
                const SizedBox(width: 8),
                Chip(
                    label: Text(c.languageCode),
                    visualDensity: VisualDensity.compact),
                const Spacer(),
                Text('${c.upvotes}✓ ${c.downvotes}✗',
                    style: Theme.of(context).textTheme.labelMedium),
              ]),
              const SizedBox(height: 18),
              Text(c.sourceText,
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('“${c.translatedText}”',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontStyle: FontStyle.italic, color: Colors.brown)),
              const Spacer(),
              if (c.audioUrl != null)
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Hear the herder’s voice'),
                  onPressed: () =>
                      _player.play(UrlSource(c.audioUrl!)),
                ),
              const SizedBox(height: 10),
              const Center(
                child: Text('Swipe right to approve · left to reject',
                    style: TextStyle(color: Colors.black45)),
              ),
            ],
          ),
        ),
      );
}
