import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/alerts.dart';
import 'package:nutrition_flutter_app/clinical/constraints.dart';

/// アラートエンジン（#1 評価 / #2 スコア）のゴールデンテスト。
/// Hard=feasibility足切り(error)、Soft=warning、評価不能=info(dataMissing)。
void main() {
  final cs = ConstraintSet.standard();
  final weights = ScoreWeights.standard();

  // 体重60kg・目標1800kcal/タンパク1.5g/kg(=90g)・制約内のクリーン処方。
  EvalContext clean({
    Set<String> tags = const {},
    double totalKcal = 1800,
    double totalProteinG = 90,
    double totalVolumeMl = 2000,
    double? ivGlucose = 300, // gir≈3.5(ok)
    double? lipid = 50, // 0.83 g/kg(ok)
    double? npcN = 170, // 目標175±15%内
    double? naMEq = 80,
    bool peripheral = false,
    List<EvalProduct> products = const [
      EvalProduct(name: 'A'),
      EvalProduct(name: 'B'),
    ],
  }) =>
      EvalContext(
        weightKg: 60,
        conditionTags: tags,
        targetKcal: 1800,
        proteinGoalPerKg: 1.5,
        totalKcal: totalKcal,
        totalProteinG: totalProteinG,
        totalVolumeMl: totalVolumeMl,
        ivGlucoseGramPerDay: ivGlucose,
        lipidGramPerDay: lipid,
        npcN: npcN,
        naMEq: naMEq,
        peripheralLine: peripheral,
        products: products,
      );

  bool has(List<NutritionAlert> a, String code) => a.any((x) => x.code == code);
  NutritionAlert? find(List<NutritionAlert> a, String code) {
    for (final x in a) {
      if (x.code == code) return x;
    }
    return null;
  }

  group('クリーン処方', () {
    test('制約内なら警告ゼロ・feasible', () {
      final a = evaluate(clean(), cs);
      expect(a, isEmpty, reason: 'クリーンなのにアラート: ${a.map((e) => e.code)}');
      expect(isFeasible(a), isTrue);
    });
  });

  group('Hard constraints（error＝足切り）', () {
    test('GIR>5 → gir_limit error・infeasible', () {
      final a = evaluate(clean(ivGlucose: 500), cs); // 5.79 mg/kg/min
      expect(find(a, 'gir_limit')?.severity, AlertSeverity.error);
      expect(isFeasible(a), isFalse);
    });

    test('糖質制限病態(critical)はGIR上限4 → 400gでerror', () {
      final a = evaluate(
          clean(tags: {'critical'}, ivGlucose: 400, npcN: null), cs); // 4.63
      expect(find(a, 'gir_limit')?.severity, AlertSeverity.error);
    });

    test('脂質>1.5 g/kg/day → lipid_day_limit error', () {
      final a = evaluate(clean(lipid: 100), cs); // 1.67 g/kg
      expect(find(a, 'lipid_day_limit')?.severity, AlertSeverity.error);
      expect(isFeasible(a), isFalse);
    });

    test('総液量>80 ml/kg/day → fluid_max error', () {
      final a = evaluate(clean(totalVolumeMl: 5000), cs); // 83.3 ml/kg
      expect(find(a, 'fluid_max')?.severity, AlertSeverity.error);
    });

    test('CRRTありなら総液量上限は無効（fluid_max出ない）', () {
      final a = evaluate(clean(totalVolumeMl: 5000, tags: {'crrt'}), cs);
      expect(has(a, 'fluid_max'), isFalse);
    });

    test('胆汁うっ滞 × Mn含有製剤 → contraindicated_product error', () {
      final a = evaluate(
          clean(tags: {'cholestasis'}, products: const [
            EvalProduct(name: 'エルネオパ', mnAmountUmol: 20),
            EvalProduct(name: 'グルコース'),
          ]),
          cs);
      expect(find(a, 'contraindicated_product')?.severity, AlertSeverity.error);
    });

    test('胆汁うっ滞でもMn-free（Mn=0）なら禁忌アラート無し', () {
      final a = evaluate(
          clean(tags: {'cholestasis'}, products: const [
            EvalProduct(name: 'ボルビサール', mnAmountUmol: 0),
          ]),
          cs);
      expect(has(a, 'contraindicated_product'), isFalse);
    });
  });

  group('Soft targets（warning）', () {
    test('kcal +12% → kcal_dev warning / +6%は出ない', () {
      expect(has(evaluate(clean(totalKcal: 2016), cs), 'kcal_dev'), isTrue);
      expect(has(evaluate(clean(totalKcal: 1908), cs), 'kcal_dev'), isFalse);
    });

    test('タンパク 目標1.5に対し2.2 g/kg → protein_balance warning(1件)', () {
      final a = evaluate(clean(totalProteinG: 132), cs); // 2.2 g/kg
      final pb = a.where((x) => x.code == 'protein_balance').toList();
      expect(pb.length, 1);
      expect(pb.first.severity, AlertSeverity.warning);
    });

    test('AAは適正でもNPC/Nが大きく外れれば同じ1件で warning', () {
      final a = evaluate(clean(npcN: 300), cs); // 目標175から+71%
      final pb = a.where((x) => x.code == 'protein_balance').toList();
      expect(pb.length, 1);
    });

    test('Na>102.7(食塩6g) → na_excess warning / 90は出ない', () {
      expect(has(evaluate(clean(naMEq: 120), cs), 'na_excess'), isTrue);
      expect(has(evaluate(clean(naMEq: 90), cs), 'na_excess'), isFalse);
    });

    test('脂質 1.0<x≤1.5 は error でなく lipid_day_target warning', () {
      final a = evaluate(clean(lipid: 70), cs); // 1.167 g/kg
      expect(has(a, 'lipid_day_limit'), isFalse);
      expect(find(a, 'lipid_day_target')?.severity, AlertSeverity.warning);
    });
  });

  group('dataMissing（評価不能=info・足切りしない）', () {
    test('静脈ブドウ糖未算出 → gir_limit info・feasibleは維持', () {
      final a = evaluate(clean(ivGlucose: null), cs);
      final g = find(a, 'gir_limit');
      expect(g?.severity, AlertSeverity.info);
      expect(g?.dataMissing, isTrue);
      expect(isFeasible(a), isTrue);
    });
  });

  group('softScore（小さいほど良い）', () {
    test('クリーン: warning0 → 製剤数×10 + IN(ml/kg)×1', () {
      final s = softScore(clean(), cs, weights);
      // 2製剤×10 + (2000/60)×1 = 20 + 33.33
      expect(s, closeTo(53.33, 0.1));
    });

    test('warning1件で +1000 されスコアが悪化する', () {
      final base = softScore(clean(), cs, weights);
      final worse = softScore(clean(naMEq: 120), cs, weights); // na_excess
      expect(worse, greaterThan(base + 999));
    });
  });
}
