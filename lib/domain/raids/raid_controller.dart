/// ============================================================================
/// raid_controller.dart — Client-side Raid Manager (Riverpod state machine)
/// ----------------------------------------------------------------------------
/// Phases: scouting → engaged (decryption minigame w/ watchtower timer)
///         → victory | repelled | aborted
///
/// All settlement happens server-side via the `raid_manager` Edge Function,
/// which grades token sequences against the defender's canonical source text,
/// so the client cannot lie about solving gates.
/// ============================================================================

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../srs/herd_controller.dart' show supabaseProvider;

// ---- DTOs --------------------------------------------------------------------
class RaidGate {
  const RaidGate({
    required this.slotIndex,
    required this.phraseId,
    required this.translationHint,
    required this.scrambledTokens,
    this.audioUrl,
  });

  final int slotIndex;
  final String phraseId;
  final String translationHint;
  final List<String> scrambledTokens;
  final String? audioUrl;

  factory RaidGate.fromJson(Map<String, dynamic> j) => RaidGate(
        slotIndex: j['slot_index'] as int,
        phraseId: j['phrase_id'] as String,
        translationHint: j['translation_hint'] as String,
        scrambledTokens: (j['scrambled_tokens'] as List).cast<String>(),
        audioUrl: j['audio_url'] as String?,
      );
}

enum RaidPhase { idle, scouting, engaged, victory, repelled, error }

class RaidState {
  const RaidState({
    required this.phase,
    this.gates = const [],
    this.currentGate = 0,
    this.assembled = const [],
    this.timeLimitSecs = 0,
    this.remainingSecs = 0,
    this.energySpent = 0,
    this.livestockStolen = 0,
    this.message,
  });

  final RaidPhase phase;
  final List<RaidGate> gates;
  final int currentGate;

  /// Tokens tapped into the answer line for the active gate.
  final List<String> assembled;
  final int timeLimitSecs;
  final int remainingSecs;
  final int energySpent;
  final int livestockStolen;
  final String? message;

  bool get canAffordTarget => true; // pre-flight handled server-side
  RaidGate? get activeGate =>
      currentGate < gates.length ? gates[currentGate] : null;

  RaidState copyWith({
    RaidPhase? phase,
    List<RaidGate>? gates,
    int? currentGate,
    List<String>? assembled,
    int? timeLimitSecs,
    int? remainingSecs,
    int? energySpent,
    int? livestockStolen,
    String? message,
  }) =>
      RaidState(
        phase: phase ?? this.phase,
        gates: gates ?? this.gates,
        currentGate: currentGate ?? this.currentGate,
        assembled: assembled ?? this.assembled,
        timeLimitSecs: timeLimitSecs ?? this.timeLimitSecs,
        remainingSecs: remainingSecs ?? this.remainingSecs,
        energySpent: energySpent ?? this.energySpent,
        livestockStolen: livestockStolen ?? this.livestockStolen,
        message: message ?? this.message,
      );
}

// ---- Controller ----------------------------------------------------------------
class RaidController extends Notifier<RaidState> {
  Timer? _ticker;
  final List<List<String>> _solvedAttempts = []; // per-gate submitted order
  late final DateTime _engagedAt;

  String _targetBomaId = '';

  @override
  RaidState build() {
    ref.onDispose(() => _ticker?.cancel());
    return const RaidState(phase: RaidPhase.idle);
  }

  /// Step 1 — Engage: check shield/milk & pull defense configuration.
  Future<void> beginRaid(String targetBomaId) async {
    state = state.copyWith(phase: RaidPhase.scouting);
    try {
      final res = await ref.read(supabaseProvider).functions.post(
            'raid_manager',
            body: {'action': 'begin', 'target_boma_id': targetBomaId},
          );
      final json = res.data as Map<String, dynamic>;
      if (res.status != 200) {
        state = state.copyWith(
          phase: RaidPhase.error,
          message: json['error'] as String? ?? 'raid refused',
        );
        return;
      }
      _solvedAttempts.clear();
      _targetBomaId = targetBomaId; // captured for the resolve call below
      _engagedAt = DateTime.now();
      state = RaidState(
        phase: RaidPhase.engaged,
        gates: (json['gates'] as List)
            .map((g) => RaidGate.fromJson(g as Map<String, dynamic>))
            .toList(),
        timeLimitSecs: json['time_limit_secs'] as int,
        remainingSecs: json['time_limit_secs'] as int,
        energySpent: json['energy_spent'] as int,
      );
      _startWatchtower();
    } catch (e) {
      state = state.copyWith(phase: RaidPhase.error, message: '$e');
    }
  }

  /// Watchtower countdown — fence posts visually weaken as it drains.
  void _startWatchtower() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = state.remainingSecs - 1;
      if (left <= 0) {
        t.cancel();
        _resolve(withTimeout: true);
      } else {
        state = state.copyWith(remainingSecs: left);
      }
    });
  }

  /// Tap a scrambled token into the answer line.
  void tapToken(String token) {
    final gate = state.activeGate;
    if (gate == null || !gate.scrambledTokens.contains(token)) return;
    if (state.assembled.contains(token)) return; // each tile used once
    state = state.copyWith(assembled: [...state.assembled, token]);
  }

  void undoLastToken() {
    if (state.assembled.isEmpty) return;
    state = state.copyWith(
      assembled: state.assembled.sublist(0, state.assembled.length - 1),
    );
  }

  /// Submit the active gate; advance or finish.
  Future<void> submitGate() async {
    final gate = state.activeGate;
    if (gate == null) return;
    // Record the attacker's token ordering for this slot (graded server-side).
    _solvedAttempts.add(List.of(state.assembled));

    if (state.currentGate + 1 < state.gates.length) {
      state = state.copyWith(
        currentGate: state.currentGate + 1,
        assembled: const [],
      );
    } else {
      _ticker?.cancel();
      await _resolve(withTimeout: false);
    }
  }

  /// Step 2 — Resolve: server grades attempts and settles spoils.
  Future<void> _resolve({required bool withTimeout}) async {
    final attempts = <Map<String, dynamic>>[
      for (var i = 0; i < state.gates.length; i++)
        if (i < _solvedAttempts.length)
          {'slot_index': state.gates[i].slotIndex, 'tokens': _solvedAttempts[i]}
        else
          {'slot_index': state.gates[i].slotIndex, 'tokens': <String>[]},
    ];

    final duration = withTimeout
        ? state.timeLimitSecs
        : DateTime.now().difference(_engagedAt).inSeconds;

    final res = await ref.read(supabaseProvider).functions.post(
          'raid_manager',
          body: {
            'action': 'resolve',
            'target_boma_id': _targetBomaId,
            'attempts': attempts,
            'duration_secs': duration,
          },
        );
    final json = res.data as Map<String, dynamic>;
    final won = json['status'] == 'victory';
    state = state.copyWith(
      phase: won ? RaidPhase.victory : RaidPhase.repelled,
      livestockStolen: (json['livestock_stolen'] as int?) ?? 0,
      message: json['message'] as String?,
    );
  }

  /// Abandon the raid mid-minigame: burn escrow, face the defenders' trophies.
  Future<void> abort() async {
    _ticker?.cancel();
    await _resolve(withTimeout: true);
  }

  void reset() {
    _ticker?.cancel();
    state = const RaidState(phase: RaidPhase.idle);
  }
}

final raidControllerProvider = NotifierProvider<RaidController, RaidState>(
  RaidController.new,
);
