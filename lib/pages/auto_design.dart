part of '../main.dart';

class AutoDesignInline extends StatefulWidget {
  const AutoDesignInline(
      {super.key,
      required this.state,
      required this.current,
      this.onSettingsChanged});
  final AppState state;
  final PatientCase current;

  /// 設定変更時に親ウィジェットへ通知（チャートパネルのリアルタイム更新用）
  final VoidCallback? onSettingsChanged;

  @override
  State<AutoDesignInline> createState() => _AutoDesignPageState();
}

// 後方互換: 独立ページとして開く場合はScaffoldでラップ
class AutoDesignPage extends StatelessWidget {
  const AutoDesignPage({super.key, required this.state, required this.current});
  final AppState state;
  final PatientCase current;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: const Text('Day別 投与設計'),
        ),
        body: AutoDesignInline(state: state, current: current),
      );
}

class _AutoDesignPageState extends State<AutoDesignInline> {
  int _hoveredBarIdx = -1; // グラフホバー中のバーインデックス (-1=なし)。hoverツールチップ専用。
  bool _alertsExpanded = false; // 栄養管理アラートの展開状態(既定=折り畳み)
  // トレンド表示モード: 0=通常(グラフ表示) / 1=全画面(サジェスト全展開) / 2=折りたたみ。
  // ボタンで 0→1→2→0 とループ。
  int _trendViewMode = 0;
  double _cachedChartW = 300.0; // LayoutBuilderで更新するチャート実幅
  int _rampDays = 5; // full nutrition達成日(栄養開始からのDay)。この日に等差ランプでfullへ到達。
  // 簡易式の栄養係数の上限を使う「最終日」(until, 栄養開始からのDay)。permissive underfeeding。
  int _kcalStep20Day = 2; // 20kcal/kgを上限とする最終日(これ以前は20上限)
  int _kcalStep25Day = 4; // 25kcal/kgを上限とする最終日(20最終日の翌日〜この日は25上限)
  // true: EN/経口リハ開始日に連動して係数の最終日を自動設定(既定)
  bool _kcalStepAuto = true;
  int _enStartDay = 6; // EN導入するDay番号(食上げ開始日)
  int? _oralRehabStartDay; // 経口リハ開始Day (null=未設定)
  int _totalDays = 5; // シミュレーション全体の日数 (= _enStartDay + EN食上げ7日 -1)
  Product? _pnProduct; // PN(中心静脈栄養)主剤
  late DateTime _startDate; // 栄養開始日
  late List<double> _dayPercents; // 各Dayの達成目標%
  late List<String> _dayModes; // 各Dayのクラス
  late List<String> _dayEnDose; // 各DayのEN投与 ('0'/'r20'(速度)/'p3'(pac))
  late List<int> _dayMealPac; // 各Dayの食事 朝昼夕あたりpac数(0=食事なし, 1..3)
  late List<int> _dayMealSlots; // 各Dayの経口スロット数(0=なし, 1..3)。残りはENで補う。
  final List<List<RepairChange>> _dayRepairChanges = []; // 各Dayの自動補正(repair)記録
  // 手動修正: 処方カード下「アラート」リンク→リペア候補をワンタップ採用した結果(feedingDay index→上書きプラン)。
  // セッション内のみ保持(永続化しない)。設定変更(_rebuildDays)で破棄=プラン再生成と整合。
  final Map<int, DesignPlan> _manualDayOverride = {};
  final Map<int, List<RepairChange>> _manualDayChanges =
      {}; // 手動採用の差分記録(カード/シート表示用)
  final List<cev.ClinicalEvent> _clinicalEvents = []; // 自動設計イベントオーバーレイ（保存対象）
  cad.AutoDesignResult? _engineResult; // メタデータ専用read-model（処方生成には使わない）
  String? _engineCacheKey;
  // RSイベント検出(再栄養後の P/K/Mg 低下%)入力。transient(永続化しない=古い検査値を残さない)。
  bool _rsExpanded = false;
  bool _rsOrganDysfunction = false;
  final _rsBaseP = TextEditingController();
  final _rsCurP = TextEditingController();
  final _rsBaseK = TextEditingController();
  final _rsCurK = TextEditingController();
  final _rsBaseMg = TextEditingController();
  final _rsCurMg = TextEditingController();
  bool _labScheduleExpanded = false; // 採血提案カードの展開状態

  // EN食上げ固定シーケンス(7日): 10→20→30→40ml/h → 1pac朝昼夕(3) → 2pac朝昼夕(6) → EN単独full
  static const _enRampSequence = ['r10', 'r20', 'r30', 'r40', 'p3', 'p6', 'p6'];
  static const _enRampDays = 7;
  // 設定テーブルの Day ドロップダウン共通幅(full/EN/経口リハで揃える)
  static const double _dayDropW = 52;
  // 経口リハ食上げ(開始日から+5日=計6日): 表示期間
  static const _mealRampDays = 6;
  // 経口リハ ラダー(慎重な置換): [経口スロット数, pac/slot]。残りスロットはEN、不足はPN。
  //   朝1pac昼夕EN → 朝昼1pac夕EN → 朝昼夕1pac → 朝昼夕2pac (以降は維持)
  static const _mealLadder = [
    [1, 1],
    [2, 1],
    [3, 1],
    [3, 2],
  ];

  @override
  void initState() {
    super.initState();
    final tpn = _adopted('TPN');
    final cfg = widget.current.autoDesignConfig;
    // 入室日(bedHistoryの入室レコード)。絶食/栄養開始 既定の基準。
    DateTime admissionDate = DateTime.now();
    for (final b in widget.current.bedHistory) {
      if (b.fromBed == null) {
        final d = DateTime.tryParse(b.changedAt);
        if (d != null) {
          admissionDate = d;
          break;
        }
      }
    }
    // 絶食日の既定: 入室−3日(未設定時のみ)
    if (widget.current.fastingDate == null) {
      final f = admissionDate.subtract(const Duration(days: 3));
      widget.current.fastingDate =
          '${f.year}-${f.month.toString().padLeft(2, '0')}-${f.day.toString().padLeft(2, '0')}';
    }
    if (cfg != null) {
      // 保存済み設定を復元 (rampDays・開始日・PN製剤のみ。日別は固定シーケンスから再生成)
      _rampDays = ((cfg['rampDays'] as num?)?.toInt() ?? 5).clamp(2, 12);
      _enStartDay = (cfg['enStartDay'] as num?)?.toInt() ?? (_rampDays + 1);
      // 経口リハ導入の既定値: EN導入＋7日(EN食上げ完了の翌日)。未保存/未設定でも選択済みにし、
      // 「未選択(—)」でドロップダウンが横長になるのを防ぐ。
      _oralRehabStartDay = (cfg['oralRehabStartDay'] as num?)?.toInt() ??
          (_enStartDay + _enRampDays).clamp(1, 28);
      _startDate = DateTime.tryParse(cfg['startDate'] as String? ?? '') ??
          DateTime.now();
      _kcalStep20Day = (cfg['kcalStep20Day'] as num?)?.toInt() ?? 2;
      _kcalStep25Day = (cfg['kcalStep25Day'] as num?)?.toInt() ?? 4;
      _kcalStepAuto = (cfg['kcalStepAuto'] as bool?) ?? true;
      final pid = cfg['pnProductId'] as String?;
      _pnProduct = pid != null
          ? widget.state.catalog.byId(pid)
          : (tpn.isNotEmpty ? tpn.first : null);
      final rawEvents = cfg['clinicalEvents'];
      if (rawEvents is List) {
        _clinicalEvents
          ..clear()
          ..addAll(rawEvents
              .whereType<Map>()
              .map((e) => _clinicalEventFromMap(e))
              .whereType<cev.ClinicalEvent>());
      }
    } else {
      final p = widget.state.protocols.firstWhere(
          (e) => e.id == widget.current.selectedProtocolId,
          orElse: () => widget.state.protocols.first);
      _rampDays = p.percentages.length;
      _enStartDay = _rampDays + 1;
      // 経口リハ導入の既定値: EN導入＋7日(EN食上げ完了の翌日)
      _oralRehabStartDay = (_enStartDay + _enRampDays).clamp(1, 28);
      _pnProduct = tpn.isNotEmpty ? tpn.first : null;
      // 栄養開始日の既定: 入室+2日
      _startDate = admissionDate.add(const Duration(days: 2));
    }
    _rebuildDays();
  }

