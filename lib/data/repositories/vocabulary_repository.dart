/// vocabulary_repository.dart — Data access for the Council review queue,
/// phrase submission (with audio upload), and the consensus Edge call.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/vocabulary_card.dart';
import '../../domain/srs/herd_controller.dart' show supabaseProvider;

class VocabularyRepository {
  const VocabularyRepository(this._db);
  final SupabaseClient _db;

  static const audioBucket = 'pronunciation-audio';

  /// Pending phrases the reviewer hasn't judged yet (oldest first).
  Future<List<VocabularyCard>> fetchReviewQueue(String reviewerId) async {
    final judged = await _db
        .from('phrase_validations')
        .select('phrase_id')
        .eq('reviewer_id', reviewerId);
    final rows = await _db
        .from('vocabulary')
        .select()
        .eq('status', 'pending')
        .neq('contributor_id', reviewerId)
        .not('id', 'in', '(${(judged.map((j) => j['phrase_id']) as List).join(",")})')
        .order('created_at')
        .limit(20);
    return rows.map(VocabularyCard.fromJson).toList();
  }

  /// Submit a new word/phrase with an optional local recording.
  /// Upload path is `<uid>/<uuid>.m4a` — enforced by Storage RLS policies.
  Future<void> submitPhrase({
    required String languageCode,
    required String sourceText,
    required String translatedText,
    required String category,
    File? audioFile,
  }) async {
    final uid = _db.auth.currentUser!.id;
    String? audioUrl;

    if (audioFile != null) {
      final ext = audioFile.path.split('.').last; // m4a | ogg
      final path = '$uid/${DateTime.now().microsecondsSinceEpoch}.$ext';
      await _db.storage.from(audioBucket).uploadBinary(
            path,
            await audioFile.readAsBytes(),
            fileOptions: FileOptions(contentType: 'audio/$ext'),
          );
      audioUrl = _db.storage.from(audioBucket).getPublicUrl(path);
    }

    await _db.from('vocabulary').insert({
      'contributor_id': uid,
      'language_code': languageCode,
      'source_text': sourceText,
      'translated_text': translatedText,
      'category': category,
      'audio_url': audioUrl,
      'status': 'pending',
    });
  }

  /// Cast an elder verdict through the consensus Edge Function.
  /// Returns true when this vote tipped the phrase into `verified`.
  Future<bool> review({
    required String phraseId,
    required bool isAccurate,
    String? notes,
  }) async {
    final res = await _db.functions.invoke(
      'review_submission',
      body: {
        'phrase_id': phraseId,
        'is_accurate': isAccurate,
        if (notes != null) 'notes': notes,
      },
    );
    return (res.data as Map<String, dynamic>)['verified'] == true;
  }
}

final vocabularyRepositoryProvider = Provider<VocabularyRepository>(
  (ref) => VocabularyRepository(ref.watch(supabaseProvider)),
);
