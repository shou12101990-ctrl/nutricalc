/// Repair Loop の基盤型と低リスク修復アクション（Flutter非依存・純粋）。
///
/// 設計（仕様書準拠）:
/// - alerts.dart は評価のみ。repair はここで alert code から逆引きして処方を補正する。
/// - 何を変えたかは必ず RepairChange として残す（医療安全＝説明可能性）。
/// - 本ファイルは「型＋低リスクな2アクション(B1追加 / Mn-free置換)」に限定。
///   候補生成・ランキング(engine)・UIは後フェーズ。
library;

import '../models/models.dart';
import 'alerts.dart';
import 'constraints.dart';

double _microOf(Map? m, String key) =>
    (m?[key] as num?)?.toDouble() ?? 0;

bool _isEnteralProduct(Product p) => p.inEnTab || p.isFood;

/// PlanState(製剤＋本数)から評価コンテキストを算出する純関数。
/// repair engine の候補再評価・ライブ評価で共通利用する（＝同じ評価器）。
/// IV glucose は「非経腸カテゴリのcarb」、hasGlucoseLoad は総carb>0。
EvalContext computeEvalContext(
  PlanState plan, {
  required double weightKg,
  required Set<String> conditionTags,
  required double targetKcal,
  required double proteinGoalPerKg,
  double lipidHours = 24,
  bool fastingDaysGE5 = false,
  bool refeedingRisk = false,
  double changeMagnitude = 0,
}) {
  double kcal = 0, prot = 0, vol = 0;
  double ivGlucoseG = 0, carbTotalG = 0, lipidG = 0;
  double na = 0, k = 0, pMmol = 0, mg = 0;
  double b1 = 0, mn = 0, cu = 0, zn = 0, se = 0;
  final evalProducts = <EvalProduct>[];
  for (final it in plan.items) {
    final pr = it.product;
    final u = it.units.toDouble();
    if (u <= 0) continue;
    kcal += (pr.kcal ?? 0) * u;
    prot += (pr.aminoAcidG ?? 0) * u;
    vol += (pr.volumeMl ?? 0) * u;
    final carb = (pr.carbBase ?? 0) * u;
    carbTotalG += carb;
    if (!_isEnteralProduct(pr)) ivGlucoseG += carb;
    lipidG += (pr.fatBase ?? 0) * u;
    final el = pr.micro?['elec'] as Map?;
    na += _microOf(el, 'Na') * u;
    k += _microOf(el, 'K') * u;
    pMmol += _microOf(el, 'P') * u;
    mg += _microOf(el, 'Mg') * u;
    final tr = pr.micro?['trace'] as Map?;
    mn += _microOf(tr, 'Mn') * u;
    cu += _microOf(tr, 'Cu') * u;
    zn += _microOf(tr, 'Zn') * u;
    se += _microOf(tr, 'Se') * u;
    b1 += _microOf(pr.micro?['vit'] as Map?, 'B1') * u;
    evalProducts.add(EvalProduct(
      name: pr.name,
      mnAmountUmol: pr.mnAmount,
      dailyVolumeMl: (pr.volumeMl ?? 0) * u,
    ));
  }
  double? npcN;
  if (prot > 0) {
    final n = prot / 6.25;
    final v = (kcal - prot * 4) / n;
    if (v.isFinite) npcN = v;
  }
  return EvalContext(
    weightKg: weightKg,
    conditionTags: conditionTags,
    targetKcal: targetKcal,
    proteinGoalPerKg: proteinGoalPerKg,
    totalKcal: kcal,
    totalProteinG: prot,
    totalVolumeMl: vol,
    ivGlucoseGramPerDay: ivGlucoseG,
    carbGramPerDay: carbTotalG,
    lipidGramPerDay: lipidG,
    lipidHours: lipidHours,
    npcN: npcN,
    naMEq: na,
    kMEq: k,
    pMmol: pMmol,
    mgMEq: mg,
    vitaminB1Mg: b1,
    mnUmol: mn,
    cuUmol: cu,
    znUmol: zn,
    seUmol: se,
    hasGlucoseLoad: carbTotalG > 0,
    refeedingRisk: refeedingRisk,
    fastingDaysGE5: fastingDaysGE5,
    products: evalProducts,
    changeMagnitude: changeMagnitude,
  );
}

/// 変更の種類。
enum RepairChangeKind { add, remove, replace, increase, decrease, cap }

