/// 微量栄養素 3層エンジン（Flutter非依存・純粋）。handoff §11/§12/§24.4。
///
/// 「不足時にB1/Zn/Seを足す」だけでなく、3層に分離する:
///   A. Maintenance（維持カバレッジ）… 栄養療法中の全患者。green/amber/red バンド。
///   B. Additional obligation（追加義務）… 病態連動（B1/Se/Zn/Cu）。普遍ではない。
///   C. Toxicity guard（毒性ガード）… Mn（胆汁うっ滞/長期PN）。
///
/// 維持は「日々の厳密な100%一致」ではなく coverage band で評価する（§11.1）。
/// 臨床的に重要な失敗は「PN/栄養療法中の欠如・長期不足」であって日々の微差ではない。
library;

import 'source_tier.dart';

/// 維持カバレッジのバンド。
enum CoverageBand {
  green, // 充足（PN MVI/trace内蔵・full EN formula量・等価）
  amber, // 部分的/不確実（48–72h持続で警告）
  red, // 栄養療法中に明確に欠如（重大アラート）
}

/// 維持カバレッジの評価結果。
class MaintenanceCoverage {
  /// 水溶性/脂溶性ビタミン（MVI）のカバレッジ。
  final CoverageBand vitamins;

  /// 微量元素（trace elements）のカバレッジ。
  final CoverageBand traceElements;
  final String reason;
  final SourceTier sourceTier;
  const MaintenanceCoverage({
    required this.vitamins,
    required this.traceElements,
    required this.reason,
    required this.sourceTier,
  });

  /// 全体バンド（ビタミン/traceの悪い方）。後方互換・サマリ表示用。
  CoverageBand get band =>
      vitamins.index >= traceElements.index ? vitamins : traceElements;
}

/// 微量栄養素の追加義務 or 毒性ガード（1件）。
class MicronutrientObligation {
  final String nutrient; // 'thiamine'|'selenium'|'zinc'|'copper'|'manganese'
  final String action; // 'supplement_high_dose'|'monitor_review'|'prefer_mn_free'
  final String reason; // 日本語
  final SourceTier sourceTier;
  final bool requiresReview; // 高用量/長期は要再評価
  const MicronutrientObligation({
    required this.nutrient,
    required this.action,
    required this.reason,
    required this.sourceTier,
    this.requiresReview = false,
  });
}

// ─────────────── A. Maintenance（§11.1, §12, §24.4-1/2/3） ───────────────

/// 維持カバレッジを評価（ビタミン/trace を独立に判定）。
/// codexレビュー反映: PNのMVI内蔵とtrace内蔵は別々に成立しうる（例: フルカリックは
/// MVI内蔵だがtrace無し）ため `pnContainsMvi` / `pnContainsTrace` を分離。
/// - PN active で当該群が未カバー → red（重大・§24.4-1）。
/// - full EN formula 量（fraction>=fullEnFractionForGreen）→ green（維持充足・§24.4-2）。
/// - 部分EN/経口（0<fraction<full）→ amber（不確実・§24.4-3）。daysOnSupport>2 で注記。
/// [fullEnFractionForGreen]: EN量がこの割合以上で「full=維持充足」とみなす（既定1.0=満量）。
MaintenanceCoverage assessMaintenanceCoverage({
  bool pnActive = false,
  bool enActive = false,
  bool oralSupplementActive = false,
  bool pnContainsMvi = false, // 総合ビタミン内蔵/加注
  bool pnContainsTrace = false, // 微量元素内蔵/加注
  double enFormulaVolumeFraction = 0, // 0..1（1.0=full EN量）
  double oralDietMicronutrientCompleteness = 0, // 0..1
  int daysOnSupport = 0,
  double fullEnFractionForGreen = 1.0,
}) {
  final onSupport = pnActive || enActive || oralSupplementActive;
  if (!onSupport) {
    return const MaintenanceCoverage(
      vitamins: CoverageBand.green,
      traceElements: CoverageBand.green,
      reason: '医療的栄養療法なし（維持カバレッジ対象外）',
      sourceTier: SourceTier.localPolicy,
    );
  }

  // full EN/経口は維持を満たす（§24.4-2）。EN/経口は MVI/trace を一体で供給する想定。
  final fullEn = enActive && enFormulaVolumeFraction >= fullEnFractionForGreen;
  final fullOral = oralDietMicronutrientCompleteness >= 1.0;
  // 部分的に供給はあるが不確実（amber 判定用）。
  final anyPartial = (enActive && enFormulaVolumeFraction > 0) ||
      oralSupplementActive ||
      (oralDietMicronutrientCompleteness > 0);

  // 群ごとの判定。pnGroupCovered=その群がPN由来でカバーされているか。
  CoverageBand bandFor(bool pnGroupCovered) {
    if (fullEn || fullOral || pnGroupCovered) return CoverageBand.green;
    if (pnActive) return CoverageBand.red; // PN稼働中に当該群が欠如
    return anyPartial ? CoverageBand.amber : CoverageBand.red;
  }

  final vit = bandFor(pnActive && pnContainsMvi);
  final tr = bandFor(pnActive && pnContainsTrace);

  String reason;
  SourceTier tier;
  final worst = vit.index >= tr.index ? vit : tr;
  switch (worst) {
    case CoverageBand.red:
      reason = pnActive
          ? 'PN稼働中に${vit == CoverageBand.red ? 'MVI' : ''}'
              '${vit == CoverageBand.red && tr == CoverageBand.red ? '・' : ''}'
              '${tr == CoverageBand.red ? '微量元素' : ''}のカバレッジが無い（付与を）'
          : '栄養療法中に微量栄養素カバレッジが明確に欠如';
      tier = SourceTier.guidelineObligation;
      break;
    case CoverageBand.amber:
      reason = daysOnSupport > 2
          ? '部分的EN/経口で微量栄養素カバレッジが不確実（48–72h以上持続→補正を検討）'
          : '部分的EN/経口で微量栄養素カバレッジが不確実';
      tier = SourceTier.guidelineBand;
      break;
    case CoverageBand.green:
      reason = 'PNのMVI/trace内蔵 or full EN/経口量で維持カバレッジ充足';
      tier = pnActive ? SourceTier.guidelineObligation : SourceTier.guidelineBand;
      break;
  }

  return MaintenanceCoverage(
    vitamins: vit,
    traceElements: tr,
    reason: reason,
    sourceTier: tier,
  );
}