  @override
  void didUpdateWidget(covariant AutoDesignInline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current != widget.current ||
        _engineCacheKey != _engineInputCacheKey()) {
      _invalidateEngineResult();
    }
  }

  @override
  void dispose() {
    _saveConfig();
    for (final c in [
      _rsBaseP,
      _rsCurP,
      _rsBaseK,
      _rsCurK,
      _rsBaseMg,
      _rsCurMg
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _saveConfig() {
    widget.current.autoDesignConfig = {
      'rampDays': _rampDays,
      'enStartDay': _enStartDay,
      'oralRehabStartDay': _oralRehabStartDay,
      'pnProductId': _pnProduct?.id,
      'startDate': _startDate.toIso8601String(),
      'kcalStep20Day': _kcalStep20Day,
      'kcalStep25Day': _kcalStep25Day,
      'kcalStepAuto': _kcalStepAuto,
      'clinicalEvents': _clinicalEvents.map(_clinicalEventToMap).toList(),
    };
    widget.state.persist();
  }

  void _invalidateEngineResult() {
    _engineResult = null;
    _engineCacheKey = null;
  }

  String _engineInputCacheKey() => jsonEncode({
        'patientId': widget.current.id,
        'weightKg': widget.current.weightKg,
        'usualWeightKg': widget.current.usualWeightKg,
        'conditionTags': [...widget.current.conditionTags]..sort(),
        'fastingDate': widget.current.fastingDate,
        'energyModel': widget.current.energyModel,
        'kcalPerKgValue': widget.current.kcalPerKgValue,
        'measuredREE': widget.current.measuredREE,
        'activityFactor': widget.current.activityFactor,
        'stressFactor': widget.current.stressFactor,
        'refeedingFlags': [...widget.current.refeedingFlags]..sort(),
        'rampDays': _rampDays,
        'enStartDay': _enStartDay,
        'oralRehabStartDay': _oralRehabStartDay,
        'totalDays': _totalDays,
        'startDate': _startDate.toIso8601String(),
        'refeedingTier': _refeedingTier.name,
        'events': _clinicalEvents.map(_clinicalEventToMap).toList(),
      });

  cad.AutoDesignResult get _engineReadModel {
    final key = _engineInputCacheKey();
    final cached = _engineResult;
    if (cached != null && _engineCacheKey == key) return cached;
    final built = const cad.AutoDesignEngine().build(_autoDesignInput());
    _engineResult = built;
    _engineCacheKey = key;
    return built;
  }

  cad.AutoDesignInput _autoDesignInput() => cad.AutoDesignInput(
        weightKg: widget.current.weightKg,
        usualOrPrehospitalWeightKg: widget.current.usualWeightKg,
        conditionTags: widget.current.conditionTags.toSet(),
        events: List<cev.ClinicalEvent>.unmodifiable(_clinicalEvents),
        rampDays: _rampDays,
        enStartDay: _enStartDay,
        oralRehabStartDay: _oralRehabStartDay,
        totalDays: _totalDays,
        estimatedFullKcal: NutritionCalculator.targetEnergy(widget.current),
        refeedingTier: _refeedingTier,
        feedingStartDay: 1,
        krtFluidCaloriesStatus: cad.OptionalCaloriesStatus.unknown,
        eventEnergyCapKcalByDay: _eventEnergyCapKcalByDay(),
      );

  Map<int, double> _eventEnergyCapKcalByDay() {
    final caps = <int, double>{};
    for (var day = 1; day <= _totalDays; day++) {
      final overlay = cov.resolveDayOverlay(_clinicalEvents, day);
      double? cap;
      if (overlay.energy == cev.EnergyEffect.restrictFor48h) {
        cap = widget.current.weightKg * 10;
      }
      for (final event in overlay.activeEvents) {
        final value = event.parameters['cap_kcal_day'];
        if (value is num) {
          final kcal = value.toDouble();
          cap = cap == null ? kcal : (cap < kcal ? cap : kcal);
        }
      }
      if (cap != null) caps[day] = cap;
    }
    return caps;
  }

  Map<String, dynamic> _clinicalEventToMap(cev.ClinicalEvent e) => {
        'id': e.id,
        'type': e.type.name,
        'startDay': e.startDay,
        'endDay': e.endDay,
        'severity': e.severity.name,
        'sourceTier': cst.SourceTierMeta(e.sourceTier).key,
        'rrtModality': e.rrtModality?.key,
        'parameters': e.parameters,
        'explanation': e.explanation,
      };

  cev.ClinicalEvent? _clinicalEventFromMap(Map raw) {
    final type = _clinicalEventTypeFromKey(raw['type']?.toString());
    if (type == null) return null;
    final startDay = (raw['startDay'] as num?)?.toInt();
    if (startDay == null || startDay < 1) return null;
    final params = raw['parameters'] is Map
        ? Map<String, Object?>.from(raw['parameters'] as Map)
        : <String, Object?>{};
    return cev.ClinicalEvent(
      id: raw['id']?.toString() ??
          'event_${DateTime.now().microsecondsSinceEpoch}',
      type: type,
      startDay: startDay,
      endDay: (raw['endDay'] as num?)?.toInt(),
      severity: _eventSeverityFromKey(raw['severity']?.toString()) ??
          cev.EventSeverity.moderate,
      sourceTier: cst.sourceTierFromKey(raw['sourceTier']?.toString() ?? '') ??
          cst.SourceTier.userInputEvent,
      rrtModality: _rrtModalityFromKey(raw['rrtModality']?.toString()),
      parameters: params,
      explanation: raw['explanation']?.toString() ?? '',
    );
  }

  cev.ClinicalEventType? _clinicalEventTypeFromKey(String? key) {
    switch (key) {
      case 'enHold':
      case 'en_hold':
        return cev.ClinicalEventType.enHold;
      case 'enIntolerance':
      case 'en_intolerance':
        return cev.ClinicalEventType.enIntolerance;
      case 'recurrentNpo':
      case 'recurrent_npo':
        return cev.ClinicalEventType.recurrentNpo;
      case 'refeedingHypophosphatemia':
      case 'refeeding_hypophosphatemia':
        return cev.ClinicalEventType.refeedingHypophosphatemia;
      case 'bunRiseAfterFeeding':
      case 'bun_rise_after_feeding':
        return cev.ClinicalEventType.bunRiseAfterFeeding;
      case 'cholestasisOrLiverDysfunction':
      case 'cholestasis_or_liver_dysfunction':
        return cev.ClinicalEventType.cholestasisOrLiverDysfunction;
      case 'fluidOverload':
      case 'fluid_overload':
        return cev.ClinicalEventType.fluidOverload;
      case 'rrtStart':
      case 'rrt_start':
        return cev.ClinicalEventType.rrtStart;
      // 旧 rrtStop は廃止（モダリティ別の開始＋期間で表現）。読み飛ばす。
      default:
        return null;
    }
  }

  cev.EventSeverity? _eventSeverityFromKey(String? key) {
    switch (key) {
      case 'mild':
        return cev.EventSeverity.mild;
      case 'moderate':
        return cev.EventSeverity.moderate;
      case 'severe':
        return cev.EventSeverity.severe;
      default:
        return null;
    }
  }

  cev.RrtModality? _rrtModalityFromKey(String? key) {
    switch (key?.toUpperCase()) {
      case 'IRRT':
        return cev.RrtModality.irrt;
      case 'SLED':
        return cev.RrtModality.sled;
      case 'CRRT':
        return cev.RrtModality.crrt;
      default:
        return null;
    }
  }

  List<Product> _adopted(String cat) => widget.state.catalog
      .byCategory(cat)
      .where((p) => widget.state.isAdopted(p.id))
      .toList();

  double _b1Of(Product? p) =>
      ((p?.micro?['vit'] as Map?)?['B1'] as num?)?.toDouble() ?? 0;

  /// 高用量B1製剤(vit.B1≥50mg)。採用済み＞マスタ、ビタメジン優先＞B1量最大。
  /// refeeding安全のため採用が無ければマスタにフォールバックする。
  Product? _highDoseB1Product() {
    final all = widget.state.catalog
        .byCategory('ビタミン')
        .where((p) => _b1Of(p) >= 50)
        .toList();
    if (all.isEmpty) return null;
    final adopted = all.where((p) => widget.state.isAdopted(p.id)).toList();
    final pool = adopted.isNotEmpty ? adopted : all;
    pool.sort((a, b) {
      final av = a.name.contains('ビタメジン') ? 1 : 0;
      final bv = b.name.contains('ビタメジン') ? 1 : 0;
      if (av != bv) return bv - av;
      return _b1Of(b).compareTo(_b1Of(a));
    });
    return pool.first;
  }

  /// プランの糖質(g)とB1(mg)合計を製剤組成から算出。
  ({double carb, double b1}) _carbAndB1OfPlan(DesignPlan plan) {
    double carb = 0, b1 = 0;
    for (final it in plan.items) {
      final prod = widget.state.catalog.byName(it.name);
      if (prod == null) continue;
      final pv = prod.volumeMl ?? 0;
      final mult = pv > 0 ? it.volumeMl / pv : (it.units ?? 0).toDouble();
      carb += (prod.carbBase ?? 0) * mult;
      b1 += _b1Of(prod) * mult;
    }
    return (carb: carb, b1: b1);
  }

  double _traceMicro(Product p, String key) =>
      ((p.micro?['trace'] as Map?)?[key] as num?)?.toDouble() ?? 0;

  Product? _mnFreeForRepair() {
    final all = widget.state.catalog
        .byCategory('微量元素')
        .where((p) => p.isMnFreeTrace)
        .toList();
    if (all.isEmpty) return null;
    final ad = all.where((p) => widget.state.isAdopted(p.id)).toList();
    return (ad.isNotEmpty ? ad : all).first;
  }

  Product? _znForRepair() {
    final all = widget.state.catalog
        .byCategory('微量元素')
        .where((p) => _traceMicro(p, 'Zn') > 0)
        .toList();
    if (all.isEmpty) return null;
    final mf = all.where((p) => p.isMnFreeTrace).toList();
    final pool = mf.isNotEmpty ? mf : all;
    final ad = pool.where((p) => widget.state.isAdopted(p.id)).toList();
    return (ad.isNotEmpty ? ad : pool).first;
  }

  Product? _seForRepair() {
    final all = widget.state.catalog
        .byCategory('微量元素')
        .where((p) => _traceMicro(p, 'Se') > 0)
        .toList();
    if (all.isEmpty) return null;
    final ad = all.where((p) => widget.state.isAdopted(p.id)).toList();
    return (ad.isNotEmpty ? ad : all).first;
  }

  Map<String, List<RepairAction>> _repairRegistry() => buildRepairActions(
        mnFreeProduct: _mnFreeForRepair(),
        znProduct: _znForRepair(),
        seProduct: _seForRepair(),
      );

  int _fastingDaysToStart() {
    final f = widget.current.fastingDate;
    final fd = f != null ? DateTime.tryParse(f) : null;
    if (fd == null) return 0;
    final d = DateTime(_startDate.year, _startDate.month, _startDate.day)
        .difference(DateTime(fd.year, fd.month, fd.day))
        .inDays;
    return d < 0 ? 0 : d;
  }

  PlanState _planStateFromDayPlan(DesignPlan plan) {
    final items = <PlanItem>[];
    for (final it in plan.items) {
      final p = widget.state.catalog.byName(it.name);
      if (p == null) continue;
      final vol = p.volumeMl ?? 0;
      final units = it.units ?? (vol > 0 ? (it.volumeMl / vol).round() : 0);
      if (units <= 0) continue;
      items.add(PlanItem(p, units));
    }
    return PlanState(items);
  }

  ae.EvalContext _evalDayPlan(PlanState p) => computeEvalContext(
        p,
        weightKg: NutritionCalculator.referenceWeightKg(widget.current),
        conditionTags: widget.current.conditionTags.toSet(),
        targetKcal: NutritionCalculator.targetEnergy(widget.current),
        proteinGoalPerKg: widget.current.proteinGoalPerKg,
        refeedingRisk: _refeedingTier != cr.RefeedingTier.none,
      );

  /// repair差分のみ DesignPlan へ反映（プレースホルダ・PN部分量は不変）。
  DesignPlan _applyRepairToDayPlan(
      DesignPlan plan, PlanState before, PlanState after) {
    DesignItem mk(Product p, int u) => DesignItem(
        name: p.name,
        units: u,
        volumeMl: (p.volumeMl ?? 0) * u,
        kcal: (p.kcal ?? 0) * u,
        proteinG: (p.aminoAcidG ?? 0) * u);
    final beforeU = {for (final i in before.items) i.product.id: i};
    final afterU = {for (final i in after.items) i.product.id: i};
    final items = [...plan.items];
    for (final id in {...beforeU.keys, ...afterU.keys}) {
      final b = beforeU[id]?.units ?? 0;
      final a = afterU[id]?.units ?? 0;
      if (a == b) continue;
      final prod = (afterU[id] ?? beforeU[id])!.product;
      final idx = items
          .indexWhere((it) => widget.state.catalog.byName(it.name)?.id == id);
      if (a == 0) {
        if (idx >= 0) items.removeAt(idx);
      } else if (idx >= 0) {
        items[idx] = mk(prod, a);
      } else {
        items.add(mk(prod, a));
      }
    }
    return DesignPlan(label: plan.label, items: items, enKcal: plan.enKcal);
  }

  /// その日のプランに B1自動加注 + repair を適用（チャート/カード共通）。
  /// thiamine は B1自動加注で処理するため registry には含めない。
  DesignPlan _b1AndRepair(DesignPlan plan, int feedingDayIdx,
      {List<RepairChange>? out}) {
    final b1Prod = _highDoseB1Product();
    if (b1Prod != null) {
      final cb = _carbAndB1OfPlan(plan);
      final units = NutritionCalculator.thiamineUnitsToAdd(
        fastingDays: _fastingDaysToStart(),
        feedingDay: feedingDayIdx + 1,
        carbPresent: cb.carb > 0,
        currentB1Mg: cb.b1,
        b1PerUnitMg: _b1Of(b1Prod),
        refeedingRisk: _refeedingTier != cr.RefeedingTier.none,
        alcoholUse: widget.current.conditionTags.contains('alcohol'),
      );
      if (units > 0) {
        plan = DesignPlan(label: plan.label, enKcal: plan.enKcal, items: [
          ...plan.items,
          DesignItem(
              name: b1Prod.name,
              units: units,
              volumeMl: (b1Prod.volumeMl ?? 0) * units,
              kcal: (b1Prod.kcal ?? 0) * units,
              proteinG: 0),
        ]);
      }
    }
    final before = _planStateFromDayPlan(plan);
    final outcome = repair(
      before,
      actions: _repairRegistry(),
      evalOf: _evalDayPlan,
      constraints: ae.ConstraintSet.standard(),
      weights: ae.ScoreWeights.standard(),
    );
    if (outcome.hasRepair) {
      out?.addAll(outcome.best!.changes);
      return _applyRepairToDayPlan(plan, before, outcome.best!.plan);
    }
    return plan;
  }

  /// その日の処方をアラートエンジンで評価（read-only）。severity順にソート。
  List<ae.NutritionAlert> _engineDayAlerts(DesignPlan plan) {
    final ps = _planStateFromDayPlan(plan);
    if (ps.items.isEmpty) return const [];
    return ae
        .evaluate(_evalDayPlan(ps), ae.ConstraintSet.standard())
        .where((a) => !a.dataMissing)
        .toList()
      ..sort((a, b) => a.severity.index.compareTo(b.severity.index));
  }

  Map<int, List<cad.StructuredNutritionAlert>> _structuredAlertsByDay(
      cad.AutoDesignResult result) {
    final out = <int, List<cad.StructuredNutritionAlert>>{};
    for (final alert in result.alerts) {
      (out[alert.day - 1] ??= <cad.StructuredNutritionAlert>[]).add(alert);
    }
    for (final alerts in out.values) {
      alerts.sort((a, b) {
        final s = a.severity.index.compareTo(b.severity.index);
        if (s != 0) return s;
        return a.ruleId.compareTo(b.ruleId);
      });
    }
    return out;
  }

  List<cad.StructuredNutritionAlert> _structuredDayAlerts(int dayIndex) {
    final result = _engineReadModel;
    return _structuredAlertsByDay(result)[dayIndex] ?? const [];
  }

  /// その日の処方をアラートエンジンで評価し、engine structured alert と合算する。
  ({int err, int warn, int info}) _engineDayAlertCounts(DesignPlan plan,
      [List<cad.StructuredNutritionAlert> structuredAlerts = const []]) {
    final alerts = _engineDayAlerts(plan);
    var err = alerts.where((a) => a.severity == ae.AlertSeverity.error).length;
    var warn =
        alerts.where((a) => a.severity == ae.AlertSeverity.warning).length;
    var info = alerts.where((a) => a.severity == ae.AlertSeverity.info).length;
    for (final alert in structuredAlerts) {
      switch (alert.severity) {
        case cad.RuleSeverity.hard:
          err++;
          break;
        case cad.RuleSeverity.major:
        case cad.RuleSeverity.soft:
          warn++;
          break;
        case cad.RuleSeverity.info:
          info++;
          break;
      }
    }
    return (err: err, warn: warn, info: info);
  }

  Color _sevColor(ae.AlertSeverity s) => s == ae.AlertSeverity.error
      ? Colors.red.shade700
      : s == ae.AlertSeverity.warning
          ? Colors.orange.shade800
          : Colors.blueGrey;
  IconData _sevIcon(ae.AlertSeverity s) => s == ae.AlertSeverity.error
      ? Icons.error_outline
      : s == ae.AlertSeverity.warning
          ? Icons.warning_amber_rounded
          : Icons.info_outline;
  String _sevLabel(ae.AlertSeverity s) => s == ae.AlertSeverity.error
      ? '禁忌'
      : s == ae.AlertSeverity.warning
          ? '警告'
          : '情報';

  Color _ruleColor(cad.RuleSeverity s) => switch (s) {
        cad.RuleSeverity.hard => Colors.red.shade700,
        cad.RuleSeverity.major => Colors.orange.shade800,
        cad.RuleSeverity.soft => Colors.amber.shade800,
        cad.RuleSeverity.info => Colors.blueGrey.shade700,
      };

  IconData _ruleIcon(cad.RuleSeverity s) => switch (s) {
        cad.RuleSeverity.hard => Icons.error_outline,
        cad.RuleSeverity.major => Icons.warning_amber_rounded,
        cad.RuleSeverity.soft => Icons.info_outline,
        cad.RuleSeverity.info => Icons.info_outline,
      };

  String _ruleLabel(cad.RuleSeverity s) => switch (s) {
        cad.RuleSeverity.hard => '禁忌',
        cad.RuleSeverity.major => '警告',
        cad.RuleSeverity.soft => '注意',
        cad.RuleSeverity.info => '情報',
      };

  Color _bandColor(cad.BandLevel level) => switch (level) {
        cad.BandLevel.green => Colors.green.shade600,
        cad.BandLevel.amber => Colors.amber.shade800,
        cad.BandLevel.red => Colors.deepOrange.shade700,
        cad.BandLevel.hardViolation => Colors.red.shade700,
      };

  String _bandLabel(cad.BandLevel level) => switch (level) {
        cad.BandLevel.green => '適正',
        cad.BandLevel.amber => '要注意',
        cad.BandLevel.red => '範囲外',
        cad.BandLevel.hardViolation => '禁忌超過',
      };

  List<Widget> _engineBandDots(
    int dayIndex,
    DesignPlan plan,
    double referenceWeight,
    cad.AutoDesignResult result,
  ) {
    Widget dot(cad.BandLevel level, String message) => Tooltip(
          message: message,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _bandColor(level),
              border: Border.all(
                  color: level == cad.BandLevel.hardViolation
                      ? Colors.black54
                      : Colors.white,
                  width: 0.8),
            ),
          ),
        );

    final out = <Widget>[];
    if (dayIndex < result.energyTargets.length) {
      final target = result.energyTargets[dayIndex];
      final level = target.classify(plan.totalKcal);
      out.add(dot(
        level,
        'エネルギー ${_bandLabel(level)}: ${plan.totalKcal.round()}kcal / '
        '適正帯 ${target.greenMinKcal.round()}–${target.greenMaxKcal.round()}kcal',
      ));
    }
    if (referenceWeight > 0 && dayIndex < result.proteinTargets.length) {
      final target = result.proteinTargets[dayIndex];
      final actual = plan.totalProteinG / referenceWeight;
      final level = target.classify(actual);
      out.add(dot(
        level,
        'タンパク ${_bandLabel(level)}: ${actual.toStringAsFixed(2)}g/kg / '
        '目標帯 ${target.minGPerKg.toStringAsFixed(1)}–${target.maxGPerKg.toStringAsFixed(1)}g/kg',
      ));
    }
    return out;
  }

  Widget _engineSourceBadgeLegend(cad.AutoDesignResult result) {
    if (result.sourceBadges.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(Icons.fact_check_outlined,
              size: 14, color: Colors.blueGrey.shade600),
          for (final badge in result.sourceBadges)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.blueGrey.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: Colors.blueGrey.withValues(alpha: 0.28)),
              ),
              child: Text(badge,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: Colors.blueGrey.shade700,
                      fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }

  Color? _overlayTintColor(cov.DayOverlay overlay) {
    if (overlay.activeEvents.isEmpty && overlay.activeRrtModality == null) {
      return null;
    }
    if (overlay.activeRrtModality != null) {
      return overlay.activeRrtModality == cev.RrtModality.crrt
          ? Colors.teal.shade700
          : Colors.purple.shade700;
    }
    if (overlay.route != cev.RouteEffect.none || overlay.enteralBlocked) {
      return overlay.enteralBlocked ||
              overlay.route == cev.RouteEffect.npo ||
              overlay.route == cev.RouteEffect.pnOnly
          ? Colors.red.shade700
          : Colors.amber.shade800;
    }
    if (overlay.energy != cev.EnergyEffect.none ||
        overlay.protein != cev.ProteinEffect.none ||
        overlay.electrolyte != cev.ElectrolyteEffect.none ||
        overlay.micronutrient.isNotEmpty) {
      return Colors.deepOrange.shade700;
    }
    if (overlay.fluid != cev.FluidEffect.none) {
      return Colors.blue.shade700;
    }
    if (overlay.productFilters.isNotEmpty) {
      return Colors.deepOrange.shade700;
    }
    return Colors.blueGrey.shade600;
  }

  /// 処方カード下「アラート」リンクから開く、その日のアラート＋手動修正シート。
  /// 残存アラートごとにリペア候補(repair.dart)を提示し、[採用]でワンタップ適用。
  /// 採用結果は _manualDayOverride[feedingIdx] に保持し、カード/グラフへ即反映。
  void _showDayRepairSheet(int feedingIdx, DesignPlan dayPlan,
      {List<cad.StructuredNutritionAlert> structuredAlerts = const []}) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        // ダイアログ内で採用→再評価を反映するため working を保持。
        DesignPlan working = _manualDayOverride[feedingIdx] ?? dayPlan;

        // 1つのリペアアクションを採用してプランへ反映。
        void adopt(RepairAction act, ae.NutritionAlert alert,
            void Function(void Function()) dlgSet) {
          final before = _planStateFromDayPlan(working);
          final res = act.apply(before, _evalDayPlan(before), alert);
          if (!res.changed) return;
          final newPlan = _applyRepairToDayPlan(working, before, res.plan);
          setState(() {
            _manualDayOverride[feedingIdx] = newPlan;
            (_manualDayChanges[feedingIdx] ??= <RepairChange>[])
                .addAll(res.changes.map((c) => RepairChange(
                      code: c.code,
                      label: c.label,
                      reason: c.reason,
                      beforeText: c.beforeText,
                      afterText: c.afterText,
                      kind: c.kind,
                      autoApplied: false,
                    )));
          });
          dlgSet(() => working = newPlan);
          widget.onSettingsChanged?.call();
        }

        void resetManual(void Function(void Function()) dlgSet) {
          setState(() {
            _manualDayOverride.remove(feedingIdx);
            _manualDayChanges.remove(feedingIdx);
          });
          widget.onSettingsChanged?.call();
          Navigator.of(ctx).pop(); // 再生成された素のプランで開き直せるよう閉じる
        }

        return StatefulBuilder(builder: (ctx, dlgSet) {
          final alerts = _engineDayAlerts(working);
          final structured = structuredAlerts.isNotEmpty
              ? structuredAlerts
              : _structuredDayAlerts(feedingIdx);
          final registry = _repairRegistry();
          final before = _planStateFromDayPlan(working);
          final ctxEval = _evalDayPlan(before);
          final manual =
              _manualDayChanges[feedingIdx] ?? const <RepairChange>[];

          Widget alertCard(ae.NutritionAlert a) {
            final col = _sevColor(a.severity);
            // このアラートに適用できるリペア候補をドライランで取得(状態は変えない)。
            final candidates = <(RepairAction, RepairChange)>[];
            for (final act in (registry[a.code] ?? const <RepairAction>[])) {
              if (!act.canApply(before, ctxEval, a)) continue;
              final res = act.apply(before, ctxEval, a);
              if (res.changed && res.changes.isNotEmpty) {
                candidates.add((act, res.changes.first));
              }
            }
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: col.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: col.withValues(alpha: 0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(_sevIcon(a.severity), size: 16, color: col),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('【${_sevLabel(a.severity)}】${a.code}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: col)),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(a.message,
                      style: const TextStyle(fontSize: 12, height: 1.4)),
                  if (candidates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('→ 自動修正候補なし（手動で製剤調整が必要）',
                          style: TextStyle(fontSize: 11, color: Colors.grey)),
                    )
                  else
                    for (final c in candidates)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.indigo.shade200),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.$2.reason,
                                    style: const TextStyle(
                                        fontSize: 11.5, height: 1.3)),
                                Text('${c.$2.beforeText} → ${c.$2.afterText}',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        color: Colors.indigo.shade700)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          FilledButton(
                            onPressed: () => adopt(c.$1, a, dlgSet),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('採用',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ]),
                      ),
                ],
              ),
            );
          }

          Widget structuredAlertCard(cad.StructuredNutritionAlert alert) {
            final col = _ruleColor(alert.severity);
            final source = cst.SourceTierMeta(alert.sourceTier).badgeLabel;
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: col.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: col.withValues(alpha: 0.45)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(_ruleIcon(alert.severity), size: 16, color: col),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '【${_ruleLabel(alert.severity)}】${alert.ruleId}',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: col),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(alert.explanation,
                      style: const TextStyle(fontSize: 12, height: 1.4)),
                  const SizedBox(height: 4),
                  Text('metric: ${alert.metric} / source: $source',
                      style:
                          const TextStyle(fontSize: 10.5, color: Colors.grey)),
                  if (alert.suggestedRepair != null) ...[
                    const SizedBox(height: 6),
                    Text('→ ${alert.suggestedRepair}',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: col,
                            fontWeight: FontWeight.bold)),
                  ],
                ],
              ),
            );
          }

          return AlertDialog(
            title: Text(
                '${_dateOf(feedingIdx)} (Day${feedingIdx + 1}) のアラートと手動修正',
                style: const TextStyle(fontSize: 15)),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (alerts.isEmpty && structured.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: const Text('この日の残存アラートはありません。',
                            style: TextStyle(fontSize: 12)),
                      )
                    else ...[
                      if (alerts.isNotEmpty) ...[
                        const Text('残存アラート（採用で当日の処方を修正）',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54)),
                        const SizedBox(height: 6),
                        for (final a in alerts) alertCard(a),
                      ],
                      if (structured.isNotEmpty) ...[
                        if (alerts.isNotEmpty) const SizedBox(height: 6),
                        const Text('engine表示メタデータ',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54)),
                        const SizedBox(height: 6),
                        for (final a in structured) structuredAlertCard(a),
                      ],
                    ],
                    if (manual.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Icon(Icons.back_hand_outlined,
                            size: 14, color: Colors.indigo.shade600),
                        const SizedBox(width: 4),
                        Text('手動で採用した修正 ${manual.length}件',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.indigo.shade700)),
                      ]),
                      for (final c in manual)
                        Padding(
                          padding: const EdgeInsets.only(top: 3, left: 18),
                          child: Text('・${c.reason}（${c.afterText}）',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.indigo.shade400)),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              if (manual.isNotEmpty)
                TextButton(
                    onPressed: () => resetManual(dlgSet),
                    child: const Text('手動修正を取り消し',
                        style: TextStyle(color: Colors.red))),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('閉じる')),
            ],
          );
        });
      },
    );
  }

  /// 簡易式 栄養係数(20/25/30 kcal/kg)の段階開始日 設定。
  /// イベント日付決定(絶食〜経口リハ)と同じテーブルに行として配置する。
  /// 既定は自動(EN/経口リハ開始日に連動)。チェックを外すと手動設定。
  /// 設定テーブルのラベルセル。アイコン有無に依らず固定幅スロット(18px)でテキスト開始位置を揃える。
  /// 全設定行をこのヘルパーで生成し、ラベルのズレを構造的に防止する。
  Widget _settingLabelCell(IconData? icon, String label, Color color,
      {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.only(right: 10, bottom: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 18,
          child: icon == null ? null : Icon(icon, size: 14, color: color),
        ),
        Text(label,
            style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
      ]),
    );
  }

  List<TableRow> _kcalStepTableRows() {
    final enabled = !_kcalStepAuto;
    TableRow dayRow(
        String label, Color color, int value, ValueChanged<int> onCh) {
      return TableRow(children: [
        _settingLabelCell(
            Icons.trending_up, label, enabled ? color : Colors.grey),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('〜Day ', style: TextStyle(fontSize: 13)),
            SizedBox(
              width: _dayDropW,
              child: DropdownButton<int>(
                value: value.clamp(1, 28),
                isDense: true,
                isExpanded: true,
                items: List.generate(28, (i) => i + 1)
                    .map((d) => DropdownMenuItem(value: d, child: Text('$d')))
                    .toList(),
                onChanged: enabled
                    ? (v) {
                        if (v == null) return;
                        setState(() {
                          onCh(v);
                          // 単調性: 20上限の最終日 ≤ 25上限の最終日
                          if (_kcalStep25Day < _kcalStep20Day) {
                            _kcalStep25Day = _kcalStep20Day;
                          }
                          if (_kcalStep20Day > _kcalStep25Day) {
                            _kcalStep20Day = _kcalStep25Day;
                          }
                          _rebuildDays();
                        });
                        _saveConfig();
                        widget.onSettingsChanged?.call();
                      }
                    : null,
              ),
            ),
          ]),
        ),
      ]);
    }

    return [
      // 見出し + 自動連動チェックボックス
      TableRow(children: [
        _settingLabelCell(null, '栄養係数上限:', Colors.green.shade800, bold: true),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: _kcalStepAuto,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) {
                  setState(() {
                    _kcalStepAuto = v ?? true;
                    if (_kcalStepAuto) _applyAutoKcalSteps();
                    _rebuildDays();
                  });
                  _saveConfig();
                  widget.onSettingsChanged?.call();
                },
              ),
            ),
            const SizedBox(width: 2),
            const Text('自動', style: TextStyle(fontSize: 11)),
          ]),
        ),
      ]),
      dayRow('20 kcal/kg', Colors.green.shade700, _kcalStep20Day,
          (v) => _kcalStep20Day = v),
      dayRow('25 kcal/kg', Colors.green.shade700, _kcalStep25Day,
          (v) => _kcalStep25Day = v),
    ];
  }

  /// 食事(経口リハ)用の採用製剤: 濃厚流動食+栄養サポート。未採用なら全食事製剤。
  List<Product> _adoptedMeals() {
    final adopted = widget.state.catalog.products
        .where((p) => p.isFood && widget.state.isAdopted(p.id))
        .toList();
    if (adopted.isNotEmpty) return adopted;
    return widget.state.catalog.products.where((p) => p.isFood).toList();
  }

  /// EN製剤を全日程で1製剤に固定するための選択。
  /// 40ml/h連続投与(=ピーク)でtargetKcalを超えず、できるだけ目標に近い製剤を選ぶ。
  /// → 同じ製剤を全日に使うのでENカロリーが単調増加し、INのガタつきも抑制。
  Product? _pickEnProduct(List<Product> ens, double targetKcal) {
    if (ens.isEmpty) return null;
    const peakMl = 40.0 * 24; // 40ml/h × 24h = 960ml
    Product? best;
    double bestScore = double.infinity;
    for (final p in ens) {
      if ((p.kcal ?? 0) <= 0 || (p.volumeMl ?? 0) <= 0) continue;
      final kcalAt40 = (p.kcal ?? 0) * peakMl / p.volumeMl!;
      final ratio = targetKcal > 0 ? kcalAt40 / targetKcal : 1.0;
      double s;
      if (ratio > 1.0) {
        s = (ratio - 1.0) * 100; // over厳禁
      } else {
        s = (1.0 - ratio); // 不足はなるべく少なく(高密度優先)
      }
      if (s < bestScore) {
        bestScore = s;
        best = p;
      }
    }
    return best ?? ens.first;
  }

  // EN投与dose文字列の解釈: 'r20'=20ml/h, 'p3'=3pac, '0'=なし
  double _rateOf(String dose) =>
      dose.startsWith('r') ? (double.tryParse(dose.substring(1)) ?? 0) : 0;
  int _pacOf(String dose) =>
      dose.startsWith('p') ? (int.tryParse(dose.substring(1)) ?? 0) : 0;

  // EN投与doseのラベル
  String _doseLabel(String dose) {
    switch (dose) {
      case '0':
        return 'なし';
      case 'r10':
        return '10ml/h';
      case 'r20':
        return '20ml/h';
      case 'r30':
        return '30ml/h';
      case 'r40':
        return '40ml/h';
      case 'p3':
        return '朝昼夕1pac';
      case 'p6':
        return '朝昼夕2pac';
      default:
        return dose;
    }
  }

  cov.DayOverlay _overlayForDay(int i) =>
      cov.resolveDayOverlay(_clinicalEvents, i + 1);

  String _templateRouteSummaryForDay(int i) {
    final parts = <String>[_dayModes[i]];
    if (_dayEnDose[i] != '0') parts.add(_doseLabel(_dayEnDose[i]));
    if (_dayMealSlots[i] > 0 && _dayMealPac[i] > 0) {
      parts.add('食事 ${_dayMealSlots[i]}枠 x ${_dayMealPac[i]}pac');
    }
    return parts.join(' / ');
  }

  String _derivedRouteSummaryForDay(int i) {
    final parts = <String>[_derivedModeForDay(i)];
    final dose = _derivedEnDoseForDay(i);
    if (dose != '0') parts.add(_doseLabel(dose));
    final mealSlots = _derivedMealSlotsForDay(i);
    final mealPac = _derivedMealPacForDay(i);
    if (mealSlots > 0 && mealPac > 0) {
      parts.add('食事 $mealSlots枠 x ${mealPac}pac');
    }
    return parts.join(' / ');
  }

  bool _hasTemplateDerivedRouteDelta(int i) =>
      _templateRouteSummaryForDay(i) != _derivedRouteSummaryForDay(i);

  String _derivedModeForDay(int i) {
    final overlay = _overlayForDay(i);
    if (overlay.enteralBlocked) return 'TPN';
    if (overlay.route == cev.RouteEffect.holdEn ||
        overlay.route == cev.RouteEffect.reduceEn) {
      return 'TPN+EN';
    }
    return _dayModes[i];
  }

  String _derivedEnDoseForDay(int i) {
    final overlay = _overlayForDay(i);
    if (overlay.enteralBlocked) return '0';
    if (overlay.route == cev.RouteEffect.holdEn) {
      final hold = overlay.activeEvents
          .where((e) => e.type == cev.ClinicalEventType.enHold)
          .firstOrNull;
      final rate =
          (hold?.parameters['hold_rate_ml_h'] as num?)?.toDouble() ?? 20;
      return 'r${rate.round()}';
    }
    if (overlay.route == cev.RouteEffect.reduceEn) {
      final currentRate = _rateOf(_dayEnDose[i]);
      final rate = currentRate > 0 ? (currentRate < 20 ? currentRate : 20) : 20;
      return 'r${rate.round()}';
    }
    return _dayEnDose[i];
  }

  int _derivedMealPacForDay(int i) =>
      _overlayForDay(i).route == cev.RouteEffect.none ? _dayMealPac[i] : 0;

  int _derivedMealSlotsForDay(int i) =>
      _overlayForDay(i).route == cev.RouteEffect.none ? _dayMealSlots[i] : 0;

  double _derivedProteinTarget(int i, double templateProteinTarget) {
    final rrt = _overlayForDay(i).activeRrtModality;
    if (rrt == null) return templateProteinTarget;
    final band = rrt.proteinBand;
    return ((band.min + band.max) / 2) * widget.current.weightKg;
  }

  double? _eventHardKcalCap(int i, double templateTargetKcal) {
    final overlay = _overlayForDay(i);
    double? cap;
    if (overlay.energy == cev.EnergyEffect.restrictFor48h) {
      cap = widget.current.weightKg * 10;
    }
    for (final e in overlay.activeEvents) {
      final v = e.parameters['cap_kcal_day'];
      if (v is num)
        cap = cap == null ? v.toDouble() : (cap < v ? cap : v.toDouble());
    }
    if (cap == null) return null;
    return cap < templateTargetKcal ? cap : templateTargetKcal;
  }

  bool _hasEventEnergyCap(int i) {
    final overlay = _overlayForDay(i);
    return overlay.energy == cev.EnergyEffect.restrictFor48h ||
        overlay.activeEvents.any((e) => e.parameters['cap_kcal_day'] is num) ||
        _postRefeedingGlideCap(i, double.infinity) != null;
  }

  /// Refeedingイベント終了後の緩徐再上げ（glide）上限。
  /// 終了直後にfullへ跳ねると再Refeedingを起こすため、終了→full を約5日かけて漸増。
  /// 制限中のcap値から templateTarget へ線形補間し、template側が低ければそちらを優先(min)。
  static const int _postRefeedingGlideDays = 5;
  double? _postRefeedingGlideCap(int i, double templateTargetKcal) {
    final day = i + 1; // _overlayForDay と同じ 1-based feeding-day
    final w = widget.current.weightKg;
    double? best;
    for (final e in _clinicalEvents) {
      if (e.type != cev.ClinicalEventType.refeedingHypophosphatemia) continue;
      final end = e.endDay;
      if (end == null) continue; // 終了日未設定（継続中）はglide対象外
      final since = day - end; // 終了の翌日=1
      if (since < 1 || since > _postRefeedingGlideDays) continue;
      // 制限中のcap値（cap_kcal_day指定 or 10kcal/kg）から full へ漸増。
      final capParam = e.parameters['cap_kcal_day'];
      final refeedCap = capParam is num ? capParam.toDouble() : w * 10;
      final frac = since / _postRefeedingGlideDays; // 1/5 .. 5/5
      var glide = refeedCap + (templateTargetKcal - refeedCap) * frac;
      if (glide > templateTargetKcal) glide = templateTargetKcal;
      if (best == null || glide < best) best = glide;
    }
    return best;
  }

  double _derivedKcalTarget(int i, double templateTargetKcal) {
    var t = _eventHardKcalCap(i, templateTargetKcal) ?? templateTargetKcal;
    final glide = _postRefeedingGlideCap(i, templateTargetKcal);
    if (glide != null && glide < t) t = glide; // 終了後の緩徐再上げ
    return t;
  }

  double? _hardKcalCapForDay(int i, double derivedTargetKcal) =>
      (_refeedingTier != cr.RefeedingTier.none || _hasEventEnergyCap(i))
          ? derivedTargetKcal
          : null;

  /// 臨床イベントの表示色（種別/RRTモダリティで決定）。
  Color _eventSpanColor(cev.ClinicalEvent e) {
    switch (e.type) {
      case cev.ClinicalEventType.recurrentNpo:
        return Colors.red.shade600;
      case cev.ClinicalEventType.enHold:
      case cev.ClinicalEventType.enIntolerance:
        return Colors.amber.shade800;
      case cev.ClinicalEventType.refeedingHypophosphatemia:
        return Colors.deepOrange.shade700;
      case cev.ClinicalEventType.cholestasisOrLiverDysfunction:
        return Colors.brown.shade600;
      case cev.ClinicalEventType.fluidOverload:
        return Colors.blue.shade700;
      case cev.ClinicalEventType.bunRiseAfterFeeding:
        return Colors.blueGrey.shade600;
      case cev.ClinicalEventType.rrtStart:
        return e.rrtModality == cev.RrtModality.crrt
            ? Colors.purple.shade600
            : Colors.teal.shade700;
    }
  }

  /// 日付軸の下に、臨床イベントの有効期間を ┝────┤ の帯で表示（§23.3）。
  /// チャートの棒/線座標は触らず、日付列に揃えた帯を別Rowで重ねる。
  /// RRT開始は次のRRTイベント直前まで（無ければ終端まで）。停止は帯にしない。
  static const double _eventSpanRowH = 17.0;
  static const int _eventSpanMaxRows = 6;

  /// 種類別レーンの並び順（小さいほど上）。RRTはモダリティ問わず1レーン。
  int _eventLaneOrder(cev.ClinicalEventType t) => switch (t) {
        cev.ClinicalEventType.recurrentNpo => 0,
        cev.ClinicalEventType.refeedingHypophosphatemia => 1,
        cev.ClinicalEventType.rrtStart => 2,
        cev.ClinicalEventType.fluidOverload => 3,
        cev.ClinicalEventType.cholestasisOrLiverDysfunction => 4,
        cev.ClinicalEventType.enIntolerance => 5,
        cev.ClinicalEventType.enHold => 6,
        cev.ClinicalEventType.bunRiseAfterFeeding => 7,
      };

  /// 各臨床イベントの帯スパン (start,end(chart idx),label,color,lane) を算出。
  /// 同じ種類は同じレーン、種類が違えば別レーンに縦並列（空きレーンは詰める）。
  List<(int, int, String, Color, int)> _eventSpans(int n, int preDays) {
    if (_clinicalEvents.isEmpty || n <= 0) return const [];
    final raw = <(int, int, String, Color, int)>[]; // 第5要素=種類のlaneOrder
    final presentKeys = <int>{};
    for (final e in _clinicalEvents) {
      final startIdx = (preDays + e.startDay - 1).clamp(0, n - 1);
      if (preDays + e.startDay - 1 > n - 1) continue; // タイムライン外
      final endIdx = e.endDay != null
          ? (preDays + e.endDay! - 1).clamp(startIdx, n - 1)
          : n - 1;
      final label = e.type == cev.ClinicalEventType.rrtStart
          ? (e.rrtModality?.key ?? 'RRT')
          : _clinicalEventShortLabel(e.type);
      final key = _eventLaneOrder(e.type);
      presentKeys.add(key);
      raw.add((startIdx, endIdx, label, _eventSpanColor(e), key));
    }
    if (raw.isEmpty) return const [];
    // 出現した種類だけで詰めたレーンindexへ（空レーンを作らない）。
    final sortedKeys = presentKeys.toList()..sort();
    final laneOf = {for (var i = 0; i < sortedKeys.length; i++) sortedKeys[i]: i};
    final spans = raw
        .map((s) => (s.$1, s.$2, s.$3, s.$4, laneOf[s.$5]!))
        .toList()
      ..sort((a, b) => a.$1.compareTo(b.$1)); // 同レーン内の描画順
    return spans;
  }

  /// 使用レーン数（=縦の本数。最大 _eventSpanMaxRows）。
  int _eventLaneCount(int n, int preDays) {
    final spans = _eventSpans(n, preDays);
    if (spans.isEmpty) return 0;
    var maxLane = 0;
    for (final s in spans) {
      if (s.$5 > maxLane) maxLane = s.$5;
    }
    return (maxLane + 1).clamp(1, _eventSpanMaxRows);
  }

  /// 期間バー領域の高さ（チャート固定高さに加算してクリップを防ぐ）。
  double _eventSpanHeight(int n, int preDays) {
    final lanes = _eventLaneCount(n, preDays);
    if (lanes == 0) return 0;
    // _eventSpanBars: SizedBox(lanes*rowH+2) + Padding(top2+bottom2)=+6
    return lanes * _eventSpanRowH + 6;
  }

  /// ラベル幅の概算（CJKは広め）。配置判定用。
  double _estLabelWidth(String s) {
    var w = 0.0;
    for (final r in s.runes) {
      w += r > 0x2E80 ? 10.0 : 6.2; // CJK ~10px / ASCII ~6px (fontSize 9.5)
    }
    return w;
  }

  Widget _eventSpanBars(int n, int preDays) {
    if (_cachedChartW <= 0 || n <= 0) return const SizedBox.shrink();
    // レーンが上限を超える種類は描画しない（稀）。
    final rows = _eventSpans(n, preDays)
        .where((s) => s.$5 < _eventSpanMaxRows)
        .toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    final cellW = _cachedChartW / n;
    const rowH = _eventSpanRowH;
    final cardBg = Theme.of(context).cardColor;
    final laneCount = _eventLaneCount(n, preDays);

    // ┝─┤ バー本体（cap＋線＋cap）。
    Widget bar(Color color) => Row(children: [
          Container(width: 1.5, height: 8, color: color),
          Expanded(child: Container(height: 2.5, color: color)),
          Container(width: 1.5, height: 8, color: color),
        ]);

    Widget rowWidget((int, int, String, Color, int) s) {
      final left = s.$1 * cellW;
      final width = (s.$2 - s.$1 + 1) * cellW;
      final color = s.$4;
      final lane = s.$5; // 種類別の縦レーン
      final labelW = _estLabelWidth(s.$3);
      // 1: バーが十分長い → 中央に記載（線の上に乗せ、背景でマスク）
      final fitsCenter = labelW + 12 <= width;
      // 3: 短く、同レーンで直後に別バーが続く（CRRT→IRRT等）→ 左端に記載
      final hasFollower = rows.any((o) =>
          !identical(o, s) &&
          o.$5 == s.$5 &&
          o.$1 >= s.$2 &&
          o.$1 <= s.$2 + 1);

      final label = Text(s.$3,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: TextStyle(
              fontSize: 9.5,
              height: 1.0,
              color: color,
              fontWeight: FontWeight.bold));

      final children = <Widget>[
        // バー本体
        Positioned(left: left, width: width, top: 5, child: bar(color)),
      ];
      if (fitsCenter) {
        // 1: 中央（線を背景色でマスクして ├──CRRT──┤ に見せる）
        children.add(Positioned(
          left: left,
          width: width,
          top: 2.5,
          child: Center(
            child: Container(
              color: cardBg,
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: label,
            ),
          ),
        ));
      } else {
        // 短い → バー外側へ。画面端・自バーと重ならない側を選ぶ（pixel基準）。
        final rightX = left + width + 3;
        final leftX = left - labelW - 3;
        final rightFits = rightX + labelW <= _cachedChartW;
        final leftFits = leftX >= 0;
        double x;
        if (hasFollower && leftFits) {
          x = leftX; // 3: 後続あり（CRRT→IRRT等）は左端優先
        } else if (rightFits) {
          x = rightX; // 2: 右端
        } else if (leftFits) {
          x = leftX; // 右に入らなければ左へ退避
        } else {
          x = (_cachedChartW - labelW).clamp(0.0, _cachedChartW); // 端でクランプ
        }
        children.add(Positioned(left: x, top: 2.5, child: label));
      }

      return Positioned(
        left: 0,
        width: _cachedChartW,
        top: lane * rowH, // 種類別レーンの縦位置
        height: rowH,
        child: Stack(clipBehavior: Clip.none, children: children),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: SizedBox(
        width: _cachedChartW,
        height: laneCount * rowH + 2,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final s in rows) rowWidget(s),
          ],
        ),
      ),
    );
  }

  // 栄養開始日からの mm/dd
  String _dateOf(int i) {
    final d = _startDate.add(Duration(days: i));
    return '${d.month}/${d.day}';
  }

  // クラスのバッジ表示
  Widget _modeBadge(String mode, {bool planIsZero = false}) {
    final baseLabel = switch (mode) {
      'TPN' => 'PN',
      'TPN+EN' => 'EN+PN',
      'EN' => 'EN',
      'ZERO' => 'ゼロmenu',
      '食事' => '食事',
      _ => mode,
    };
    // PN部分がゼロmenuにフォールバックした場合の表記
    final label = (mode == 'TPN+EN' && planIsZero) ? 'EN+ゼロmenu' : baseLabel;
    final color = switch (mode) {
      'TPN' => Colors.blue,
      'TPN+EN' => Colors.teal,
      'EN' => Colors.amber.shade500,
      '食事' => Colors.deepOrange.shade400,
      _ => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 12, color: color, fontWeight: FontWeight.bold)),
    );
  }

  // 全期間を固定シーケンスで自動生成:
  //   目標%(総カロリー)はrampDaysで100%まで等差で漸増し、以降100%を維持(EN導入とは独立)
  //   EN食上げ(enStartDay以降7日): 10→20→30→40ml/h → 1pac→2pac朝昼夕、PNは自動減量、最終日はEN単独full
  /// 自動連動(inclusive): 20kcal/kg上限はEN開始日まで、25kcal/kg上限は経口リハ開始日まで。
  /// 以降は上限解除(full)。full達成(_rampDays=傾きの終点)は連動しない(実到達日は別途算出)。
  void _applyAutoKcalSteps() {
    // 20kcal/kg上限はEN開始日まで、25kcal/kg上限は経口リハ開始日まで(以降はfull)。
    _kcalStep20Day = _enStartDay.clamp(1, 28);
    final oral = _oralRehabStartDay ?? (_enStartDay + _enRampDays);
    _kcalStep25Day = oral.clamp(_kcalStep20Day, 28);
    // full達成(_rampDays)は強制連動しない(傾きと実到達点は別概念)。
    // 実到達日は effectiveFullDay() で算出し UI に並記する。
  }

  void _rebuildDays() {
    _invalidateEngineResult();
    // 日構成・設定が変わるとプランが作り直されるので手動修正は破棄(整合性優先)。
    _manualDayOverride.clear();
    _manualDayChanges.clear();
    if (_enStartDay < 1) _enStartDay = 1;
    if (_kcalStepAuto) _applyAutoKcalSteps();
    final enEnd = _enStartDay + _enRampDays - 1;
    final oral = _oralRehabStartDay;
    // 経口リハ開始日+5日(計6日)まで延長
    final mealEnd = oral != null ? oral + _mealRampDays - 1 : 0;
    _totalDays = enEnd > mealEnd ? enEnd : mealEnd;
    // 実到達日(係数上限・refeeding capでfullが遅れうる)まで表示期間を拡張し、full到達を含める。
    final effFull = _effectiveFullDay();
    if (effFull > _totalDays) _totalDays = effFull;
    for (final e in _clinicalEvents) {
      var eventEnd = e.endDay ?? e.startDay;
      // Refeeding終了後のglide(緩徐再上げ)期間も表示・計算に含める
      if (e.type == cev.ClinicalEventType.refeedingHypophosphatemia &&
          e.endDay != null) {
        eventEnd = e.endDay! + _postRefeedingGlideDays;
      }
      if (eventEnd > _totalDays) _totalDays = eventEnd;
    }
    // 設定変更を親(チャートパネル)に通知
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSettingsChanged?.call();
    });
    final n = _totalDays;
    _dayPercents = List.generate(n, (i) {
      final day = i + 1;
      // 総カロリーは等差ramp優先: rampDaysで100%まで漸増、以降100%維持
      if (day <= _rampDays) {
        return ((day * 100.0 / _rampDays).clamp(0.0, 100.0)).roundToDouble();
      }
      return 100.0;
    });
    _dayModes = List.generate(n, (i) {
      final day = i + 1;
      if (oral != null && day >= oral) return '食事'; // 経口リハ期は食事主体
      if (day < _enStartDay) return 'TPN'; // EN導入前はPNのみ
      final step = (day - _enStartDay).clamp(0, _enRampDays - 1);
      if (step == _enRampDays - 1) return 'EN'; // 最終ステップはEN単独full
      return 'TPN+EN'; // 食上げ中はPN+EN併用(PN自動減量)
    });
    _dayEnDose = List.generate(n, (i) {
      final day = i + 1;
      if (oral != null && day >= oral) return '0'; // 食事期のENは食事ロジック側で補完
      if (day < _enStartDay) return '0';
      final step = (day - _enStartDay).clamp(0, _enRampDays - 1);
      return _enRampSequence[step];
    });
    // 経口リハ ラダー: 経口スロット数とpac/slotを段階的に上げる(残りスロットはEN)。
    //   朝1pac昼夕EN → 朝昼1pac夕EN → 朝昼夕1pac → 朝昼夕2pac。以降は最終段を維持。
    _dayMealSlots = List.generate(n, (i) {
      final day = i + 1;
      if (oral == null || day < oral) return 0;
      final d = (day - oral).clamp(0, _mealLadder.length - 1);
      return _mealLadder[d][0];
    });
    _dayMealPac = List.generate(n, (i) {
      final day = i + 1;
      if (oral == null || day < oral) return 0;
      final d = (day - oral).clamp(0, _mealLadder.length - 1);
      return _mealLadder[d][1];
    });
  }

  @override
  Widget build(BuildContext context) {
    final targetKcal = NutritionCalculator.targetEnergy(widget.current);
    final referenceWeight =
        NutritionCalculator.referenceWeightKg(widget.current);
    final engineResult = _engineReadModel;
    final structuredAlertsByDay = _structuredAlertsByDay(engineResult);
    final pcts = _dayPercents;
    // お気に入り製剤(手動★＋病態タグ由来)を先頭に並べて優先選択させる
    List<Product> sortFav(List<Product> list) {
      final fav = list
          .where((p) => widget.state.isEffectiveFavorite(p.id, widget.current))
          .toList();
      final rest = list
          .where((p) => !widget.state.isEffectiveFavorite(p.id, widget.current))
          .toList();
      return [...fav, ...rest];
    }

    final enList = sortFav(_adopted('EN'));
    final tpnAll = sortFav(_adopted('TPN'));
    final tpnList = tpnAll;
    final ppnList = sortFav(_adopted('PPN'));
    final mealList = sortFav(_adoptedMeals());
    // _pnProduct が採用TPNに無ければ先頭にフォールバック
    if (_pnProduct == null || !tpnAll.any((p) => p.id == _pnProduct!.id)) {
      _pnProduct = tpnAll.isNotEmpty ? tpnAll.first : null;
    }
    // プランを逐次生成して minEnKcal(単調増加制約)を引き継ぐ
    double prevEnKcal = 0;
    final dayPlans = <DesignPlan>[];
    _dayRepairChanges.clear();
    for (int i = 0; i < pcts.length; i++) {
      final phase = _acutePhaseTarget(i);
      final mode = _derivedModeForDay(i);
      final enDose = _derivedEnDoseForDay(i);
      final dayTargetKcal = _derivedKcalTarget(i, phase.kcal);
      final dayTargetProt = _derivedProteinTarget(i, phase.prot);
      var plan = NutritionCalculator.designDay(
        mode: mode,
        dayTargetKcal: dayTargetKcal,
        dayTargetProt: dayTargetProt,
        weightKg: referenceWeight,
        enProducts: enList,
        enRateMlH: _rateOf(enDose),
        enPac: _pacOf(enDose),
        pnProduct: _pnProduct,
        tpnProducts: tpnList,
        ppnProducts: ppnList,
        glucoseProduct: widget.state.adoptedByBase('70% グルコース'),
        aminoProduct: widget.state.adoptedAminoForZero(),
        lipidProduct: widget.state.adoptedLipidForZero(),
        minEnKcal: prevEnKcal,
        mealProducts: mealList,
        mealPac: _derivedMealPacForDay(i),
        mealSlots: _derivedMealSlotsForDay(i),
        girLimitMgKgMin: _girLimit,
        maxLipidGramPerKgDay: ck.ClinicalConst.lipidDayLimitGKgD,
        // ゼロmenuはPN専用が6日続いた翌日(7日目, i>=6)以降のPN専用日のみ許可
        allowZeroMenu: mode == 'TPN' && i >= 6,
        // refeeding/event時はAA補充込みの総kcalがその日のcapを超えないようにする(安全優先)。
        hardKcalCap: _hardKcalCapForDay(i, dayTargetKcal),
        aaSupplementBelowFrac: 0.90, // 目標90%未満(=10%以上へこむ)時だけAA補充
        aaSupplementMaxMl: 500, // アミパレン補充は合計500ml/day上限
        conditionTags: widget.current.conditionTags, // ゼロmenuのNPC/N・脂質を病態連動
      );
      // B1自動加注 + repair(Mn-free置換/Na減/Zn・Se補充/タンパク調整)を適用
      final changes = <RepairChange>[];
      plan = _b1AndRepair(plan, i, out: changes);
      // 手動修正(アラートリンクからワンタップ採用)があれば上書き
      if (_manualDayOverride.containsKey(i)) plan = _manualDayOverride[i]!;
      _dayRepairChanges.add(changes);
      dayPlans.add(plan);
      if (plan.enKcal > 0 && mode != '食事') prevEnKcal = plan.enKcal;
    }

    final screenH = MediaQuery.of(context).size.height;
    // Visibility(maintainState)内でExpandedは使えないため高さを固定する
    final listH = (screenH * 0.55).clamp(300.0, 600.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: listH,
          child: ListView(
            padding: EdgeInsets.zero, // 外側ListView(all:16)が既にパディングを持つ
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 設定: 絶食〜経口リハ(左) + 栄養係数上限(右)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Table(
                              defaultVerticalAlignment:
                                  TableCellVerticalAlignment.middle,
                              columnWidths: const {
                                0: IntrinsicColumnWidth(), // ラベル列（最長に合わせる）
                                1: IntrinsicColumnWidth(), // 値列
                              },
                              children: [
                                // 行0: 絶食日（常時表示・タップで設定）
                                TableRow(children: [
                                  _settingLabelCell(Icons.no_meals, '絶食日:',
                                      Colors.red.shade400),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        TextButton(
                                          style: TextButton.styleFrom(
                                              padding: EdgeInsets.zero,
                                              minimumSize: const Size(0, 0),
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              foregroundColor:
                                                  Colors.red.shade400),
                                          onPressed: () async {
                                            final fd =
                                                widget.current.fastingDate;
                                            final initial = fd != null
                                                ? (DateTime.tryParse(fd) ??
                                                    _startDate)
                                                : _startDate;
                                            final picked = await _quickPickDate(
                                                context, initial);
                                            if (picked != null) {
                                              setState(() {
                                                widget.current.fastingDate =
                                                    '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                                              });
                                              widget.state.persist();
                                              widget.onSettingsChanged?.call();
                                            }
                                          },
                                          child: Builder(builder: (_) {
                                            final fd =
                                                widget.current.fastingDate;
                                            final p = fd != null
                                                ? DateTime.tryParse(fd)
                                                : null;
                                            final label = p != null
                                                ? '${p.year}/${p.month.toString().padLeft(2, '0')}/${p.day.toString().padLeft(2, '0')}'
                                                : '未設定';
                                            return Text(label,
                                                style: TextStyle(
                                                    fontSize: 13,
                                                    color: p != null
                                                        ? Colors.red.shade400
                                                        : Colors.grey));
                                          }),
                                        ),
                                      ],
                                    ),
                                  ),
                                ]),
                                // 行1: 栄養開始日
                                TableRow(children: [
                                  _settingLabelCell(Icons.water_drop, '栄養開始日:',
                                      Colors.blue.shade600),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton(
                                          style: TextButton.styleFrom(
                                              padding: EdgeInsets.zero,
                                              minimumSize: const Size(0, 0),
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              foregroundColor:
                                                  Colors.blue.shade600),
                                          onPressed: () async {
                                            final picked = await _quickPickDate(
                                                context, _startDate);
                                            if (picked != null) {
                                              setState(
                                                  () => _startDate = picked);
                                              _saveConfig();
                                              widget.onSettingsChanged?.call();
                                            }
                                          },
                                          child: Text(
                                              '${_startDate.year}/${_startDate.month.toString().padLeft(2, '0')}/${_startDate.day.toString().padLeft(2, '0')}',
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.blue.shade600)),
                                        )),
                                  ),
                                ]),
                                // 行2: full nutrition達成
                                TableRow(children: [
                                  _settingLabelCell(Icons.flag, 'full達成:',
                                      Colors.green.shade800),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text('Day ',
                                            style: TextStyle(fontSize: 13)),
                                        SizedBox(
                                          width: _dayDropW,
                                          child: DropdownButton<int>(
                                            value: _rampDays.clamp(2, 12),
                                            isDense: true,
                                            isExpanded: true,
                                            items:
                                                List.generate(11, (i) => i + 2)
                                                    .map((d) =>
                                                        DropdownMenuItem(
                                                            value: d,
                                                            child: Text('$d')))
                                                    .toList(),
                                            // 自動時も編集可能(傾きの終点)。実到達日は別途並記。
                                            onChanged: (v) {
                                              setState(() {
                                                _rampDays = v ?? _rampDays;
                                                _rebuildDays();
                                              });
                                              _saveConfig();
                                              widget.onSettingsChanged?.call();
                                            },
                                          ),
                                        ),
                                        // 実到達日(係数上限で設定値と乖離しうるため並記)
                                        Builder(builder: (_) {
                                          final effFull = _effectiveFullDay();
                                          return Padding(
                                            padding:
                                                const EdgeInsets.only(left: 6),
                                            child: Text('実到達 Day$effFull',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: effFull == _rampDays
                                                        ? Colors.grey
                                                        : Colors.deepOrange
                                                            .shade400)),
                                          );
                                        }),
                                      ],
                                    ),
                                  ),
                                ]),
                                // 行3: EN導入 (色はグラフのEN(アンバー)と統一)
                                TableRow(children: [
                                  _settingLabelCell(Icons.lunch_dining, 'EN導入:',
                                      Colors.amber.shade700),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text('Day ',
                                            style: TextStyle(fontSize: 13)),
                                        SizedBox(
                                          width: _dayDropW,
                                          child: DropdownButton<int>(
                                            value: _enStartDay.clamp(1, 21),
                                            isDense: true,
                                            isExpanded: true,
                                            items:
                                                List.generate(21, (i) => i + 1)
                                                    .map((d) =>
                                                        DropdownMenuItem(
                                                            value: d,
                                                            child: Text('$d')))
                                                    .toList(),
                                            onChanged: (v) {
                                              setState(() {
                                                _enStartDay = v ?? _enStartDay;
                                                _rebuildDays();
                                              });
                                              _saveConfig();
                                              widget.onSettingsChanged?.call();
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ]),
                                // 行4: 経口リハ導入 (EN導入行と同一レイアウト)
                                TableRow(children: [
                                  _settingLabelCell(Icons.restaurant, '経口リハ導入:',
                                      Colors.red.shade400),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text('Day ',
                                            style: TextStyle(fontSize: 13)),
                                        SizedBox(
                                          width: _dayDropW,
                                          child: DropdownButton<int?>(
                                            value: _oralRehabStartDay,
                                            isDense: true,
                                            isExpanded: true,
                                            hint: const Text('—',
                                                style: TextStyle(fontSize: 13)),
                                            items: [
                                              const DropdownMenuItem<int?>(
                                                  value: null,
                                                  child: Text('—')),
                                              ...List.generate(28, (i) => i + 1)
                                                  .map((d) =>
                                                      DropdownMenuItem<int?>(
                                                          value: d,
                                                          child: Text('$d'))),
                                            ],
                                            onChanged: (v) {
                                              setState(() {
                                                _oralRehabStartDay = v;
                                                _rebuildDays(); // 食事フェーズを再生成
                                              });
                                              _saveConfig();
                                              widget.onSettingsChanged?.call();
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ]),
                              ],
                            ),
                            const SizedBox(width: 16),
                            // 栄養係数上限(絶食〜経口リハの右側)
                            Table(
                              defaultVerticalAlignment:
                                  TableCellVerticalAlignment.middle,
                              columnWidths: const {
                                0: IntrinsicColumnWidth(),
                                1: IntrinsicColumnWidth(),
                              },
                              children: _kcalStepTableRows(),
                            ),
                            const SizedBox(width: 16),
                            // 3列目: 主要な臨床経過（イベント名 dd/mm - dd/mm）
                            _clinicalCourseColumn(),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      _engineSourceBadgeLegend(engineResult),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: (listH - 240).clamp(220.0, 460.0),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    ...List.generate(pcts.length, (i) {
                      final phase = _acutePhaseTarget(i);
                      final dayKcal = _derivedKcalTarget(i, phase.kcal);
                      final dayProt = _derivedProteinTarget(i, phase.prot);
                      final pctOfFull =
                          targetKcal > 0 ? dayKcal / targetKcal * 100 : 0.0;
                      final mode = _derivedModeForDay(i);
                      final dose = _derivedEnDoseForDay(i);
                      final showEn = mode == 'EN' || mode == 'TPN+EN';
                      // 逐次生成済みのプランを使用（minEnKcal単調増加制約適用済み）
                      final plan = dayPlans[i];
                      final structuredAlerts =
                          structuredAlertsByDay[i] ?? const [];
                      return SizedBox(
                          width: 264,
                          child: Card(
                            margin: const EdgeInsets.only(right: 10),
                            child: InkWell(
                              onTap: () =>
                                  _showDayDetail(i, plan, dayKcal, dayProt),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Text(_dateOf(i),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold)),
                                      const SizedBox(width: 6),
                                      Text('(Day${i + 1})',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey)),
                                    ]),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        // 目標% or "full nutrition"（常にgreen）
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.green.shade100,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            pctOfFull >= 99
                                                ? 'full nutrition'
                                                : '目標 ${pctOfFull.round()}%',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.green.shade800),
                                          ),
                                        ),
                                        if (showEn) ...[
                                          const SizedBox(width: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: Colors.amber.shade200,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              border: Border.all(
                                                  color: Colors.amber.shade600,
                                                  width: 0.8),
                                            ),
                                            child: Text(_doseLabel(dose),
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color:
                                                        Colors.brown.shade700)),
                                          ),
                                        ],
                                        if (mode == '食事') ...[
                                          const SizedBox(width: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: Colors.orange.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              border: Border.all(
                                                  color: Colors
                                                      .deepOrange.shade400,
                                                  width: 0.8),
                                            ),
                                            child: Text(
                                                '朝昼夕 ${_derivedMealPacForDay(i)}pac',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors
                                                        .orange.shade800)),
                                          ),
                                        ],
                                        ..._eventBadgesForDay(i),
                                        ..._engineBandDots(i, plan,
                                            referenceWeight, engineResult),
                                        _modeBadges(plan),
                                      ],
                                    ),
                                    const Divider(height: 16),
                                    Expanded(
                                      child: SingleChildScrollView(
                                        child: _planBody(
                                            plan, dayKcal, dayProt, mode),
                                      ),
                                    ),
                                    // 処方カード下のアラートリンク → 当日のアラート/手動修正シート
                                    if (plan.items.isNotEmpty)
                                      _dayAlertLink(i, plan,
                                          structuredAlerts: structuredAlerts),
                                  ],
                                ),
                              ),
                            ),
                          ));
                    }),
                  ],
                ),
              ),
            ],
          ),
        ), // SizedBox(listH)
      ],
    );
  }

  // BuilderPage の _buildAutoChartPanel から呼ばれる
  Widget _buildBarChartsForBuilder() {
    final targetKcal = NutritionCalculator.targetEnergy(widget.current);
    final pcts = _dayPercents;
    List<Product> sortFav(String cat) {
      final list = widget.state.catalog
          .byCategory(cat)
          .where((p) => widget.state.isAdopted(p.id))
          .toList();
      final fav = list
          .where((p) => widget.state.isEffectiveFavorite(p.id, widget.current))
          .toList();
      final rest = list
          .where((p) => !widget.state.isEffectiveFavorite(p.id, widget.current))
          .toList();
      return [...fav, ...rest];
    }

    return _buildBarCharts(
        targetKcal, pcts, sortFav('EN'), sortFav('TPN'), sortFav('PPN'));
  }

  /// プラン内のEN/EN補助製剤由来のカロリーを集計
  double _enKcalOfPlan(DesignPlan plan) {
    double s = 0;
    for (final it in plan.items) {
      final p = widget.state.catalog.byName(it.name);
      // 食事(濃厚流動食/栄養サポート)はEN扱いしない。EN本体/補助のみ集計
      if (p != null &&
          !p.isFood &&
          (p.category == 'EN' || p.category == 'EN_AUX')) {
        s += it.kcal;
      }
    }
    return s;
  }

  // 食事(経口リハ)由来kcal: 濃厚流動食/栄養サポート製剤の合計
  double _mealKcalOfPlan(DesignPlan plan) {
    double s = 0;
    for (final it in plan.items) {
      final p = widget.state.catalog.byName(it.name);
      if (p != null && p.isFood) s += it.kcal;
    }
    return s;
  }

  /// 自動設計で用いるGIR上限（糖質制限病態は4、それ以外は5 mg/kg/min）。
  double get _girLimit =>
      (cc.resolveCoeff(widget.current.conditionTags)?.glucoseRestrict ?? false)
          ? ck.ClinicalConst.girWarnMgKgMin
          : ck.ClinicalConst.girLimitMgKgMin;

  /// Refeeding（NICE）リスク階層。
  /// BMI・絶食日数から自動で立つフラグ ∪ 患者編集で手動選択した基準フラグ
  /// （体重減・低電解質・アルコール/薬物歴 等）を refeedingTierFromFlags で評価する。
  /// 従来のBMI/絶食自動判定の上位互換（手動入力も連動）。
  cr.RefeedingTier get _refeedingTier {
    final c = widget.current;
    final bmi = cbw.bmiOf(c.weightKg, c.heightCm);
    int? days;
    final fr = c.fastingDate != null ? DateTime.tryParse(c.fastingDate!) : null;
    if (fr != null) {
      days = DateTime(_startDate.year, _startDate.month, _startDate.day)
          .difference(DateTime(fr.year, fr.month, fr.day))
          .inDays;
    }
    // 保存値は手動基準のみ採用（旧/外部JSONの stale な自動フラグ bmi_*/intake_* を除外）。
    final flags = cr.autoRefeedingFlags(bmi: bmi, daysNoIntake: days)
      ..addAll(c.refeedingFlags.where(cr.isManualRefeedingCriterion));
    return cr.refeedingTierFromFlags(flags);
  }

  /// Refeedingリスク時、栄養開始からの feeding 日(0始まり)で kcal を上限cap。
  double _refeedCappedKcal(int dayIndexZero, double rawKcal) {
    final tier = _refeedingTier;
    if (tier == cr.RefeedingTier.none) return rawKcal;
    final fw =
        NutritionCalculator.targetEnergyResult(widget.current).feedingWeightKg;
    if (fw <= 0) return rawKcal;
    final fullKpk = NutritionCalculator.targetEnergy(widget.current) / fw;
    final cap = cr.refeedingCapKcalPerKg(tier, dayIndexZero + 1, fullKpk) * fw;
    return rawKcal < cap ? rawKcal : cap;
  }

  /// 各日の目標。kcal = 等差ランプ ∧ 係数上限(ce.acutePhaseTargetKcal)。
  /// タンパクも同じ等差ランプ(day1=15〜30%→full達成日で100%)で増やす(係数上限は掛けない)。
  /// 等差なので単調増加=AAが途中でへこまない。
  ({double kcal, double prot}) _acutePhaseTarget(int i) {
    final realFull = NutritionCalculator.targetEnergy(widget.current);
    final realProt = NutritionCalculator.targetProtein(widget.current);
    final fw =
        NutritionCalculator.targetEnergyResult(widget.current).feedingWeightKg;
    final raw = ce.acutePhaseTargetKcal(
      day: i + 1,
      feedingWeightKg: fw,
      realFullKcal: realFull,
      fullAchieveDay: _rampDays,
      kcal20UntilDay: _kcalStep20Day,
      kcal25UntilDay: _kcalStep25Day,
    );
    final cappedKcal = _refeedCappedKcal(i, raw);
    // タンパクもカロリーと同じ等差ランプ(day1=15〜30%→full達成日で100%)で増やす。
    final protFrac =
        ce.acutePhaseRampFraction(day: i + 1, fullAchieveDay: _rampDays);
    return (kcal: cappedKcal, prot: realProt * protFrac);
  }

  /// full nutrition 実到達日(1始まり)。等差ランプ・係数上限に加え **refeeding cap も込み**で
  /// 各日目標kcalが realFull に到達する最初の日。設定上のfull達成(傾き終点)とは別概念。
  int _effectiveFullDay() {
    final realFull = NutritionCalculator.targetEnergy(widget.current);
    if (realFull <= 0) return _rampDays;
    for (int d = 1; d <= 90; d++) {
      if (_acutePhaseTarget(d - 1).kcal >= realFull * 0.995) return d;
    }
    return 90;
  }

  /// 1日プランの電解質・微量元素・ビタミンUL超過アラート。
  List<cm.MicroAlert> _dayMicroAlerts(DesignPlan p) {
    final totals = cm.aggregateMicro(p.items.map((it) {
      var prod = widget.state.catalog.byName(it.name);
      double mult;
      if (prod == null) {
        // 加注プレースホルダ('電解質製剤'/'微量元素製剤'/'ビタミン製剤')→採用標準製剤に解決
        prod = _resolveAdditivePlaceholder(it.name);
        mult = prod != null ? 1.0 : 0.0; // 1日1管相当
      } else if ((it.units ?? 0) > 0) {
        mult = it.units!.toDouble();
      } else if ((prod.volumeMl ?? 0) > 0) {
        mult = it.volumeMl / prod.volumeMl!;
      } else {
        mult = 0;
      }
      return cm.MicroContribution(prod?.micro, mult);
    }));
    final bmi = cbw.bmiOf(widget.current.weightKg, widget.current.heightCm);
    final f = _microFlags(widget.current.conditionTags,
        bmi: bmi, refeedingHigh: _refeedingTier != cr.RefeedingTier.none);
    double carb = 0;
    for (final it in p.items) {
      final pr = widget.state.catalog.byName(it.name);
      final base = pr?.carbBase ?? 0;
      if (base <= 0) continue;
      carb += (pr?.volumeMl ?? 0) > 0
          ? base * it.volumeMl / pr!.volumeMl!
          : base * (it.units ?? 0);
    }
    return cm.microAlerts(totals,
        isMale: widget.current.sex == Sex.male,
        longTermTpn: false,
        cholestasis: f.cholestasis,
        liver: f.liver,
        renal: f.renal,
        crrt: f.crrt,
        giLoss: f.giLoss,
        glucoseLoad: carb > 0,
        wernickeRisk: f.wernicke);
  }

  /// 加注プレースホルダ名→採用済み標準製剤(なければ先頭)に解決。
  Product? _resolveAdditivePlaceholder(String name) {
    String? cat;
    if (name == '微量元素製剤') {
      cat = '微量元素';
    } else if (name == 'ビタミン製剤') {
      cat = 'ビタミン';
    } else if (name == '電解質製剤') {
      cat = '電解質';
    }
    if (cat == null) return null;
    final adopted = widget.state.catalog
        .byCategory(cat)
        .where((p) => widget.state.isAdopted(p.id))
        .toList();
    // 胆汁うっ滞/肝障害では微量元素はMn-freeを優先
    if (cat == '微量元素' &&
        (widget.current.conditionTags.contains('cholestasis') ||
            widget.current.conditionTags.contains('liver'))) {
      final mnFree = adopted.where((p) => p.isMnFreeTrace).toList();
      if (mnFree.isNotEmpty) return mnFree.first;
      final anyMnFree = widget.state.catalog
          .byCategory('微量元素')
          .where((p) => p.isMnFreeTrace)
          .toList();
      if (anyMnFree.isNotEmpty) return anyMnFree.first;
    }
    if (adopted.isNotEmpty) return adopted.first;
    final all = widget.state.catalog.byCategory(cat);
    return all.isNotEmpty ? all.first : null;
  }

  Widget _buildBarCharts(double targetKcal, List<double> pcts, List<Product> en,
      List<Product> tpn, List<Product> ppn) {
    final referenceWeight =
        NutritionCalculator.referenceWeightKg(widget.current);
    final engineResult = _engineReadModel;
    final structuredAlertsByDay = _structuredAlertsByDay(engineResult);
    // 逐次生成して minEnKcal 単調増加制約を適用
    double prevEnKcalChart = 0;
    final designPlans = <DesignPlan>[];
    for (int i = 0; i < pcts.length; i++) {
      final phase = _acutePhaseTarget(i);
      final mode = _derivedModeForDay(i);
      final enDose = _derivedEnDoseForDay(i);
      final dayTargetKcal = _derivedKcalTarget(i, phase.kcal);
      final dayTargetProt = _derivedProteinTarget(i, phase.prot);
      var p = NutritionCalculator.designDay(
        mode: mode,
        dayTargetKcal: dayTargetKcal,
        dayTargetProt: dayTargetProt,
        weightKg: referenceWeight,
        enProducts: en,
        enRateMlH: _rateOf(enDose),
        enPac: _pacOf(enDose),
        pnProduct: _pnProduct,
        tpnProducts: tpn,
        ppnProducts: ppn,
        glucoseProduct: widget.state.adoptedByBase('70% グルコース'),
        aminoProduct: widget.state.adoptedAminoForZero(),
        lipidProduct: widget.state.adoptedLipidForZero(),
        minEnKcal: prevEnKcalChart,
        mealProducts: _adoptedMeals(),
        mealPac: _derivedMealPacForDay(i),
        mealSlots: _derivedMealSlotsForDay(i),
        girLimitMgKgMin: _girLimit,
        maxLipidGramPerKgDay: ck.ClinicalConst.lipidDayLimitGKgD,
        // ゼロmenuはPN専用が6日続いた翌日(7日目, i>=6)以降のPN専用日のみ許可
        allowZeroMenu: mode == 'TPN' && i >= 6,
        // refeeding/event時はAA補充込みの総kcalがその日のcapを超えないようにする(安全優先)。
        hardKcalCap: _hardKcalCapForDay(i, dayTargetKcal),
        aaSupplementBelowFrac: 0.90, // 目標90%未満時だけAA補充
        aaSupplementMaxMl: 500, // アミパレン補充は合計500ml/day上限
        conditionTags: widget.current.conditionTags, // ゼロmenuのNPC/N・脂質を病態連動
      );
      p = _b1AndRepair(p, i);
      // 手動修正(アラートリンクからワンタップ採用)があれば上書き(カードとグラフを一致させる)
      if (_manualDayOverride.containsKey(i)) p = _manualDayOverride[i]!;
      if (p.enKcal > 0 && mode != '食事') prevEnKcalChart = p.enKcal;
      designPlans.add(p);
    }

    // 絶食日が設定されていればそこから起算、なければ今日から
    final today = DateTime.now();
    final todayNorm = DateTime(today.year, today.month, today.day);
    final startNorm =
        DateTime(_startDate.year, _startDate.month, _startDate.day);
    final fastingRaw = widget.current.fastingDate != null
        ? DateTime.tryParse(widget.current.fastingDate!)
        : null;
    final chartOrigin = fastingRaw != null
        ? DateTime(fastingRaw.year, fastingRaw.month, fastingRaw.day)
        : todayNorm;
    final preDays = startNorm.difference(chartOrigin).inDays.clamp(0, 60);
    final emptyPlan = DesignPlan(label: 'Day', items: const []);
    final plans = [
      ...List.filled(preDays, emptyPlan),
      ...designPlans,
    ];

    final enKcals = plans.map(_enKcalOfPlan).toList();
    final mealKcals = plans.map(_mealKcalOfPlan).toList();
    final ins = plans.map((p) => p.totalVolumeMl).toList();
    final prots = plans.map((p) => p.totalProteinG).toList();
    final n = plans.length;
    // アラート(サジェスト)の表示: 折りたたみ(2)では非表示、全画面(1)では強制展開。
    final alertsShown = _trendViewMode != 2 &&
        (_alertsExpanded || _trendViewMode == 1);

    // 必須脂肪酸欠乏(EFAD)チェック:
    //   絶食開始(chartOrigin)からday14までに脂質が全く補充されていなければアラート。
    //   各itemの脂質gは製剤のfatBaseを投与量比で按分して算出。
    double fatOfPlan(DesignPlan p) {
      double f = 0;
      for (final it in p.items) {
        final prod = widget.state.catalog.byName(it.name);
        final base = prod?.fatBase ?? 0;
        if (base <= 0) continue;
        final pv = prod?.volumeMl ?? 0;
        f += pv > 0 ? base * it.volumeMl / pv : base * (it.units ?? 0);
      }
      return f;
    }

    // day14まで到達し、その間の累積脂質がほぼ0なら欠乏リスク
    final efadRisk = n >= 14 &&
        List.generate(14, (i) => fatOfPlan(plans[i]))
                .fold<double>(0.0, (s, v) => s + v) <
            1.0;

    // ビタミンB1(チアミン)アラート: リフィーディング症候群/Wernicke脳症予防
    //   公開情報: B1体内貯蔵は約30mg=2〜3週で枯渇。糖質(ブドウ糖)負荷でB1消費が
    //   増大し、絶食後の栄養再開でWernicke脳症/乳酸アシドーシスを来しうる。
    //   NICE基準: 5日以上の絶食/低栄養はリフィーディング高リスク。
    //   → 絶食≥5日 かつ 糖質投与あり でB1補充を促す。
    double carbOfPlan(DesignPlan p) {
      double c = 0;
      for (final it in p.items) {
        final prod = widget.state.catalog.byName(it.name);
        final base = prod?.carbBase ?? 0;
        if (base <= 0) continue;
        final pv = prod?.volumeMl ?? 0;
        c += pv > 0 ? base * it.volumeMl / pv : base * (it.units ?? 0);
      }
      return c;
    }

    final thiamineRisk =
        preDays >= 5 && designPlans.any((p) => carbOfPlan(p) > 0);

    // PN主体モニタリングアラート:
    //   EN≤30ml/hでPNが栄養の主体となる期間が、絶食開始から一定日数(7日)続く場合、
    //   電解質・微量元素・ビタミンの過不足を採血で確認し補正を検討するよう促す。
    int pnHeavyMaxDay = 0;
    for (int i = preDays; i < n; i++) {
      final j = i - preDays;
      if (j < 0 || j >= _dayEnDose.length) continue;
      final enRate = _rateOf(_dayEnDose[j]);
      final pnKcal = plans[i].totalKcal - _enKcalOfPlan(plans[i]);
      if (enRate <= 30 && pnKcal > 1) {
        final dayFromFasting = i + 1; // chartOrigin=絶食開始 → i番目はDay(i+1)
        if (dayFromFasting > pnHeavyMaxDay) pnHeavyMaxDay = dayFromFasting;
      }
    }
    final pnMonitorRisk = pnHeavyMaxDay >= 7;

    // Refeeding（NICE）リスク: 自動フラグ(絶食日数・BMI) ∪ 手動フラグ(体重減/低電解質/既往歴)で判定。
    final refeedTier = _refeedingTier;
    final refeedRisk = refeedTier != cr.RefeedingTier.none;
    // EN開始/遅延 判断（患者編集で選択した基準から推奨を算出）。
    final enTimingRec =
        cen.enTimingRecommendation(widget.current.enTimingFlags.toSet());
    final enTimingShow = widget.current.enTimingFlags.isNotEmpty;
    // CKRT稼働（採血提案のトリガー）。
    final ckrtActive =
        cc.CkrtObligation.appliesTo(widget.current.conditionTags);
    // 採血提案カード: refeeding/CKRT/長期PN いずれかで監視が必要なとき表示。
    final labShow = refeedRisk || ckrtActive || pnMonitorRisk;
    // 電解質・微量元素・ビタミンのUL超過: 日毎に集計し栄養素ごとに最高レベル/最早日を採用。
    final microByNutrient = <String, ({cm.MicroAlert alert, int dayIdx})>{};
    for (int i = 0; i < n; i++) {
      for (final a in _dayMicroAlerts(plans[i])) {
        final prev = microByNutrient[a.nutrient];
        if (prev == null || a.level.index > prev.alert.level.index) {
          microByNutrient[a.nutrient] = (alert: a, dayIdx: i);
        }
      }
    }
    final microAlertsList = microByNutrient.values.toList();
    final hasAlerts = efadRisk ||
        thiamineRisk ||
        pnMonitorRisk ||
        refeedRisk ||
        enTimingShow ||
        labShow ||
        microAlertsList.isNotEmpty;
    final alertCount = (efadRisk ? 1 : 0) +
        (thiamineRisk && !refeedRisk ? 1 : 0) +
        (pnMonitorRisk ? 1 : 0) +
        (refeedRisk ? 1 : 0) +
        (enTimingShow ? 1 : 0) +
        (labShow ? 1 : 0) +
        microAlertsList.length;

    // 日付ラベル: 同月内は日のみ, 月が変わる初日はmm/dd
    final dates = List.generate(n, (i) => chartOrigin.add(Duration(days: i)));
    String dateLabel(int i) {
      if (i == 0) return '${dates[i].month}/${dates[i].day}';
      if (dates[i].month != dates[i - 1].month) {
        return '${dates[i].month}/${dates[i].day}';
      }
      return '${dates[i].day}';
    }

    // 後方互換
    String mmdd(int i) => dateLabel(i);
    final maxKcal =
        plans.map((p) => p.totalKcal).fold<double>(1, (a, b) => a > b ? a : b) *
            1.1;
    final maxIn = ins.fold<double>(1, (a, b) => a > b ? a : b) * 1.1;
    // IN(水分量)のピーク値とそのDay（ピーク注記線・ラベル用）
    double inPeakVal = 0;
    int inPeakIdx = 0;
    for (var i = 0; i < ins.length; i++) {
      if (ins[i] > inPeakVal) {
        inPeakVal = ins[i];
        inPeakIdx = i;
      }
    }
    final maxAA = prots.fold<double>(1, (a, b) => a > b ? a : b) * 1.15;
    const hidden = AxisTitles(sideTitles: SideTitles(showTitles: false));
    // 特別日インデックス
    final fastingIdx = (widget.current.fastingDate != null) ? 0 : -1;
    final admissionEntry =
        widget.current.bedHistory.where((b) => b.fromBed == null).firstOrNull;
    final admissionRaw = admissionEntry != null
        ? DateTime.tryParse(admissionEntry.changedAt)
        : null;
    final admissionIdx = admissionRaw != null
        ? DateTime(admissionRaw.year, admissionRaw.month, admissionRaw.day)
            .difference(chartOrigin)
            .inDays
        : -1;
    final admissionIdxClamped =
        (admissionIdx >= 0 && admissionIdx < n) ? admissionIdx : -1;
    final nutritionIdx = preDays;
    // full nutrition実到達日(refeeding cap込み。設定上のfull達成=傾き終点とは別)。
    final _fullDay = _effectiveFullDay();
    final fullIdx = (preDays + _fullDay - 1).clamp(0, n - 1);
    final enIdx = (preDays + _enStartDay - 1).clamp(0, n - 1);
    final oralIdx =
        (_oralRehabStartDay != null && preDays + _oralRehabStartDay! - 1 < n)
            ? preDays + _oralRehabStartDay! - 1
            : -1;

    // 日付＋イベントアイコンのセル（グラフ下の独立Rowで使用）
    Widget dateCell(int i) {
      if (i < 0 || i >= n) return const SizedBox.shrink();

      // 同日イベントを収集して縦並べ
      // 表示順(上→下): 絶食 > 入室 > 栄養開始 > EN > full (EN/full同日はEN上)
      final List<bool> flags = [
        i == fastingIdx,
        i == admissionIdxClamped,
        i == nutritionIdx,
        i == enIdx && i >= preDays,
        i == fullIdx && i >= preDays,
        i == oralIdx && oralIdx >= 0,
      ];
      final dayIdx = i - preDays;
      final activeClinicalEvents = dayIdx >= 0 && dayIdx < _dayModes.length
          ? _overlayForDay(dayIdx).activeEvents
          : const <cev.ClinicalEvent>[];
      const maxClinicalMarkers = 2;
      final visibleClinicalMarkerCount =
          activeClinicalEvents.length > maxClinicalMarkers
              ? maxClinicalMarkers + 1
              : activeClinicalEvents.length;
      final bool hasEvent =
          flags.any((f) => f) || activeClinicalEvents.isNotEmpty;
      final int evCount =
          flags.where((f) => f).length + visibleClinicalMarkerCount;
      final double fs = evCount >= 2 ? 12.0 : 15.0; // boxラベル文字/アイコンサイズ

      // 入室からの経過日数(入室=0)。5の倍数(day5/10/15…)を丸囲み対象にする
      final int daysFromAdm =
          admissionIdxClamped >= 0 ? i - admissionIdxClamped : -999;
      final bool mult5FromAdm = daysFromAdm > 0 && daysFromAdm % 5 == 0;

      // 横幅が詰まっているとき(セル幅が狭い)は、日付ラベルを
      // 「イベント日」または「入室後5の倍数の日」のみに間引く
      //  (入室未設定時は従来どおり暦日の5の倍数で間引く)
      final double cellW = n > 0 ? _cachedChartW / n : 999;
      final bool cramped = cellW < 30;
      final bool showDate = !cramped ||
          hasEvent ||
          mult5FromAdm ||
          (admissionIdxClamped < 0 && dates[i].day % 5 == 0);

      // 横幅をはみ出しても折り返さない（横方向の制約を外す）
      Widget noWrap(Widget child) => UnconstrainedBox(
            constrainedAxis: Axis.vertical,
            clipBehavior: Clip.none,
            child: child,
          );

      Widget mkBox(String t, Color c) => noWrap(Container(
            padding: EdgeInsets.symmetric(
                horizontal: evCount >= 2 ? 2 : 3,
                vertical: evCount >= 2 ? 0.5 : 1),
            decoration: BoxDecoration(
              border: Border.all(color: c, width: 0.9),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(t,
                softWrap: false,
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: TextStyle(
                    fontSize: fs,
                    color: c,
                    fontWeight: FontWeight.bold,
                    height: 1.2)),
          ));

      // Material アイコンを四角囲みにする（mkBoxと同じ枠スタイル）
      Widget mkIconBox(IconData icon, Color c) => noWrap(Container(
            padding: EdgeInsets.all(evCount >= 2 ? 1 : 1.5),
            decoration: BoxDecoration(
              border: Border.all(color: c, width: 0.9),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Icon(icon, size: fs, color: c),
          ));

      final fixedEventWidgets = [
        if (flags[0]) mkIconBox(Icons.no_meals, Colors.red.shade400),
        if (flags[1]) mkIconBox(Icons.bed, Colors.blueGrey.shade400),
        // 栄養開始(=PN/輸液開始)は点滴(water_drop)アイコン。
        if (flags[2]) mkIconBox(Icons.water_drop, Colors.blue.shade600),
        if (flags[3]) mkBox('EN', Colors.amber.shade500),
        if (flags[4]) mkBox('full', Colors.green.shade700),
        // 経口リハ開始(濃厚流動食・栄サポ食品・一般食)はフォーク&ナイフアイコン。
        if (flags[5]) mkIconBox(Icons.restaurant, Colors.deepOrange.shade400),
      ];
      // 臨床イベントは日付下の期間バー(┝────┤)で表示するため、
      // 日付軸の色付きマーカーは出さない（重複・色変え不要）。
      final evWidgets = [...fixedEventWidgets];

      Widget? icon;
      if (evWidgets.length == 1) {
        icon = evWidgets.first;
      } else if (evWidgets.length >= 2) {
        icon = Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: evWidgets,
        );
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8), // バーと日付の間隔
          // 日付ラベル領域は固定高(22)。丸囲みの有無でアイコン位置がずれないように揃える
          SizedBox(
            height: 22,
            child: Center(
              child: !showDate
                  ? const SizedBox.shrink()
                  : mult5FromAdm
                      // 入室後day5の倍数は「円」で強調(楕円ではなく真円)
                      ? noWrap(Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Colors.blueGrey.shade400, width: 1.2),
                          ),
                          child: Text(dateLabel(i),
                              softWrap: false,
                              maxLines: 1,
                              overflow: TextOverflow.visible,
                              style: TextStyle(
                                  fontSize: 12,
                                  letterSpacing: -0.5,
                                  height: 1.0,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueGrey.shade700)),
                        ))
                      : noWrap(Text(dateLabel(i),
                          softWrap: false,
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                          style: const TextStyle(
                              fontSize: 14, letterSpacing: -0.5, height: 1.0))),
            ),
          ),
          const SizedBox(height: 8), // 日付とスタンプの間隔
          if (icon != null) icon else const SizedBox(height: 20),
        ],
      );
    }

    // 共通の透明な線グラフビルダー（タイトルなし・全4辺hidden）
    LineChart lineLayer(List<double> ys, double maxY, Color color) =>
        LineChart(LineChartData(
          minX: -0.5,
          maxX: n - 0.5,
          minY: 0,
          maxY: maxY,
          lineBarsData: [
            LineChartBarData(
              spots: [for (var i = 0; i < n; i++) FlSpot(i.toDouble(), ys[i])],
              color: color,
              barWidth: 2.5,
              dotData: FlDotData(
                show: true,
                getDotPainter: (s, p, b, idx) =>
                    FlDotCirclePainter(radius: 3, color: color, strokeWidth: 0),
              ),
            ),
          ],
          titlesData: const FlTitlesData(
            bottomTitles: hidden,
            leftTitles: hidden,
            topTitles: hidden,
            rightTitles: hidden,
          ),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          clipData: const FlClipData.all(),
          lineTouchData: const LineTouchData(enabled: false),
        ));

    Widget eventShadeLayer() => Positioned.fill(
          child: IgnorePointer(
            child: Row(
              children: [
                for (int idx = 0; idx < n; idx++)
                  Expanded(
                    child: Builder(builder: (_) {
                      final dayIdx = idx - preDays;
                      if (dayIdx < 0 || dayIdx >= _dayModes.length) {
                        return const SizedBox.expand();
                      }
                      final overlay = _overlayForDay(dayIdx);
                      final color = _overlayTintColor(overlay);
                      if (color == null) {
                        return const SizedBox.expand();
                      }
                      return Container(
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.055),
                          border: Border(
                            left: BorderSide(
                                color: color.withValues(alpha: 0.16),
                                width: 0.6),
                            right: BorderSide(
                                color: color.withValues(alpha: 0.08),
                                width: 0.4),
                          ),
                        ),
                      );
                    }),
                  ),
              ],
            ),
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('トレンド', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Text(
                switch (_trendViewMode) {
                  1 => '全画面',
                  2 => '折りたたみ中',
                  _ => '',
                },
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const Spacer(),
              IconButton(
                // 0→1→2→0 でループ（通常→全画面→折りたたみ）
                icon: Icon(
                    switch (_trendViewMode) {
                      0 => Icons.open_in_full, // → 全画面へ
                      1 => Icons.unfold_less, // → 折りたたみへ
                      _ => Icons.unfold_more, // → 通常へ
                    },
                    size: 20),
                tooltip: switch (_trendViewMode) {
                  0 => 'サジェストを全画面表示',
                  1 => '折りたたむ',
                  _ => '展開',
                },
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(
                    () => _trendViewMode = (_trendViewMode + 1) % 3),
              ),
            ]),
            if (_trendViewMode != 2) const SizedBox(height: 8),
            if (_trendViewMode != 2)
              // グラフはhoverツールチップ専用(クリック起動は中段の処方カードへ移動)。
              // plot(184)+axis(66)=250 に、イベント期間バー分の高さを加算してクリップを防ぐ。
              SizedBox(
                height: 250 + _eventSpanHeight(n, preDays),
                child: MouseRegion(
                  onHover: (e) {
                    if (n == 0) return;
                    final barWidth = _cachedChartW / n;
                    final idx =
                        (e.localPosition.dx / barWidth).floor().clamp(0, n - 1);
                    if (idx != _hoveredBarIdx) {
                      setState(() => _hoveredBarIdx = idx);
                      widget.onSettingsChanged?.call();
                    }
                  },
                  onExit: (_) {
                    setState(() => _hoveredBarIdx = -1);
                    widget.onSettingsChanged?.call();
                  },
                  child: LayoutBuilder(builder: (_, _lbc) {
                    _cachedChartW = _lbc.maxWidth;
                    const plotH = 184.0; // プロット領域(棒・線)の高さ
                    const axisH = 66.0; // 日付＋アイコン軸の高さ
                    return Column(
                      children: [
                        // === プロット領域: 棒グラフ・線グラフを同一184px領域に重ねる ===
                        // 棒も線も同じ高さの箱に置くので、ゼロ基線(=底辺)が物理的に完全一致する
                        SizedBox(
                          height: plotH,
                          child: ClipRect(
                            child: Stack(
                              children: [
                                eventShadeLayer(),
                                // ① 積み上げ棒: カロリー内訳 (下→上: PN→EN→食事)
                                BarChart(BarChartData(
                                  alignment: BarChartAlignment.spaceAround,
                                  minY: 0,
                                  maxY: maxKcal,
                                  barTouchData: BarTouchData(enabled: false),
                                  barGroups: List.generate(n, (i) {
                                    final enK = enKcals[i];
                                    final mealK = mealKcals[i];
                                    final total = plans[i].totalKcal;
                                    return BarChartGroupData(x: i, barRods: [
                                      BarChartRodData(
                                        toY: total,
                                        width: 16,
                                        borderRadius: BorderRadius.circular(2),
                                        rodStackItems: [
                                          // 下: 食事(橙) — 淡め
                                          BarChartRodStackItem(0, mealK,
                                              Colors.deepOrange.shade200),
                                          // 中: EN(黄) — 暗めのアンバー(白背景との視認性確保)
                                          BarChartRodStackItem(
                                              mealK,
                                              mealK + enK,
                                              Colors.amber.shade500),
                                          // 上: PN(緑) — 淡め
                                          BarChartRodStackItem(mealK + enK,
                                              total, Colors.green.shade200),
                                        ],
                                      ),
                                    ]);
                                  }),
                                  titlesData: const FlTitlesData(
                                    bottomTitles: hidden,
                                    leftTitles: hidden,
                                    topTitles: hidden,
                                    rightTitles: hidden,
                                  ),
                                  gridData: const FlGridData(show: false),
                                  borderData: FlBorderData(show: false),
                                )),
                                // ② 合計IN ③ AA — 棒と同じ箱に重ねる
                                lineLayer(ins, maxIn, Colors.blue.shade600),
                                // IN最高点の注記: ±1日分の淡い水平線 + _ml ラベル
                                if (inPeakVal > 0) ...[
                                  LineChart(LineChartData(
                                    minX: -0.5,
                                    maxX: n - 0.5,
                                    minY: 0,
                                    maxY: maxIn,
                                    lineBarsData: [
                                      LineChartBarData(
                                        spots: [
                                          FlSpot((inPeakIdx - 1).toDouble(),
                                              inPeakVal),
                                          FlSpot(
                                              inPeakIdx.toDouble(), inPeakVal),
                                          FlSpot((inPeakIdx + 1).toDouble(),
                                              inPeakVal),
                                        ],
                                        gradient: LinearGradient(colors: [
                                          Colors.blueGrey.shade700
                                              .withValues(alpha: 0.0),
                                          Colors.blueGrey.shade700
                                              .withValues(alpha: 0.9),
                                          Colors.blueGrey.shade700
                                              .withValues(alpha: 0.9),
                                          Colors.blueGrey.shade700
                                              .withValues(alpha: 0.0),
                                        ], stops: const [
                                          0.0,
                                          0.35,
                                          0.65,
                                          1.0
                                        ]),
                                        barWidth: 2,
                                        dotData: const FlDotData(show: false),
                                      ),
                                    ],
                                    titlesData: const FlTitlesData(
                                      bottomTitles: hidden,
                                      leftTitles: hidden,
                                      topTitles: hidden,
                                      rightTitles: hidden,
                                    ),
                                    gridData: const FlGridData(show: false),
                                    borderData: FlBorderData(show: false),
                                    clipData: const FlClipData.all(),
                                    lineTouchData:
                                        const LineTouchData(enabled: false),
                                  )),
                                  Positioned(
                                    left: ((_cachedChartW / n) * inPeakIdx +
                                            (_cachedChartW / n) / 2) -
                                        32,
                                    // 線とテキストの間隔をグラフ↔日付と同じ8pxにする
                                    top: (plotH * (1.0 - (inPeakVal / maxIn)) -
                                            22)
                                        .clamp(0.0, plotH - 16),
                                    child: SizedBox(
                                      width: 64,
                                      child: Text(
                                        '${inPeakVal.round()}ml',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            fontSize: 14,
                                            height: 1.0,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.blueGrey.shade700),
                                      ),
                                    ),
                                  ),
                                ],
                                lineLayer(prots, maxAA, Colors.red.shade400),
                                // フローター: hoverツールチップ専用(読み取りのみ)
                                Builder(builder: (ctx) {
                                  final displayIdx = _hoveredBarIdx;
                                  if (displayIdx < 0 || displayIdx >= n) {
                                    return const SizedBox.shrink();
                                  }
                                  final idx = displayIdx;
                                  final plan = plans[idx];
                                  final w = widget.current.weightKg;
                                  final barRatio = maxKcal > 0
                                      ? (plans[idx].totalKcal / maxKcal)
                                          .clamp(0.0, 1.0)
                                      : 0.0;
                                  final barTopY = plotH * (1.0 - barRatio) - 8;
                                  final chartW = _cachedChartW;
                                  final barW = chartW / n;
                                  final barCenterX = barW * idx + barW / 2;
                                  const tipW = 156.0;
                                  final tipX = (barCenterX - tipW / 2)
                                      .clamp(0.0, chartW - tipW);
                                  final mmdd =
                                      '${dates[idx].month.toString().padLeft(2, '0')}/${dates[idx].day.toString().padLeft(2, '0')}';
                                  return Positioned(
                                    left: tipX,
                                    top: barTopY.clamp(0.0, plotH - 60),
                                    child: Container(
                                      width: tipW,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 9, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFF8E7),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                            color: Colors.brown.shade200,
                                            width: 0.6),
                                        boxShadow: const [
                                          BoxShadow(
                                              color: Colors.black26,
                                              blurRadius: 4,
                                              offset: Offset(1, 2)),
                                        ],
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(mmdd,
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold)),
                                          if (plan.items.isEmpty)
                                            const Text('栄養開始前',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.grey))
                                          else ...[
                                            Text(
                                                'IN ${plan.totalVolumeMl.round()}ml, ${plan.totalKcal.round()}kcal',
                                                style: const TextStyle(
                                                    fontSize: 11)),
                                            Text(
                                                'AA ${plan.totalProteinG.toStringAsFixed(1)}g'
                                                '${w > 0 ? ' (${(plan.totalProteinG / w).toStringAsFixed(2)}g/kg)' : ''}',
                                                style: const TextStyle(
                                                    fontSize: 11)),
                                            Builder(builder: (_) {
                                              final dayIdx = idx - preDays;
                                              final structured = dayIdx >= 0
                                                  ? (structuredAlertsByDay[
                                                          dayIdx] ??
                                                      const <cad
                                                          .StructuredNutritionAlert>[])
                                                  : const <cad
                                                      .StructuredNutritionAlert>[];
                                              final ac = _engineDayAlertCounts(
                                                  plan, structured);
                                              if (ac.err == 0 &&
                                                  ac.warn == 0 &&
                                                  ac.info == 0) {
                                                return const SizedBox.shrink();
                                              }
                                              final alertColor = ac.err > 0
                                                  ? Colors.red.shade700
                                                  : ac.warn > 0
                                                      ? Colors.orange.shade800
                                                      : Colors
                                                          .blueGrey.shade700;
                                              // 読み取りのみ。修正は処方カード下の「アラート」リンクから。
                                              return Padding(
                                                padding: const EdgeInsets.only(
                                                    top: 2),
                                                child: Row(children: [
                                                  Icon(Icons.health_and_safety,
                                                      size: 11,
                                                      color: alertColor),
                                                  const SizedBox(width: 3),
                                                  Text(
                                                      '${ac.err > 0 ? '禁忌${ac.err} ' : ''}${ac.warn > 0 ? '警告${ac.warn} ' : ''}${ac.info > 0 ? '情報${ac.info}' : ''}',
                                                      style: TextStyle(
                                                          fontSize: 10.5,
                                                          color: alertColor)),
                                                ]),
                                              );
                                            }),
                                            Builder(builder: (_) {
                                              final di = idx - preDays;
                                              if (di < 0 ||
                                                  di >=
                                                      _dayRepairChanges
                                                          .length) {
                                                return const SizedBox.shrink();
                                              }
                                              final ch = _dayRepairChanges[di];
                                              if (ch.isEmpty) {
                                                return const SizedBox.shrink();
                                              }
                                              return Padding(
                                                padding: const EdgeInsets.only(
                                                    top: 3),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                        '🔧 自動補正 ${ch.length}件',
                                                        style: TextStyle(
                                                            fontSize: 10,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            color: Colors.indigo
                                                                .shade600)),
                                                    for (final c in ch.take(3))
                                                      Text('・${c.reason}',
                                                          style: TextStyle(
                                                              fontSize: 9.5,
                                                              color: Colors
                                                                  .indigo
                                                                  .shade400)),
                                                  ],
                                                ),
                                              );
                                            }),
                                          ],
                                        ],
                                      ),
                                    ),
                                  );
                                }),
                                // 凡例カード（プロット領域の上下中央・左寄せ）
                                Positioned(
                                  left: 10,
                                  top: 0,
                                  bottom: 0,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.white
                                            .withValues(alpha: 0.88),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                            color: Colors.black12, width: 0.8),
                                        boxShadow: const [
                                          BoxShadow(
                                              color: Colors.black12,
                                              blurRadius: 4,
                                              offset: Offset(0, 1)),
                                        ],
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _legItem(Colors.deepOrange.shade200,
                                              '食事 (kcal)', false),
                                          _legItem(Colors.amber.shade500,
                                              'EN (kcal)', false),
                                          _legItem(Colors.green.shade200,
                                              'PN (kcal)', false),
                                          _legItem(Colors.blue.shade600,
                                              'IN (ml)', true),
                                          _legItem(Colors.red.shade400,
                                              'AA (g)', true),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // === 日付＋イベントアイコン軸（棒・線と独立した別Row） ===
                        SizedBox(
                          height: axisH,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < n; i++)
                                Expanded(child: dateCell(i)),
                            ],
                          ),
                        ),
                        // === 臨床イベントの有効期間バー（┝────┤・§23.3） ===
                        _eventSpanBars(n, preDays),
                      ],
                    );
                  }), // Column / LayoutBuilder
                ), // MouseRegion
              ), // SizedBox
            // === 栄養管理アラート（グラフの下・既定は折り畳み、タップで展開） ===
            if (hasAlerts && _trendViewMode != 2) ...[
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  setState(() => _alertsExpanded = !_alertsExpanded);
                  widget.onSettingsChanged?.call();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    const Icon(Icons.notifications_active_outlined,
                        size: 16, color: Colors.deepOrange),
                    const SizedBox(width: 4),
                    const Text('リスクと補充サジェスト',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.black54)),
                    const SizedBox(width: 6),
                    // アラート件数バッジ
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.deepOrange.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.deepOrange.shade200),
                      ),
                      child: Text('$alertCount件',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.deepOrange.shade700)),
                    ),
                    const Spacer(),
                    Icon(
                        _alertsExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: Colors.black45),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (alertsShown && efadRisk)
              _chartAlert(
                color: Colors.orange.shade800,
                title: '${_alertDate(14, dates, n)}以降　必須脂肪酸欠乏のリスク',
                body: '絶食開始からDay14まで脂質の投与がありません。長期化で必須脂肪酸が欠乏します。'
                    '脂肪乳剤を開始してください。',
                suggest: 'イントラリポス20% 100mL/日（脂質20g）を補充'
                    '（または週2回100mL）',
              ),
            if (alertsShown && thiamineRisk && !refeedRisk)
              _chartAlert(
                color: Colors.red.shade700,
                title: '${_alertDate(preDays + 1, dates, n)}以降（栄養再開・糖負荷時）'
                    '　リフィーディング/Wernicke脳症のリスク',
                body: '絶食5日以上＋糖質投与でビタミンB1の需要が増大し欠乏しうる'
                    '（貯蔵は約2週間で枯渇）。糖負荷の前〜同時に補充してください。',
                suggest: 'ビタミンB1（チアミン）100〜300mg/日を静注で補充',
              ),
            if (alertsShown && pnMonitorRisk)
              _chartAlert(
                color: Colors.teal.shade700,
                title:
                    '${_alertDate(pnHeavyMaxDay, dates, n)}以降（PN主体がDay$pnHeavyMaxDayまで継続）'
                    '　電解質・微量元素の過不足に注意',
                body: 'EN≤30ml/hでPN主体の状態が続きます。'
                    'P・K・Mg・亜鉛・ビタミンの過不足が生じやすい時期です。'
                    '採血検査を追加して確認してください。',
                suggest: '不足時は リン酸Na/KCL/硫酸Mg補正液・微量元素製剤・'
                    '総合ビタミン剤 で補正',
              ),
            if (alertsShown && refeedRisk)
              _chartAlert(
                color: Colors.red.shade700,
                title: '${_alertDate(preDays + 1, dates, n)}以降（栄養再開初期）'
                    '　Refeeding症候群 ${refeedTier.label}（NICE）',
                body:
                    '絶食$preDays日・BMI ${cbw.bmiOf(widget.current.weightKg, widget.current.heightCm).toStringAsFixed(1)}'
                    '${widget.current.refeedingFlags.isNotEmpty ? '＋手動基準' : ''}。'
                    '初期は10 kcal/kg（超高リスクは5）から開始し4–7日で漸増します'
                    '（本設計は自動でcap済み）。',
                suggest: cr.refeedingActionText(refeedTier),
              ),
            // EN開始/遅延 判断（患者編集で選択した状況からの推奨）
            if (alertsShown && enTimingShow)
              _chartAlert(
                color: switch (enTimingRec) {
                  cen.EnTimingRecommendation.avoid => Colors.red.shade700,
                  cen.EnTimingRecommendation.startEarly =>
                    Colors.green.shade700,
                  cen.EnTimingRecommendation.startStandard =>
                    Colors.blueGrey.shade700,
                },
                title: 'EN開始/遅延 判断：${enTimingRec.label}',
                body: '患者編集で選択した状況'
                    '（${widget.current.enTimingFlags.length}項目）に基づく推奨です。',
                suggest: cen.enTimingActionText(enTimingRec),
              ),
            // 採血(モニタリング)提案
            if (alertsShown && labShow)
              _buildLabScheduleCard(refeedTier, ckrtActive, pnHeavyMaxDay),
            // Refeeding RSイベント検出（再栄養後 P/K/Mg 低下%）
            if (alertsShown && refeedRisk) _buildRsPanel(),
            for (final m in microAlertsList)
              if (alertsShown)
                _chartAlert(
                  color: m.alert.level == ci.AlertLevel.danger
                      ? Colors.red.shade700
                      : Colors.orange.shade800,
                  title:
                      '${_alertDate(m.dayIdx + 1, dates, n)}以降　${m.alert.nutrient} 過剰のリスク',
                  body: m.alert.message,
                ),
          ],
        ),
      ),
    );
  }

  // Dayカードのタップで処方詳細(何を何pac)をダイアログ表示
  Widget _legItem(Color c, String lbl, bool line) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          // マーカーを固定幅スロットに収め、テキストの左位置を全項目で揃える
          SizedBox(
            width: 18,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: line ? 18 : 13,
                height: line ? 3.5 : 13,
                decoration: BoxDecoration(
                    color: c, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
          const SizedBox(width: 5),
          Text(lbl,
              style: const TextStyle(
                  fontSize: 13, color: Colors.black54, height: 1.3)),
        ]),
      );

  /// アラート用の日付文字列 (chartOrigin起算のDay番号 → ○月○日)
  String _alertDate(int dayNum, List<DateTime> dates, int n) {
    if (dates.isEmpty) return '';
    final idx = (dayNum - 1).clamp(0, n - 1);
    return '${dates[idx].month}月${dates[idx].day}日';
  }

  /// 栄養管理アラート用の共通バナー
  /// title=「○月○日以降 …リスク」, body=対処, suggest=補充する製剤/成分+量
  Widget _chartAlert({
    required Color color,
    required String title,
    required String body,
    String? suggest,
  }) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(
                        text: '$title\n',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: color,
                            fontSize: 12.5,
                            height: 1.4)),
                    TextSpan(
                        text: body,
                        style: TextStyle(
                            color: color, fontSize: 11.5, height: 1.4)),
                  ])),
                  if (suggest != null) ...[
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.add_circle_outline,
                              size: 15, color: color),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(suggest,
                                style: TextStyle(
                                    color: color,
                                    fontSize: 11.5,
                                    height: 1.35,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  /// 採血(モニタリング)提案カード（折りたたみ）。
  /// refeeding/CKRT/長期PN の臨床コンテキストから採血項目・頻度・トリガーを提示。
  Widget _buildLabScheduleCard(
      cr.RefeedingTier tier, bool ckrtActive, int pnHeavyMaxDay) {
    // daysSinceNutritionStart は渡さない(計画ビュー)= 両期間の頻度を併記表示。
    final suggestions = clab.labSchedule(
      refeedingTier: tier,
      ckrtActive: ckrtActive,
      pnHeavyMaxDay: pnHeavyMaxDay,
    );
    final color = Colors.indigo.shade700;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () =>
                setState(() => _labScheduleExpanded = !_labScheduleExpanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(children: [
                Icon(Icons.science_outlined, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('採血(モニタリング)提案　${suggestions.length}件',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: color,
                          fontSize: 12.5)),
                ),
                Icon(
                    _labScheduleExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                    color: color),
              ]),
            ),
          ),
          if (_labScheduleExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in suggestions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(TextSpan(children: [
                            TextSpan(
                                text: '${s.panel}　',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: color,
                                    fontSize: 11.5)),
                            TextSpan(
                                text: s.frequency,
                                style: TextStyle(
                                    color: color,
                                    fontSize: 11.5,
                                    height: 1.35)),
                          ])),
                          Text(s.reason,
                              style: TextStyle(
                                  color: Colors.black54,
                                  fontSize: 10.5,
                                  height: 1.3)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Refeeding RSイベント検出パネル（折りたたみ・入力はtransient）。
  /// 再栄養後の P/K/Mg baseline→current 低下%から RS重症度を分類して表示。
  Widget _buildRsPanel() {
    crev.RsLab labOf(TextEditingController b, TextEditingController c) =>
        crev.RsLab(
          baseline: double.tryParse(b.text.trim()),
          current: double.tryParse(c.text.trim()),
        );
    final assess = crev.assessRefeedingSyndrome(
      phosphate: labOf(_rsBaseP, _rsCurP),
      potassium: labOf(_rsBaseK, _rsCurK),
      magnesium: labOf(_rsBaseMg, _rsCurMg),
      organDysfunction: _rsOrganDysfunction,
    );
    final color = switch (assess.severity) {
      crev.RsSeverity.severe => Colors.red.shade700,
      crev.RsSeverity.moderate => Colors.deepOrange.shade700,
      crev.RsSeverity.mild => Colors.orange.shade800,
      crev.RsSeverity.none => Colors.blueGrey.shade600,
    };

    Widget labRow(String name, TextEditingController b, TextEditingController c,
        String? dropKey) {
      final drop = dropKey != null ? assess.dropPercents[dropKey] : null;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          SizedBox(
              width: 28,
              child: Text(name,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold))),
          Expanded(child: _rsField(b, '前値')),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.arrow_right_alt, size: 16),
          ),
          Expanded(child: _rsField(c, '現値')),
          SizedBox(
            width: 56,
            child: Text(
              drop != null && drop > 0 ? '−${drop.toStringAsFixed(0)}%' : '—',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: drop != null &&
                          crev.rsSeverityFromDrop(drop) != crev.RsSeverity.none
                      ? color
                      : Colors.black45),
            ),
          ),
        ]),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _rsExpanded = !_rsExpanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(children: [
                Icon(Icons.monitor_heart_outlined, size: 18, color: color),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Refeeding 発症モニタ（P/K/Mg 低下%）',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12.5)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                  ),
                  child: Text(assess.severity.label,
                      style: TextStyle(
                          fontSize: 11,
                          color: color,
                          fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 4),
                Icon(_rsExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: color),
              ]),
            ),
          ),
          if (_rsExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('再栄養5日以内の血清値を入力（前値=再栄養前/現値=直近）',
                      style: TextStyle(fontSize: 10.5, color: Colors.black54)),
                  const SizedBox(height: 6),
                  labRow('P', _rsBaseP, _rsCurP, 'P'),
                  labRow('K', _rsBaseK, _rsCurK, 'K'),
                  labRow('Mg', _rsBaseMg, _rsCurMg, 'Mg'),
                  Row(children: [
                    SizedBox(
                      height: 28,
                      width: 28,
                      child: Checkbox(
                        value: _rsOrganDysfunction,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (v) =>
                            setState(() => _rsOrganDysfunction = v ?? false),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text('低下に伴う臓器障害あり（→重症）',
                          style: TextStyle(fontSize: 11.5)),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: color.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                        '${assess.severity.label}：${crev.rsActionText(assess.severity)}',
                        style: TextStyle(
                            fontSize: 11.5, color: color, height: 1.4)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// RSパネルの小さな数値入力欄。
  Widget _rsField(TextEditingController c, String hint) => SizedBox(
        height: 34,
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 11, color: Colors.black38),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
      );

  /// 設定エリア3列目: 主要な臨床経過。+追加ボタン＋一覧（種類/モダリティ mm/dd 〜 mm/dd）。
  /// 行タップで編集、×で削除。イベント管理はここに集約。
  Widget _clinicalCourseColumn() {
    final base = DateTime(_startDate.year, _startDate.month, _startDate.day);
    String md(int day) {
      final d = base.add(Duration(days: day - 1));
      return '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
    }

    String headLabel(cev.ClinicalEvent e) {
      final t = _clinicalEventTypeLabel(e.type);
      return e.type == cev.ClinicalEventType.rrtStart && e.rrtModality != null
          ? '$t / ${e.rrtModality!.key}'
          : t;
    }

    String rangeText(cev.ClinicalEvent e) =>
        '${md(e.startDay)} 〜${e.endDay != null ? ' ${md(e.endDay!)}' : ''}';

    final events = [..._clinicalEvents]
      ..sort((a, b) => a.startDay.compareTo(b.startDay));

    void removeAt(cev.ClinicalEvent e) {
      final idx = _clinicalEvents.indexOf(e);
      if (idx < 0) return;
      setState(() {
        _clinicalEvents.removeAt(idx);
        _rebuildDays();
      });
      _saveConfig();
      widget.onSettingsChanged?.call();
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 190),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.event_note_outlined,
                size: 13, color: Colors.blueGrey.shade700),
            const SizedBox(width: 3),
            Text('主要な臨床経過',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueGrey.shade700)),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => _showClinicalEventEditor(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add, size: 14, color: Colors.indigo.shade600),
                  Text('イベント追加',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo.shade600)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('イベント未設定',
                  style: TextStyle(fontSize: 11, color: Colors.black45)),
            )
          else
            for (final e in events)
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => _showClinicalEventEditor(
                    index: _clinicalEvents.indexOf(e)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(children: [
                    Expanded(
                      child: Text.rich(TextSpan(children: [
                        TextSpan(
                            text: headLabel(e),
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: _eventSpanColor(e))),
                        TextSpan(
                            text: '  ${rangeText(e)}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.black54)),
                      ])),
                    ),
                    InkWell(
                      onTap: () => removeAt(e),
                      child: Icon(Icons.close,
                          size: 13, color: Colors.red.shade300),
                    ),
                  ]),
                ),
              ),
        ],
      ),
    );
  }

  String _clinicalEventTypeLabel(cev.ClinicalEventType type) {
    switch (type) {
      case cev.ClinicalEventType.enHold:
        return 'EN流量 維持';
      case cev.ClinicalEventType.enIntolerance:
        return 'EN不耐でPNにスイッチ';
      case cev.ClinicalEventType.recurrentNpo:
        return 'NPO管理';
      case cev.ClinicalEventType.refeedingHypophosphatemia:
        return '低P 低K 低Mg (Refeeding症候群)';
      case cev.ClinicalEventType.bunRiseAfterFeeding:
        return 'BUN上昇';
      case cev.ClinicalEventType.cholestasisOrLiverDysfunction:
        return '胆汁うっ滞 / 肝障害';
      case cev.ClinicalEventType.fluidOverload:
        return '溢水';
      case cev.ClinicalEventType.rrtStart:
        return 'RRT 開始';
    }
  }

  String _clinicalEventShortLabel(cev.ClinicalEventType type) {
    switch (type) {
      case cev.ClinicalEventType.enHold:
        return 'EN維持';
      case cev.ClinicalEventType.enIntolerance:
        return 'EN不耐→PN';
      case cev.ClinicalEventType.recurrentNpo:
        return 'NPO';
      case cev.ClinicalEventType.refeedingHypophosphatemia:
        return '低P/K/Mg';
      case cev.ClinicalEventType.bunRiseAfterFeeding:
        return 'BUN↑';
      case cev.ClinicalEventType.cholestasisOrLiverDysfunction:
        return '胆汁/肝';
      case cev.ClinicalEventType.fluidOverload:
        return '溢水';
      case cev.ClinicalEventType.rrtStart:
        return 'RRT';
    }
  }

  String _energyEffectLabel(cev.EnergyEffect effect) {
    switch (effect) {
      case cev.EnergyEffect.none:
        return 'なし';
      case cev.EnergyEffect.cap:
        return 'cap';
      case cev.EnergyEffect.reducePercent:
        return '減量';
      case cev.EnergyEffect.restartRefeedingRamp:
        return 'refeeding再開';
      case cev.EnergyEffect.restrictFor48h:
        return '48h制限';
    }
  }

  String _proteinEffectLabel(cev.ProteinEffect effect) {
    switch (effect) {
      case cev.ProteinEffect.none:
        return 'なし';
      case cev.ProteinEffect.renalRestrict:
        return '腎制限';
      case cev.ProteinEffect.krtTarget:
        return 'IRRT目標';
      case cev.ProteinEffect.sledTarget:
        return 'SLED目標';
      case cev.ProteinEffect.crrtTarget:
        return 'CRRT目標';
      case cev.ProteinEffect.reviewOnly:
        return 'review';
    }
  }

  Future<void> _showClinicalEventEditor({int? index}) async {
    final existing = index != null ? _clinicalEvents[index] : null;
    final typeOptions = [
      cev.ClinicalEventType.enHold,
      cev.ClinicalEventType.enIntolerance,
      cev.ClinicalEventType.recurrentNpo,
      cev.ClinicalEventType.refeedingHypophosphatemia,
      cev.ClinicalEventType.bunRiseAfterFeeding,
      cev.ClinicalEventType.cholestasisOrLiverDysfunction,
      cev.ClinicalEventType.fluidOverload,
      cev.ClinicalEventType.rrtStart,
    ];
    var type = existing?.type ?? cev.ClinicalEventType.enHold;
    // severity は栄養設計に影響しないため UI からは外す（既定 moderate を保持）。
    final severity = existing?.severity ?? cev.EventSeverity.moderate;
    var rrt = existing?.rrtModality ?? cev.RrtModality.crrt;
    // 開始/停止はカレンダー(日付)で選ぶ。内部は栄養開始からのDay(1始まり)で保持。
    final nutritionDay0 =
        DateTime(_startDate.year, _startDate.month, _startDate.day);
    DateTime dayToDate(int day) =>
        nutritionDay0.add(Duration(days: day - 1));
    int dateToDay(DateTime d) {
      final diff =
          DateTime(d.year, d.month, d.day).difference(nutritionDay0).inDays;
      return diff < 0 ? 1 : diff + 1;
    }

    DateTime startDate = dayToDate(existing?.startDay ?? _enStartDay);
    DateTime? endDate =
        existing?.endDay != null ? dayToDate(existing!.endDay!) : null;
    final holdRateCtrl = TextEditingController(
        text: (existing?.parameters['hold_rate_ml_h'] ?? 20).toString());
    final fluidCapCtrl = TextEditingController(
        text: existing?.parameters['max_fluid_ml_kg_day']?.toString() ?? '');
    final phosphateCtrl = TextEditingController(
        text: existing?.parameters['phosphate_value']?.toString() ?? '');
    final kcalCapCtrl = TextEditingController(
        text: existing?.parameters['cap_kcal_day']?.toString() ?? '');
    final noteCtrl = TextEditingController(text: existing?.explanation ?? '');

    double? parseDouble(TextEditingController c) {
      final s = c.text.trim();
      return s.isEmpty ? null : double.tryParse(s);
    }

    final saved = await showDialog<cev.ClinicalEvent>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        const showEnd = true; // 全イベント期間(停止日)を持てる
        return AlertDialog(
          title: Text(index == null ? 'イベント追加' : 'イベント編集',
              style: const TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 360,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButtonFormField<cev.ClinicalEventType>(
                  value: type,
                  decoration: const InputDecoration(
                      labelText: 'イベント種別', isDense: true),
                  items: typeOptions
                      .map((t) => DropdownMenuItem(
                          value: t, child: Text(_clinicalEventTypeLabel(t))))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setLocal(() => type = v);
                  },
                ),
                const SizedBox(height: 6),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('期間（クリックで開始/終了・ドラッグで一括）',
                      style: TextStyle(fontSize: 11, color: Colors.black54)),
                ),
                _EventRangeCalendar(
                  nutritionDay0: nutritionDay0,
                  start: startDate,
                  end: endDate,
                  firstDate: nutritionDay0.subtract(const Duration(days: 14)),
                  lastDate: nutritionDay0.add(const Duration(days: 365)),
                  onChanged: (s, e) => setLocal(() {
                    startDate = s;
                    endDate = e;
                  }),
                ),
                if (type == cev.ClinicalEventType.enHold) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: holdRateCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'EN保持速度 (ml/h)', isDense: true),
                  ),
                ],
                if (type == cev.ClinicalEventType.rrtStart) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<cev.RrtModality>(
                    value: rrt,
                    decoration: const InputDecoration(
                        labelText: 'RRTモダリティ', isDense: true),
                    items: cev.RrtModality.values
                        .map((m) =>
                            DropdownMenuItem(value: m, child: Text(m.key)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setLocal(() => rrt = v);
                    },
                  ),
                ],
                if (type ==
                    cev.ClinicalEventType.refeedingHypophosphatemia) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: phosphateCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: '血清P値（任意）', isDense: true),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: kcalCapCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'エネルギー上限 kcal/日（任意）', isDense: true),
                  ),
                ],
                if (type == cev.ClinicalEventType.fluidOverload) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: fluidCapCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: '水分上限 ml/kg/日（任意）', isDense: true),
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: noteCtrl,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'メモ（任意）', isDense: true),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('キャンセル')),
            FilledButton(
              onPressed: () {
                final start = dateToDay(startDate);
                if (start < 1) return;
                final end =
                    showEnd && endDate != null ? dateToDay(endDate!) : null;
                final params = <String, Object?>{};
                if (type == cev.ClinicalEventType.enHold) {
                  params['hold_rate_ml_h'] = parseDouble(holdRateCtrl) ?? 20;
                }
                if (type == cev.ClinicalEventType.refeedingHypophosphatemia) {
                  final p = parseDouble(phosphateCtrl);
                  final cap = parseDouble(kcalCapCtrl);
                  if (p != null) params['phosphate_value'] = p;
                  if (cap != null) params['cap_kcal_day'] = cap;
                }
                if (type == cev.ClinicalEventType.fluidOverload) {
                  final cap = parseDouble(fluidCapCtrl);
                  if (cap != null) params['max_fluid_ml_kg_day'] = cap;
                }
                Navigator.pop(
                  ctx,
                  cev.ClinicalEvent(
                    id: existing?.id ??
                        'event_${DateTime.now().microsecondsSinceEpoch}',
                    type: type,
                    startDay: start,
                    endDay: end != null && end >= start ? end : null,
                    severity: severity,
                    sourceTier: cst.SourceTier.userInputEvent,
                    rrtModality:
                        type == cev.ClinicalEventType.rrtStart ? rrt : null,
                    parameters: params,
                    explanation: noteCtrl.text.trim(),
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        );
      }),
    );

    for (final c in [
      holdRateCtrl,
      fluidCapCtrl,
      phosphateCtrl,
      kcalCapCtrl,
      noteCtrl,
    ]) {
      c.dispose();
    }
    if (saved == null) return;
    setState(() {
      if (index == null) {
        _clinicalEvents.add(saved);
      } else {
        _clinicalEvents[index] = saved;
      }
      _clinicalEvents.sort((a, b) {
        final d = a.startDay.compareTo(b.startDay);
        if (d != 0) return d;
        return a.priority.compareTo(b.priority);
      });
      _rebuildDays();
    });
    _saveConfig();
    widget.onSettingsChanged?.call();
  }

  /// 処方カード下のアラートリンク。タップで _showDayRepairSheet を開く。
  /// カード本体のタップ(処方詳細)とは独立(InkWellのネストで内側が優先)。
  Widget _dayAlertLink(int i, DesignPlan plan,
      {List<cad.StructuredNutritionAlert> structuredAlerts = const []}) {
    final ac = _engineDayAlertCounts(plan, structuredAlerts);
    final manualCount = _manualDayChanges[i]?.length ?? 0;
    final hasAlert = ac.err > 0 || ac.warn > 0 || ac.info > 0;
    final col = ac.err > 0
        ? Colors.red.shade700
        : ac.warn > 0
            ? Colors.orange.shade800
            : ac.info > 0
                ? Colors.blueGrey.shade700
                : Colors.green.shade700;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () =>
          _showDayRepairSheet(i, plan, structuredAlerts: structuredAlerts),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(hasAlert ? Icons.health_and_safety : Icons.check_circle_outline,
              size: 14, color: col),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              hasAlert
                  ? 'アラート ${ac.err > 0 ? '禁忌${ac.err} ' : ''}${ac.warn > 0 ? '警告${ac.warn} ' : ''}${ac.info > 0 ? '情報${ac.info}' : ''}・修正'
                  : 'アラートなし・手動修正',
              style: TextStyle(
                  fontSize: 11.5, color: col, fontWeight: FontWeight.bold),
            ),
          ),
          if (manualCount > 0) ...[
            Icon(Icons.back_hand_outlined,
                size: 12, color: Colors.indigo.shade600),
            Text('$manualCount',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.indigo.shade600,
                    fontWeight: FontWeight.bold)),
            const SizedBox(width: 2),
          ],
          Icon(Icons.chevron_right, size: 16, color: col),
        ]),
      ),
    );
  }

  void _showDayDetail(int i, DesignPlan plan, double dayKcal, double dayProt) {
    final date = _dateOf(i);
    final mode = _derivedModeForDay(i);
    final overlay = _overlayForDay(i);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$date (Day${i + 1}) の処方',
            style: const TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (overlay.activeEvents.isNotEmpty) ...[
                _overlayDetailBox(i),
                const SizedBox(height: 8),
              ],
              _planBody(plan, dayKcal, dayProt, mode),
              const Divider(height: 16),
              const SizedBox(height: 2),
              Text('当日目標 ${dayKcal.round()}kcal / タンパク ${dayProt.round()}g',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('閉じる')),
        ],
      ),
    );
  }

  Widget _overlayDetailBox(int dayIndex) {
    final overlay = _overlayForDay(dayIndex);
    final sourceTiers = <cst.SourceTier>{
      for (final e in overlay.activeEvents) e.sourceTier,
    };
    final hasRouteDelta = _hasTemplateDerivedRouteDelta(dayIndex);
    final lines = <String>[
      for (final e in overlay.activeEvents)
        '${_clinicalEventTypeLabel(e.type)}: Day${e.startDay}'
            '${e.endDay != null ? '–${e.endDay}' : '以降'}',
      if (overlay.activeRrtModality != null)
        'RRT: ${overlay.activeRrtModality!.key}',
      if (overlay.energy != cev.EnergyEffect.none)
        'Energy: ${_energyEffectLabel(overlay.energy)}',
      if (overlay.protein != cev.ProteinEffect.none)
        'Protein: ${_proteinEffectLabel(overlay.protein)}',
      ...overlay.notes,
    ];
    Widget pill(String text, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 10.5, color: color, fontWeight: FontWeight.bold)),
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.indigo.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.indigo.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.layers, size: 14, color: Colors.indigo.shade600),
            const SizedBox(width: 4),
            Text('Active overlays',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.indigo.shade700)),
          ]),
          if (sourceTiers.isNotEmpty) ...[
            const SizedBox(height: 5),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final tier in sourceTiers)
                  pill(cst.SourceTierMeta(tier).badgeLabel,
                      Colors.indigo.shade600),
              ],
            ),
          ],
          if (hasRouteDelta) ...[
            const SizedBox(height: 7),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.70),
                borderRadius: BorderRadius.circular(5),
                border:
                    Border.all(color: Colors.indigo.withValues(alpha: 0.18)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('テンプレート → 反映後',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo.shade700)),
                  const SizedBox(height: 3),
                  Text(_templateRouteSummaryForDay(dayIndex),
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black54, height: 1.25)),
                  Row(children: [
                    Icon(Icons.arrow_downward,
                        size: 12, color: Colors.indigo.shade400),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(_derivedRouteSummaryForDay(dayIndex),
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black87,
                              fontWeight: FontWeight.bold,
                              height: 1.25)),
                    ),
                  ]),
                ],
              ),
            ),
          ],
          const SizedBox(height: 4),
          for (final line in lines)
            Text(line,
                style: const TextStyle(
                    fontSize: 11.5, color: Colors.black87, height: 1.35)),
        ],
      ),
    );
  }

  List<Widget> _eventBadgesForDay(int i) {
    final overlay = _overlayForDay(i);
    if (overlay.activeEvents.isEmpty) return const [];
    Widget badge(String label, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 11, color: color, fontWeight: FontWeight.bold)),
        );
    final sourceTiers = <cst.SourceTier>{
      for (final e in overlay.activeEvents) e.sourceTier,
    };
    final out = <Widget>[
      for (final tier in sourceTiers)
        badge(cst.SourceTierMeta(tier).badgeLabel, Colors.indigo.shade600),
      for (final e in overlay.activeEvents.take(2))
        badge(_clinicalEventShortLabel(e.type), Colors.indigo.shade500),
    ];
    if (overlay.activeRrtModality != null) {
      out.add(badge(overlay.activeRrtModality!.key, Colors.blueGrey.shade600));
    }
    return out;
  }

  /// 日次処方カードのモードバッジ（プラン内容に応じて 食事/EN/PN を横並び表示）
  Widget _modeBadges(DesignPlan plan) {
    final mealK = _mealKcalOfPlan(plan);
    final enK = _enKcalOfPlan(plan);
    final pnK = (plan.totalKcal - mealK - enK);
    final isZero = plan.label == 'ZERO';
    Widget badge(String label, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.5)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12, color: color, fontWeight: FontWeight.bold)),
        );
    final badges = <Widget>[];
    if (mealK > 1) badges.add(badge('食事', Colors.deepOrange.shade400));
    if (enK > 1) badges.add(badge('EN', Colors.amber.shade500));
    if (pnK > 1) {
      badges.add(badge(isZero ? 'ゼロmenu' : 'PN', Colors.blue));
    }
    if (badges.isEmpty) badges.add(badge('—', Colors.grey));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < badges.length; i++) ...[
        if (i > 0) const SizedBox(width: 4),
        badges[i],
      ],
    ]);
  }

  Widget _planBody(
      DesignPlan plan, double targetKcal, double targetProt, String mode) {
    if (plan.items.isEmpty) {
      return const Text('（条件を満たす組み合わせなし）',
          style: TextStyle(color: Colors.red, fontSize: 12));
    }
    final w = widget.current.weightKg;
    final protPerKg = w > 0 ? plan.totalProteinG / w : 0.0;
    final isZero = mode == 'ZERO' || plan.label == 'ZERO';
    const ts = TextStyle(fontSize: 12.5);
    final children = <Widget>[];
    double pnRoundDelta = 0; // PNを10ml丸めしたことによるIN補正
    Widget line(String s, {TextStyle style = ts}) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(s, style: style));

    if (isZero) {
      for (final it in plan.items) {
        children.add(line('${it.name}  ${it.volumeMl.round()}ml'));
      }
    } else {
      double tpnVol = 0, ppnVol = 0; // 10ml丸め後
      double tpnOrig = 0, ppnOrig = 0;
      double r10(double v) => (v / 10).round() * 10.0;
      final tpnNames = <String>[], ppnNames = <String>[];
      for (final it in plan.items) {
        final p = widget.state.catalog.byName(it.name);
        final cat = p?.category;
        final isFood = p?.isFood ?? false;
        if (isFood) {
          // 食事: 経口摂取(嚥下リハ)なので流量指定なし。合計容量 ml/day のみ
          final n = it.units != null ? '${it.units}本 ' : '';
          children.add(line('${it.name}  $n(${it.volumeMl.round()}ml/day)'));
        } else if (cat == 'EN' || cat == 'EN_AUX') {
          if (it.units != null) {
            final mealPac = (it.units! / 3).round().clamp(1, it.units!);
            children.add(line(
                '${it.name}  朝昼夕${mealPac}pac (${it.volumeMl.round()}ml/day)'));
          } else {
            final rateMlH = it.volumeMl / 24;
            final pacPerExchange = (rateMlH * 8 / (p?.volumeMl ?? 200)).ceil();
            children.add(line(
                '${it.name}  ${rateMlH.toStringAsFixed(0)}ml/h  朝昼夕${pacPerExchange}pac'));
          }
        } else if (cat == 'TPN') {
          final v10 = r10(it.volumeMl);
          tpnVol += v10;
          tpnOrig += it.volumeMl;
          final u = it.units != null ? '${it.units}本 ' : '';
          tpnNames.add('${it.name}  $u(${v10.round()}ml)');
        } else if (cat == 'PPN') {
          final v10 = r10(it.volumeMl);
          ppnVol += v10;
          ppnOrig += it.volumeMl;
          final u = it.units != null ? '${it.units}本 ' : '';
          ppnNames.add('${it.name}  $u(${v10.round()}ml)');
        } else {
          children.add(line(it.name));
        }
      }
      pnRoundDelta = (tpnVol + ppnVol) - (tpnOrig + ppnOrig);
      // TPN / PPN はそれぞれまとめて別々に流量表記
      if (tpnVol > 0) {
        children.add(line(
            'TPN  ${(tpnVol / 24).toStringAsFixed(0)}ml/h（計${tpnVol.round()}ml）',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.blue.shade700)));
        for (final s in tpnNames) {
          children.add(line('　$s'));
        }
      }
      if (ppnVol > 0) {
        children.add(line(
            'PPN  ${(ppnVol / 24).toStringAsFixed(0)}ml/h（計${ppnVol.round()}ml）',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.cyan.shade700)));
        for (final s in ppnNames) {
          children.add(line('　$s'));
        }
      }
    }
    children.add(const SizedBox(height: 4));
    children.add(Text(
      'IN ${(plan.totalVolumeMl + pnRoundDelta).round()}ml, 熱量 ${plan.totalKcal.round()}kcal, '
      'タンパク ${plan.totalProteinG.toStringAsFixed(1)}g (${protPerKg.toStringAsFixed(1)}g/kg)',
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
    ));
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

