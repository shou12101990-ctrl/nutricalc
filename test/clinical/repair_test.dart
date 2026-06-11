import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/alerts.dart';
import 'package:nutrition_flutter_app/clinical/constraints.dart';
import 'package:nutrition_flutter_app/clinical/repair.dart';
import 'package:nutrition_flutter_app/models/models.dart';

/// Repair Loop 基盤: thiamine_needed 評価 + 低リスク2アクション(B1追加 / Mn-free置換)。
void main() {
  Product mk(String name, String cat, Map<String, dynamic> micro) =>
      Product.fromMap({
        'id': name,
        'category': cat,
        'name': name,
        'micro': micro,
      });

  final b1Prod = mk('ビタメジン静注用', 'ビタミン', {
    'vit': {'B1': 100}
  });
  final mnTrace = mk('エレメンミック注', '微量元素', {
    'trace': {'Zn': 60, 'Cu': 5, 'Mn': 20}
  });
  final mnFree = mk('ボルビサール注', '微量元素', {
    'trace': {'Zn': 60, 'Cu': 5, 'Mn': 0}
  });

  const baseCtx = EvalContext(
    weightKg: 60,
    targetKcal: 1500,
    proteinGoalPerKg: 1.2,
    totalKcal: 1500,
    totalProteinG: 72,
    totalVolumeMl: 2000,
  );

  group('evaluate: thiamine_needed', () {
    final cs = ConstraintSet.standard();
    bool hasThiamine(EvalContext c) =>
        evaluate(c, cs).any((a) => a.code == 'thiamine_needed');

    test('絶食≥5日+糖負荷+B1<200 → thiamine_needed', () {
      expect(
          hasThiamine(const EvalContext(
            weightKg: 60,
            targetKcal: 1500,
            proteinGoalPerKg: 1.2,
            totalKcal: 1500,
            totalProteinG: 72,
            totalVolumeMl: 2000,
            fastingDaysGE5: true,
            hasGlucoseLoad: true,
            vitaminB1Mg: 0,
          )),
          isTrue);
    });

    test('B1≥200 → 出ない', () {
      expect(
          hasThiamine(const EvalContext(
            weightKg: 60,
            targetKcal: 1500,
            proteinGoalPerKg: 1.2,
            totalKcal: 1500,
            totalProteinG: 72,
            totalVolumeMl: 2000,
            fastingDaysGE5: true,
            hasGlucoseLoad: true,
            vitaminB1Mg: 200,
          )),
          isFalse);
    });

    test('絶食<5日 → 出ない', () {
      expect(
          hasThiamine(const EvalContext(
            weightKg: 60,
            targetKcal: 1500,
            proteinGoalPerKg: 1.2,
            totalKcal: 1500,
            totalProteinG: 72,
            totalVolumeMl: 2000,
            fastingDaysGE5: false,
            hasGlucoseLoad: true,
            vitaminB1Mg: 0,
          )),
          isFalse);
    });
  });

  group('AddVitaminB1Action', () {
    const alert = NutritionAlert(
        code: 'thiamine_needed', severity: AlertSeverity.warning, message: '');
    final action = AddVitaminB1Action(b1Prod);

    test('B1=0 → 100mg製剤2本(=200mg)を追加(kind=add)', () {
      final plan = const PlanState([]);
      expect(action.canApply(plan, baseCtx, alert), isTrue);
      final r = action.apply(plan, baseCtx, alert);
      expect(r.changed, isTrue);
      final b1 = r.plan.items
          .where((i) => i.product.name == 'ビタメジン静注用')
          .fold<int>(0, (s, i) => s + i.units);
      expect(b1, 2);
      expect(r.changes.single.kind, RepairChangeKind.add);
      expect(r.changes.single.label, '補充');
    });

    test('既に200mg → 変更なし', () {
      final plan = PlanState([PlanItem(b1Prod, 2)]); // 200mg
      final r = action.apply(plan, baseCtx, alert);
      expect(r.changed, isFalse);
    });
  });

  group('ReplaceMnTraceToMnFreeAction', () {
    const alert = NutritionAlert(
        code: 'contraindicated_product',
        severity: AlertSeverity.error,
        message: '');
    final action = ReplaceMnTraceToMnFreeAction(mnFree);

    test('Mn含有trace → Mn-freeへ置換(kind=replace)', () {
      final plan = PlanState([PlanItem(mnTrace, 1)]);
      expect(action.canApply(plan, baseCtx, alert), isTrue);
      final r = action.apply(plan, baseCtx, alert);
      expect(r.plan.items.any((i) => i.product.name == 'エレメンミック注'), isFalse,
          reason: 'Mn含有が残存');
      expect(r.plan.items.any((i) => i.product.name == 'ボルビサール注'), isTrue,
          reason: 'Mn-freeへ置換されていない');
      expect(r.changes.single.kind, RepairChangeKind.replace);
    });

    test('Mn含有traceなし → canApply false', () {
      final plan = PlanState([PlanItem(mnFree, 1)]);
      expect(action.canApply(plan, baseCtx, alert), isFalse);
    });
  });

  group('repair engine (候補生成・ランキング)', () {
    // 70%グルコース: 1本=carb70g/280kcal/100ml(非経腸=IV glucose)
    final glu = Product.fromMap({
      'id': 'glu',
      'category': 'PPN',
      'name': '70%グルコース',
      'carb_g_or_kcal_basis': 70,
      'kcal': 280,
      'volume_ml': 100,
    });
    // Na含有加注(電解質): 1本=Na 50mEq
    final naAdd = mk('10%NaCl', '電解質', {
      'elec': {'Na': 50}
    });
    final cs = ConstraintSet.standard();
    final w = ScoreWeights.standard();

    test('シナリオ: 胆汁うっ滞×Mn → Mn-free置換で禁忌(error)解消', () {
      final actions = buildRepairActions(mnFreeProduct: mnFree);
      final original = PlanState([PlanItem(mnTrace, 1)]);
      EvalContext evalOf(PlanState p) => computeEvalContext(p,
          weightKg: 60,
          conditionTags: {'cholestasis'},
          targetKcal: 1500,
          proteinGoalPerKg: 1.2);
      final o = repair(original,
          actions: actions, evalOf: evalOf, constraints: cs, weights: w);
      expect(o.originalAlerts.any((a) => a.code == 'contraindicated_product'),
          isTrue);
      expect(o.hasRepair, isTrue);
      expect(o.best!.errorCount, 0);
      expect(o.best!.plan.items.any((i) => i.product.name == 'ボルビサール注'),
          isTrue);
    });

    test('シナリオ: 絶食5日+糖負荷+B1なし → B1追加でthiamine解消', () {
      final actions = buildRepairActions(b1Product: b1Prod);
      final original = PlanState([PlanItem(glu, 3)]); // carb 210g
      EvalContext evalOf(PlanState p) => computeEvalContext(p,
          weightKg: 60,
          conditionTags: const {},
          targetKcal: 1500,
          proteinGoalPerKg: 1.2,
          fastingDaysGE5: true);
      final o = repair(original,
          actions: actions, evalOf: evalOf, constraints: cs, weights: w);
      expect(o.originalAlerts.any((a) => a.code == 'thiamine_needed'), isTrue);
      expect(o.hasRepair, isTrue);
      expect(o.best!.alerts.any((a) => a.code == 'thiamine_needed'), isFalse);
    });

    test('シナリオ: GIR超過 → 糖液減量でGIR上限以下(error解消)', () {
      final actions = buildRepairActions();
      final original = PlanState([PlanItem(glu, 7)]); // 490g → GIR≈5.67
      EvalContext evalOf(PlanState p) => computeEvalContext(p,
          weightKg: 60,
          conditionTags: const {},
          targetKcal: 2000,
          proteinGoalPerKg: 1.2);
      final o = repair(original,
          actions: actions, evalOf: evalOf, constraints: cs, weights: w);
      expect(
          o.originalAlerts.any((a) =>
              a.code == 'gir_limit' && a.severity == AlertSeverity.error),
          isTrue);
      expect(o.hasRepair, isTrue);
      expect(o.best!.errorCount, 0);
    });

    test('シナリオ: Na過多 → Na加注減量(na_excess軽減)', () {
      final actions = buildRepairActions();
      final original = PlanState([PlanItem(naAdd, 4)]); // Na 200mEq
      EvalContext evalOf(PlanState p) => computeEvalContext(p,
          weightKg: 60,
          conditionTags: const {},
          targetKcal: 1500,
          proteinGoalPerKg: 1.2);
      final o = repair(original,
          actions: actions, evalOf: evalOf, constraints: cs, weights: w);
      expect(o.originalAlerts.any((a) => a.code == 'na_excess'), isTrue);
      expect(o.hasRepair, isTrue);
      final naMEq = computeEvalContext(o.best!.plan,
              weightKg: 60,
              conditionTags: const {},
              targetKcal: 1500,
              proteinGoalPerKg: 1.2)
          .naMEq!;
      expect(naMEq, lessThan(200));
    });

    test('シナリオ: 腎保存期+重症 → ESPEN腎GLで1.0→1.3に解決(conflictにしない)', () {
      final ctx = computeEvalContext(const PlanState([]),
          weightKg: 60,
          conditionTags: {'renal', 'critical'},
          targetKcal: 1500,
          proteinGoalPerKg: 1.2);
      final alerts = evaluate(ctx, cs);
      // マトリクスが衝突を解決するため conflict_alert は出さない
      expect(alerts.any((a) => a.code == 'conflict_alert'), isFalse);
      // 0蛋白(空プラン)なので推奨1.0–1.3を下回り protein_condition
      expect(alerts.any((a) => a.code == 'protein_condition'), isTrue);
    });

    test('シナリオ: CRRT+Seなし → セレン補充で se_needed 解消', () {
      final seProd = mk('アセレンド注', '微量元素', {
        'trace': {'Se': 1.27} // 100µg/本(マスタ単位μmol)
      });
      final actions = buildRepairActions(seProduct: seProd);
      EvalContext evalOf(PlanState p) => computeEvalContext(p,
          weightKg: 60,
          conditionTags: {'crrt'},
          targetKcal: 1500,
          proteinGoalPerKg: 1.2);
      final o = repair(const PlanState([]),
          actions: actions, evalOf: evalOf, constraints: cs, weights: w);
      expect(o.originalAlerts.any((a) => a.code == 'se_needed'), isTrue);
      expect(o.hasRepair, isTrue);
      expect(o.best!.alerts.any((a) => a.code == 'se_needed'), isFalse);
    });

    test('シナリオ: 高排出消化管+Znなし → 亜鉛補充で zn_needed 解消', () {
      final actions = buildRepairActions(znProduct: mnFree); // Mn-free(Zn60)
      EvalContext evalOf(PlanState p) => computeEvalContext(p,
          weightKg: 60,
          conditionTags: {'gi_loss'},
          targetKcal: 1500,
          proteinGoalPerKg: 1.2);
      final o = repair(const PlanState([]),
          actions: actions, evalOf: evalOf, constraints: cs, weights: w);
      expect(o.originalAlerts.any((a) => a.code == 'zn_needed'), isTrue);
      expect(o.hasRepair, isTrue);
      expect(o.best!.alerts.any((a) => a.code == 'zn_needed'), isFalse);
    });
  });
}
