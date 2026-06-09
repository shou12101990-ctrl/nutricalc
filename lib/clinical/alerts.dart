/// 栄養処方アラートエンジン（#1 評価 / #2 スコア）。Flutter非依存・純粋関数。
///
/// 役割:
/// - evaluate(): 処方の算出済み指標を制約(ConstraintSet)で評価し NutritionAlert 一覧を返す。
///     Hard違反 = severity.error（feasibility足切り）, Softズレ = warning, 評価不能 = info(dataMissing)。
/// - isFeasible(): error が1つも無ければ true（リペアで候補採用可）。
/// - softScore(): feasibleな候補同士を比較する「小さいほど良い」スカラー。
///
/// 入力(EvalContext)は「すでに算出された値」だけを持つ＝計算機の中身に依存しない。
/// これにより 個別選択・ゼロmenu・自動計算・リペアループ のどれからでも同じ評価が使える。
library;

import 'conditions.dart';
import 'constraints.dart';
import 'infusion.dart';

enum AlertSeverity { error, warning, info }

/// 1件のアラート（= 制約の評価結果）。
class NutritionAlert {
  final String code; // 'gir_limit' / 'protein_balance' など
  final AlertSeverity severity;
  final String message;
  final double? value; // 実測値
  final double? limit; // Hard上限
  final double? target; // Soft目標
  final String unit;
  final bool dataMissing; // 評価に必要なデータ/検査値が無く未評価

  const NutritionAlert({
    required this.code,
    required this.severity,
    required this.message,
    this.value,
    this.limit,
    this.target,
    this.unit = '',
    this.dataMissing = false,
  });

  bool get isError => severity == AlertSeverity.error;
  bool get isWarning => severity == AlertSeverity.warning;
}

/// 処方に含まれる1製剤分の安全評価用データ。
/// 拡張用フィールド（osmolarity/route/maxDose/rate/price）は null 可。
/// データが入った時点で対応する制約が自動で有効化される（v1は null なら静かにスキップ）。
class EvalProduct {
  final String name;
  final double mnAmountUmol; // Mn含有量（胆汁うっ滞での禁忌判定）
  final double? dailyVolumeMl; // 当該製剤の1日投与量 ml
  final double? osmolarity; // mOsm/L（末梢投与の浸透圧判定）
  final String? route; // 'central'|'peripheral'|'either'
  final double? maxDosePerDay; // 添付文書 1日最大量 ml
  final double? rateMlPerHr; // 投与速度 ml/h
  final double? maxRateMlPerHr; // 投与速度上限 ml/h
  final double? price; // コスト（将来）

  const EvalProduct({
    required this.name,
    this.mnAmountUmol = 0,
    this.dailyVolumeMl,
    this.osmolarity,
    this.route,
    this.maxDosePerDay,
    this.rateMlPerHr,
    this.maxRateMlPerHr,
    this.price,
  });
}

/// 評価コンテキスト（算出済みの実測値＋患者目標＋病態）。
class EvalContext {
  final double weightKg;
  final Set<String> conditionTags;

  // 目標
  final double targetKcal;
  final double proteinGoalPerKg;

  // 算出済み実測値
  final double totalKcal;
  final double totalProteinG;
  final double totalVolumeMl;
  final double? ivGlucoseGramPerDay; // 静脈ブドウ糖のみ（GIR用）。null=未算出
  final double? lipidGramPerDay; // 脂質 g/day。null=未算出
  final double lipidHours; // 脂質投与時間（既定24h）
  final double? npcN; // 算出済み NPC/N 比
  final double? naMEq; // 合計 Na mEq/day
  // 電解質（repair/病態制約用。null=未算出）
  final double? kMEq;
  final double? pMmol;
  final double? mgMEq;
  // ビタミン・微量元素（repair用。null=未算出）
  final double? vitaminB1Mg;
  final double? mnUmol;
  final double? cuUmol;
  final double? znUmol;
  final double? seUmol;
  // 状態フラグ（repair用）
  final bool hasGlucoseLoad; // 糖質(静脈ブドウ糖/PN/EN)投与あり
  final bool refeedingRisk;
  final bool fastingDaysGE5; // 不十分摂取≥5日
  final bool peripheralLine; // 末梢ライン投与か