/// イベント期間用のカスタム範囲カレンダー。
/// 操作: 単一クリック=開始 / 開始より前をクリック=開始変更 / 後をクリック=終了設定 /
///       押しっぱドラッグ=開始〜終了を一発設定。
class _EventRangeCalendar extends StatefulWidget {
  final DateTime nutritionDay0; // Day1 = この日（Day番号表示）
  final DateTime start;
  final DateTime? end;
  final DateTime firstDate;
  final DateTime lastDate;
  final void Function(DateTime start, DateTime? end) onChanged;
  const _EventRangeCalendar({
    required this.nutritionDay0,
    required this.start,
    required this.end,
    required this.firstDate,
    required this.lastDate,
    required this.onChanged,
  });
  @override
  State<_EventRangeCalendar> createState() => _EventRangeCalendarState();
}

class _EventRangeCalendarState extends State<_EventRangeCalendar> {
  static const double _cellH = 30.0;
  late DateTime _visibleMonth;
  late DateTime _start;
  DateTime? _end;
  DateTime? _anchor;
  bool _moved = false;
  Offset _downPos = Offset.zero;
  static const double _dragSlop = 12.0; // この距離を超えて動いたらドラッグ扱い

  @override
  void initState() {
    super.initState();
    _start = _d(widget.start);
    _end = widget.end != null ? _d(widget.end!) : null;
    _visibleMonth = DateTime(_start.year, _start.month);
  }

