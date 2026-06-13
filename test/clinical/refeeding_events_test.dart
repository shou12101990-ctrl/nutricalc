import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/refeeding_events.dart';

void main() {
  group('electrolyteDropPercent', () {
    test('30%低下', () {
      expect(electrolyteDropPercent(4.0, 2.8), closeTo(30, 1e-9));
    });
    test('上昇は0%', () {
      expect(electrolyteDropPercent(3.0, 3.5), 0);
    });
    test('baseline<=0 は0%', () {
      expect(electrolyteDropPercent(0, 1.0), 0);
      expect(electrolyteDropPercent(-1, 1.0), 0);
    });
  });

  group('rsSeverityFromDrop（境界）', () {
    test('9.9%は none', () {
      expect(rsSeverityFromDrop(9.9), RsSeverity.none);
    });
    test('10%は mild', () {
      expect(rsSeverityFromDrop(10), RsSeverity.mild);
    });
    test('19.9%は mild / 20%は moderate', () {
      expect(rsSeverityFromDrop(19.9), RsSeverity.mild);
      expect(rsSeverityFromDrop(20), RsSeverity.moderate);
    });
    test('29.9%は moderate / 30%は severe', () {
      expect(rsSeverityFromDrop(29.9), RsSeverity.moderate);
      expect(rsSeverityFromDrop(30), RsSeverity.severe);
    });
  });

  group('assessRefeedingSyndrome', () {
    test('全て正常 → none', () {
      final a = assessRefeedingSyndrome(
        phosphate: const RsLab(baseline: 3.5, current: 3.4),
        potassium: const RsLab(baseline: 4.0, current: 3.9),
      );
      expect(a.severity, RsSeverity.none);
      expect(a.hasFinding, isFalse);
    });
    test('Pが35%低下 → severe（最大重症度を採用）', () {
      final a = assessRefeedingSyndrome(
        phosphate: const RsLab(baseline: 4.0, current: 2.6), // 35%
        potassium: const RsLab(baseline: 4.0, current: 3.9), // ~2.5%
      );
      expect(a.severity, RsSeverity.severe);
      expect(a.dropPercents['P'], closeTo(35, 1e-9));
    });
    test('Kが15%低下のみ → mild', () {
      final a = assessRefeedingSyndrome(
        potassium: const RsLab(baseline: 4.0, current: 3.4), // 15%
      );
      expect(a.severity, RsSeverity.mild);
    });
    test('Mg中等度低下+臓器障害 → severe へ引き上げ', () {
      final a = assessRefeedingSyndrome(
        magnesium: const RsLab(baseline: 2.0, current: 1.55), // 22.5% moderate
        organDysfunction: true,
      );
      expect(a.severity, RsSeverity.severe);
      expect(a.organDysfunction, isTrue);
    });
    test('採血未入力でも臓器障害ありなら severe（安全側）', () {
      final a = assessRefeedingSyndrome(organDysfunction: true);
      expect(a.severity, RsSeverity.severe);
      expect(a.dropPercents, isEmpty);
    });
    test('片側のみ測定（baselineのみ）はドロップ計算しない', () {
      final a = assessRefeedingSyndrome(
        phosphate: const RsLab(baseline: 4.0), // current欠損
      );
      expect(a.severity, RsSeverity.none);
      expect(a.dropPercents, isEmpty);
    });
  });

  group('rsActionText', () {
    test('各重症度で非空', () {
      for (final s in RsSeverity.values) {
        expect(rsActionText(s).isNotEmpty, isTrue);
      }
    });
  });
}