/// 1件の自動補正の記録（差分説明・バッジ用）。
class RepairChange {
  final String code; // alert code (例: 'thiamine_needed')
  final String label; // バッジ表示（'補充'/'置換' など）
  final String reason; // なぜ変えたか
  final String beforeText;
  final String afterText;
  final RepairChangeKind kind;
  final bool autoApplied;
  const RepairChange({
    required this.code,
    required this.label,
    required this.reason,
    required this.beforeText,
    required this.afterText,
    required this.kind,
    this.autoApplied = true,
  });
}

/// 処方1製剤分（製剤＋本数）。Product は組成(micro)を持つので評価/差分に使える。
class PlanItem {
  final Product product;
  final int units;
  const PlanItem(this.product, this.units);
}

/// 処方状態（修復はこれを入出力にする・不変）。
class PlanState {
  final List<PlanItem> items;
  const PlanState(this.items);
}

/// 修復1手の結果（補正後プラン＋変更記録）。
class RepairResult {
  final PlanState plan;
  final List<RepairChange> changes;
  const RepairResult(this.plan, this.changes);
  bool get changed => changes.isNotEmpty;
}

/// alert code から逆引きされる修復操作。無差別探索しない。
abstract class RepairAction {
  String get id;
  String get label;
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert);
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert);
}

double _b1Mg(Product p) =>
    ((p.micro?['vit'] as Map?)?['B1'] as num?)?.toDouble() ?? 0;

/// 高用量B1を追加し、合計B1を目標mg(既定200)へ。alert: 'thiamine_needed'。
class AddVitaminB1Action implements RepairAction {
  final Product b1Product; // 高用量B1製剤(vit.B1≥50mg想定)
  final double targetMg;
  const AddVitaminB1Action(this.b1Product, {this.targetMg = 200});

  @override
  String get id => 'add_vitamin_b1';
  @override
  String get label => '補充';

  @override
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert) =>
      alert.code == 'thiamine_needed' && _b1Mg(b1Product) > 0;

  @override
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert) {
    final per = _b1Mg(b1Product);
    final cur =
        plan.items.fold<double>(0, (s, it) => s + _b1Mg(it.product) * it.units);
    if (per <= 0 || cur >= targetMg) return RepairResult(plan, const []);
    final units = ((targetMg - cur) / per).ceil().clamp(1, 10);
    final total = cur + per * units;
    return RepairResult(
      PlanState([...plan.items, PlanItem(b1Product, units)]),
      [
        RepairChange(
          code: 'thiamine_needed',
          label: '補充',
          reason: '絶食5日以上＋糖負荷のためビタミンB1を追加',
          beforeText: 'B1 ${cur.toStringAsFixed(0)}mg',
          afterText:
              'B1 ${total.toStringAsFixed(0)}mg（${b1Product.name} ×$units）',
          kind: RepairChangeKind.add,
        ),
      ],
    );
  }
}

/// Mn含有の複合微量元素を Mn-free 製剤へ置換。alert: 'contraindicated_product'。
class ReplaceMnTraceToMnFreeAction implements RepairAction {
  final Product mnFreeProduct; // Mn-free 複合微量元素
  const ReplaceMnTraceToMnFreeAction(this.mnFreeProduct);

  @override
  String get id => 'replace_mn_trace_mnfree';
  @override
  String get label => '置換';

  bool _isMnContainingTrace(Product p) =>
      p.isCombinedTrace && p.mnAmount > 0;

  @override
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert) =>
      alert.code == 'contraindicated_product' &&
      mnFreeProduct.isMnFreeTrace &&
      plan.items.any((it) => _isMnContainingTrace(it.product));

  @override
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert) {
    final mnItems =
        plan.items.where((it) => _isMnContainingTrace(it.product)).toList();
    if (mnItems.isEmpty) return RepairResult(plan, const []);
    final removedUnits = mnItems.fold<int>(0, (s, it) => s + it.units);
    final units = removedUnits > 0 ? removedUnits : 1;
    final kept =
        plan.items.where((it) => !_isMnContainingTrace(it.product)).toList();
    return RepairResult(
      PlanState([...kept, PlanItem(mnFreeProduct, units)]),
      [
        RepairChange(
          code: 'contraindicated_product',
          label: '置換',
          reason: '胆汁うっ滞/胆道閉塞のためMn含有微量元素をMn-freeへ置換',
          beforeText: mnItems.map((it) => it.product.name).join('・'),
          afterText: '${mnFreeProduct.name} ×$units',
          kind: RepairChangeKind.replace,
        ),
      ],
    );
  }
}

