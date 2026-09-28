/// ============================================================================
/// herd_controller.dart — The SM-2 Livestock Lifecycle Handler (Riverpod)
/// ----------------------------------------------------------------------------
/// Orchestrates the full animal lifecycle:
///   newborn → grazing drills (SM-2 scheduling) → milk production → decay
///
/// Design:
///   * [Sm2Engine] computes the next schedule locally for instant UI feedback.
///   * The authoritative write-back happens through the `apply_srs_review`
///     Postgres RPC so a hacked client can never forge intervals.
///   * Realtime subscription keeps the kraal in sync when animals are minted
///     by consensus or stolen in raids while you're away.
/// ============================================================================

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../srs/sm2_engine.dart';
import '../../data/models/herd_animal.dart';

/// ---- Dependency providers --------------------------------------------------
final supabaseProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

final sm2EngineProvider = Provider<Sm2Engine>(
  (ref) => const Sm2Engine(),
);

/// Live herd of the signed-in player, keyed by boma_id.
final herdStreamProvider =
    StreamProvider.autoDispose<List<HerdAnimal>>((ref) async* {
  final db = ref.watch(supabaseProvider);
  final uid = db.auth.currentUser?.id;
  if (uid == null) return;

  final bomaId = await _bomaIdFor(db, uid);
  if (bomaId == null) return;

  // Initial snapshot…
  yield await fetchHerd(db, bomaId);

  // …then delta updates whenever any animal is fed, sickens, or is rustled.
  // (RealtimeChannel is not a Dart Stream; bridge DB-change events through a
  // broadcast controller that re-pulls the authoritative herd on each event.)
  final changes = StreamController<List<HerdAnimal>>();
  late final channelRef = db.channel('herd:$bomaId');
  channelRef.onPostgresChanges(
    event: PostgresChangeEvent.all,
    schema: 'public',
    table: 'herd_animals',
    filter: PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'boma_id',
      value: bomaId,
    ),
    callback: (_) async {
      try {
        changes.add(await fetchHerd(db, bomaId));
      } catch (e) {
        changes.addError(e);
      }
    },
  ).subscribe();

  ref.onDispose(() {
    changes.close();
    db.removeChannel(channelRef);
  });

  yield* changes.stream;
});

Future<List<HerdAnimal>> fetchHerd(SupabaseClient db, String bomaId) async {
  final rows = await db
      .from('herd_animals')
      .select('''
        id, boma_id, phrase_id, animal_type, health_status,
        next_review_at, interval_days, ease_factor, repetition_count,
        last_fed_at, vocabulary ( source_text, translated_text, audio_url, language_code )
      ''')
      .eq('boma_id', bomaId)
      .order('next_review_at');
  return rows.map(HerdAnimal.fromJson).toList();
}

Future<String?> _bomaIdFor(SupabaseClient db, String uid) async {
  final row = await db.from('player_bomas')
      .select('id').eq('user_id', uid).maybeSingle();
  return row?['id'] as String?;
}

/// ---- Grazing Run state ------------------------------------------------------
class GrazingSession {
  const GrazingSession({
    required this.queue,
    required this.index,
    this.revealed = false,
  });

  /// Animals due for review, ordered oldest-due first.
  final List<HerdAnimal> queue;
  final int index;
  final bool revealed;

  HerdAnimal? get current => index < queue.length ? queue[index] : null;
  bool get finished => index >= queue.length;
  double get progress => queue.isEmpty ? 1 : index / queue.length;

  GrazingSession copyWith({int? index, bool? revealed}) => GrazingSession(
        queue: queue,
        index: index ?? this.index,
        revealed: revealed ?? this.revealed,
      );
}

/// Drives one Daily Grazing Run and commits SM-2 results to the server.
class GrazingController extends Notifier<GrazingSession?> {
  @override
  GrazingSession? build() => null;

  SupabaseClient get _db => ref.read(supabaseProvider);
  Sm2Engine get _engine => ref.read(sm2EngineProvider);

  /// Called when the player taps a cow with an alert icon (next_review_at <= now).
  Future<void> startSession() async {
    final herd = ref.read(herdStreamProvider).valueOrNull ?? const [];
    final due = herd.where((a) => a.isDue && !a.isQuarantined).toList()
      ..sort((x, y) => x.nextReviewAt.compareTo(y.nextReviewAt));
    state = GrazingSession(queue: due, index: 0);
  }

  void revealAnswer() {
    if (state != null && !state!.revealed) {
      state = state!.copyWith(revealed: true);
    }
  }

  /// Grade the visible card with quality [q] ∈ 0..5.
  ///
  /// Buttons map: Again=1 · Hard=3 · Good=4 · Easy=5.
  Future<SrsState> gradeCurrent(int q) async {
    final session = state;
    final animal = session?.current;
    if (session == null || animal == null) {
      throw StateError('grazing session not active');
    }

    // 1. Local optimistic scheduling for instant sprite feedback.
    final predicted = _engine.schedule(state: animal.srs, q: q);

    // 2. Authoritative write-back (server recomputes identical math).
    final rows = await _db.rpc<List<dynamic>>(
      'apply_srs_review',
      params: {'p_animal_id': animal.id, 'p_quality': q},
    );
    final applied = SrsState(
      easeFactor: (rows.first['ease_factor'] as num).toDouble(),
      intervalDays: (rows.first['interval_days'] as num).toDouble(),
      repetitionCount: (rows.first['repetition_count'] as num).toInt(),
      nextReviewAt: DateTime.parse(rows.first['next_review_at'] as String),
      health: AnimalHealth.values.byName(rows.first['health_status'] as String),
    );
    assert(
      applied.intervalDays == predicted.intervalDays,
      'client/server SM-2 divergence detected — reconcile engines',
    );

    // 3. Advance the drill queue.
    state = session.copyWith(index: session.index + 1, revealed: false);
    return applied;
  }
}

final grazingControllerProvider =
    NotifierProvider<GrazingController, GrazingSession?>(
  GrazingController.new,
);

/// ---- Passive economy: Milk/Energy --------------------------------------------
class MilkController extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    final db = ref.watch(supabaseProvider);
    final row = await db.from('player_bomas')
        .select('milk_energy').eq('user_id', db.auth.currentUser!.id)
        .maybeSingle();
    return (row?['milk_energy'] as int?) ?? 0;
  }

  /// Collect milk produced by every healthy, up-to-date animal (≥6h since last).
  Future<int> claim() async {
    final gained = await ref.read(supabaseProvider).rpc<int>('claim_milk');
    state = AsyncData((await future) + gained);
    ref.invalidate(herdStreamProvider); // refresh fed timestamps
    return gained;
  }
}

final milkControllerProvider = AsyncNotifierProvider<MilkController, int>(
  MilkController.new,
);