// ─────────────── B. Additional obligations（§11.2, §24.4-4/5/7） ───────────────

/// 追加微量栄養素義務（B1/Se/Zn/Cu）。病態連動・普遍ではない。
List<MicronutrientObligation> additionalMicronutrientObligations({
  // thiamine トリガー
  bool highOrExtremeRefeedingRisk = false,
  bool fastingOrPoorIntakeGe5d = false,
  bool dextroseOrHighCarbStart = false,
  bool alcoholUseDisorderOrSuspicion = false,
  bool severeMalnutrition = false,
  bool icuAdmissionWithPoorIntake = false,
  // Se/Zn 共通トリガー
  bool crrtOrSledActive = false,
  bool highOutputGiLoss = false,
  bool majorWoundOrBurn = false,
  bool measuredSeDeficiency = false,
  bool measuredZnDeficiency = false,
  bool localHighRiskCriticalIllness = false,
  // Cu
  int crrtDurationDays = 0,
  bool longTermPn = false,
  bool suspectedCuDeficiency = false,
}) {
  final out = <MicronutrientObligation>[];

  // ── Thiamine（追加・維持ではない。糖負荷前に投与） ──
  final b1Trigger = highOrExtremeRefeedingRisk ||
      fastingOrPoorIntakeGe5d ||
      dextroseOrHighCarbStart ||
      alcoholUseDisorderOrSuspicion ||
      severeMalnutrition ||
      icuAdmissionWithPoorIntake;
  if (b1Trigger) {
    out.add(const MicronutrientObligation(
      nutrient: 'thiamine',
      action: 'supplement_high_dose',
      reason: '高リスク（refeeding/絶食≥5日/糖負荷開始/アルコール/重度低栄養 等）'
          'のため高用量B1 200mg/day×10日を糖負荷・栄養開始の前に投与',
      sourceTier: SourceTier.guidelineObligation,
      requiresReview: false,
    ));
  }

  // ── Selenium（条件連動・高用量は要再評価 48–72h） ──
  final seGuidelineTrigger = crrtOrSledActive ||
      highOutputGiLoss ||
      majorWoundOrBurn ||
      measuredSeDeficiency;
  if (seGuidelineTrigger || localHighRiskCriticalIllness) {
    out.add(MicronutrientObligation(
      nutrient: 'selenium',
      action: 'supplement_high_dose',
      reason: 'CRRT/SLED・高排出消化管・熱傷/重度創傷・欠乏 等のSe喪失/需要増に対し補充'
          '（無期限高用量は避け48–72hで再評価）',
      sourceTier: seGuidelineTrigger
          ? SourceTier.guidelineBand
          : SourceTier.localPolicy,
      requiresReview: true,
    ));
  }

  // ── Zinc（条件連動・高用量は要再評価） ──
  final znTrigger = highOutputGiLoss ||
      majorWoundOrBurn ||
      measuredZnDeficiency ||
      crrtOrSledActive;
  if (znTrigger) {
    out.add(const MicronutrientObligation(
      nutrient: 'zinc',
      action: 'supplement_high_dose',
      reason: '高排出消化管・創傷/熱傷・欠乏・CRRT/SLED のZn喪失に対し補充'
          '（高用量は48–72hで再評価）',
      sourceTier: SourceTier.guidelineBand,
      requiresReview: true,
    ));
  }

  // ── Copper（モニタ/再評価。長期CRRT/長期PN/欠乏） ──
  final cuTrigger = crrtDurationDays >= 14 ||
      longTermPn ||
      highOutputGiLoss ||
      suspectedCuDeficiency;
  if (cuTrigger) {
    out.add(const MicronutrientObligation(
      nutrient: 'copper',
      action: 'monitor_review',
      reason: '長期CRRT(≥14日)/長期PN/高排出消化管/欠乏疑いでは銅のモニタ・血中銅評価を'
          '（補充は要再評価）',
      sourceTier: SourceTier.guidelineBand,
      requiresReview: true,
    ));
  }

  return out;
}

// ─────────────── C. Toxicity guard（§11.3, §24.4-6） ───────────────

/// マンガン毒性ガード。胆汁うっ滞/肝不全/長期PN/高ビリルビン/肝性脳症でリスク。
/// リスクなしなら null。
MicronutrientObligation? manganeseGuard({
  bool cholestasis = false,
  bool liverFailure = false,
  bool longTermPn = false,
  bool elevatedBilirubin = false,
  bool hepaticEncephalopathy = false,
}) {
  final risk = cholestasis ||
      liverFailure ||
      longTermPn ||
      elevatedBilirubin ||
      hepaticEncephalopathy;
  if (!risk) return null;
  return const MicronutrientObligation(
    nutrient: 'manganese',
    action: 'prefer_mn_free',
    reason: '胆汁うっ滞/肝不全/長期PN/高ビリルビン/肝性脳症ではMn蓄積(淡蒼球・神経毒性)'
        'のためMn-free微量元素を選択し、追加のMnを投与しない',
    sourceTier: SourceTier.guidelineObligation,
    requiresReview: true,
  );
}