  DateTime _d(DateTime x) => DateTime(x.year, x.month, x.day);

  DateTime _firstCell() {
    final first = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    return first.subtract(Duration(days: first.weekday % 7)); // 日曜始まり
  }

  int _dayNum(DateTime d) =>
      _d(d).difference(_d(widget.nutritionDay0)).inDays + 1;

  void _commit() => widget.onChanged(_start, _end);

  void _applyTap(DateTime d) {
    setState(() {
      if (d.isBefore(_start)) {
        _start = d; // 前をクリック→開始変更
      } else if (d.isAfter(_start)) {
        _end = d; // 後をクリック→終了設定
      } else {
        _end = null; // 開始と同日→単一日（終了クリア）
      }
    });
    _commit();
  }

  DateTime? _dayAt(Offset pos, double gridW) {
    // グリッド外（右/下/負）は無効。右外を土曜に丸めない。
    if (gridW <= 0) return null;
    if (pos.dx < 0 || pos.dy < 0 || pos.dx >= gridW || pos.dy >= _cellH * 6) {
      return null;
    }
    final col = (pos.dx / (gridW / 7)).floor().clamp(0, 6);
    final row = (pos.dy / _cellH).floor().clamp(0, 5);
    final d = _firstCell().add(Duration(days: row * 7 + col));
    if (d.isBefore(_d(widget.firstDate)) || d.isAfter(_d(widget.lastDate))) {
      return null;
    }
    return d;
  }