  final List<EvalProduct> products;
  final double changeMagnitude; // 元処方からの変更度（リペアで設定。単独評価は0）

  const EvalContext({
    required this.weightKg,
    this.conditionTags = const {},
    required this.targetKcal,
    required this.proteinGoalPerKg,
    required this.totalKcal,
    required this.totalProteinG,
    required this.totalVolumeMl,
    this.ivGlucoseGramPerDay,
    this.lipidGramPerDay,
    this.lipidHours = 24,
    this.npcN,
    this.naMEq,
    this.kMEq,
    this.pMmol,
    this.mgMEq,
    this.vitaminB1Mg,
    this.mnUmol,
    this.cuUmol,
    this.znUmol,
    this.seUmol,
    this.hasGlucoseLoad = false,
    this.refeedingRisk = false,
    this.fastingDaysGE5 = false,
    this.peripheralLine = false,
    this.products = const [],
    this.changeMagnitude = 0,
  });

  double get targetProteinG => proteinGoalPerKg * weightKg;
  double get aaPerKg => weightKg > 0 ? totalProteinG / weightKg : 0;
}

double _absPct(double actual, double target) =>
    target == 0 ? 0 : (actual - target).abs() / target * 100;

/// 処方を制約で評価してアラート一覧を返す（決定的・順序固定）。
List<NutritionAlert> evaluate(EvalContext c, ConstraintSet cs) {
  final out = <NutritionAlert>[];
  final w = c.weightKg;
  final resolved = resolveCoeff(c.conditionTags); // 病態係数（無ければnull）
  final glucoseRestrict = resolved?.glucoseRestrict ?? false;

  // ─────────── Hard constraints（error＝足切り） ───────────

  // GIR（糖質制限病態は上限4）
  final girLimit =
      glucoseRestrict ? cs.girRestrictMgKgMin : cs.girLimitMgKgMin;
  if (c.ivGlucoseGramPerDay == null) {
    out.add(const NutritionAlert(
        code: 'gir_limit',
        severity: AlertSeverity.info,
        dataMissing: true,
        unit: 'mg/kg/min',
        message: 'GIR未評価（静脈ブドウ糖量が未算出）'));
  } else {
    final g = gir(glucoseGramPerDay: c.ivGlucoseGramPerDay!, weightKg: w);
    if (g > girLimit + 1e-9) {
      out.add(NutritionAlert(
          code: 'gir_limit',
          severity: AlertSeverity.error,
          value: g,
          limit: girLimit,
          unit: 'mg/kg/min',
          message:
              'GIR ${g.toStringAsFixed(1)} が上限 ${girLimit.toStringAsFixed(0)} mg/kg/min を超過'
              '${glucoseRestrict ? '（糖質制限病態）' : ''}'));
    }
  }

  // 脂質（1日量・速度）
  if (c.lipidGramPerDay == null) {
    out.add(const NutritionAlert(
        code: 'lipid_limit',
        severity: AlertSeverity.info,
        dataMissing: true,
        unit: 'g/kg/day',
        message: '脂質負荷未評価（脂質量が未算出）'));
  } else {
    final lpk = lipidPerDayGramPerKg(lipidGramPerDay: c.lipidGramPerDay!, weightKg: w);
    if (lpk > cs.lipidDayLimitGKgD + 1e-9) {
      out.add(NutritionAlert(
          code: 'lipid_day_limit',
          severity: AlertSeverity.error,
          value: lpk,
          limit: cs.lipidDayLimitGKgD,
          unit: 'g/kg/day',
          message:
              '脂質 ${lpk.toStringAsFixed(2)} が上限 ${cs.lipidDayLimitGKgD} g/kg/day を超過'));
    }
    final rate = lipidRatePerHour(
        lipidGramPerDay: c.lipidGramPerDay!, weightKg: w, hours: c.lipidHours);
    if (rate > cs.lipidRateLimitGKgH + 1e-9) {
      out.add(NutritionAlert(
          code: 'lipid_rate_limit',
          severity: AlertSeverity.error,
          value: rate,
          limit: cs.lipidRateLimitGKgH,
          unit: 'g/kg/h',
          message:
              '脂質速度 ${rate.toStringAsFixed(3)} が上限 ${cs.lipidRateLimitGKgH} g/kg/h を超過'));
    }
  }

  // 総液量（CRRTありで無制限化）
  final fluidCapActive =
      cs.fluidMaxEnabled && !c.conditionTags.contains('crrt');
  if (fluidCapActive && w > 0) {
    final mlkg = c.totalVolumeMl / w;
    if (mlkg > cs.fluidMaxMlKgD + 1e-9) {
      out.add(NutritionAlert(
          code: 'fluid_max',
          severity: AlertSeverity.error,
          value: mlkg,
          limit: cs.fluidMaxMlKgD,
          unit: 'ml/kg/day',
          message:
              '総液量 ${mlkg.toStringAsFixed(0)} が上限 ${cs.fluidMaxMlKgD.toStringAsFixed(0)} ml/kg/day を超過'));
    }
  }

  // 禁忌製剤: 胆汁うっ滞/胆道閉塞 × Mn含有製剤
  if (c.conditionTags.contains('cholestasis')) {
    final mnNames = c.products
        .where((p) => p.mnAmountUmol > 0)
        .map((p) => p.name)
        .toList();
    if (mnNames.isNotEmpty) {
      out.add(NutritionAlert(
          code: 'contraindicated_product',
          severity: AlertSeverity.error,
          message: '胆汁うっ滞/胆道閉塞でMn含有製剤は禁忌: ${mnNames.join('・')}'));
    }
  }

  // 末梢投与の浸透圧 / 中心専用製剤の末梢投与（拡張: データがあれば有効）
  if (c.peripheralLine) {
    for (final p in c.products) {
      if (p.route == 'central') {
        out.add(NutritionAlert(
            code: 'peripheral_forbidden',
            severity: AlertSeverity.error,
            message: '中心静脈専用製剤を末梢投与: ${p.name}'));
      }
      if (p.osmolarity != null &&
          p.osmolarity! > cs.peripheralOsmolarityLimit + 1e-9) {
        out.add(NutritionAlert(
            code: 'osmolarity_peripheral',
            severity: AlertSeverity.error,
            value: p.osmolarity,
            limit: cs.peripheralOsmolarityLimit,
            unit: 'mOsm/L',
            message:
                '末梢で浸透圧 ${p.osmolarity!.toStringAsFixed(0)} mOsm/L 超過: ${p.name}'));
      }
    }
  }

  // 製剤1日最大量 / 投与速度上限（拡張: データがあれば有効）
  for (final p in c.products) {
    if (p.maxDosePerDay != null &&
        p.dailyVolumeMl != null &&
        p.dailyVolumeMl! > p.maxDosePerDay! + 1e-9) {
      out.add(NutritionAlert(
          code: 'max_dose_per_day',
          severity: AlertSeverity.error,
          value: p.dailyVolumeMl,
          limit: p.maxDosePerDay,
          unit: 'ml/day',
          message:
              '${p.name} が1日最大量 ${p.maxDosePerDay!.toStringAsFixed(0)} ml を超過'));
    }
    if (p.maxRateMlPerHr != null &&
        p.rateMlPerHr != null &&
        p.rateMlPerHr! > p.maxRateMlPerHr! + 1e-9) {
      out.add(NutritionAlert(
          code: 'rate_max',
          severity: AlertSeverity.error,
          value: p.rateMlPerHr,
          limit: p.maxRateMlPerHr,
          unit: 'ml/h',
          message:
              '${p.name} の投与速度が上限 ${p.maxRateMlPerHr!.toStringAsFixed(0)} ml/h を超過'));
    }
  }

  // ─────────── Soft targets（warning） ───────────

  // kcal 目標からのズレ（±kcalWarnPct）
  final kcalDev = _absPct(c.totalKcal, c.targetKcal);
  if (kcalDev > cs.kcalWarnPct + 1e-9) {
    final over = c.totalKcal > c.targetKcal;
    out.add(NutritionAlert(
        code: 'kcal_dev',
        severity: AlertSeverity.warning,
        value: c.totalKcal,
        target: c.targetKcal,
        unit: 'kcal',
        message:
            'カロリーが目標 ${c.targetKcal.toStringAsFixed(0)} kcal から ${over ? '+' : '−'}${kcalDev.toStringAsFixed(0)}%（許容±${cs.kcalWarnPct.toStringAsFixed(0)}%）'));
  }

  // タンパク質バランス: AA g/kg と NPC/N を1つの warning に統合（±15%）
  final aaDev = _absPct(c.aaPerKg, c.proteinGoalPerKg);
  final npcnTarget = resolved?.npcN ?? kGeneralCoeff.npcN; // 既定 175
  final double? npcnDev =
      c.npcN == null ? null : _absPct(c.npcN!, npcnTarget);
  final aaOff = aaDev > cs.proteinWarnPct + 1e-9;
  final npcnOff = npcnDev != null && npcnDev > cs.npcnWarnPct + 1e-9;
  if (aaOff || npcnOff) {
    final parts = <String>[];
    if (aaOff) {
      parts.add(
          'AA ${c.aaPerKg.toStringAsFixed(2)} g/kg（目標 ${c.proteinGoalPerKg.toStringAsFixed(1)}±${cs.proteinWarnPct.toStringAsFixed(0)}%）');
    }
    if (npcnOff) {
      parts.add(
          'NPC/N ${c.npcN!.round()}（目標 ${npcnTarget.round()}±${cs.npcnWarnPct.toStringAsFixed(0)}%）');
    }
    out.add(NutritionAlert(
        code: 'protein_balance',
        severity: AlertSeverity.warning,
        value: c.aaPerKg,
        target: c.proteinGoalPerKg,
        unit: 'g/kg',
        message: 'タンパク質バランスが目標域外: ${parts.join(' / ')}'));
  }

  // 病態タンパク範囲: 病態が範囲を持つとき、AA g/kgが範囲外なら警告。
  //   複数病態で範囲が重ならない(衝突)なら自動決定せず conflict_alert(医師判断)。
  final pRanges = proteinRangesFor(c.conditionTags);
  if (pRanges.isNotEmpty) {
    final inter = intersectedProteinRange(c.conditionTags);
    if (inter == null) {
      out.add(NutritionAlert(
          code: 'conflict_alert',
          severity: AlertSeverity.warning,
          unit: 'g/kg',
          message:
              'タンパク目標が病態間で衝突（${pRanges.map((r) => '${r.id} ${r.proteinMinPerKg}–${r.proteinMaxPerKg}').join(' / ')}）。自動決定せず現在値を維持'));
    } else if (c.aaPerKg < inter.min - 1e-9 || c.aaPerKg > inter.max + 1e-9) {
      final over = c.aaPerKg > inter.max;
      out.add(NutritionAlert(
          code: 'protein_condition',
          severity: AlertSeverity.warning,
          value: c.aaPerKg,
          target: over ? inter.max : inter.min,
          unit: 'g/kg',
          message:
              'AA ${c.aaPerKg.toStringAsFixed(2)} g/kg が病態推奨 ${inter.min}–${inter.max} g/kg を${over ? '超過' : '下回る'}'));
    }
  }

  // Mn蓄積注意（肝不全）。胆汁うっ滞×Mn製剤は別途 hard error。
  if (c.mnUmol != null &&
      c.conditionTags.contains('liver') &&
      c.mnUmol! > 20 + 1e-9) {
    out.add(NutritionAlert(
        code: 'mn_excess',
        severity: AlertSeverity.warning,
        value: c.mnUmol,
        unit: 'μmol/day',
        message:
            'Mn ${c.mnUmol!.toStringAsFixed(0)} μmol/日。肝不全では蓄積し神経毒性。Mn-free製剤を検討'));
  }

  // 脂質 1日量の目標上限（>1.0 g/kg/day）
  if (c.lipidGramPerDay != null) {
    final lpk =
        lipidPerDayGramPerKg(lipidGramPerDay: c.lipidGramPerDay!, weightKg: w);
    if (lpk > cs.lipidDayTargetGKgD + 1e-9 &&
        lpk <= cs.lipidDayLimitGKgD + 1e-9) {
      out.add(NutritionAlert(
          code: 'lipid_day_target',
          severity: AlertSeverity.warning,
          value: lpk,
          target: cs.lipidDayTargetGKgD,
          unit: 'g/kg/day',
          message:
              '脂質 ${lpk.toStringAsFixed(2)} が目標上限 ${cs.lipidDayTargetGKgD} g/kg/day 超過'));
    }
  }

  // Na 過剰（>食塩6g=102.7 mEq）
  if (c.naMEq != null && c.naMEq! > cs.naSoftLimitMEq + 1e-9) {
    out.add(NutritionAlert(
        code: 'na_excess',
        severity: AlertSeverity.warning,
        value: c.naMEq,
        target: cs.naSoftLimitMEq,
        unit: 'mEq/day',
        message:
            'Na ${c.naMEq!.toStringAsFixed(0)} mEq/日（食塩 ${(c.naMEq! * 0.05844).toStringAsFixed(1)} g）が目標6g（102.7 mEq）超過'));
  }

  // B1(チアミン): 不十分摂取≥5日 かつ 糖質負荷 で 合計B1<200mg なら不足warning。
  //   Wernicke/refeeding予防。repairの thiamine_needed アクションが逆引きで補充する。
  if (c.fastingDaysGE5 && c.hasGlucoseLoad) {
    final b1 = c.vitaminB1Mg ?? 0;
    if (b1 < 200) {
      out.add(NutritionAlert(
          code: 'thiamine_needed',
          severity: AlertSeverity.warning,
          value: b1,
          target: 200,
          unit: 'mg',
          message:
              'ビタミンB1 ${b1.toStringAsFixed(0)}mg（糖負荷前〜10日は200–300mg推奨）。Wernicke/refeeding予防に高用量B1を追加'));
    }
  }

  return out;
}

