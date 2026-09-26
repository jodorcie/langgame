/// ============================================================================
/// sm2_engine.dart — Pure Modified SuperMemo-2 scheduler for Boma livestock.
/// ----------------------------------------------------------------------------
/// Zero dependencies (no Flutter imports) so it is unit-testable on the VM and
/// mirrors `apply_srs_review()` in supabase/migrations for server parity.
///
/// SM-2 recap (with Boma flavour rules):
///   q ∈ [0..5] recall quality ("Again" maps to 0-1, "Hard" 3, "Good" 4,
///   "Easy" 5).
///   • q < 3  → repetition reset to 0, interval back to 1 day, animal SICK.
///   • q ≥ 3  → I(1)=1, I(2)=6, I(n)=I(n-1)·EF ; animal HEALTHY.
///   EF' = EF + (0.1 − (5−q)·(0.08 + (5−q)·0.02)), clamped to ≥ 1.30.
/// ============================================================================

/// Health outcome of an animal after a drill answer.
enum AnimalHealth { healthy, hungry, sick, quarantined }

/// Immutable snapshot of one animal's scheduling state.
class SrsState {
  const SrsState({
    required this.easeFactor,
    required this.intervalDays,
    required this.repetitionCount,
    required this.nextReviewAt,
    required this.health,
  });

  /// Ease factor (EF). Canonical SM-2 range: [1.3, ∞), birth default 2.5.
  final double easeFactor;

  /// Current repetition interval in days (fractional allowed for sub-day drills).
  final double intervalDays;

  /// Number of consecutive successful recalls (SM-2 "n").
  final int repetitionCount;

  /// When the next Grazing Run should surface this card.
  final DateTime nextReviewAt;

  /// Livestock condition derived from recall quality.
  final AnimalHealth health;

  static const double initialEase = 2.5;
  static const double minEase = 1.3;
  static const double firstIntervalDays = 1.0;
  static const double secondIntervalDays = 6.0;

  /// Freshly-hatched calf defaults (matches review_submission minting).
  factory SrsState.newborn({DateTime? now}) {
    final t = now ?? DateTime.now();
    return SrsState(
      easeFactor: initialEase,
      intervalDays: firstIntervalDays,
      repetitionCount: 0,
      nextReviewAt: t.add(const Duration(days: 1)),
      health: AnimalHealth.healthy,
    );
  }

  bool get isDue => !DateTime.now().isBefore(nextReviewAt);

  SrsState copyWith({
    double? easeFactor,
    double? intervalDays,
    int? repetitionCount,
    DateTime? nextReviewAt,
    AnimalHealth? health,
  }) =>
      SrsState(
        easeFactor: easeFactor ?? this.easeFactor,
        intervalDays: intervalDays ?? this.intervalDays,
        repetitionCount: repetitionCount ?? this.repetitionCount,
        nextReviewAt: nextReviewAt ?? this.nextReviewAt,
        health: health ?? this.health,
      );

  @override
  String toString() => 'SrsState(EF: ${easeFactor.toStringAsFixed(2)}, '
      'I: ${intervalDays.toStringAsFixed(1)}d, n: $repetitionCount, '
      'due: $nextReviewAt, ${health.name})';
}

/// Stateless SM-2 evaluator. Injected into repositories/controllers via
/// Riverpod so alternative schedulers (FSRS etc.) can replace it later.
class Sm2Engine {
  const Sm2Engine();

  /// Compute the next scheduling state for [state] given answer quality [q].
  ///
  /// [now] is injectable for deterministic tests.
  SrsState schedule({
    required SrsState state,
    required int q,
    DateTime? now,
  }) {
    assert(q >= 0 && q <= 5, 'quality must be within 0..5');
    final t0 = now ?? DateTime.now();

    // ---- 1. Ease factor update (canonical SM-2 delta formula) --------------
    final delta = 0.1 - (5 - q) * (0.08 + (5 - q) * 0.02);
    final ef = _clamp(state.easeFactor + delta, SrsState.minEase, 4.0);

    // ---- 2. Interval & repetition progression -------------------------------
    double interval;
    int repetitions;
    AnimalHealth health;

    if (q < 3) {
      // Failed recall: the beast wanders off and falls ill; restart grazing.
      repetitions = 0;
      interval = SrsState.firstIntervalDays;
      health = AnimalHealth.sick;
    } else {
      repetitions = state.repetitionCount + 1;
      interval = switch (repetitions) {
        1 => SrsState.firstIntervalDays,
        2 => SrsState.secondIntervalDays,
        // From the 3rd rep onward the interval compounds by the NEW ease factor.
        _ => state.intervalDays * ef,
      };
      health = AnimalHealth.healthy;
    }

    // ---- 3. Next appointment --------------------------------------------------
    return SrsState(
      easeFactor: _round2(ef),
      intervalDays: _round2(interval),
      repetitionCount: repetitions,
      nextReviewAt: t0.add(Duration(minutes: (interval * 24 * 60).round())),
      health: health,
    );
  }

  /// Passive-production decay used by the nightly cron equivalent on-device:
  /// animals overdue by [days] lapse healthy → hungry → sick → quarantined.
  static AnimalHealth decayOf(SrsState state, {required int daysOverdue}) {
    if (daysOverdue <= 0) return state.health;
    if (daysOverdue >= 7) return AnimalHealth.quarantined;
    if (daysOverdue >= 3) return AnimalHealth.sick;
    return AnimalHealth.hungry;
  }

  static double _clamp(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  /// Two-decimal rounding keeps client/server rows byte-identical.
  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}