  bool _inRange(DateTime d) {
    if (_end == null) return false;
    return !d.isBefore(_start) && !d.isAfter(_end!);
  }

  @override
  Widget build(BuildContext context) {
    final first = _firstCell();
    const wd = ['日', '月', '火', '水', '木', '金', '土'];
    final accent = Theme.of(context).colorScheme.primary;

    Widget cell(int idx) {
      final d = first.add(Duration(days: idx));
      final inMonth = d.month == _visibleMonth.month;
      final isStart = _d(d) == _start;
      final isEnd = _end != null && _d(d) == _end;
      final inRange = _inRange(d);
      final selectable = !d.isBefore(_d(widget.firstDate)) &&
          !d.isAfter(_d(widget.lastDate));
      return SizedBox(
        height: _cellH,
        child: Container(
          margin: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            color: (isStart || isEnd)
                ? accent
                : inRange
                    ? accent.withValues(alpha: 0.16)
                    : null,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            '${d.day}',
            style: TextStyle(
              fontSize: 12,
              fontWeight:
                  (isStart || isEnd) ? FontWeight.bold : FontWeight.normal,
              color: (isStart || isEnd)
                  ? Colors.white
                  : !selectable
                      ? Colors.grey.shade300
                      : inMonth
                          ? Colors.black87
                          : Colors.grey.shade400,
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 月ナビ
        Row(children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _visibleMonth = DateTime(
                _visibleMonth.year, _visibleMonth.month - 1)),
          ),
          Expanded(
            child: Text('${_visibleMonth.year}年 ${_visibleMonth.month}月',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.bold)),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _visibleMonth = DateTime(
                _visibleMonth.year, _visibleMonth.month + 1)),
          ),
        ]),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Text(wd[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 10.5,
                        color: i == 0
                            ? Colors.red.shade400
                            : i == 6
                                ? Colors.blue.shade400
                                : Colors.black54)),
              ),
          ],
        ),
        const SizedBox(height: 2),
        LayoutBuilder(builder: (_, c) {
          final gridW = c.maxWidth;
          return Listener(
            onPointerDown: (e) {
              _anchor = _dayAt(e.localPosition, gridW);
              _moved = false;
              _downPos = e.localPosition;
            },
            onPointerMove: (e) {
              if (_anchor == null) return;
              // slop未満の微動はタップ扱い（境界jitterで誤ドラッグしない）
              if (!_moved && (e.localPosition - _downPos).distance < _dragSlop) {
                return;
              }
              final d = _dayAt(e.localPosition, gridW);
              if (d == null) return;
              _moved = true;
              setState(() {
                if (!d.isBefore(_anchor!)) {
                  _start = _anchor!;
                  _end = d;
                } else {
                  _start = d;
                  _end = _anchor!;
                }
              });
            },
            onPointerUp: (e) {
              if (_anchor == null) return;
              if (_moved) {
                _commit();
              } else {
                _applyTap(_anchor!);
              }
              _anchor = null;
            },
            // キャンセル時もエディタへ確実に反映（古い日付でSaveされるのを防ぐ）
            onPointerCancel: (e) {
              if (_anchor == null) return;
              if (_moved) _commit();
              _anchor = null;
            },
            child: Column(
              children: [
                for (var row = 0; row < 6; row++)
                  Row(children: [
                    for (var col = 0; col < 7; col++)
                      Expanded(child: cell(row * 7 + col)),
                  ]),
              ],
            ),
          );
        }),
        const SizedBox(height: 4),
        Text(
          _end == null
              ? '開始 ${_start.month}/${_start.day} (Day${_dayNum(_start)}) 〜 継続中'
              : '${_start.month}/${_start.day} (Day${_dayNum(_start)}) 〜 '
                  '${_end!.month}/${_end!.day} (Day${_dayNum(_end!)})',
          style: TextStyle(fontSize: 11.5, color: Colors.blueGrey.shade700),
        ),
      ],
    );
  }
}
