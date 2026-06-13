import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/en_timing.dart';

void main() {
  group('kEnTimingCriteria', () {
    test('avoid 7件 / early 12件', () {
      expect(kEnTimingCriteria.where((c) => c.group == 'avoid').length, 7);
      expect(kEnTimingCriteria.where((c) => c.group == 'early').length, 12);
    });
    test('id がユニーク', () {
      final ids = kEnTimingCriteria.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
    });
    test('enTimingCriterionById', () {
      expect(enTimingCriterionById('grv_high')?.group, 'avoid');
      expect(enTimingCriterionById('ecmo')?.group, 'early');
      expect(enTimingCriterionById('unknown'), isNull);
    });
  });

  group('enTimingRecommendation', () {
    test('該当なし → startStandard', () {
      expect(enTimingRecommendation({}), EnTimingRecommendation.startStandard);
    });
    test('avoid基準1つ → avoid', () {
      expect(enTimingRecommendation({'uncontrolled_shock'}),
          EnTimingRecommendation.avoid);
      expect(enTimingRecommendation({'grv_high'}),
          EnTimingRecommendation.avoid);
    });
    test('early基準のみ → startEarly', () {
      expect(enTimingRecommendation({'ecmo'}),
          EnTimingRecommendation.startEarly);
      expect(enTimingRecommendation({'severe_pancreatitis', 'prone'}),
          EnTimingRecommendation.startEarly);
    });
    test('avoidとearly併存 → avoid優先（安全側）', () {
      expect(enTimingRecommendation({'ecmo', 'bowel_ischemia'}),
          EnTimingRecommendation.avoid);
    });
    test('未知idは無視 → startStandard', () {
      expect(enTimingRecommendation({'foo', 'bar'}),
          EnTimingRecommendation.startStandard);
    });
  });

  group('enTimingActionText', () {
    test('各推奨で非空', () {
      for (final r in EnTimingRecommendation.values) {
        expect(enTimingActionText(r).isNotEmpty, isTrue);
      }
    });
  });
}
