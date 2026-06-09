/// アラート/リペアエンジンの制約パラメータ（Hard上限・Soft目標）とスコア重み。
/// Flutter非依存・純粋データ。施設別プリセットは copyWith / 名前付きコンストラクタで外挿する。
///
/// 設計（合意済み）:
/// - Hard constraints = feasibility 足切り（禁忌・絶対上限）。1つでも違反した候補は不採用。
/// - Soft targets     = 目標からのズレ＝スコア。warning を出しつつ最小化する。
/// - 病態別チューニング（NPC/N・脂質・糖質制限・タンパク範囲）は conditions.dart に集約し重複させない。
library;

import 'constants.dart';

/// Hard上限・Soft閾値の数値セット（施設プリセットの実体）。
class ConstraintSet {
  final String id;

  // ── Hard constraints（足切り＝禁忌・絶対上限）──
  final double girLimitMgKgMin; // 静脈ブドウ糖 GIR 上限（糖質制限病態は別途 girRestrictMgKgMin）
  final double girRestrictMgKgMin; // 糖質制限病態（重症/呼吸/糖尿）の GIR 上限
  final double lipidDayLimitGKgD; // 脂質 1日量上限 g/kg/day
  final double lipidRateLimitGKgH; // 脂質速度上限 g/kg/h
  final double fluidMaxMlKgD; // 総液量 上限 ml/kg/day（通常患者の禁忌上限）
  final bool fluidMaxEnabled; // false で総液量上限を無効化（施設方針）
  final double peripheralOsmolarityLimit; // 末梢投与の浸透圧上限 mOsm/L

  // ── Soft targets（目標ズレ＝スコア／warning閾値）──
  final double kcalWarnPct; // 目標kcalからの許容%（超で warning）
  final double proteinWarnPct; // 目標タンパク(AA g/kg)からの許容%
  final double npcnWarnPct; // 病態NPC/N目標からの許容%
  final double lipidDayTargetGKgD; // 脂質 1日量の目標上限 g/kg/day（超で warning）
  final double naSoftLimitMEq; // Na 過剰の warning 閾値 mEq/day（食塩6g=102.7）

  const ConstraintSet({
    required this.id,
    required this.girLimitMgKgMin,
    required this.girRestrictMgKgMin,
    required this.lipidDayLimitGKgD,
    required this.lipidRateLimitGKgH,
    required this.fluidMaxMlKgD,
    required this.fluidMaxEnabled,
    required this.peripheralOsmolarityLimit,
    required this.kcalWarnPct,
    required this.proteinWarnPct,
    required this.npcnWarnPct,
    required this.lipidDayTargetGKgD,
    required this.naSoftLimitMEq,
  });

  /// 通常成人の標準セット。数値は constants.dart（ガイドライン由来）を出所にする。
  factory ConstraintSet.standard() => const ConstraintSet(
        id: 'standard',
        girLimitMgKgMin: ClinicalConst.girLimitMgKgMin, // 5
        girRestrictMgKgMin: ClinicalConst.girWarnMgKgMin, // 4（糖質制限病態）
        lipidDayLimitGKgD: ClinicalConst.lipidDayLimitGKgD, // 1.5
        lipidRateLimitGKgH: ClinicalConst.lipidRateLimitGKgH, // 0.125
        fluidMaxMlKgD: 80, // 通常患者の禁忌上限（ゆるめ・基本はINを小さく）
        fluidMaxEnabled: true,
        peripheralOsmolarityLimit: 900, // 末梢静脈の目安上限 mOsm/L（要マスタ浸透圧データ）
        kcalWarnPct: 10,
        proteinWarnPct: 15,
        npcnWarnPct: 15,
        lipidDayTargetGKgD: ClinicalConst.lipidDayWarnGKgD, // 1.0
        naSoftLimitMEq: ClinicalConst.salt6gNaMEq, // 102.7（食塩6g）
      );

  /// 施設別/病態別オーバーライド（拡張点）。指定したフィールドだけ差し替える。
  ConstraintSet copyWith({
    String? id,
    double? girLimitMgKgMin,
    double? girRestrictMgKgMin,
    double? lipidDayLimitGKgD,
    double? lipidRateLimitGKgH,
    double? fluidMaxMlKgD,
    bool? fluidMaxEnabled,
    double? peripheralOsmolarityLimit,
    double? kcalWarnPct,
    double? proteinWarnPct,
    double? npcnWarnPct,
    double? lipidDayTargetGKgD,
    double? naSoftLimitMEq,
  }) =>
      ConstraintSet(
        id: id ?? this.id,
        girLimitMgKgMin: girLimitMgKgMin ?? this.girLimitMgKgMin,
        girRestrictMgKgMin: girRestrictMgKgMin ?? this.girRestrictMgKgMin,
        lipidDayLimitGKgD: lipidDayLimitGKgD ?? this.lipidDayLimitGKgD,
        lipidRateLimitGKgH: lipidRateLimitGKgH ?? this.lipidRateLimitGKgH,
        fluidMaxMlKgD: fluidMaxMlKgD ?? this.fluidMaxMlKgD,
        fluidMaxEnabled: fluidMaxEnabled ?? this.fluidMaxEnabled,
        peripheralOsmolarityLimit:
            peripheralOsmolarityLimit ?? this.peripheralOsmolarityLimit,
        kcalWarnPct: kcalWarnPct ?? this.kcalWarnPct,
        proteinWarnPct: proteinWarnPct ?? this.proteinWarnPct,
        npcnWarnPct: npcnWarnPct ?? this.npcnWarnPct,
        lipidDayTargetGKgD: lipidDayTargetGKgD ?? this.lipidDayTargetGKgD,
        naSoftLimitMEq: naSoftLimitMEq ?? this.naSoftLimitMEq,
      );
}

/// スコア関数の重み（施設別に差し替え可能）。
/// score = warning×W + kcal%ズレ×W + protein%ズレ×W + 製剤数×W + 変更幅×W + IN(ml/kg)×W
class ScoreWeights {
  final double warning; // soft閾値超え1件あたり
  final double kcalDevPct; // 目標kcalからの%ズレ
  final double proteinDevPct; // 目標タンパクからの%ズレ
  final double productCount; // 製剤数（処方の複雑さ）
  final double changeMagnitude; // 元処方からの変更度
  final double fluidPerKg; // IN(ml/kg/day)（小さいほど良い＝最小化圧）

  const ScoreWeights({
    required this.warning,
    required this.kcalDevPct,
    required this.proteinDevPct,
    required this.productCount,
    required this.changeMagnitude,
    required this.fluidPerKg,
  });

  factory ScoreWeights.standard() => const ScoreWeights(
        warning: 1000,
        kcalDevPct: 5,
        proteinDevPct: 5,
        productCount: 10,
        changeMagnitude: 2,
        fluidPerKg: 1,
      );
}
