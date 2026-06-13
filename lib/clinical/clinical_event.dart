/// 臨床イベント型と効果プロファイル（Flutter非依存・純粋）。
///
/// handoff §13（Clinical Event Overlay Engine）, §14（Event Priority）,
/// §15（Required Clinical Events）, §16（RRT/SLED/CRRT）。
///
/// 設計意図（§0, §2, §13）:
/// - 固定フェーズテンプレートは「上書きしない」。イベントはテンプレートの上に
///   重ねて derived plan を生成するための modifier を提供する。
/// - 同一入力 → 同一出力（決定論的）。実行時にLLM推論を使わない。
///
/// 既存 conditions.dart の `RrtType{none,intermittent,continuous}` とは別概念。
/// こちらはユーザー入力イベントとしての3モダリティ `RrtModality{irrt,sled,crrt}`
/// を扱う（§16.1 ユーザー向けは IRRT/SLED/CRRT の3択のみ。CVVH等は出さない）。
library;

import 'source_tier.dart';

// ─────────────── 効果プロファイル（§13.1 effect_profile） ───────────────

/// 投与経路への効果。
enum RouteEffect {
  none,
  holdEn, // EN を固定速度で保持
  reduceEn, // EN 減量
  npo, // 禁食（EN/経口停止）
  pnOnly, // PN のみ許可
  enToPostpyloric, // 幽門後(空腸)へ切替
  oralHold, // 経口のみ停止
}

/// エネルギー目標への効果。
enum EnergyEffect {
  none,
  cap, // 上限でcap
  reducePercent, // %減
  restartRefeedingRamp, // refeeding ランプを再スタート
  restrictFor48h, // 48h エネルギー制限（refeeding hypophosphatemia）
}

/// タンパク目標への効果。
enum ProteinEffect {
  none,
  renalRestrict, // 安定非透析CKDの保存的制限
  krtTarget, // 間欠KRT(IRRT)バンド
  sledTarget, // SLED/PIKRT-likeバンド
  crrtTarget, // CRRT/CKRTバンド
  reviewOnly, // 自動変更せず再評価のみ
}

/// 水分制約への効果。
enum FluidEffect {
  none,
  cap, // 単純上限
  liberalizeWithCrrt, // CRRT下で緩和
  strictBalance, // 厳格バランス
  netBalanceAware, // 正味バランス考慮（CRRT）
}

/// 電解質への効果。
enum ElectrolyteEffect {
  none,
  monitor, // モニタ強化
  supplement, // 補充（低値/低下時）
  dialysisFluidReview, // 透析液組成の確認
}

/// 微量栄養素への効果（複数同時に成立しうる→集合で集約）。
enum MicronutrientEffect {
  none,
  maintenanceRequired, // 維持カバレッジ必須
  additionalObligation, // 追加義務（B1/Se/Zn/Cu）
  toxicityGuard, // 毒性ガード（Mn）
}

/// 製剤フィルタへの効果（複数同時に成立しうる→集合で集約）。
enum ProductFilterEffect {
  none,
  excludeEnteral, // 経腸/経口を除外（NOMI等）
  mnFreeTrace, // Mn-free 微量元素
  highProteinFormula, // 高タンパク製剤
  renalFormula, // 腎不全用製剤
  semiSolid, // 半固形/とろみ
  energyDenseLowVolume, // 高濃度・低容量（水分制限）
}

/// イベント重症度。
enum EventSeverity { mild, moderate, severe }

/// RRT モダリティ（ユーザー向け3択・§16.1）。
enum RrtModality { irrt, sled, crrt }

extension RrtModalityMeta on RrtModality {
  String get key => switch (this) {
        RrtModality.irrt => 'IRRT',
        RrtModality.sled => 'SLED',
        RrtModality.crrt => 'CRRT',
      };

  String get label => switch (this) {
        RrtModality.irrt => '間欠透析 (IRRT)',
        RrtModality.sled => 'SLED (長時間低効率/PIKRT様)',
        RrtModality.crrt => '持続透析 (CRRT)',
      };

  /// タンパク目標バンド g/kg/day（§16.3–16.5）。
  /// IRRT 1.3–1.5 / SLED 1.5–1.7（CRRT寄り）/ CRRT 1.5–1.7。
  ({double min, double max}) get proteinBand => switch (this) {
        RrtModality.irrt => (min: 1.3, max: 1.5),
        RrtModality.sled => (min: 1.5, max: 1.7),
        RrtModality.crrt => (min: 1.5, max: 1.7),
      };

  /// 微量栄養素喪失リスク（§16）。
  String get micronutrientLossRisk => switch (this) {
        RrtModality.irrt => 'moderate',
        RrtModality.sled => 'moderate_to_high',
        RrtModality.crrt => 'high',
      };