// ─────────── 共通ヘルパー（製剤の特定・本数変更） ───────────

double _naMEqOf(Product p) => _microOf(p.micro?['elec'] as Map?, 'Na');

/// plan 内の target 製剤の本数を newUnits に置換（0なら除去）。
PlanState _withUnits(PlanState plan, Product target, int newUnits) {
  final items = <PlanItem>[];
  for (final it in plan.items) {
    if (it.product.id == target.id) {
      if (newUnits > 0) items.add(PlanItem(it.product, newUnits));
    } else {
      items.add(it);
    }
  }
  return PlanState(items);
}

/// match する製剤のうち、weight×units が最大の item（=その指標の主寄与）。
PlanItem? _topItem(PlanState plan, bool Function(Product) match,
    double Function(Product) weight) {
  PlanItem? best;
  double bestW = -1;
  for (final it in plan.items) {
    if (!match(it.product)) continue;
    final w = weight(it.product) * it.units;
    if (w > bestW) {
      best = it;
      bestW = w;
    }
  }
  return best;
}

/// 糖液（非経腸・carb主体・AA/脂質ほぼ無し）。GIR repair の対象。
bool _isGlucoseDominant(Product p) =>
    !_isEnteralProduct(p) &&
    (p.carbBase ?? 0) > 0 &&
    (p.aminoAcidG ?? 0) <= 0.5 &&
    (p.fatBase ?? 0) <= 0.5;

bool _isLipidProduct(Product p) => (p.fatBase ?? 0) > 0;

/// 純AA寄り（AA>0・脂質≈0・carb<AA）。タンパク調整の対象。
bool _isAminoDominant(Product p) =>
    (p.aminoAcidG ?? 0) > 0 &&
    (p.fatBase ?? 0) <= 0.5 &&
    (p.carbBase ?? 0) < (p.aminoAcidG ?? 0);

// ─────────── 修復アクション（reduce系） ───────────

/// 糖質過多 → 糖液を減量して上限以下へ。alert: 'gir_limit' / 'carb_limit'。
class ReduceIvGlucoseAction implements RepairAction {
  const ReduceIvGlucoseAction();
  @override
  String get id => 'reduce_iv_glucose';
  @override
  String get label => '自動補正';

  @override
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert) =>
      (alert.code == 'gir_limit' || alert.code == 'carb_limit') &&
      _topItem(plan, _isGlucoseDominant, (p) => p.carbBase ?? 0) != null;

  @override
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert) {
    final top = _topItem(plan, _isGlucoseDominant, (p) => p.carbBase ?? 0);
    if (top == null) return RepairResult(plan, const []);
    // 超過g: gir_limit=IVブドウ糖がGIR上限超過 / carb_limit=総炭水化物が7.2g/kg/day超過
    final double excessG;
    final String reason;
    if (alert.code == 'carb_limit') {
      final limit = alert.limit ?? 7.2; // g/kg/day
      excessG = (ctx.carbGramPerDay ?? 0) - limit * ctx.weightKg;
      reason = '炭水化物上限 ${limit.toStringAsFixed(1)} g/kg/day(5mg/kg/min相当)超過のため糖液を減量';
    } else {
      final limit = alert.limit ?? 5; // mg/kg/min
      excessG = (ctx.ivGlucoseGramPerDay ?? 0) - limit * ctx.weightKg * 1440 / 1000;
      reason = 'GIR上限 ${limit.toStringAsFixed(0)} mg/kg/min 超過のため糖液を減量';
    }
    final carbPerUnit = top.product.carbBase ?? 0;
    if (carbPerUnit <= 0 || excessG <= 0) return RepairResult(plan, const []);
    final removeUnits = (excessG / carbPerUnit).ceil();
    final newUnits = (top.units - removeUnits).clamp(0, top.units);
    if (newUnits == top.units) return RepairResult(plan, const []);
    return RepairResult(_withUnits(plan, top.product, newUnits), [
      RepairChange(
        code: alert.code,
        label: '自動補正',
        reason: reason,
        beforeText: '${top.product.name} ×${top.units}',
        afterText: newUnits > 0
            ? '${top.product.name} ×$newUnits'
            : '${top.product.name} 中止',
        kind: RepairChangeKind.decrease,
      ),
    ]);
  }
}

