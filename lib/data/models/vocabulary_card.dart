/// vocabulary_card.dart — Row model for `public.vocabulary`.
class VocabularyCard {
  const VocabularyCard({
    required this.id,
    required this.contributorId,
    required this.languageCode,
    required this.sourceText,
    required this.translatedText,
    required this.category,
    required this.status,
    required this.upvotes,
    required this.downvotes,
    this.audioUrl,
    this.createdAt,
  });

  final String id;
  final String contributorId;
  final String languageCode;
  final String sourceText;
  final String translatedText;
  final String? audioUrl;
  final String category; // livestock | flora | fauna | tools | idioms | kinship
  final String status; // pending | verified | flagged
  final int upvotes;
  final int downvotes;
  final DateTime? createdAt;

  bool get isPending => status == 'pending';
  bool get isVerified => status == 'verified';

  /// Consensus approval ratio currently on the card (for queue badges).
  double get approvalRatio {
    final total = upvotes + downvotes;
    return total == 0 ? 0 : upvotes / total;
  }

  factory VocabularyCard.fromJson(Map<String, dynamic> j) => VocabularyCard(
        id: j['id'] as String,
        contributorId: j['contributor_id'] as String,
        languageCode: j['language_code'] as String,
        sourceText: j['source_text'] as String,
        translatedText: j['translated_text'] as String,
        audioUrl: j['audio_url'] as String?,
        category: j['category'] as String,
        status: j['status'] as String,
        upvotes: j['upvotes'] as int,
        downvotes: j['downvotes'] as int,
        createdAt: j['created_at'] == null
            ? null
            : DateTime.parse(j['created_at'] as String),
      );
}
