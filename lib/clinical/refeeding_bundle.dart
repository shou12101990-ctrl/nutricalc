/// Refeeding バンドル（Flutter非依存・純粋）。handoff §10/§24.3。
///
/// 既存の「B1のみ + kcal cap」を、NICE/ASPEN の refeeding バンドルへ拡張・集約する:
///   - risk tier（refeeding.dart を再利用）
///   - energy cap schedule（refeeding.dart の ramp を再利用）
///   - thiamine（糖負荷/栄養開始前。micronutrient_obligations と整合）
///   - P/K/Mg のベースライン採血・高リスク初期頻回モニタ
///   - 電解質補充（低値/低下時）
///   - MVI/trace 維持カバレッジ必須
///   - 水分（IO/体重）モニタ
///   - イベント連動再評価（refeeding hypophosphatemia = clinical_event 側）
///
/// 本モジュールは「集約と説明」を担い、判定の一次ロジックは既存純モジュールに委ねる。
library;

import 'refeeding.dart';
import 'source_tier.dart';

/// 採血モニタの推奨頻度。
class RefeedingMonitorPlan {
  final List<String> baselineLabs; // 投与前ベースライン必須
  final String highRiskFirst72h; // 高リスク初期72h
  final String firstWeek; // 第1週
  final bool alertIfMissingLabs; // ベースライン欠落でアラート
  const RefeedingMonitorPlan({
    required this.baselineLabs,
    required this.highRiskFirst72h,
    required this.firstWeek,
    required this.alertIfMissingLabs,
  });
}

/// Refeeding バンドル全体（説明可能な集約結果）。
class RefeedingBundle {
  final RefeedingTier tier;
  final SourceTier sourceTier;

  /// kcal/kg/day 漸増スケジュール（cap）。配列長=漸増日数、超過後は full 維持。
  final List<double> kcalPerKgRamp;

  /// cap に含めるべきカロリー源（§10 cap_includes・二重計上しない台帳の対象）。
  final List<String> capIncludes;

  /// チアミン（糖負荷/栄養開始前に投与）。
  final bool thiamineRequired;
  final double thiamineDoseMgPerDay;
  final int thiamineDurationDays;

  final RefeedingMonitorPlan monitor;

  /// 電解質補充（低値/低下時）。
  final List<String> electrolyteRepletion; // ['phosphate','potassium','magnesium']

  /// MVI/trace 維持カバレッジ必須。
  final bool mviTraceMaintenanceRequired;

  /// 水分（IO/体重）モニタ。
  final bool fluidMonitoring;

  const RefeedingBundle({
    required this.tier,
    required this.sourceTier,
    required this.kcalPerKgRamp,
    required this.capIncludes,
    required this.thiamineRequired,
    required this.thiamineDoseMgPerDay,
    required this.thiamineDurationDays,
    required this.monitor,
    required this.electrolyteRepletion,
    required this.mviTraceMaintenanceRequired,
    required this.fluidMonitoring,
  });

  bool get isActive => tier != RefeedingTier.none;
}

/// refeeding cap に算入すべきカロリー源（§10 cap_includes）。
/// 二重計上回避のため、derived plan 側では「製剤kcalに既に含まれるもの」と
/// 「別途入力の非栄養カロリー(propofol/KRT液)」を1つの台帳で1回ずつ数える。
const List<String> kRefeedingCapIncludes = [
  'PN',
  'EN',
  'oral',
  'amino_acid_solution_calories',
  'dextrose_iv_fluids',
  'propofol_if_entered',
  'krt_solution_calories_if_entered',
];

/// リスク階層と要求量から refeeding バンドルを構築。
/// [fullKcalPerKg] は最終要求量（kcal/kg/day）。
RefeedingBundle buildRefeedingBundle({
  required RefeedingTier tier,
  double fullKcalPerKg = 25,
  double thiamineDoseMgPerDay = 200,
  int thiamineDurationDays = 10,
}) {
  final highRisk = tier != RefeedingTier.none;
  return RefeedingBundle(
    tier: tier,
    sourceTier: SourceTier.guidelineObligation,
    kcalPerKgRamp: refeedingKcalPerKgRamp(tier, fullKcalPerKg),
    capIncludes: kRefeedingCapIncludes,
    thiamineRequired: highRisk,
    thiamineDoseMgPerDay: thiamineDoseMgPerDay,
    thiamineDurationDays: thiamineDurationDays,
    monitor: RefeedingMonitorPlan(
      baselineLabs: const ['phosphate', 'potassium', 'magnesium'],
      highRiskFirst72h:
          tier == RefeedingTier.extreme ? 'q12h以上（超高リスク・心電図監視）' : 'q12h以上',
      firstWeek: '毎日',
      alertIfMissingLabs: highRisk,
    ),
    electrolyteRepletion: const ['phosphate', 'potassium', 'magnesium'],
    mviTraceMaintenanceRequired: highRisk,
    fluidMonitoring: highRisk,
  );
}