  /// このモダリティが安定非透析CKDの保存的タンパク制限を抑制するか（§7,§16）。
  /// SLED/CRRT は抑制。IRRT も活動中はKRTバンドが支配（制限しない）。
  bool get suppressesStableCkdRestriction => true;

  /// EffectProfile 用の ProteinEffect。
  ProteinEffect get proteinEffect => switch (this) {
        RrtModality.irrt => ProteinEffect.krtTarget,
        RrtModality.sled => ProteinEffect.sledTarget,
        RrtModality.crrt => ProteinEffect.crrtTarget,
      };
}

/// 効果プロファイル（§13.1）。既定は全て none。
class EffectProfile {
  final RouteEffect route;
  final EnergyEffect energy;
  final ProteinEffect protein;
  final FluidEffect fluid;
  final ElectrolyteEffect electrolyte;
  final Set<MicronutrientEffect> micronutrient;
  final Set<ProductFilterEffect> productFilter;
  const EffectProfile({
    this.route = RouteEffect.none,
    this.energy = EnergyEffect.none,
    this.protein = ProteinEffect.none,
    this.fluid = FluidEffect.none,
    this.electrolyte = ElectrolyteEffect.none,
    this.micronutrient = const {},
    this.productFilter = const {},
  });
}

// ─────────────── 臨床イベント（§13.1, §15, §16） ───────────────

/// 臨床イベント種別（§15 + RRT §16）。
enum ClinicalEventType {
  enHold, // §15.1
  enIntolerance, // §15.2
  recurrentNpo, // §15.3
  refeedingHypophosphatemia, // §15.5
  bunRiseAfterFeeding, // §15.6
  cholestasisOrLiverDysfunction, // §15.7
  fluidOverload, // §15.8
  rrtStart, // §16.2（モダリティ別に開始＋期間。切替は別モダリティの開始で表現）
}

/// 1件の臨床イベント。day は栄養開始起算の 1-based Day index。
/// endDay==null は open-ended（§13 末尾・§16.2: 生成タイムライン終端まで継続）。
class ClinicalEvent {
  final String id;
  final ClinicalEventType type;
  final int startDay;
  final int? endDay;
  final EventSeverity severity;
  final SourceTier sourceTier;
  final RrtModality? rrtModality; // rrtStart のとき
  final Map<String, Object?> parameters;
  final String explanation;
  final int? priorityOverride; // 既定優先度を上書きしたい場合

  const ClinicalEvent({
    required this.id,
    required this.type,
    required this.startDay,
    this.endDay,
    this.severity = EventSeverity.moderate,
    this.sourceTier = SourceTier.userInputEvent,
    this.rrtModality,
    this.parameters = const {},
    this.explanation = '',
    this.priorityOverride,
  });

