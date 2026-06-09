part of '../main.dart';

class AutoDesignInline extends StatefulWidget {
  const AutoDesignInline({super.key, required this.state, required this.current, this.onSettingsChanged});
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
  int _hoveredBarIdx = -1;  // グラフホバー中のバーインデックス (-1=なし)
  int _selectedBarIdx = -1; // タップ固定のバーインデックス (-1=なし)
  bool _alertsExpanded = false; // 栄養管理アラートの展開状態(既定=折り畳み)
  bool _trendCollapsed = false; // トレンド(栄養の推移)折りたたみ
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
      _startDate =
          DateTime.tryParse(cfg['startDate'] as String? ?? '') ?? DateTime.now();
      _kcalStep20Day = (cfg['kcalStep20Day'] as num?)?.toInt() ?? 2;
      _kcalStep25Day = (cfg['kcalStep25Day'] as num?)?.toInt() ?? 4;
      _kcalStepAuto = (cfg['kcalStepAuto'] as bool?) ?? true;
      final pid = cfg['pnProductId'] as String?;
      _pnProduct = pid != null ? widget.state.catalog.byId(pid) : (tpn.isNotEmpty ? tpn.first : null);
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
  void dispose() {
    _saveConfig();
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
    };
    widget.state.persist();
  }

  List<Product> _adopted(String cat) => widget.state.catalog
      .byCategory(cat)
      .where((p) => widget.state.isAdopted(p.id))
      .toList();

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
    TableRow dayRow(String label, Color color, int value, ValueChanged<int> onCh) {
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
        _settingLabelCell(null, '栄養係数上限:', Colors.green.shade800,
            bold: true),
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
    final targetProt = NutritionCalculator.targetProtein(widget.current);
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
    for (int i = 0; i < pcts.length; i++) {
      final phase = _acutePhaseTarget(i);
      final plan = NutritionCalculator.designDay(
        mode: _dayModes[i],
        dayTargetKcal: phase.kcal,
        dayTargetProt: phase.prot,
        weightKg: widget.current.weightKg,
        enProducts: enList,
        enRateMlH: _rateOf(_dayEnDose[i]),
        enPac: _pacOf(_dayEnDose[i]),
        pnProduct: _pnProduct,
        tpnProducts: tpnList,
        ppnProducts: ppnList,
        glucoseProduct: widget.state.adoptedByBase('70% グルコース'),
        aminoProduct: widget.state.adoptedAminoForZero(),
        lipidProduct: widget.state.adoptedLipidForZero(),
        minEnKcal: prevEnKcal,
        mealProducts: mealList,
        mealPac: _dayMealPac[i],
        mealSlots: _dayMealSlots[i],
        girLimitMgKgMin: _girLimit,
        maxLipidGramPerKgDay: ck.ClinicalConst.lipidDayLimitGKgD,
        // ゼロmenuはPN専用が6日続いた翌日(7日目, i>=6)以降のPN専用日のみ許可
        allowZeroMenu: _dayModes[i] == 'TPN' && i >= 6,
        // refeeding時はAA補充込みの総kcalがその日のcapを超えないようにする(安全優先)。
        hardKcalCap: _refeedingTier != cr.RefeedingTier.none
            ? _refeedCappedKcal(i, 1e9)
            : null,
        aaSupplementBelowFrac: 0.90, // 目標90%未満(=10%以上へこむ)時だけAA補充
        aaSupplementMaxMl: 500, // アミパレン補充は合計500ml/day上限
      );
      dayPlans.add(plan);
      if (plan.enKcal > 0 && _dayModes[i] != '食事') prevEnKcal = plan.enKcal;
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
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    columnWidths: const {
                      0: IntrinsicColumnWidth(), // ラベル列（最長に合わせる）
                      1: IntrinsicColumnWidth(), // 値列
                    },
                    children: [
                      // 行0: 絶食日（常時表示・タップで設定）
                      TableRow(children: [
                        _settingLabelCell(
                            Icons.no_meals, '絶食日:', Colors.red.shade400),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    minimumSize: const Size(0, 0),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    foregroundColor: Colors.red.shade400),
                                onPressed: () async {
                                  final fd = widget.current.fastingDate;
                                  final initial = fd != null
                                      ? (DateTime.tryParse(fd) ?? _startDate)
                                      : _startDate;
                                  final picked = await _quickPickDate(context, initial);
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
                                  final fd = widget.current.fastingDate;
                                  final p = fd != null ? DateTime.tryParse(fd) : null;
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
                        _settingLabelCell(
                            Icons.water_drop, '栄養開始日:', Colors.blue.shade600),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                            style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 0),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                foregroundColor: Colors.blue.shade600),
                            onPressed: () async {
                              final picked = await _quickPickDate(context, _startDate);
                              if (picked != null) {
                                setState(() => _startDate = picked);
                                _saveConfig();
                                widget.onSettingsChanged?.call();
                              }
                            },
                            child: Text(
                                '${_startDate.year}/${_startDate.month.toString().padLeft(2, '0')}/${_startDate.day.toString().padLeft(2, '0')}',
                                style: TextStyle(fontSize: 13, color: Colors.blue.shade600)),
                          )),
                        ),
                      ]),
                      // 行2: full nutrition達成
                      TableRow(children: [
                        _settingLabelCell(
                            Icons.flag, 'full達成:', Colors.green.shade800),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Day ', style: TextStyle(fontSize: 13)),
                              SizedBox(
                                width: _dayDropW,
                                child: DropdownButton<int>(
                                  value: _rampDays.clamp(2, 12),
                                  isDense: true,
                                  isExpanded: true,
                                  items: List.generate(11, (i) => i + 2)
                                      .map((d) => DropdownMenuItem(
                                          value: d, child: Text('$d')))
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
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Text('実到達 Day$effFull',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: effFull == _rampDays
                                              ? Colors.grey
                                              : Colors.deepOrange.shade400)),
                                );
                              }),
                            ],
                          ),
                        ),
                      ]),
                      // 行3: EN導入 (色はグラフのEN(アンバー)と統一)
                      TableRow(children: [
                        _settingLabelCell(
                            Icons.lunch_dining, 'EN導入:', Colors.amber.shade700),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Day ', style: TextStyle(fontSize: 13)),
                              SizedBox(
                                width: _dayDropW,
                                child: DropdownButton<int>(
                                  value: _enStartDay.clamp(1, 21),
                                  isDense: true,
                                  isExpanded: true,
                                  items: List.generate(21, (i) => i + 1)
                                      .map((d) => DropdownMenuItem(
                                          value: d, child: Text('$d')))
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
                        _settingLabelCell(
                            Icons.restaurant, '経口リハ導入:', Colors.red.shade400),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Day ', style: TextStyle(fontSize: 13)),
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
                                        value: null, child: Text('—')),
                                    ...List.generate(28, (i) => i + 1).map((d) =>
                                        DropdownMenuItem<int?>(
                                            value: d, child: Text('$d'))),
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
                    ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('★ お気に入り製剤を優先して設計します',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
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
            final dayKcal = phase.kcal;
            final dayProt = phase.prot;
            final pctOfFull =
                targetKcal > 0 ? dayKcal / targetKcal * 100 : 0.0;
            final mode = _dayModes[i];
            final showEn = mode == 'EN' || mode == 'TPN+EN';
            final showPn = mode == 'TPN' || mode == 'TPN+EN';
            // 逐次生成済みのプランを使用（minEnKcal単調増加制約適用済み）
            final plan = dayPlans[i];
            return SizedBox(
              width: 264,
              child: Card(
              margin: const EdgeInsets.only(right: 10),
              child: InkWell(
                onTap: () => _showDayDetail(i, plan, dayKcal, dayProt),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(_dateOf(i),
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                        Text('(Day${i + 1})',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ]),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          // 目標% or "full nutrition"（常にgreen）
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.green.shade100,
                              borderRadius: BorderRadius.circular(4),
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
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: Colors.amber.shade600, width: 0.8),
                              ),
                              child: Text(_doseLabel(_dayEnDose[i]),
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.brown.shade700)),
                            ),
                          ],
                          if (mode == '食事') ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade100,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: Colors.deepOrange.shade400, width: 0.8),
                              ),
                              child: Text('朝昼夕 ${_dayMealPac[i]}pac',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange.shade800)),
                            ),
                          ],
                          _modeBadges(plan),
                        ],
                      ),
                      const Divider(height: 16),
                      Expanded(
                        child: SingleChildScrollView(
                          child: _planBody(plan, dayKcal, dayProt, mode),
                        ),
                      ),
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
        ),   // SizedBox(listH)
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
      if (p != null && !p.isFood &&
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

  /// Refeeding（NICE）リスク階層。栄養開始日−絶食開始日 と BMI から判定。
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
    return cr.refeedingTier(bmi: bmi, daysNoIntake: days);
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

  Widget _buildBarCharts(double targetKcal, List<double> pcts,
      List<Product> en, List<Product> tpn, List<Product> ppn) {
    final targetProt = NutritionCalculator.targetProtein(widget.current);
    // 逐次生成して minEnKcal 単調増加制約を適用
    double prevEnKcalChart = 0;
    final designPlans = <DesignPlan>[];
    for (int i = 0; i < pcts.length; i++) {
      final phase = _acutePhaseTarget(i);
      final p = NutritionCalculator.designDay(
              mode: _dayModes[i],
              dayTargetKcal: phase.kcal,
              dayTargetProt: phase.prot,
              weightKg: widget.current.weightKg,
              enProducts: en,
              enRateMlH: _rateOf(_dayEnDose[i]),
              enPac: _pacOf(_dayEnDose[i]),
              pnProduct: _pnProduct,
              tpnProducts: tpn,
              ppnProducts: ppn,
              glucoseProduct: widget.state.adoptedByBase('70% グルコース'),
              aminoProduct: widget.state.adoptedAminoForZero(),
              lipidProduct: widget.state.adoptedLipidForZero(),
              minEnKcal: prevEnKcalChart,
              mealProducts: _adoptedMeals(),
              mealPac: _dayMealPac[i],
              girLimitMgKgMin: _girLimit,
              maxLipidGramPerKgDay: ck.ClinicalConst.lipidDayLimitGKgD,
              // ゼロmenuはPN専用が6日続いた翌日(7日目, i>=6)以降のPN専用日のみ許可
              allowZeroMenu: _dayModes[i] == 'TPN' && i >= 6,
              // refeeding時はAA補充込みの総kcalがその日のcapを超えないようにする(安全優先)。
              hardKcalCap: _refeedingTier != cr.RefeedingTier.none
                  ? _refeedCappedKcal(i, 1e9)
                  : null,
              aaSupplementBelowFrac: 0.90, // 目標90%未満時だけAA補充
              aaSupplementMaxMl: 500, // アミパレン補充は合計500ml/day上限
            );
      if (p.enKcal > 0 && _dayModes[i] != '食事') prevEnKcalChart = p.enKcal;
      designPlans.add(p);
    }

    // 絶食日が設定されていればそこから起算、なければ今日から
    final today = DateTime.now();
    final todayNorm = DateTime(today.year, today.month, today.day);
    final startNorm = DateTime(_startDate.year, _startDate.month, _startDate.day);
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
            .fold<double>(0.0, (s, v) => s + v) < 1.0;

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

    // Refeeding（NICE）リスク: 絶食日数(preDays)とBMIから判定。
    final refeedTier = _refeedingTier;
    final refeedRisk = refeedTier != cr.RefeedingTier.none;
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
        microAlertsList.isNotEmpty;
    final alertCount = (efadRisk ? 1 : 0) +
        (thiamineRisk && !refeedRisk ? 1 : 0) +
        (pnMonitorRisk ? 1 : 0) +
        (refeedRisk ? 1 : 0) +
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
        plans.map((p) => p.totalKcal).fold<double>(1, (a, b) => a > b ? a : b) * 1.1;
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
    final fastingIdx   = (widget.current.fastingDate != null) ? 0 : -1;
    final admissionEntry = widget.current.bedHistory
        .where((b) => b.fromBed == null)
        .firstOrNull;
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
    final fullIdx      = (preDays + _fullDay - 1).clamp(0, n - 1);
    final enIdx        = (preDays + _enStartDay - 1).clamp(0, n - 1);
    final oralIdx      = (_oralRehabStartDay != null &&
            preDays + _oralRehabStartDay! - 1 < n)
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
      final bool hasEvent = flags.any((f) => f);
      final int evCount = flags.where((f) => f).length;
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

      final evWidgets = [
        if (flags[0]) mkIconBox(Icons.no_meals,   Colors.red.shade400),
        if (flags[1]) mkIconBox(Icons.bed,         Colors.blueGrey.shade400),
        // 栄養開始(=PN/輸液開始)は点滴(water_drop)アイコン。
        if (flags[2]) mkIconBox(Icons.water_drop,  Colors.blue.shade600),
        if (flags[3]) mkBox('EN',   Colors.amber.shade500),
        if (flags[4]) mkBox('full', Colors.green.shade700),
        // 経口リハ開始(濃厚流動食・栄サポ食品・一般食)はフォーク&ナイフアイコン。
        if (flags[5]) mkIconBox(Icons.restaurant,  Colors.deepOrange.shade400),
      ];

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
                              fontSize: 14,
                              letterSpacing: -0.5,
                              height: 1.0))),
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
                getDotPainter: (s, p, b, idx) => FlDotCirclePainter(
                    radius: 3, color: color, strokeWidth: 0),
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('トレンド',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: Icon(
                    _trendCollapsed ? Icons.expand_less : Icons.expand_more,
                    size: 22),
                tooltip: _trendCollapsed ? '展開' : '折りたたむ',
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    setState(() => _trendCollapsed = !_trendCollapsed),
              ),
            ]),
            if (!_trendCollapsed) const SizedBox(height: 8),
            if (!_trendCollapsed)
            TapRegion(
              // チャート外タップでフローターを消去
              onTapOutside: (_) {
                if (_selectedBarIdx >= 0) {
                  setState(() { _selectedBarIdx = -1; _hoveredBarIdx = -1; });
                  widget.onSettingsChanged?.call();
                }
              },
              child: SizedBox(
              height: 250,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  if (n == 0) return;
                  final barWidth = _cachedChartW / n;
                  final idx = (details.localPosition.dx / barWidth)
                      .floor()
                      .clamp(0, n - 1);
                  setState(() { _selectedBarIdx = idx; });
                  widget.onSettingsChanged?.call();
                },
                child: MouseRegion(
                onHover: (e) {
                  if (n == 0) return;
                  final barWidth = _cachedChartW / n;
                  final idx = (e.localPosition.dx / barWidth)
                      .floor()
                      .clamp(0, n - 1);
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
                  const axisH = 66.0;  // 日付＋アイコン軸の高さ
                  return Column(
                    children: [
                      // === プロット領域: 棒グラフ・線グラフを同一184px領域に重ねる ===
                      // 棒も線も同じ高さの箱に置くので、ゼロ基線(=底辺)が物理的に完全一致する
                      SizedBox(
                        height: plotH,
                        child: ClipRect(
                          child: Stack(
                            children: [
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
                                        BarChartRodStackItem(mealK, mealK + enK,
                                            Colors.amber.shade500),
                                        // 上: PN(緑) — 淡め
                                        BarChartRodStackItem(mealK + enK, total,
                                            Colors.green.shade200),
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
                                        FlSpot((inPeakIdx - 1).toDouble(), inPeakVal),
                                        FlSpot(inPeakIdx.toDouble(), inPeakVal),
                                        FlSpot((inPeakIdx + 1).toDouble(), inPeakVal),
                                      ],
                                      gradient: LinearGradient(colors: [
                                        Colors.blueGrey.shade700.withValues(alpha: 0.0),
                                        Colors.blueGrey.shade700.withValues(alpha: 0.9),
                                        Colors.blueGrey.shade700.withValues(alpha: 0.9),
                                        Colors.blueGrey.shade700.withValues(alpha: 0.0),
                                      ], stops: const [0.0, 0.35, 0.65, 1.0]),
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
                                  lineTouchData: const LineTouchData(enabled: false),
                                )),
                                Positioned(
                                  left: ((_cachedChartW / n) * inPeakIdx +
                                          (_cachedChartW / n) / 2) -
                                      32,
                                  // 線とテキストの間隔をグラフ↔日付と同じ8pxにする
                                  top: (plotH * (1.0 - (inPeakVal / maxIn)) - 22)
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
                              // フローター: タップ固定優先、次いでホバー
                              Builder(builder: (ctx) {
                                final displayIdx = _selectedBarIdx >= 0
                                    ? _selectedBarIdx
                                    : _hoveredBarIdx;
                                if (displayIdx < 0 || displayIdx >= n) {
                                  return const SizedBox.shrink();
                                }
                                final idx = displayIdx;
                                final plan = plans[idx];
                                final w = widget.current.weightKg;
                                final isPinned = _selectedBarIdx >= 0;
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
                                      color: isPinned
                                          ? const Color(0xFFF0F4FF)
                                          : const Color(0xFFFFF8E7),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                          color: isPinned
                                              ? Colors.blue.shade200
                                              : Colors.brown.shade200,
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
                                      color:
                                          Colors.white.withValues(alpha: 0.88),
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
                    ],
                  );
                }), // Column / LayoutBuilder
              ), // MouseRegion
              ), // GestureDetector
              ), // SizedBox
            ), // TapRegion
            // === 栄養管理アラート（グラフの下・既定は折り畳み、タップで展開） ===
            if (hasAlerts) ...[
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
                        border:
                            Border.all(color: Colors.deepOrange.shade200),
                      ),
                      child: Text(
                          '$alertCount件',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.deepOrange.shade700)),
                    ),
                    const Spacer(),
                    Icon(
                        _alertsExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 20,
                        color: Colors.black45),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_alertsExpanded && efadRisk)
              _chartAlert(
                color: Colors.orange.shade800,
                title: '${_alertDate(14, dates, n)}以降　必須脂肪酸欠乏のリスク',
                body:
                    '絶食開始からDay14まで脂質の投与がありません。長期化で必須脂肪酸が欠乏します。'
                    '脂肪乳剤を開始してください。',
                suggest: 'イントラリポス20% 100mL/日（脂質20g）を補充'
                    '（または週2回100mL）',
              ),
            if (_alertsExpanded && thiamineRisk && !refeedRisk)
              _chartAlert(
                color: Colors.red.shade700,
                title: '${_alertDate(preDays + 1, dates, n)}以降（栄養再開・糖負荷時）'
                    '　リフィーディング/Wernicke脳症のリスク',
                body:
                    '絶食5日以上＋糖質投与でビタミンB1の需要が増大し欠乏しうる'
                    '（貯蔵は約2週間で枯渇）。糖負荷の前〜同時に補充してください。',
                suggest: 'ビタミンB1（チアミン）100〜300mg/日を静注で補充',
              ),
            if (_alertsExpanded && pnMonitorRisk)
              _chartAlert(
                color: Colors.teal.shade700,
                title:
                    '${_alertDate(pnHeavyMaxDay, dates, n)}以降（PN主体がDay$pnHeavyMaxDayまで継続）'
                    '　電解質・微量元素の過不足に注意',
                body:
                    'EN≤30ml/hでPN主体の状態が続きます。'
                    'P・K・Mg・亜鉛・ビタミンの過不足が生じやすい時期です。'
                    '採血検査を追加して確認してください。',
                suggest: '不足時は リン酸Na/KCL/硫酸Mg補正液・微量元素製剤・'
                    '総合ビタミン剤 で補正',
              ),
            if (_alertsExpanded && refeedRisk)
              _chartAlert(
                color: Colors.red.shade700,
                title:
                    '${_alertDate(preDays + 1, dates, n)}以降（栄養再開初期）'
                        '　Refeeding症候群 ${refeedTier.label}（NICE）',
                body:
                    '絶食$preDays日・BMI ${cbw.bmiOf(widget.current.weightKg, widget.current.heightCm).toStringAsFixed(1)}。'
                    '初期は10 kcal/kg（超高リスクは5）から開始し4–7日で漸増します'
                    '（本設計は自動でcap済み）。',
                suggest: cr.refeedingActionText(refeedTier),
              ),
            for (final m in microAlertsList)
              if (_alertsExpanded)
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

  void _showDayDetail(int i, DesignPlan plan, double dayKcal, double dayProt) {
    final date = _dateOf(i);
    final mode = _dayModes[i];
    final dose = _dayEnDose[i];
    final mealPac = _pacOf(dose) > 0 ? (_pacOf(dose) / 3).round() : 0;
    final isZero = mode == 'ZERO' || plan.label == 'ZERO';
    final w = widget.current.weightKg;
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
              onPressed: () => Navigator.pop(ctx),
              child: const Text('閉じる')),
        ],
      ),
    );
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
            final pacPerExchange =
                (rateMlH * 8 / (p?.volumeMl ?? 200)).ceil();
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