/// 脂質過多 → 脂質を減量。alert: 'lipid_day_limit' / 'lipid_rate_limit'。
class ReduceLipidAction implements RepairAction {
  const ReduceLipidAction();
  @override
  String get id => 'reduce_lipid';
  @override
  String get label => '自動補正';

  @override
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert) =>
      (alert.code == 'lipid_day_limit' || alert.code == 'lipid_rate_limit') &&
      _topItem(plan, _isLipidProduct, (p) => p.fatBase ?? 0) != null;

  @override
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert) {
    final top = _topItem(plan, _isLipidProduct, (p) => p.fatBase ?? 0);
    if (top == null) return RepairResult(plan, const []);
    final wt = ctx.weightKg;
    final double maxG = alert.code == 'lipid_rate_limit'
        ? (alert.limit ?? 0.125) * wt * ctx.lipidHours
        : (alert.limit ?? 1.5) * wt;
    final cur = ctx.lipidGramPerDay ?? 0;
    final fatPerUnit = top.product.fatBase ?? 0;
    if (fatPerUnit <= 0 || cur <= maxG) return RepairResult(plan, const []);
    final removeUnits = ((cur - maxG) / fatPerUnit).ceil();
    final newUnits = (top.units - removeUnits).clamp(0, top.units);
    if (newUnits == top.units) return RepairResult(plan, const []);
    return RepairResult(_withUnits(plan, top.product, newUnits), [
      RepairChange(
        code: alert.code,
        label: '自動補正',
        reason: '脂質上限超過のため脂質を減量',
        beforeText: '${top.product.name} ×${top.units}',
        afterText: newUnits > 0
            ? '${top.product.name} ×$newUnits'
            : '${top.product.name} 中止',
        kind: RepairChangeKind.decrease,
      ),
    ]);
  }
}

/// Na過多 → Na含有加注を減量/除外。alert: 'na_excess'。
class ReduceNaAdditiveAction implements RepairAction {
  const ReduceNaAdditiveAction();
  @override
  String get id => 'reduce_na_additive';
  @override
  String get label => '自動補正';

  bool _isNaAdditive(Product p) => p.category == '電解質' && _naMEqOf(p) > 0;

  @override
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert) =>
      alert.code == 'na_excess' &&
      _topItem(plan, _isNaAdditive, _naMEqOf) != null;

  @override
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert) {
    final top = _topItem(plan, _isNaAdditive, _naMEqOf);
    if (top == null) return RepairResult(plan, const []);
    final target = alert.target ?? 102.7; // mEq
    final cur = ctx.naMEq ?? 0;
    final naPerUnit = _naMEqOf(top.product);
    if (naPerUnit <= 0 || cur <= target) return RepairResult(plan, const []);
    final removeUnits = ((cur - target) / naPerUnit).ceil();
    final newUnits = (top.units - removeUnits).clamp(0, top.units);
    if (newUnits == top.units) return RepairResult(plan, const []);
    return RepairResult(_withUnits(plan, top.product, newUnits), [
      RepairChange(
        code: 'na_excess',
        label: '自動補正',
        reason: 'Na過多のため Na含有加注を減量',
        beforeText: '${top.product.name} ×${top.units}',
        afterText: newUnits > 0
            ? '${top.product.name} ×$newUnits'
            : '${top.product.name} 中止',
        kind: RepairChangeKind.decrease,
      ),
    ]);
  }
}

/// タンパク過多 → 純AA製剤を減量。alert: 'protein_balance' / 'protein_condition'。
/// （不足側の追加はベース製剤側で行うため、本アクションは過量のみ扱う）
class AdjustAminoAcidAction implements RepairAction {
  const AdjustAminoAcidAction();
  @override
  String get id => 'adjust_amino_acid';
  @override
  String get label => '自動補正';

  double _targetGPerKg(EvalContext ctx, NutritionAlert alert) =>
      alert.target ?? ctx.proteinGoalPerKg;

