/// herd_animal.dart — Row model for `public.herd_animals` joined with its
/// bound vocabulary card. Bridges Postgres rows to the SM-2 [SrsState].
import '../../domain/srs/sm2_engine.dart';

class HerdAnimal {
  const HerdAnimal({
    required this.id,
    required this.bomaId,
    required this.phraseId,
    required this.animalType,
    required this.srs,
    required this.lastFedAt,
    required this.sourceText,
    required this.translatedText,
    required this.languageCode,
    this.audioUrl,
  });

  final String id;
  final String bomaId;
  final String phraseId;
  final String animalType; // 'cow' | 'goat' | 'bull' | 'calf' | 'kid'

  /// Scheduling + health state (single source of truth for sprite rendering).
  final SrsState srs;

  final DateTime lastFedAt;
  final String sourceText;
  final String translatedText;
  final String languageCode;
  final String? audioUrl;

  // Convenience delegations used by the Boma view & drill queues -------------
  DateTime get nextReviewAt => srs.nextReviewAt;
  bool get isDue => srs.isDue;
  AnimalHealth get health => srs.health;
  bool get isQuarantined => health == AnimalHealth.quarantined;
  bool get showsAlert => isDue && !isQuarantined; // "!" bubble over the sprite

  factory HerdAnimal.fromJson(Map<String, dynamic> j) {
    final vocab = (j['vocabulary'] ?? const {}) as Map<String, dynamic>;
    return HerdAnimal(
      id: j['id'] as String,
      bomaId: j['boma_id'] as String,
      phraseId: j['phrase_id'] as String,
      animalType: j['animal_type'] as String,
      lastFedAt: DateTime.parse(j['last_fed_at'] as String),
      sourceText: vocab['source_text'] as String? ?? '',
      translatedText: vocab['translated_text'] as String? ?? '',
      languageCode: vocab['language_code'] as String? ?? '',
      audioUrl: vocab['audio_url'] as String?,
      srs: SrsState(
        easeFactor: (j['ease_factor'] as num).toDouble(),
        intervalDays: (j['interval_days'] as num).toDouble(),
        repetitionCount: (j['repetition_count'] as num).toInt(),
        nextReviewAt: DateTime.parse(j['next_review_at'] as String),
        health: AnimalHealth.values.byName(j['health_status'] as String),
      ),
    );
  }
}
