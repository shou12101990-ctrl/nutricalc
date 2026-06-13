import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/lab_schedule.dart';
import 'package:nutrition_flutter_app/clinical/refeeding.dart';

void main() {
  group('labSchedule', () {
    test('リスク無し → ベースラインのみ', () {
      final s = labSchedule();
      expect(s.length, 1);
      expect(s.first.panel.contains('電解質'), isTrue);
    });

    test('refeeding high → P/K/Mg が最上位', () {
      final s = labSchedule(refeedingTier: RefeedingTier.high);
      expect(s.first.panel, 'P / K / Mg');
      expect(s.first.priority, 0);
      expect(s.any((e) => e.panel == '血糖'), isTrue);
    });

    test('extreme + 5日以内 は1日1–2回の文言', () {
      final s = labSchedule(
          refeedingTier: RefeedingTier.extreme, daysSinceNutritionStart: 3);
      final pkmg = s.firstWhere((e) => e.panel == 'P / K / Mg');
      expect(pkmg.frequency.contains('1日1–2回'), isTrue);
    });

    test('6日目以降は頻度が下がる', () {
      final s = labSchedule(
          refeedingTier: RefeedingTier.high, daysSinceNutritionStart: 7);
      final pkmg = s.firstWhere((e) => e.panel == 'P / K / Mg');
      expect(pkmg.frequency.contains('2–3日毎'), isTrue);
    });

    test('CKRT稼働 → 微量元素/水溶性ビタミンとCu評価', () {
      final s = labSchedule(ckrtActive: true);
      expect(s.any((e) => e.panel.contains('Se')), isTrue);
      expect(s.any((e) => e.panel.contains('Cu（血清銅）')), isTrue);
    });

    test('長期PN(>=7日) → PN関連肝障害監視', () {
      final s = labSchedule(pnHeavyMaxDay: 9);
      expect(s.any((e) => e.panel.contains('肝胆道系')), isTrue);
      // 6日では出ない
      final s6 = labSchedule(pnHeavyMaxDay: 6);
      expect(s6.any((e) => e.panel.contains('肝胆道系')), isFalse);
    });

    test('priority昇順でソートされている', () {
      final s = labSchedule(
          refeedingTier: RefeedingTier.high, ckrtActive: true, pnHeavyMaxDay: 8);
      for (var i = 1; i < s.length; i++) {
        expect(s[i].priority >= s[i - 1].priority, isTrue);
      }
    });
  });
}
