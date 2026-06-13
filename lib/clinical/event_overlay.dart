/// 臨床イベントオーバーレイ解決器（Flutter非依存・純粋）。
///
/// handoff §13/§14/§18。固定フェーズテンプレートは「変更しない」。
/// 各 Day について有効イベントを優先度順に解決し、テンプレートの上に重ねる
/// 「次元別 modifier（DayOverlay）」を返す。derived plan 生成側はこれを参照する。
///
/// codexレビュー反映:
/// - RRT は start/stop を畳み込み、その日の「実効モダリティ」を1つに決める
///   （open-ended な rrt_start は後続の rrt_stop / 別 rrt_start で終了/置換）。
/// - 次元（route/energy/protein/fluid/electrolyte/micro/productFilter）は独立に解決。
///   → refeeding hypophosphatemia の energy 制限と CRRT の protein バンドは「共存」する。
/// - protein は RRT が有効ならモダリティが支配（安定CKD制限を抑制・§7,§16）。
library;

import 'clinical_event.dart';

/// 1日分の解決済みオーバーレイ。テンプレートに重ねる次元別 modifier。
class DayOverlay {
  final int day; // 1-based
  final List<ClinicalEvent> activeEvents; // 優先度昇順（小=先＝制限的）
  final RouteEffect route;
  final EnergyEffect energy;
  final ProteinEffect protein;
  final ClinicalEvent? proteinSource; // protein を決めたイベント（説明用）
  final FluidEffect fluid;
  final ElectrolyteEffect electrolyte;
  final Set<MicronutrientEffect> micronutrient;
  final Set<ProductFilterEffect> productFilters;
  final RrtModality? activeRrtModality; // その日の実効RRTモダリティ（なければnull）
  final List<String> notes;

  const DayOverlay({
    required this.day,
    required this.activeEvents,
    this.route = RouteEffect.none,
    this.energy = EnergyEffect.none,
    this.protein = ProteinEffect.none,
    this.proteinSource,
    this.fluid = FluidEffect.none,
    this.electrolyte = ElectrolyteEffect.none,
    this.micronutrient = const {},
    this.productFilters = const {},
    this.activeRrtModality,
    this.notes = const [],
  });

  bool get hasOverlay =>
      activeEvents.isNotEmpty &&
      (route != RouteEffect.none ||
          energy != EnergyEffect.none ||
          protein != ProteinEffect.none ||
          fluid != FluidEffect.none ||
          electrolyte != ElectrolyteEffect.none ||
          micronutrient.isNotEmpty ||
          productFilters.isNotEmpty);

  /// 経腸/経口が経路レベルで遮断されているか（NOMI/NPO）。
  bool get enteralBlocked =>
      route == RouteEffect.npo ||
      productFilters.contains(ProductFilterEffect.excludeEnteral);
}

// ─────────────── 制限度の順序（数値が大きいほど制限的） ───────────────

int _routeRank(RouteEffect r) => switch (r) {
      RouteEffect.none => 0,
      RouteEffect.oralHold => 1,
      RouteEffect.reduceEn => 2,
      RouteEffect.enToPostpyloric => 2,
      RouteEffect.holdEn => 3,
      RouteEffect.pnOnly => 4,
      RouteEffect.npo => 5,
    };

int _energyRank(EnergyEffect e) => switch (e) {
      EnergyEffect.none => 0,
      EnergyEffect.reducePercent => 1,
      EnergyEffect.cap => 2,
      EnergyEffect.restartRefeedingRamp => 3,
      EnergyEffect.restrictFor48h => 4,
    };

int _fluidRank(FluidEffect f) => switch (f) {
      FluidEffect.none => 0,
      FluidEffect.liberalizeWithCrrt => 1,
      FluidEffect.cap => 2,
      FluidEffect.strictBalance => 3,
      FluidEffect.netBalanceAware => 4,
    };

int _electrolyteRank(ElectrolyteEffect e) => switch (e) {
      ElectrolyteEffect.none => 0,
      ElectrolyteEffect.dialysisFluidReview => 1,
      ElectrolyteEffect.monitor => 2,
      ElectrolyteEffect.supplement => 3,
    };

// ─────────────── RRT モダリティの畳み込み ───────────────