  @override
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert) {
    if (alert.code != 'protein_balance' && alert.code != 'protein_condition') {
      return false;
    }
    final over = ctx.aaPerKg > _targetGPerKg(ctx, alert) + 1e-9;
    return over && _topItem(plan, _isAminoDominant, (p) => p.aminoAcidG ?? 0) != null;
  }

  @override
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert) {
    final top = _topItem(plan, _isAminoDominant, (p) => p.aminoAcidG ?? 0);
    if (top == null) return RepairResult(plan, const []);
    final targetG = _targetGPerKg(ctx, alert) * ctx.weightKg;
    final cur = ctx.totalProteinG;
    final aaPerUnit = top.product.aminoAcidG ?? 0;
    if (aaPerUnit <= 0 || cur <= targetG) return RepairResult(plan, const []);
    final removeUnits = ((cur - targetG) / aaPerUnit).floor();
    if (removeUnits <= 0) return RepairResult(plan, const []);
    final newUnits = (top.units - removeUnits).clamp(0, top.units);
    if (newUnits == top.units) return RepairResult(plan, const []);
    return RepairResult(_withUnits(plan, top.product, newUnits), [
      RepairChange(
        code: alert.code,
        label: '自動補正',
        reason: 'タンパク過多のため高濃度AAを減量',
        beforeText: '${top.product.name} ×${top.units}',
        afterText: newUnits > 0
            ? '${top.product.name} ×$newUnits'
            : '${top.product.name} 中止',
        kind: RepairChangeKind.decrease,
      ),
    ]);
  }
}

double _traceOf(Product p, String key) =>
    _microOf(p.micro?['trace'] as Map?, key);

/// Zn補充。alert: 'zn_needed'。標準trade未満のとき亜鉛源(Mn-free推奨)を追加。
class AddZincAction implements RepairAction {
  final Product znProduct;
  final double targetUmol;
  const AddZincAction(this.znProduct, {this.targetUmol = 45.9}); // 3mg(ESPEN PN標準下限)
  @override
  String get id => 'add_zinc';
  @override
  String get label => '補充';
  @override
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert) =>
      alert.code == 'zn_needed' && _traceOf(znProduct, 'Zn') > 0;
  @override
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert) {
    final per = _traceOf(znProduct, 'Zn');
    final cur = ctx.znUmol ?? 0;
    if (per <= 0 || cur >= targetUmol) return RepairResult(plan, const []);
    final units = ((targetUmol - cur) / per).ceil().clamp(1, 5);
    return RepairResult(
      PlanState([...plan.items, PlanItem(znProduct, units)]),
      [
        RepairChange(
          code: 'zn_needed',
          label: '補充',
          reason: '高排出消化管/創傷のZn喪失に対し亜鉛を補充',
          beforeText: 'Zn ${cur.toStringAsFixed(0)} μmol',
          afterText: '${znProduct.name} ×$units',
          kind: RepairChangeKind.add,
        ),
      ],
    );
  }
}

/// Se補充。alert: 'se_needed'。CRRT/創傷でSe不足のときセレン源を追加。
class AddSeleniumAction implements RepairAction {
  final Product seProduct;
  final double targetUmol;
  const AddSeleniumAction(this.seProduct, {this.targetUmol = 1.27}); // 100μg(欠乏時の開始量)
  @override
  String get id => 'add_selenium';
  @override
  String get label => '補充';
  @override
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert) =>
      alert.code == 'se_needed' && _traceOf(seProduct, 'Se') > 0;
  @override
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert) {
    final per = _traceOf(seProduct, 'Se');
    final cur = ctx.seUmol ?? 0;
    if (per <= 0 || cur >= targetUmol) return RepairResult(plan, const []);
    final units = ((targetUmol - cur) / per).ceil().clamp(1, 5);
    return RepairResult(
      PlanState([...plan.items, PlanItem(seProduct, units)]),
      [
        RepairChange(
          code: 'se_needed',
          label: '補充',
          reason: 'CRRT/創傷のSe喪失・需要増に対しセレンを補充',
          beforeText: 'Se ${cur.toStringAsFixed(0)} μmol',
          afterText: '${seProduct.name} ×$units',
          kind: RepairChangeKind.add,
        ),
      ],
    );
  }
}

// ─────────── レジストリ ───────────

/// alert code → RepairAction[]。注入製剤(B1/Mn-free/Zn/Se)は対象に応じて追加。
Map<String, List<RepairAction>> buildRepairActions({
  Product? b1Product,
  Product? mnFreeProduct,
  Product? znProduct,
  Product? seProduct,
}) {
  return {
    'gir_limit': const [ReduceIvGlucoseAction()],
    'carb_limit': const [ReduceIvGlucoseAction()],
    'lipid_day_limit': const [ReduceLipidAction()],
    'lipid_rate_limit': const [ReduceLipidAction()],
    'na_excess': const [ReduceNaAdditiveAction()],
    'protein_balance': const [AdjustAminoAcidAction()],
    'protein_condition': const [AdjustAminoAcidAction()],
    if (b1Product != null) 'thiamine_needed': [AddVitaminB1Action(b1Product)],
    if (mnFreeProduct != null)
      'contraindicated_product': [ReplaceMnTraceToMnFreeAction(mnFreeProduct)],
    if (znProduct != null) 'zn_needed': [AddZincAction(znProduct)],
    if (seProduct != null) 'se_needed': [AddSeleniumAction(seProduct)],
  };
}

