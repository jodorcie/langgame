/// raid_screen.dart — Asynchronous Raiding: scouting list + decryption minigame.
/// ----------------------------------------------------------------------------
/// Two stacked experiences in one route:
///   • IDLE/SCOUTING  — rival Boma leaderboard; tap a clan to launch an assault
///     (server rejects shielded or unaffordable targets with clear codes).
///   • ENGAGED        — the timed linguistic decryption gauntlet:
///        - Watchtower countdown bar drains toward zero; fence posts visibly
///          splinter as time runs out (timer IS the fence strength metaphor).
///        - Each of the defender's up-to-5 Defense Phrases is a gate: listen to
///          the audio / read the translation hint, then TAP scrambled syntax
///          tokens into the correct grammatical order.
/// All grading & settlement happens server-side via RaidController ->
/// `raid_manager` Edge Function (anti-cheat: expected order never ships).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/raids/raid_controller.dart';
import '../../domain/srs/herd_controller.dart' show supabaseProvider;

/// Rival discovery feed (public rows via RLS select policy).
final rivalsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
    (ref) async {
  final db = ref.watch(supabaseProvider);
  final me = db.auth.currentUser!.id;
  return db
      .from('player_bomas')
      .select('id, clan_name, fence_level, boma_tier, shield_until, trophies')
      .neq('user_id', me)
      .order('trophies', ascending: false)
      .limit(25);
});

class RaidScreen extends ConsumerWidget {
  const RaidScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raid = ref.watch(raidControllerProvider);

    switch (raid.phase) {
      case RaidPhase.engaged:
        return _DecryptionView(raid: raid);
      case RaidPhase.victory:
      case RaidPhase.repelled:
        return _OutcomeView(raid: raid);
      default:
        return const _ScoutView();
    }
  }
}

// ============================================================================
// Scouting board
// ============================================================================
class _ScoutView extends ConsumerWidget {
  const _ScoutView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rivals = ref.watch(rivalsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Scout the Neighbours')),
      body: rivals.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Scouts lost: $e')),
        data: (rows) => ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = rows[i];
            final shielded =
                DateTime.parse(r['shield_until'] as String).isAfter(DateTime.now());
            return ListTile(
              leading: Icon(shielded ? Icons.shield : Icons.flag,
                  color: shielded ? Colors.blueGrey : Colors.redAccent),
              title: Text(r['clan_name'] as String),
              subtitle: Text(
                  'Fence Lv ${r['fence_level']} · Tier ${r['boma_tier']}'
                  '${shielded ? " · SHIELDED" : ""}'),
              trailing: shielded
                  ? null
                  : FilledButton(
                      onPressed: () => ref
                          .read(raidControllerProvider.notifier)
                          .beginRaid(r['id'] as String),
                      child: const Text('RAID'),
                    ),
            );
          },
        ),
      ),
    );
  }
}

// ============================================================================
// The decryption minigame
// ============================================================================
class _DecryptionView extends ConsumerWidget {
  const _DecryptionView({required this.raid});
  final RaidState raid;

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(raidControllerProvider.notifier);
    final gate = raid.activeGate;
    if (gate == null) return const SizedBox.shrink();

    // Fence integrity visualises remaining time: 10 posts, breaking left→right.
    final intactPosts =
        (10 * raid.remainingSecs / raid.timeLimitSecs).ceil().clamp(0, 10);
    final urgent = raid.remainingSecs <= 15;

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${gate.slotIndex} of ${raid.gates.length} gates'),
          backgroundColor: urgent ? Colors.red.shade700 : null,
          actions: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(_fmt(raid.remainingSecs),
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: urgent ? Colors.white : Colors.brown)),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            // Watchtower timer = fence strength bar ---------------------------
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: List.generate(
                  10,
                  (p) => Expanded(
                    child: Icon(
                      p < intactPosts ? Icons.vertical_align_top : Icons.close,
                      size: 18,
                      color: p < intactPosts
                          ? Colors.brown.shade800
                          : Colors.black12,
                    ),
                  ),
                ),
              ),
            ),
            LinearProgressIndicator(
              value: raid.remainingSecs / raid.timeLimitSecs,
              minHeight: 6,
              color: urgent ? Colors.red : Colors.green,
            ),
            const SizedBox(height: 16),
            // Gate prompt ------------------------------------------------------
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Text('Reconstruct the defenders’ phrase:',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text('“${gate.translationHint}”',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontStyle: FontStyle.italic)),
                  if (gate.audioUrl != null)
                    IconButton(
                        onPressed: () {}, // wire to AudioPlayer like Council
                        icon: const Icon(Icons.hearing)),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            // Answer line -------------------------------------------------------
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 56),
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.brown, width: 2),
                borderRadius: BorderRadius.circular(12),
                color: Colors.amber.shade50,
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in raid.assembled)
                    ActionChip(
                        label: Text(t),
                        onPressed: controller.undoLastToken),
                  if (raid.assembled.isEmpty)
                    const Text('tap word tiles below…',
                        style: TextStyle(color: Colors.black38)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Scrambled token pool ----------------------------------------------
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final t in gate.scrambledTokens)
                    OutlinedButton(
                      onPressed: raid.assembled.contains(t)
                          ? null
                          : () => controller.tapToken(t),
                      style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          side: const BorderSide(color: Colors.brown)),
                      child: Text(t),
                    ),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  TextButton(
                      onPressed: controller.abort,
                      child: const Text('Retreat')),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: raid.assembled.length ==
                            gate.scrambledTokens.length
                        ? controller.submitGate
                        : null,
                    icon: const Icon(Icons.lock_open),
                    label: Text(gate.slotIndex == raid.gates.length
                        ? 'BREACH THE KRAAL'
                        : 'SOLVE GATE'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Outcome screen
// ============================================================================
class _OutcomeView extends ConsumerWidget {
  const _OutcomeView({required this.raid});
  final RaidState raid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final won = raid.phase == RaidPhase.victory;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(won ? Icons.card_travel : Icons.security,
                size: 96, color: won ? Colors.green : Colors.blueGrey),
            const SizedBox(height: 16),
            Text(won ? 'CATTLE DRIVEN HOME!' : 'REPELLED BY THE WATCHMAN',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(raid.message ?? '', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                ref.read(raidControllerProvider.notifier).reset();
                ref.invalidate(rivalsProvider);
              },
              child: const Text('Return to the campfire'),
            ),
          ]),
        ),
      ),
    );
  }
}