/// rrt_stop の next_modality（parameters['next_modality']）を解釈。
/// 'IRRT'/'SLED'/'CRRT' → そのモダリティ、'none'→null、'unknown'/未指定→null。
({RrtModality? modality, bool unknown}) _parseNextModality(ClinicalEvent stop) {
  final raw = stop.parameters['next_modality'];
  final s = raw?.toString().toUpperCase();
  switch (s) {
    case 'IRRT':
      return (modality: RrtModality.irrt, unknown: false);
    case 'SLED':
      return (modality: RrtModality.sled, unknown: false);
    case 'CRRT':
      return (modality: RrtModality.crrt, unknown: false);
    case 'NONE':
      return (modality: null, unknown: false);
    default:
      return (modality: null, unknown: true);
  }
}

/// RRT 畳み込み結果。modality=実効モダリティ / runStartDay=現在の連続run開始日 /
/// unknownStopDay=その日が「次モダリティ不明の停止」遷移日なら停止日（要レビュー）。
typedef _RrtState = ({
  RrtModality? modality,
  int? runStartDay,
  int? unknownStopDay,
});

/// start/stop を startDay 昇順に畳み込み、指定 Day（1-based）の状態を決める。
/// codexレビュー反映:
/// - 先行 start の無い孤立 rrt_stop は RRT を捏造しない（無視）。
/// - runStartDay は「現在の連続run」の開始日（停止→再開でリセット）。
/// - 次モダリティ不明の停止は unknownStopDay として要レビューを残す。
_RrtState _foldRrt(List<ClinicalEvent> events, int day) {
  final rrt = events
      .where((e) =>
          e.type == ClinicalEventType.rrtStart ||
          e.type == ClinicalEventType.rrtStop)
      .toList()
    ..sort((a, b) {
      final s = a.startDay.compareTo(b.startDay);
      return s != 0 ? s : a.id.compareTo(b.id);
    });
  RrtModality? current;
  int? runStart;
  int? unknownStopDay;
  var seenStart = false;
  for (final e in rrt) {
    if (e.startDay > day) break;
    if (e.type == ClinicalEventType.rrtStart) {
      seenStart = true;
      unknownStopDay = null; // 新規 start は不明停止状態をクリア
      final active = e.endDay == null || day <= e.endDay!;
      if (active) {
        if (current != e.rrtModality) runStart = e.startDay; // run切替
        current = e.rrtModality;
      } else {
        current = null; // 期間終了（後続イベントがあれば上書きされる）
        runStart = null;
      }
    } else {
      // rrt_stop。先行 start が無ければ孤立停止＝無視（捏造しない）。
      if (!seenStart) continue;
      final parsed = _parseNextModality(e);
      if (parsed.unknown) {
        unknownStopDay = e.startDay; // 次不明＝要レビュー
        current = null;
        runStart = null;
      } else {
        final next = parsed.modality;
        if (next != current) runStart = next == null ? null : e.startDay;
        current = next;
        unknownStopDay = null;
      }
    }
  }
  return (
    modality: current,
    runStartDay: current == null ? null : runStart,
    unknownStopDay: current == null ? unknownStopDay : null,
  );
}

/// 指定 Day（1-based）の実効 RRT モダリティ。start/stop を startDay 昇順に畳み込む。
/// open-ended な rrt_start は後続イベントが来るまで継続。endDay 設定があればその日まで。
RrtModality? activeRrtModalityOnDay(List<ClinicalEvent> events, int day) =>
    _foldRrt(events, day).modality;

// ─────────────── オーバーレイ解決 ───────────────