// ─────────── エンジン（候補生成・ランキング） ───────────

/// 1候補（補正後プラン＋累積変更＋評価＋スコア）。
class RepairCandidate {
  final PlanState plan;
  final List<RepairChange> changes;
  final List<NutritionAlert> alerts;
  final double score;
  const RepairCandidate({
    required this.plan,
    required this.changes,
    required this.alerts,
    required this.score,
  });
  int get errorCount =>
      alerts.where((a) => a.severity == AlertSeverity.error).length;
  int get warningCount =>
      alerts.where((a) => a.severity == AlertSeverity.warning).length;
}

/// repair() の結果（元処方・推奨案最大3・残存警告）。
class RepairOutcome {
  final PlanState original;
  final List<NutritionAlert> originalAlerts;
  final List<RepairCandidate> recommended; // 最良先頭、最大3
  final List<NutritionAlert> unresolved; // 最良案の残存（非dataMissing）
  const RepairOutcome({
    required this.original,
    required this.originalAlerts,
    required this.recommended,
    required this.unresolved,
  });
  RepairCandidate? get best => recommended.isEmpty ? null : recommended.first;
  bool get hasRepair =>
      recommended.isNotEmpty && recommended.first.changes.isNotEmpty;
  List<RepairChange> get bestChanges => best?.changes ?? const [];
}

/// alert code から逆引き修復を試み、feasibleな候補を softScore でランキングする。
/// 無差別探索しない（最大 maxSteps step・最大 maxCandidates 候補）。
RepairOutcome repair(
  PlanState original, {
  required Map<String, List<RepairAction>> actions,
  required EvalContext Function(PlanState) evalOf,
  required ConstraintSet constraints,
  required ScoreWeights weights,
  int maxSteps = 2,
  int maxCandidates = 40,
}) {
  String keyOf(PlanState p) {
    final parts = p.items.map((i) => '${i.product.id}:${i.units}').toList()
      ..sort();
    return parts.join('|');
  }

  final seen = <String>{};
  final all = <RepairCandidate>[];
  RepairCandidate makeCand(PlanState p, List<RepairChange> ch) {
    final ctx = evalOf(p);
    final al = evaluate(ctx, constraints);
    return RepairCandidate(
        plan: p,
        changes: ch,
        alerts: al,
        score: softScore(ctx, constraints, weights));
  }

  final base = makeCand(original, const []);
  seen.add(keyOf(original));
  all.add(base);
  var frontier = <RepairCandidate>[base];
  for (var step = 0; step < maxSteps && all.length < maxCandidates; step++) {
    final next = <RepairCandidate>[];
    for (final cand in frontier) {
      final ctx = evalOf(cand.plan);
      for (final alert in cand.alerts) {
        final acts = actions[alert.code];
        if (acts == null) continue;
        for (final action in acts) {
          if (!action.canApply(cand.plan, ctx, alert)) continue;
          final res = action.apply(cand.plan, ctx, alert);
          if (!res.changed) continue;
          if (!seen.add(keyOf(res.plan))) continue;
          final c = makeCand(res.plan, [...cand.changes, ...res.changes]);
          all.add(c);
          next.add(c);
          if (all.length >= maxCandidates) break;
        }
        if (all.length >= maxCandidates) break;
      }
      if (all.length >= maxCandidates) break;
    }
    frontier = next;
    if (frontier.isEmpty) break;
  }

  final feasible = all.where((c) => isFeasible(c.alerts)).toList()
    ..sort((a, b) {
      final s = a.score.compareTo(b.score);
      if (s != 0) return s;
      return a.changes.length.compareTo(b.changes.length); // 変更が少ない方
    });
  final recommended = feasible.take(3).toList();
  final best = recommended.isNotEmpty ? recommended.first : base;
  return RepairOutcome(
    original: original,
    originalAlerts: base.alerts.where((a) => !a.dataMissing).toList(),
    recommended: recommended,
    unresolved: best.alerts.where((a) => !a.dataMissing).toList(),
  );
}