/// Hard違反（error）が無ければ feasible。
bool isFeasible(List<NutritionAlert> alerts) =>
    !alerts.any((a) => a.severity == AlertSeverity.error);

/// feasibleな候補を比較する「小さいほど良い」スコア。
/// = warning数×W + kcal%ズレ×W + protein%ズレ×W + 製剤数×W + 変更幅×W + IN(ml/kg)×W
double softScore(EvalContext c, ConstraintSet cs, ScoreWeights weights) {
  final alerts = evaluate(c, cs);
  // warning は alert code 別の重みで加点（na_excess等を重く）。
  double warnPenalty = 0;
  for (final a in alerts) {
    if (a.severity == AlertSeverity.warning) {
      warnPenalty += weights.weightForAlert(a.code);
    }
  }
  final kcalDev = _absPct(c.totalKcal, c.targetKcal);
  final protDev = _absPct(c.totalProteinG, c.targetProteinG);
  final fluidPerKg = c.weightKg > 0 ? c.totalVolumeMl / c.weightKg : 0;
  return warnPenalty +
      weights.kcalDevPct * kcalDev +
      weights.proteinDevPct * protDev +
      weights.productCount * c.products.length +
      weights.changeMagnitude * c.changeMagnitude +
      weights.fluidPerKg * fluidPerKg;
}
