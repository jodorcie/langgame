// Unit tests for the pure SM-2 engine — run with `flutter test`.
import 'package:boma/domain/srs/sm2_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = Sm2Engine();
  final t0 = DateTime(2026, 9, 27, 12);

  SrsState newborn() => SrsState.newborn(now: t0);

  group('SM-2 success path (q >= 3)', () {
    test('first good recall -> 1 day interval', () {
      final s = engine.schedule(state: newborn(), q: 4, now: t0);
      expect(s.intervalDays, 1.0);
      expect(s.repetitionCount, 1);
      expect(s.health, AnimalHealth.healthy);
      expect(s.nextReviewAt.difference(t0), const Duration(days: 1));
    });

    test('second good recall -> 6 day interval', () {
      var s = engine.schedule(state: newborn(), q: 4, now: t0);
      s = engine.schedule(state: s, q: 4, now: t0.add(const Duration(days: 1)));
      expect(s.intervalDays, 6.0);
      expect(s.repetitionCount, 2);
    });

    test('third recall compounds by ease factor', () {
      var s = engine.schedule(state: newborn(), q: 5, now: t0);
      s = engine.schedule(state: s, q: 5, now: t0);
      final efBefore = s.easeFactor; // 2.6 after two "Easy" answers
      s = engine.schedule(state: s, q: 5, now: t0);
      expect(s.intervalDays, closeTo(6 * s.easeFactor, 0.05));
      expect(s.easeFactor, greaterThan(efBefore));
    });
  });

  group('SM-2 failure path (q < 3)', () {
    test('lapse resets reps, interval and makes the animal sick', () {
      var s = engine.schedule(state: newborn(), q: 4, now: t0);
      s = engine.schedule(state: s, q: 4, now: t0);
      s = engine.schedule(state: s, q: 1, now: t0);
      expect(s.repetitionCount, 0);
      expect(s.intervalDays, 1.0);
      expect(s.health, AnimalHealth.sick);
    });

    test('ease factor floors at 1.3 under repeated failures', () {
      var s = newborn();
      for (var i = 0; i < 10; i++) {
        s = engine.schedule(state: s, q: 0, now: t0);
      }
      expect(s.easeFactor, greaterThanOrEqualTo(SrsState.minEase));
    });
  });

  test('EF canonical delta matches SM-2 formula for q=3', () {
    final s = engine.schedule(state: newborn(), q: 3, now: t0);
    expect(s.easeFactor, closeTo(2.36, 0.001)); // 2.5 + (0.1 - 2*(0.08+2*0.02))
  });
}