  factory ClinicalEvent.fromMap(Map<String, dynamic> map) {
    return ClinicalEvent(
      id: _stringValue(map['id']) ?? '',
      type: _clinicalEventTypeFromValue(map['type']),
      startDay: _intValue(map['startDay']) ?? 1,
      endDay: _intValue(map['endDay']),
      severity: _eventSeverityFromValue(map['severity']),
      sourceTier: _sourceTierFromValue(map['sourceTier']),
      rrtModality: _rrtModalityFromValue(map['rrtModality']),
      parameters: _objectMapValue(map['parameters']),
      explanation: _stringValue(map['explanation']) ?? '',
      priorityOverride: _intValue(map['priorityOverride']),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type.name,
        'startDay': startDay,
        'endDay': endDay,
        'severity': severity.name,
        'sourceTier': sourceTier.key,
        'rrtModality': rrtModality?.key,
        'parameters': Map<String, Object?>.from(parameters),
        'explanation': explanation,
        'priorityOverride': priorityOverride,
      };

  /// open-ended（停止日未入力）か。
  bool get isOpenEnded => endDay == null;

  /// 指定 Day（1-based）でこのイベントが有効か。
  /// endDay 未設定（null）は open-ended（タイムライン終端まで継続）。
  bool isActiveOnDay(int day) {
    if (day < startDay) return false;
    if (endDay == null) return true; // open-ended
    return day <= endDay!;
  }

  /// 安全上の適用順（小さいほど先＝より制限的・§14）。
  int get priority => priorityOverride ?? defaultPriorityFor(type);

  /// このイベントの効果プロファイル（§15/§16 のマッピング）。
  EffectProfile get effectProfile => defaultEffectProfileFor(this);
}

ClinicalEventType _clinicalEventTypeFromValue(Object? value) {
  final key = _stringValue(value);
  for (final t in ClinicalEventType.values) {
    if (t.name == key) return t;
  }
  throw ArgumentError.value(value, 'type', 'Unknown ClinicalEventType');
}

EventSeverity _eventSeverityFromValue(Object? value) {
  final key = _stringValue(value);
  for (final s in EventSeverity.values) {
    if (s.name == key) return s;
  }
  return EventSeverity.moderate;
}

SourceTier _sourceTierFromValue(Object? value) {
  final key = _stringValue(value);
  if (key == null) return SourceTier.userInputEvent;

  final fromKey = sourceTierFromKey(key);
  if (fromKey != null) return fromKey;

  for (final t in SourceTier.values) {
    if (t.name == key) return t;
  }
  return SourceTier.userInputEvent;
}

RrtModality? _rrtModalityFromValue(Object? value) {
  final key = _stringValue(value);
  if (key == null) return null;
  for (final m in RrtModality.values) {
    if (m.key == key || m.name == key || m.key.toLowerCase() == key) return m;
  }
  return null;
}

String? _stringValue(Object? value) => value is String ? value : null;

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

Map<String, Object?> _objectMapValue(Object? value) {
  if (value is! Map) return const {};

  return value.map((key, value) => MapEntry(key.toString(), value));
}

/// §14 の優先順位（小さいほど先に適用＝より制限的）。
int defaultPriorityFor(ClinicalEventType type) => switch (type) {
      // 1: refeeding（重度電解質異常）/ NPO（経路遮断・最も制限的）
      ClinicalEventType.refeedingHypophosphatemia => 1,
      ClinicalEventType.recurrentNpo => 1,
      // 3: RRT/SLED/CRRT 稼働区間
      ClinicalEventType.rrtStart => 3,
      // 4: 溢水/ショック/高昇圧
      ClinicalEventType.fluidOverload => 4,
      // 5: 肝障害/胆汁うっ滞/高TG
      ClinicalEventType.cholestasisOrLiverDysfunction => 5,
      // 6: EN不耐/嘔吐/高GRV
      ClinicalEventType.enIntolerance => 6,
      // 7: EN hold
      ClinicalEventType.enHold => 7,
      // 8: 腎タンパク修飾（BUN上昇後の見直し）
      ClinicalEventType.bunRiseAfterFeeding => 8,
    };

/// §15/§16 に基づく既定 EffectProfile。
EffectProfile defaultEffectProfileFor(ClinicalEvent e) {
  switch (e.type) {
    case ClinicalEventType.enHold: // §15.1
      return const EffectProfile(
        route: RouteEffect.holdEn,
        energy: EnergyEffect.cap, // EN hold + 補充で cap
        micronutrient: {MicronutrientEffect.maintenanceRequired},
      );
    case ClinicalEventType.enIntolerance: // §15.2
      return const EffectProfile(
        route: RouteEffect.reduceEn,
        micronutrient: {MicronutrientEffect.maintenanceRequired},
      );
    case ClinicalEventType.recurrentNpo: // §15.3
      return const EffectProfile(
        route: RouteEffect.npo,
        energy: EnergyEffect.reducePercent,
        productFilter: {ProductFilterEffect.excludeEnteral},
        micronutrient: {MicronutrientEffect.maintenanceRequired},
      );
    case ClinicalEventType.refeedingHypophosphatemia: // §15.5
      return const EffectProfile(
        energy: EnergyEffect.restrictFor48h,
        electrolyte: ElectrolyteEffect.supplement,
        micronutrient: {MicronutrientEffect.maintenanceRequired},
      );
    case ClinicalEventType.bunRiseAfterFeeding: // §15.6
      return const EffectProfile(
        protein: ProteinEffect.reviewOnly,
      );
    case ClinicalEventType.cholestasisOrLiverDysfunction: // §15.7
      return const EffectProfile(
        productFilter: {ProductFilterEffect.mnFreeTrace},
        micronutrient: {MicronutrientEffect.toxicityGuard},
      );
    case ClinicalEventType.fluidOverload: // §15.8
      return const EffectProfile(
        fluid: FluidEffect.cap,
        productFilter: {ProductFilterEffect.energyDenseLowVolume},
      );
    case ClinicalEventType.rrtStart: // §16.2–16.5
      final m = e.rrtModality ?? RrtModality.crrt;
      return EffectProfile(
        protein: m.proteinEffect,
        fluid: m == RrtModality.crrt
            ? FluidEffect.netBalanceAware
            : FluidEffect.strictBalance,
        electrolyte: ElectrolyteEffect.monitor,
        micronutrient: const {MicronutrientEffect.additionalObligation},
      );
  }
}