/// 指定 Day（1-based）のオーバーレイを解決。
/// [rrtCalorieUnknown]: SLED/CRRT稼働中に KRT液カロリー未入力なら情報ノートを足す（§17.1）。
DayOverlay resolveDayOverlay(
  List<ClinicalEvent> events,
  int day, {
  bool rrtCalorieUnknown = true,
}) {
  // 有効イベント（RRT以外）を優先度昇順、同値は severity 降順→id で決定的に。
  final active = events.where((e) => e.isActiveOnDay(day)).toList()
    ..sort((a, b) {
      final p = a.priority.compareTo(b.priority);
      if (p != 0) return p;
      final s = b.severity.index.compareTo(a.severity.index); // severe先
      if (s != 0) return s;
      return a.id.compareTo(b.id);
    });

  final rrtState = _foldRrt(events, day);
  final rrtModality = rrtState.modality;

  // 集約用アキュムレータ
  var route = RouteEffect.none;
  var energy = EnergyEffect.none;
  var fluid = FluidEffect.none;
  var electrolyte = ElectrolyteEffect.none;
  final micro = <MicronutrientEffect>{};
  final filters = <ProductFilterEffect>{};
  final notes = <String>[];

  ProteinEffect protein = ProteinEffect.none;
  ClinicalEvent? proteinSource;

  // RRT 以外のイベント効果を次元別に集約
  for (final e in active) {
    if (e.type == ClinicalEventType.rrtStart ||
        e.type == ClinicalEventType.rrtStop) {
      continue; // RRTは実効モダリティで別途処理
    }
    final ep = e.effectProfile;
    if (_routeRank(ep.route) > _routeRank(route)) route = ep.route;
    if (_energyRank(ep.energy) > _energyRank(energy)) energy = ep.energy;
    if (_fluidRank(ep.fluid) > _fluidRank(fluid)) fluid = ep.fluid;
    if (_electrolyteRank(ep.electrolyte) > _electrolyteRank(electrolyte)) {
      electrolyte = ep.electrolyte;
    }
    micro.addAll(ep.micronutrient.where((m) => m != MicronutrientEffect.none));
    filters
        .addAll(ep.productFilter.where((f) => f != ProductFilterEffect.none));
    // protein: 最高優先(=最初に出会う非none)を採用（activeは優先度昇順）
    if (ep.protein != ProteinEffect.none && protein == ProteinEffect.none) {
      protein = ep.protein;
      proteinSource = e;
    }
  }

  // RRT 実効モダリティの効果（protein を支配・安定CKD制限を抑制）
  if (rrtModality != null) {
    protein = rrtModality.proteinEffect; // RRT(優先度3) が renal/bun(8) を支配
    proteinSource = events.firstWhere(
      (e) =>
          e.type == ClinicalEventType.rrtStart && e.rrtModality == rrtModality,
      orElse: () => ClinicalEvent(
          id: '_rrt',
          type: ClinicalEventType.rrtStart,
          startDay: day,
          rrtModality: rrtModality),
    );
    micro.add(MicronutrientEffect.additionalObligation);
    if (_electrolyteRank(ElectrolyteEffect.monitor) >
        _electrolyteRank(electrolyte)) {
      electrolyte = ElectrolyteEffect.monitor;
    }
    // 水分: CRRTはnet-balance-aware（単純capを置換）、SLED/IRRTは厳格バランス。
    final rrtFluid = rrtModality == RrtModality.crrt
        ? FluidEffect.netBalanceAware
        : FluidEffect.strictBalance;
    if (_fluidRank(rrtFluid) > _fluidRank(fluid)) fluid = rrtFluid;
    // CRRT継続日数は「現在の連続run」の開始日から算出（停止→再開でリセット）。
    if (rrtModality == RrtModality.crrt &&
        rrtState.runStartDay != null &&
        day - rrtState.runStartDay! + 1 >= 14) {
      notes.add('CRRT稼働≥14日: 銅(Cu)のモニタ/再評価を検討（§16.5）');
    }
    if (rrtCalorieUnknown &&
        (rrtModality == RrtModality.sled || rrtModality == RrtModality.crrt)) {
      notes.add('${rrtModality.key}稼働中: クエン酸/乳酸/ブドウ糖など'
          'KRT関連液のカロリーは未入力のため未算入（§17.1）');
    }
  }

  // RRT停止後の次モダリティ不明（その遷移日）→ 要レビュー（§16.6）。
  if (rrtState.unknownStopDay == day) {
    notes.add('RRT停止後の次モダリティが不明: 採血/方針を再確認（§16.6 review）');
  }

  return DayOverlay(
    day: day,
    activeEvents: active,
    route: route,
    energy: energy,
    protein: protein,
    proteinSource: proteinSource,
    fluid: fluid,
    electrolyte: electrolyte,
    micronutrient: micro,
    productFilters: filters,
    activeRrtModality: rrtModality,
    notes: notes,
  );
}

/// タイムライン全体（1..totalDays）のオーバーレイを解決。
List<DayOverlay> resolveTimeline(
  List<ClinicalEvent> events,
  int totalDays, {
  bool rrtCalorieUnknown = true,
}) =>
    [
      for (var d = 1; d <= totalDays; d++)
        resolveDayOverlay(events, d, rrtCalorieUnknown: rrtCalorieUnknown),
    ];
