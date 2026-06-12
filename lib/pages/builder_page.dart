part of '../main.dart';

class BuilderPage extends StatefulWidget {
  const BuilderPage({super.key, required this.state, required this.refresh});
  final AppState state;
  final VoidCallback refresh;

  @override
  State<BuilderPage> createState() => _BuilderPageState();
}

class _BuilderPageState extends State<BuilderPage>
    with TickerProviderStateMixin {
  String category = 'EN';
  // サマリーパネル（個別選択/ゼロmenu）
  double _summaryHeight = 80.0;
  double _snapFrom = 80.0;
  double _snapToTarget = 80.0;
  double _scrollFrom = 0.0;
  double _scrollToTarget = 0.0;
  late AnimationController _snapCtrl;
  final ScrollController _listScroll = ScrollController();
  // 栄養の推移パネル（自動計算タブ）
  static const double _chartPanelMin = 72.0;
  double _chartPanelHeight = 230.0;
  double _chartSnapFrom = 230.0;
  double _chartSnapToTarget = 230.0;
  late AnimationController _chartSnapCtrl;
  final ScrollController _chartScroll = ScrollController();
  // Phase 4-③: 処方ビルダーの2タブ状態 (0: EN/TPN/PPN 選択, 1: ゼロからブレンド)
  int _builderTabIndex = 0;
  bool _builderCardCollapsed = false; // 計算画面の患者カード折りたたみ
  bool _summaryCollapsed = false; // サマリーパネル折りたたみ
  bool _riskCollapsed = true; // リスク・補充サジェスト 折りたたみ(既定=畳む, アラート疲れ回避)
  final targetKcalController = TextEditingController(text: '1500');
  final npcnController = TextEditingController(text: '150');
  double _lipidGPerKg = 0.4;
  String glucoseSource = '70% グルコース';
  // ゼロmenu: 2サブタブ (0:本体, 1:加注) と加注製剤リスト(複数可)
  int _zeroSubTab = 0;
  final List<String> _zeroAdditives = [];
  // 個別選択モードの加注（デフォルト空。ゼロmenuの_zeroAdditivesとは独立）
  final List<String> _selectAdditives = [];
  final Set<String> expandedProducts = {};
  double _enRateMlPerHour = 0;
  // TPN/PPN 流量(ml/h)。0 = 「24hかけて」(=総量÷24)、>0 = 固定速度。表示・処方箋用。
  double _tpnRateMlPerHour = 0;
  double _ppnRateMlPerHour = 0;

  @override
  void initState() {
    super.initState();
    // ゼロmenu 加注の既定: 微量元素・ビタミンを標準で1つずつ追加
    final defTrace = widget.state.catalog.byCategory('微量元素').firstOrNull?.name;
    final defVit = widget.state.catalog.byCategory('ビタミン').firstOrNull?.name;
    if (defTrace != null) _zeroAdditives.add(defTrace);
    if (defVit != null) _zeroAdditives.add(defVit);
    // 病態の栄養制限/推奨をゼロmenuの既定入力(kcal/NPC・N/脂質)へ反映。
    final selCase = widget.state.selectedCase;
    if (selCase != null) {
      _applyZeroMenuConditionDefaults(selCase);
    }
    _snapCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 260));
    _snapCtrl.addListener(() {
      if (!mounted) return;
      final t = Curves.easeOut.transform(_snapCtrl.value);
      setState(() => _summaryHeight = _snapFrom + (_snapToTarget - _snapFrom) * t);
      if (_listScroll.hasClients) {
        final target = (_scrollFrom + (_scrollToTarget - _scrollFrom) * t)
            .clamp(0.0, _listScroll.position.maxScrollExtent);
        _listScroll.jumpTo(target);
      }
    });
    _chartSnapCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 260));
    _chartSnapCtrl.addListener(() {
      if (!mounted) return;
      final t = Curves.easeOut.transform(_chartSnapCtrl.value);
      setState(() => _chartPanelHeight =
          _chartSnapFrom + (_chartSnapToTarget - _chartSnapFrom) * t);
    });
  }

  /// 病態の栄養制限/推奨をゼロmenuの既定入力へ反映する。
  /// ・目標kcal = 目標エネルギーの90%(permissive underfeeding)
  /// ・NPC/N = 病態タンパク目標(腎マトリクス優先, 無ければ患者g/kg)から目標kcalで逆算
  ///   → 腎/AKI/RRTの蛋白制限や重症の高タンパクが NPC/N に反映される
  /// ・脂質g/kg = 病態中央値(resolveCoeff・上限1.0)
  void _applyZeroMenuConditionDefaults(PatientCase c) {
    final targetKcal = NutritionCalculator.targetEnergy(c) * 0.9;
    targetKcalController.text = targetKcal.round().toString();
    final protPerKg = cc.effectiveProteinPerKg(c.conditionTags, c.proteinGoalPerKg);
    final protG = protPerKg * c.weightKg;
    if (protG > 0 && targetKcal > 0) {
      final npc = (targetKcal - protG * 4) * 6.25 / protG;
      npcnController.text = npc.clamp(80, 500).round().toString();
    }
    final rc = cc.resolveCoeff(c.conditionTags);
    if (rc != null) {
      _lipidGPerKg = double.parse(rc.lipidGPerKg.toStringAsFixed(1));
    }
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    _chartSnapCtrl.dispose();
    _listScroll.dispose();
    _chartScroll.dispose();
    super.dispose();
  }

  /// 静脈栄養(TPN/PPN)由来のブドウ糖・脂質グラム（GIR/脂質速度の評価用）。
  ({double glucoseG, double lipidG}) _parenteralMacros(PatientCase current) {
    double glu = 0, fat = 0;
    for (final item in current.regimenItems) {
      final p = widget.state.catalog.byId(item.productId);
      if (p == null || item.units <= 0) continue;
      if (p.category == 'TPN' || p.category == 'PPN') {
        glu += (p.carbBase ?? 0) * item.units;
        fat += (p.fatBase ?? 0) * item.units;
      }
    }
    return (glucoseG: glu, lipidG: fat);
  }

  Widget _infusionAlertRow(ci.AlertLevel lv, String text) {
    final color = lv == ci.AlertLevel.danger
        ? Colors.red.shade600
        : Colors.orange.shade800;
    final label = lv == ci.AlertLevel.danger ? '危険' : '注意';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color),
      ),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text('$label  $text',
              style: TextStyle(fontSize: 11.5, color: color)),
        ),
      ]),
    );
  }

  /// GIR・脂質負荷速度のアラート群（超過時のみ表示。糖質制限病態はGIR上限4）。
  List<Widget> _infusionAlertList({
    required double glucoseGramPerDay,
    required double lipidGramPerDay,
    required double weightKg,
    required bool glucoseRestrict,
  }) {
    final rows = <Widget>[];
    if (glucoseGramPerDay > 0 && weightKg > 0) {
      final girVal =
          ci.gir(glucoseGramPerDay: glucoseGramPerDay, weightKg: weightKg);
      final hardLimit =
          glucoseRestrict ? 4.0 : ck.ClinicalConst.girLimitMgKgMin;
      final warnAt = glucoseRestrict ? 3.5 : ck.ClinicalConst.girWarnMgKgMin;
      final lv = ci.girLevel(girVal, warn: warnAt, limit: hardLimit);
      if (lv != ci.AlertLevel.ok) {
        rows.add(_infusionAlertRow(lv,
            'GIR ${girVal.toStringAsFixed(1)} mg/kg/min（上限${hardLimit.toStringAsFixed(0)}）糖負荷過剰、高血糖・脂肪肝に注意'));
      }
    }
    if (lipidGramPerDay > 0 && weightKg > 0) {
      final rate = ci.lipidRatePerHour(
          lipidGramPerDay: lipidGramPerDay, weightKg: weightKg);
      final perDay = ci.lipidPerDayGramPerKg(
          lipidGramPerDay: lipidGramPerDay, weightKg: weightKg);
      final lvRate = ci.lipidRateLevel(rate);
      final lvDay = ci.lipidDayLevel(perDay);
      final lv = lvRate.index >= lvDay.index ? lvRate : lvDay;
      if (lv != ci.AlertLevel.ok) {
        rows.add(_infusionAlertRow(lv,
            '脂質 ${perDay.toStringAsFixed(2)} g/kg/day・${rate.toStringAsFixed(3)} g/kg/h、高TG血症に注意'));
      }
    }
    return rows;
  }

  Widget _infusionAlerts({
    required double glucoseGramPerDay,
    required double lipidGramPerDay,
    required double weightKg,
    required bool glucoseRestrict,
  }) {
    final rows = _infusionAlertList(
      glucoseGramPerDay: glucoseGramPerDay,
      lipidGramPerDay: lipidGramPerDay,
      weightKg: weightKg,
      glucoseRestrict: glucoseRestrict,
    );
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// サマリー下部のアラート群（GIR/脂質 + 微量栄養素UL + 病態ガイダンス）。
  List<Widget> _summaryAlertWidgets({
    required PatientCase current,
    required double glucoseGramPerDay,
    required double lipidGramPerDay,
    required cm.MicroTotals micro,
  }) {
    final restrict =
        cc.resolveCoeff(current.conditionTags)?.glucoseRestrict ?? false;
    return [
      ..._infusionAlertList(
        glucoseGramPerDay: glucoseGramPerDay,
        lipidGramPerDay: lipidGramPerDay,
        weightKg: current.weightKg,
        glucoseRestrict: restrict,
      ),
      ..._microAlertRows(micro, current,
          glucoseLoad: glucoseGramPerDay > 0),
    ];
  }

  /// 個別選択の全ソース横断 微量栄養素集計。
  /// `_aggregateWithRates` と同一のソース集合(EN/EN補助/TPN/PPN/濃厚流動食/栄養サポート/加注)
  /// と同一の按分係数(投与速度指定時)で集計するため、マクロ集計と整合し各itemは1回のみ計上。
  cm.MicroTotals _microWithRates(PatientCase current) {
    final contributions = <cm.MicroContribution>[];
    int unitsOf(RegimenItem item) => item.hasMealTiming
        ? (item.morning + item.noon + item.evening)
        : item.units;

    // 製剤の実効本数: EN=本数(rate按分対象)、TPN/PPN=units+部分ml/bagVol(per-product ml)。
    double effOf(RegimenItem item, Product p, String categoryKey) {
      if (categoryKey == 'EN') return unitsOf(item).toDouble();
      final bagVol = p.volumeMl ?? 0;
      return item.units + (bagVol > 0 ? item.partialMl / bagVol : 0);
    }

    void addCategory(String categoryKey, double rate) {
      final selected = current.regimenItems.where((item) {
        final p = widget.state.catalog.byId(item.productId);
        if (p == null) return false;
        if (categoryKey == 'EN') {
          if (!(p.category == 'EN' || p.category == 'EN_AUX')) return false;
          return unitsOf(item) > 0;
        }
        if (p.category != categoryKey) return false;
        return item.units > 0 || item.partialMl > 0;
      }).toList();
      if (selected.isEmpty) return;
      double fullIN = 0;
      for (final item in selected) {
        final p = widget.state.catalog.byId(item.productId)!;
        fullIN += (p.volumeMl ?? 0) * effOf(item, p, categoryKey);
      }
      // ENのみ投与速度で按分。TPN/PPNはper-product mlがそのまま日量。
      final factor =
          (categoryKey == 'EN' && rate > 0 && fullIN > 0) ? (rate * 24) / fullIN : 1.0;
      for (final item in selected) {
        final p = widget.state.catalog.byId(item.productId)!;
        contributions.add(
            cm.MicroContribution(p.micro, effOf(item, p, categoryKey) * factor));
      }
    }

    addCategory('EN', _enRateMlPerHour);
    addCategory('TPN', 0);
    addCategory('PPN', 0);
    addCategory('濃厚流動食', 0);
    addCategory('栄養サポート食品', 0);
    for (final name in _selectAdditives) {
      final p = widget.state.catalog.byName(name);
      if (p != null) contributions.add(cm.MicroContribution(p.micro, 1));
    }
    return cm.aggregateMicro(contributions);
  }

  /// 微量栄養素のUL超過＋病態別ガイダンスのアラート行（_infusionAlertRow を流用）。
  List<Widget> _microAlertRows(cm.MicroTotals totals, PatientCase current,
      {bool glucoseLoad = false}) {
    final bmi = cbw.bmiOf(current.weightKg, current.heightCm);
    final f = _microFlags(current.conditionTags, bmi: bmi);
    return cm
        .microAlerts(totals,
            isMale: current.sex == Sex.male,
            cholestasis: f.cholestasis,
            liver: f.liver,
            renal: f.renal,
            crrt: f.crrt,
            giLoss: f.giLoss,
            glucoseLoad: glucoseLoad,
            wernickeRisk: f.wernicke)
        .map((a) => _infusionAlertRow(
            a.level == ci.AlertLevel.danger
                ? ci.AlertLevel.danger
                : ci.AlertLevel.caution,
            a.message))
        .toList();
  }

  /// 採用済み(なければ全体)から条件に合う製剤を1つ選ぶ。
  Product? _pickAdoptedProduct(bool Function(Product) test) {
    final all = widget.state.catalog.products.where(test).toList();
    final adopted =
        all.where((p) => widget.state.isAdopted(p.id)).toList();
    if (adopted.isNotEmpty) return adopted.first;
    return all.isNotEmpty ? all.first : null;
  }

  /// ベース製剤の内蔵成分に応じた非重複の推奨加注（胆汁うっ滞/肝障害ならMn-free）。
  List<String> _recommendedSelectAdditives(PatientCase current) {
    final bases = <Product>[];
    for (final it in current.regimenItems) {
      final p = widget.state.catalog.byId(it.productId);
      final n =
          it.hasMealTiming ? (it.morning + it.noon + it.evening) : it.units;
      if (p != null && n > 0) bases.add(p);
    }
    final hasVit = bases.any((p) => p.kitHasVitamins);
    final hasTrace = bases.any((p) => p.kitHasFullTrace);
    final mnAvoid = current.conditionTags.contains('cholestasis') ||
        current.conditionTags.contains('liver');
    final out = <String>[];
    if (!hasVit) {
      final mvi = _pickAdoptedProduct((p) => p.isFullMvi);
      if (mvi != null) out.add(mvi.name);
    }
    if (!hasTrace) {
      final trace = mnAvoid
          ? (_pickAdoptedProduct((p) => p.isMnFreeTrace) ??
              _pickAdoptedProduct((p) => p.isCombinedTrace))
          : _pickAdoptedProduct((p) => p.isCombinedTrace);
      if (trace != null) out.add(trace.name);
    }
    return out;
  }

  void _snapTo(double target) {
    _snapFrom = _summaryHeight;
    _snapToTarget = target;
    _scrollFrom = _listScroll.hasClients ? _listScroll.offset : 0.0;
    final delta = target - _summaryHeight;
    _scrollToTarget = _scrollFrom + delta.clamp(0.0, double.infinity);
    _snapCtrl.forward(from: 0);
  }

  void _chartSnapTo(double target) {
    _chartSnapFrom = _chartPanelHeight;
    _chartSnapToTarget = target;
    _chartSnapCtrl.forward(from: 0);
  }

  static const _infusionRateOptions = [0.0, 10.0, 20.0, 30.0, 40.0];

  String _rateLabel(double rate) =>
      rate <= 0 ? '全量' : '${rate.toStringAsFixed(0)} ml/h';

  List<Product> _selectedProductsForCategory(String category) {
    if (category == 'EN') {
      return widget.state.catalog.products.where((p) {
        return (p.category == 'EN' || p.category == 'EN_AUX') &&
            widget.state.isAdopted(p.id);
      }).toList();
    }
    return widget.state.catalog
        .byCategory(category)
        .where((p) => widget.state.isAdopted(p.id))
        .toList();
  }

  /// EN投与速度（持続）指定時、8h交換で1バッグに必要な本数に処方を自動調整する。
  /// 必要本数 = ceil(速度ml/h × 8h ÷ 製剤容量ml)。
  /// すでに処方されているタイミング(朝/昼/夕で1本以上)を必要本数ちょうどに合わせる（増減両方）。
  /// EN本体のみ対象（EN補助製剤は調整しない）。本数は朝昼夕ドロップダウンの上限3まで。
  Future<void> _adjustEnUnitsForRate(PatientCase current) async {
    final perBagMl = _enRateMlPerHour * 8; // ENは8h毎に交換
    for (final item in current.regimenItems.toList()) {
      final product = widget.state.catalog.byId(item.productId);
      if (product == null) continue;
      if (product.category != 'EN') continue; // EN補助(EN_AUX)は調整off
      final vol = product.volumeMl ?? 0;
      if (vol <= 0) continue;
      final needed = (perBagMl / vol).ceil().clamp(1, 3);
      if (item.hasMealTiming) {
        // 処方済み(>0)のタイミングだけを必要本数に揃える（0のタイミングは触らない）
        final m = item.morning > 0 ? needed : 0;
        final n = item.noon > 0 ? needed : 0;
        final e = item.evening > 0 ? needed : 0;
        if (m != item.morning || n != item.noon || e != item.evening) {
          await widget.state.setMealUnits(current.id, product, m, n, e);
        }
      } else if (item.units > 0 && item.units != needed) {
        await widget.state.setUnits(current.id, product, needed);
      }
    }
  }

  AggregateResult _aggregateWithRates(PatientCase current) {
    double totalVolumeMl = 0;
    double totalKcal = 0;
    double totalProteinG = 0;
    double totalFatG = 0;
    double fatKcal = 0;
    double carbKcal = 0;
    double proteinKcal = 0;

    final activeItems = current.regimenItems.toList();

    // 各レジメンアイテムの「本数」: EN朝昼夕が設定されていれば合計、なければ units
    int unitsOf(RegimenItem item) =>
        item.hasMealTiming ? (item.morning + item.noon + item.evening) : item.units;

    // Excel準拠の本数ベース集計。製剤の kcal/aminoAcidG/fatBase/carbBase/volumeMl は
    // 1パック(1本)あたりの値なので、本数を掛けるだけでよい（密度換算は不要）。
    void processCategory(String categoryKey, double rate) {
      // 該当カテゴリの実際に選択されている製剤(本数>0)を抽出
      final selectedItems = activeItems.where((item) {
        final product = widget.state.catalog.byId(item.productId);
        if (product == null) return false;
        if (categoryKey == 'EN') {
          if (!(product.category == 'EN' || product.category == 'EN_AUX')) {
            return false;
          }
          return unitsOf(item) > 0;
        }
        if (product.category != categoryKey) return false;
        // TPN/PPN/食事: 本数>0 または 部分ml>0
        return item.units > 0 || item.partialMl > 0;
      }).toList();

      // 製剤が選ばれていなければ投与速度を動かしても何も加算しない
      if (selectedItems.isEmpty) return;

      // 実効本数: EN=本数、TPN/PPN=units+部分ml/bagVol(per-product ml指定)。
      double effOf(RegimenItem item, Product product) {
        if (categoryKey == 'EN') return unitsOf(item).toDouble();
        final bagVol = product.volumeMl ?? 0;
        return item.units + (bagVol > 0 ? item.partialMl / bagVol : 0);
      }

      // 集計（本数/ml ベース）— Excel T19/T20/T21/T23 に対応
      double fullIN = 0, fullKcal = 0, fullProt = 0, fullFatG = 0, fullCarbG = 0;
      for (final item in selectedItems) {
        final product = widget.state.catalog.byId(item.productId)!;
        final n = effOf(item, product);
        fullIN += (product.volumeMl ?? 0) * n;
        fullKcal += (product.kcal ?? 0) * n;
        fullProt += (product.aminoAcidG ?? 0) * n;
        fullFatG += (product.fatBase ?? 0) * n;
        fullCarbG += (product.carbBase ?? 0) * n;
      }

      // ENのみ投与速度で「一部投与」按分。TPN/PPN/食事はper-product mlがそのまま日量。
      final factor =
          (categoryKey == 'EN' && rate > 0 && fullIN > 0) ? (rate * 24) / fullIN : 1.0;

      totalVolumeMl += fullIN * factor;
      totalKcal += fullKcal * factor;
      totalProteinG += fullProt * factor;
      totalFatG += fullFatG * factor;
      fatKcal += fullFatG * 9 * factor;
      carbKcal += fullCarbG * 4 * factor;
      proteinKcal += fullProt * 4 * factor;
    }

    // TPN/PPNはper-product ml指定(本数+部分ml)がそのまま日量。流量は表示用。
    processCategory('EN', _enRateMlPerHour);
    processCategory('TPN', 0);
    processCategory('PPN', 0);
    // 食事(濃厚流動食・栄養サポート食品)を本数ベースで合算 (rate=0 → 全量)
    processCategory('濃厚流動食', 0);
    processCategory('栄養サポート食品', 0);

    // 加注製剤(電解質/微量元素/ビタミン)を合算（個別選択は_selectAdditives）
    for (final name in _selectAdditives) {
      final p = widget.state.catalog.byName(name);
      if (p == null) continue;
      final prot = p.aminoAcidG ?? 0;
      final fat = p.fatBase ?? 0;
      final carb = p.carbBase ?? 0;
      totalVolumeMl += p.volumeMl ?? 0;
      totalKcal += p.kcal ?? 0;
      totalProteinG += prot;
      totalFatG += fat;
      fatKcal += fat * 9;
      carbKcal += carb * 4;
      proteinKcal += prot * 4;
    }

    return AggregateResult(
      totalVolumeMl: totalVolumeMl,
      totalKcal: totalKcal,
      totalProteinG: totalProteinG,
      totalFatG: totalFatG,
      fatKcal: fatKcal,
      carbKcal: carbKcal,
      proteinKcal: proteinKcal,
    );
  }

  AggregateResult _aggregateFromVolumes(
      List<Product?> products, List<double> volumesMl) {
    double totalVolumeMl = 0;
    double totalKcal = 0;
    double totalProteinG = 0;
    double totalFatG = 0;
    double fatKcal = 0;
    double carbKcal = 0;
    double proteinKcal = 0;

    for (var i = 0; i < products.length; i++) {
      final product = products[i];
      final volume = volumesMl[i];
      if (product == null || volume <= 0) continue;
      final density =
          (product.volumeMl ?? 1) == 0 ? 0 : volume / (product.volumeMl ?? 1);
      final kcal = (product.kcal ?? 0) * density;
      final protein = (product.aminoAcidG ?? 0) * density;
      final fat = (product.fatBase ?? 0) * density;
      final carb = (product.carbBase ?? 0) * density;
      totalVolumeMl += volume;
      totalKcal += kcal;
      totalProteinG += protein;
      totalFatG += fat;
      fatKcal += fat * 9;
      carbKcal += carb * 4;
      proteinKcal += protein * 4;
    }

    return AggregateResult(
      totalVolumeMl: totalVolumeMl,
      totalKcal: totalKcal,
      totalProteinG: totalProteinG,
      totalFatG: totalFatG,
      fatKcal: fatKcal,
      carbKcal: carbKcal,
      proteinKcal: proteinKcal,
    );
  }

  // 加注製剤(電解質/微量元素/ビタミン)を複数追加するピッカー。
  // カテゴリ見出し付きの1リストを最初から展開表示し、各行のステッパーで選ぶ。
  // target は ゼロmenu(_zeroAdditives) / 個別選択(_selectAdditives) を切替えて渡す。
  Widget _additivePicker(List<String> target) {
    const cats = [
      ('電解質', '電解質補正'),
      ('微量元素', '微量元素製剤'),
      ('ビタミン', 'ビタミン製剤'),
    ];
    int countOf(String name) => target.where((x) => x == name).length;

    Widget header(String label) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 6, bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          color: Colors.blueGrey.shade50,
          child: Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey.shade600)),
        );

    Widget prodRow(Product p) {
      final cnt = countOf(p.name);
      final vol = p.volumeMl != null ? '${p.volumeMl!.round()}ml' : '';
      final sub = [if (p.content.isNotEmpty) p.content, if (vol.isNotEmpty) vol]
          .join(' / ');
      return Container(
        color: cnt > 0 ? Colors.blue.shade50 : null,
        padding: const EdgeInsets.only(left: 6),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (sub.isNotEmpty)
                  Text(sub,
                      style:
                          TextStyle(fontSize: 10.5, color: Colors.grey.shade600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            visualDensity: VisualDensity.compact,
            color: Colors.red.shade400,
            onPressed:
                cnt > 0 ? () => setState(() => target.remove(p.name)) : null,
          ),
          SizedBox(
              width: 18,
              child: Text('$cnt',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: cnt > 0 ? Colors.blue.shade700 : Colors.grey))),
          IconButton(
            icon: const Icon(Icons.add_circle, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            visualDensity: VisualDensity.compact,
            color: Colors.blue.shade600,
            onPressed: () => setState(() => target.add(p.name)),
          ),
        ]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (cat, label) in cats) ...[
          header(label),
          ...sortProductsForDisplay(widget.state.catalog.byCategory(cat),
                  additiveCat: cat)
              .map(prodRow),
        ],
      ],
    );
  }

  /// 現処方＋患者からアラートエンジンの評価コンテキストを構築するアダプタ。
  /// v1: 静脈ブドウ糖(GIR)・Naは未連携のため null（→ dataMissing は非表示）。
  ae.EvalContext _evalContextFor(PatientCase current, AggregateResult agg) {
    final prot = agg.totalProteinG;
    double? npcN;
    if (prot > 0) {
      final n = prot / 6.25;
      final v = (agg.totalKcal - prot * 4) / n;
      if (v.isFinite) npcN = v;
    }
    double m(Map? mp, String key) => (mp?[key] as num?)?.toDouble() ?? 0;
    final products = <ae.EvalProduct>[];
    double na = 0, kEl = 0, pMmol = 0, mg = 0;
    double b1 = 0, mn = 0, cu = 0, zn = 0, se = 0;
    double ivGlu = 0, carbTot = 0;
    for (final item in current.regimenItems) {
      final units =
          item.units > 0 ? item.units : (item.morning + item.noon + item.evening);
      if (units <= 0) continue;
      final p = widget.state.catalog.byId(item.productId);
      if (p == null) continue;
      final u = units.toDouble();
      products.add(ae.EvalProduct(name: p.name, mnAmountUmol: p.mnAmount));
      final el = p.micro?['elec'] as Map?;
      na += m(el, 'Na') * u;
      kEl += m(el, 'K') * u;
      pMmol += m(el, 'P') * u;
      mg += m(el, 'Mg') * u;
      final tr = p.micro?['trace'] as Map?;
      mn += m(tr, 'Mn') * u;
      cu += m(tr, 'Cu') * u;
      zn += m(tr, 'Zn') * u;
      se += m(tr, 'Se') * u;
      b1 += m(p.micro?['vit'] as Map?, 'B1') * u;
      final carb = (p.carbBase ?? 0) * u;
      carbTot += carb;
      if (!(p.inEnTab || p.isFood)) ivGlu += carb;
    }
    return ae.EvalContext(
      weightKg: current.weightKg,
      conditionTags: current.conditionTags.toSet(),
      targetKcal: NutritionCalculator.targetEnergy(current),
      proteinGoalPerKg: current.proteinGoalPerKg,
      totalKcal: agg.totalKcal,
      totalProteinG: agg.totalProteinG,
      totalVolumeMl: agg.totalVolumeMl,
      ivGlucoseGramPerDay: ivGlu,
      carbGramPerDay: carbTot,
      lipidGramPerDay: agg.totalFatG,
      npcN: npcN,
      naMEq: na,
      kMEq: kEl,
      pMmol: pMmol,
      mgMEq: mg,
      vitaminB1Mg: b1,
      mnUmol: mn,
      cuUmol: cu,
      znUmol: zn,
      seUmol: se,
      hasGlucoseLoad: carbTot > 0,
      refeedingRisk: _refeedingRiskOf(current),
      fastingDaysGE5: _fastingDaysOf(current) >= 5,
      products: products,
    );
  }

  /// 折りたたみ時の件数バッジ。
  Widget _riskBadge(String text, Color color) => Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            style: const TextStyle(fontSize: 10, color: Colors.white)),
      );

  /// アラートエンジンの評価結果(dataMissing除外・severity順)。
  List<ae.NutritionAlert> _nutritionAlerts(
      PatientCase current, AggregateResult agg) {
    return ae
        .evaluate(_evalContextFor(current, agg), ae.ConstraintSet.standard())
        .where((a) => !a.dataMissing)
        .toList()
      ..sort((a, b) => a.severity.index.compareTo(b.severity.index));
  }

  /// アラートエンジンの評価結果を表示（#1 可視化）。
  /// error=禁忌(赤)/warning=警告(橙)。該当なし・dataMissingのみなら非表示。
  Widget _nutritionAlertPanel(PatientCase current, AggregateResult agg) {
    final alerts = _nutritionAlerts(current, agg);
    if (alerts.isEmpty) return const SizedBox.shrink();
    final hasError = alerts.any((a) => a.severity == ae.AlertSeverity.error);
    Color colOf(ae.AlertSeverity sv) => sv == ae.AlertSeverity.error
        ? Colors.red.shade700
        : sv == ae.AlertSeverity.warning
            ? Colors.orange.shade800
            : Colors.blueGrey;
    IconData icoOf(ae.AlertSeverity sv) => sv == ae.AlertSeverity.error
        ? Icons.error_outline
        : sv == ae.AlertSeverity.warning
            ? Icons.warning_amber_rounded
            : Icons.info_outline;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: hasError ? Colors.red.shade50 : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: hasError ? Colors.red.shade200 : Colors.orange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.health_and_safety,
                size: 14,
                color: hasError ? Colors.red.shade700 : Colors.orange.shade800),
            const SizedBox(width: 4),
            Text('リスク評価（${hasError ? '禁忌あり' : '警告あり'}）',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    color:
                        hasError ? Colors.red.shade800 : Colors.orange.shade900)),
            const Spacer(),
            // 自動修正（feasible かつ softScore 最小へ本数を調整して提案）
            OutlinedButton.icon(
              onPressed: () => _runRepair(current),
              icon: const Icon(Icons.healing, size: 14),
              label: const Text('リペア', style: TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ]),
          const SizedBox(height: 4),
          for (final a in alerts)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icoOf(a.severity), size: 13, color: colOf(a.severity)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(a.message,
                      style: TextStyle(
                          fontSize: 11,
                          color: colOf(a.severity),
                          height: 1.25)),
                ),
              ]),
            ),
        ],
      ),
    );
  }

  // ─────────── リペアループ（自動修正・説明可能） ───────────
  // alerts.evaluate のアラートから RepairAction を逆引きし、feasible案を softScore で
  // ランキングして提案する(repair engine)。食事タイミング製剤は触らない。

  double _b1mgOf(Product? p) =>
      ((p?.micro?['vit'] as Map?)?['B1'] as num?)?.toDouble() ?? 0;

  Product? _highDoseB1Product() {
    final all = widget.state.catalog
        .byCategory('ビタミン')
        .where((p) => _b1mgOf(p) >= 50)
        .toList();
    if (all.isEmpty) return null;
    final adopted = all.where((p) => widget.state.isAdopted(p.id)).toList();
    final pool = adopted.isNotEmpty ? adopted : all;
    pool.sort((a, b) {
      final av = a.name.contains('ビタメジン') ? 1 : 0;
      final bv = b.name.contains('ビタメジン') ? 1 : 0;
      if (av != bv) return bv - av;
      return _b1mgOf(b).compareTo(_b1mgOf(a));
    });
    return pool.first;
  }

  Product? _mnFreeTraceProduct() {
    final all = widget.state.catalog
        .byCategory('微量元素')
        .where((p) => p.isMnFreeTrace)
        .toList();
    if (all.isEmpty) return null;
    final adopted = all.where((p) => widget.state.isAdopted(p.id)).toList();
    return (adopted.isNotEmpty ? adopted : all).first;
  }

  double _traceMicro(Product p, String key) =>
      ((p.micro?['trace'] as Map?)?[key] as num?)?.toDouble() ?? 0;

  Product? _znTraceProduct() {
    final all = widget.state.catalog
        .byCategory('微量元素')
        .where((p) => _traceMicro(p, 'Zn') > 0)
        .toList();
    if (all.isEmpty) return null;
    // Mn-free の Zn源を優先（胆汁うっ滞でも安全）
    final mnFree = all.where((p) => p.isMnFreeTrace).toList();
    final pool = mnFree.isNotEmpty ? mnFree : all;
    final adopted = pool.where((p) => widget.state.isAdopted(p.id)).toList();
    return (adopted.isNotEmpty ? adopted : pool).first;
  }

  Product? _seProduct() {
    final all = widget.state.catalog
        .byCategory('微量元素')
        .where((p) => _traceMicro(p, 'Se') > 0)
        .toList();
    if (all.isEmpty) return null;
    final adopted = all.where((p) => widget.state.isAdopted(p.id)).toList();
    return (adopted.isNotEmpty ? adopted : all).first;
  }

  int _fastingDaysOf(PatientCase c) {
    final f = c.fastingDate;
    final fd = f != null ? DateTime.tryParse(f) : null;
    if (fd == null) return 0;
    final d = DateTime.now().difference(fd).inDays;
    return d < 0 ? 0 : d;
  }

  /// Refeeding(NICE)が高リスク以上か。BMI/絶食日数の自動フラグ ∪ 患者編集の手動フラグで判定。
  /// auto_design の _refeedingTier と同一基準で、個別設計のB1ゲート(thiamine_needed)も連動させる。
  bool _refeedingRiskOf(PatientCase c) {
    // 保存値は手動基準のみ採用（旧/外部JSONの stale な自動フラグ bmi_*/intake_* を除外）。
    final flags = cr.autoRefeedingFlags(
      bmi: cbw.bmiOf(c.weightKg, c.heightCm),
      daysNoIntake: _fastingDaysOf(c),
    )..addAll(c.refeedingFlags.where(cr.isManualRefeedingCriterion));
    return cr.refeedingTierFromFlags(flags) != cr.RefeedingTier.none;
  }

  /// 現regimen→PlanState(本数ベース。食事タイミングは合計pacを本数化)。
  PlanState _planStateFromRegimen(PatientCase current) {
    final items = <PlanItem>[];
    for (final it in current.regimenItems) {
      final p = widget.state.catalog.byId(it.productId);
      if (p == null) continue;
      final units =
          it.units > 0 ? it.units : (it.morning + it.noon + it.evening);
      if (units <= 0) continue;
      items.add(PlanItem(p, units));
    }
    return PlanState(items);
  }

  ae.EvalContext _evalOfPlan(PatientCase current, PlanState p) =>
      computeEvalContext(
        p,
        weightKg: current.weightKg,
        conditionTags: current.conditionTags.toSet(),
        targetKcal: NutritionCalculator.targetEnergy(current),
        proteinGoalPerKg: current.proteinGoalPerKg,
        refeedingRisk: _refeedingRiskOf(current),
        fastingDaysGE5: _fastingDaysOf(current) >= 5,
      );

  /// 補正案を差分のみ regimen へ反映（食事タイミング製剤は不変）。
  Future<void> _applyRepair(
      PatientCase current, PlanState before, PlanState after) async {
    final beforeU = {for (final i in before.items) i.product.id: i.units};
    final afterU = {for (final i in after.items) i.product.id: i.units};
    for (final id in {...beforeU.keys, ...afterU.keys}) {
      final b = beforeU[id] ?? 0;
      final a = afterU[id] ?? 0;
      if (a == b) continue;
      final idx = current.regimenItems.indexWhere((it) => it.productId == id);
      if (a == 0) {
        if (idx >= 0) current.regimenItems.removeAt(idx);
      } else if (idx >= 0) {
        current.regimenItems[idx].units = a;
      } else {
        current.regimenItems.add(RegimenItem(productId: id, units: a));
      }
    }
    await widget.state.persist();
    if (mounted) setState(() {});
  }

  Widget _repairChangeTile(int n, RepairChange c) {
    final color = c.kind == RepairChangeKind.add
        ? Colors.green.shade700
        : c.kind == RepairChangeKind.replace
            ? Colors.amber.shade800
            : Colors.indigo.shade600;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(8)),
            child: Text(c.label,
                style: const TextStyle(fontSize: 10, color: Colors.white)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text('$n. ${c.reason}',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 2),
          child: Text('${c.beforeText} → ${c.afterText}',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
        ),
      ],
    );
  }

  /// [リペア]ボタン: エンジンで補正案を作り、差分・残存警告を提示。採用で反映。
  Future<void> _runRepair(PatientCase current) async {
    final original = _planStateFromRegimen(current);
    final actions = buildRepairActions(
      b1Product: _highDoseB1Product(),
      mnFreeProduct: _mnFreeTraceProduct(),
      znProduct: _znTraceProduct(),
      seProduct: _seProduct(),
    );
    final outcome = repair(
      original,
      actions: actions,
      evalOf: (p) => _evalOfPlan(current, p),
      constraints: ae.ConstraintSet.standard(),
      weights: ae.ScoreWeights.standard(),
    );
    if (!mounted) return;
    if (!outcome.hasRepair) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('自動補正できる項目はありませんでした')));
      return;
    }
    final best = outcome.best!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('自動補正 ${best.changes.length}件'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < best.changes.length; i++) ...[
                  _repairChangeTile(i + 1, best.changes[i]),
                  const SizedBox(height: 8),
                ],
                if (outcome.unresolved.isNotEmpty) ...[
                  const Divider(),
                  Text('残存（自動解決できず）',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.red.shade700,
                          fontSize: 12.5)),
                  for (final a in outcome.unresolved)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('・${a.message}',
                          style: TextStyle(
                              fontSize: 11.5,
                              color: a.severity == ae.AlertSeverity.error
                                  ? Colors.red.shade700
                                  : Colors.orange.shade800)),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('却下（元のまま）')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('この補正を採用')),
        ],
      ),
    );
    if (ok == true) {
      // 元入力スナップショット(食事タイミング・部分使用も保持)→ 採用後に「元に戻す」可能
      final snapshot = current.regimenItems
          .map((it) => RegimenItem(
                productId: it.productId,
                units: it.units,
                morning: it.morning,
                noon: it.noon,
                evening: it.evening,
                partialMl: it.partialMl,
              ))
          .toList();
      await _applyRepair(current, original, best.plan);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('自動補正を適用しました'),
        action: SnackBarAction(
          label: '元に戻す',
          onPressed: () async {
            current.regimenItems
              ..clear()
              ..addAll(snapshot);
            await widget.state.persist();
            if (mounted) setState(() {});
          },
        ),
      ));
    }
  }

  /// 病態タグに応じた処方サジェスト(💡)。タグ0個なら非表示。
  /// 蛋白の目安cap超過時は控えめなテキスト1行を添える(色強調・ダイアログなし)。
  Widget _conditionSuggestionBanner(
      PatientCase current, AggregateResult aggregate) {
    final defs = current.conditionTags
        .map(ConditionCatalog.byId)
        .whereType<ConditionDef>()
        .toList();
    if (defs.isEmpty) return const SizedBox.shrink();

    final w = current.weightKg;
    final protPerKg = w > 0 ? aggregate.totalProteinG / w : 0.0;
    // cap を持つタグのうち、現処方が超過しているもの
    final overs = defs
        .where((d) =>
            d.proteinCapPerKg != null && protPerKg > d.proteinCapPerKg! + 1e-9)
        .toList();

    final textColor = Colors.brown.shade700;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final d in defs)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('💡 ${d.label}: ${d.suggestion}',
                  style: TextStyle(fontSize: 12, color: textColor)),
            ),
          if (overs.isNotEmpty)
            Text(
              '現在 ${protPerKg.toStringAsFixed(1)} g/kg'
              '（${overs.map((d) => '${d.label} 目安${d.proteinCapPerKg!.toStringAsFixed(1)}').join(' / ')} 超）',
              style: TextStyle(
                  fontSize: 12,
                  color: textColor,
                  fontWeight: FontWeight.w600),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.state.selectedCase;
    if (current == null) {
      return const Center(child: Text('先に症例を作成してください'));
    }

    final targetKcal = NutritionCalculator.targetEnergy(current);
    final targetProtein = NutritionCalculator.targetProtein(current);
    final protocol = widget.state.protocols
        .firstWhere((e) => e.id == current.selectedProtocolId);
    final zeroMenu = NutritionCalculator.zeroMenuSuggestion(
      targetKcal: double.tryParse(targetKcalController.text) ?? targetKcal,
      npcNRatio: double.tryParse(npcnController.text) ?? 125,
      lipidGramPerKg: _lipidGPerKg,
      weightKg: current.weightKg,
      glucoseProduct: widget.state.adoptedByBase(glucoseSource),
      aminoProduct: widget.state.adoptedAminoForZero(),
      lipidProduct: widget.state.adoptedLipidForZero(),
    );
    // 製剤構成と一致させる: 本体は10ml単位に丸め、加注製剤も合算してサマリーへ反映
    double _round10(double v) => (v / 10).round() * 10.0;
    final scratchAggregate = _aggregateFromVolumes(
      [
        widget.state.adoptedAminoForZero(),
        widget.state.adoptedLipidForZero(),
        widget.state.adoptedByBase(glucoseSource),
        ..._zeroAdditives.map((n) => widget.state.catalog.byName(n)),
      ],
      [
        _round10(zeroMenu.aminoVolumeMl),
        _round10(zeroMenu.lipidVolumeMl),
        _round10(zeroMenu.glucoseVolumeMl),
        ..._zeroAdditives
            .map((n) => widget.state.catalog.byName(n)?.volumeMl ?? 0),
      ],
    );
    final actualAggregate = _aggregateWithRates(current);

    final productUnits = <String, int>{};
    for (final item in current.regimenItems) {
      if (item.units > 0) {
        productUnits[item.productId] =
            (productUnits[item.productId] ?? 0) + item.units;
      }
    }

    // ENタブ選択時は、EN本体とEN補助(EN_AUX)を両方取得してグループ表示
    final products = category == 'EN'
        ? [
            ...widget.state.catalog
                .byCategory('EN')
                .where((p) => widget.state.isAdopted(p.id)),
            ...widget.state.catalog
                .byCategory('EN_AUX')
                .where((p) => widget.state.isAdopted(p.id)),
          ]
        : category == '食事'
            ? widget.state.catalog.products
                .where((p) => p.isFood && widget.state.isAdopted(p.id))
                .toList()
            : widget.state.catalog
                .byCategory(category)
                .where((p) => widget.state.isAdopted(p.id))
                .toList();
    // 朝 > 昼 > 夕 > ★ > 未選択
    products.sort((a, b) {
      int groupOf(Product p) {
        final item = current.regimenItems
            .where((e) => e.productId == p.id)
            .firstOrNull;
        if (item != null && item.hasMealTiming) {
          if (item.morning > 0) return 0;
          if (item.noon > 0) return 1;
          if (item.evening > 0) return 2;
        }
        if ((productUnits[p.id] ?? 0) >= 1) return 3;
        if (widget.state.isEffectiveFavorite(p.id)) return 4;
        return 5;
      }
      return groupOf(a).compareTo(groupOf(b));
    });

    // メイン製剤 = EN_AUX以外（ENタブならEN本体のみ）
    final mainProducts = products.where((p) => p.category != 'EN_AUX').toList();
    // EN補助製剤はENタブのときだけ表示
    final helperProducts = category == 'EN'
        ? products.where((p) => p.category == 'EN_AUX').toList()
        : <Product>[];

    final isScratchMode = _builderTabIndex == 1;
    final aggregate = isScratchMode ? scratchAggregate : actualAggregate;
    final aminoProduct = widget.state.adoptedAminoForZero();
    final glucoseProduct = widget.state.adoptedByBase(glucoseSource);
    final lipidProduct = widget.state.adoptedLipidForZero();
    final scratchTotalVolumeMl = scratchAggregate.totalVolumeMl;
    final scratchInfusionRateMlPerHour = scratchTotalVolumeMl / 24;
    String formatRequiredUnits(Product? product, double requiredMl) {
      if (product == null ||
          product.volumeMl == null ||
          product.volumeMl! <= 0) {
        return '未設定';
      }
      return '${(requiredMl / product.volumeMl!).ceil()} 本';
    }

    // 製剤構成と一致(10ml丸め)
    final scratchAminoUnits =
        formatRequiredUnits(aminoProduct, _round10(zeroMenu.aminoVolumeMl));
    final scratchGlucoseUnits =
        formatRequiredUnits(glucoseProduct, _round10(zeroMenu.glucoseVolumeMl));
    final scratchLipidUnits =
        formatRequiredUnits(lipidProduct, _round10(zeroMenu.lipidVolumeMl));
    // 加注製剤の処方表示 (名称 + 合計量, 同一製剤は×本数で集約)
    final scratchAdditiveLines = (() {
      final m = <String, int>{};
      for (final n in (isScratchMode ? _zeroAdditives : _selectAdditives)) {
        m[n] = (m[n] ?? 0) + 1;
      }
      return m.entries.map((e) {
        final vol = widget.state.catalog.byName(e.key)?.volumeMl;
        final amt = vol != null ? '${(vol * e.value).round()} ml' : '${e.value}管';
        final nm = e.value > 1 ? '${e.key} ×${e.value}' : e.key;
        return '$nm  $amt';
      }).toList();
    })();


    final screenH = MediaQuery.of(context).size.height;
    final _mqPad = MediaQuery.of(context).padding;
    // パネルの最大高さ = 画面高さ - ステータスバー - AppBar - ホームインジケータ - パディング16
    final maxSummaryH = (screenH - _mqPad.top - kToolbarHeight - _mqPad.bottom - 16.0)
        .clamp(200.0, screenH);

    // 入室日・栄養開始日 (ヘッダー表示用)
    String _mmdd(DateTime? d) => d == null ? '—' : '${d.month}/${d.day}';
    final _admissionDate = (() {
      final e =
          current.bedHistory.where((b) => b.fromBed == null).firstOrNull;
      return e != null ? DateTime.tryParse(e.changedAt) : null;
    })();
    final _nutritionStart = (() {
      final s = current.autoDesignConfig?['startDate'] as String?;
      return (s != null ? DateTime.tryParse(s) : null) ?? _admissionDate;
    })();
    final _fastingDate = current.fastingDate != null
        ? DateTime.tryParse(current.fastingDate!)
        : null;

    return Scaffold(
          appBar: AppBar(
            leading: const BackButton(),
            title: const Text('処方ビルダー'),
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  controller: _listScroll,
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _builderCardCollapsed
                            ? null
                            : () => _editPatientParams(context, current),
                        child: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: _builderCardCollapsed ? 2 : 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (!_builderCardCollapsed) ...[
                                  const Icon(Icons.person, size: 18),
                                  const SizedBox(width: 2),
                                  Text(current.caseCode,
                                      style:
                                          Theme.of(context).textTheme.titleLarge),
                                  const SizedBox(width: 12),
                                  const Icon(Icons.bed, size: 18),
                                  const SizedBox(width: 2),
                                  Text(current.currentBed,
                                      style:
                                          Theme.of(context).textTheme.titleLarge),
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 20),
                                    tooltip: '患者情報を編集',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        _editPatientParams(context, current),
                                  ),
                                ] else
                                  const Spacer(),
                                if (current.conditionTags.isNotEmpty)
                                  IconButton(
                                    icon: Icon(Icons.lightbulb,
                                        size: 20, color: Colors.amber.shade700),
                                    tooltip: '病態サジェスト',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => showDialog(
                                      context: context,
                                      builder: (_) => Dialog(
                                        backgroundColor: Colors.transparent,
                                        elevation: 0,
                                        insetPadding: const EdgeInsets.symmetric(
                                            horizontal: 24, vertical: 80),
                                        child: GestureDetector(
                                          onTap: () => Navigator.pop(context),
                                          child: SingleChildScrollView(
                                            child: _conditionSuggestionBanner(
                                                current, aggregate),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                IconButton(
                                  icon: Icon(
                                      _builderCardCollapsed
                                          ? Icons.expand_more
                                          : Icons.expand_less,
                                      size: 22),
                                  tooltip: _builderCardCollapsed
                                      ? '患者情報を展開'
                                      : '折りたたむ',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => setState(() =>
                                      _builderCardCollapsed =
                                          !_builderCardCollapsed),
                                ),
                              ],
                            ),
                            if (!_builderCardCollapsed) ...[
                            const SizedBox(height: 4),
                            // 入室日 / 絶食開始日 / 栄養開始日
                            Text(
                              '入室日 ${_mmdd(_admissionDate)}, '
                              '絶食開始日 ${_mmdd(_fastingDate)}, '
                              '栄養開始日 ${_mmdd(_nutritionStart)}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              current.patientInfoLine,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              current.energyModel == 'kcalPerKg'
                                  ? '${(current.kcalPerKgValue ?? 25).toStringAsFixed(0)} kcal/kg, '
                                      'タンパク目標 ${current.proteinGoalPerKg.toStringAsFixed(1)}g/kg'
                                  : '活動係数 ${current.activityFactor.toStringAsFixed(1)}, '
                                      '侵害係数 ${current.stressFactor.toStringAsFixed(1)}, '
                                      'タンパク目標 ${current.proteinGoalPerKg.toStringAsFixed(1)}g/kg',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            Text(
                              'カロリー ${targetKcal.round()} kcal, '
                              'タンパク ${targetProtein.round()} g/day',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            Builder(builder: (_) {
                              final er = NutritionCalculator
                                  .targetEnergyResult(current);
                              final showW = (er.feedingWeightKg -
                                          er.actualWeightKg)
                                      .abs() >=
                                  0.1;
                              final bmi = cbw.bmiOf(
                                  current.weightKg, current.heightCm);
                              return Text(
                                '式 ${ce.energyModelFromId(current.energyModel).label}'
                                ' / BMI ${bmi.toStringAsFixed(1)} ${cbw.obesityClass(bmi)}'
                                '${showW ? ' / 栄養計算体重 ${er.feedingWeightKg.toStringAsFixed(1)}kg（実${er.actualWeightKg.toStringAsFixed(0)}/理想${er.idealWeightKg.toStringAsFixed(0)}/補正適用）' : ''}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: Colors.blueGrey),
                              );
                            }),
                            // 過剰栄養アラート (H-B×係数 + 高SF + >30kcal/kg)
                            Builder(
                                builder: (_) =>
                                    _energyOverfeedAlert(current) ??
                                    const SizedBox.shrink()),
                            if (current.memo.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(current.memo,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.grey)),
                            ],
                            if (current.conditionTags.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 4,
                                runSpacing: 2,
                                children: [
                                  for (final id in current.conditionTags)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.teal.shade50,
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        border: Border.all(
                                            color: Colors.teal.shade200),
                                      ),
                                      child: Text(
                                        ConditionCatalog.labelOf(id),
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.teal.shade800),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            ],
                          ],
                        ),
                      ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 3タブ切替 (個別選択 / ゼロmenu / 自動計算)
                    Center(
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment<int>(
                            value: 0,
                            label: Text('個別選択'),
                            icon: Icon(Icons.list_alt),
                          ),
                          ButtonSegment<int>(
                            value: 1,
                            label: Text('ゼロmenu'),
                            icon: Icon(Icons.science),
                          ),
                          ButtonSegment<int>(
                            value: 2,
                            label: Text('自動計算'),
                            icon: Icon(Icons.auto_awesome),
                          ),
                        ],
                        selected: {_builderTabIndex},
                        onSelectionChanged: (Set<int> newSelection) {
                          setState(() => _builderTabIndex = newSelection.first);
                          // 自動計算タブ初回表示時: AutoDesignInline のinitState完了後に
                          // もう一度 setState してグラフパネルを描画する
                          if (newSelection.first == 2) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) setState(() {});
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 6),
                    // タブごとの説明書き
                    Text(
                      _builderTabIndex == 0
                          ? '製剤併用を集計し, 処方・カルテ記載に向けてサマライズします.'
                          : _builderTabIndex == 1
                              ? '静脈栄養のみで最小のINにする際の逆引き計算を行います.'
                              : 'フェーズに応じた処方プリセットを提案し, トレンドを可視化します',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 12),
                    // ゼロmenu タブ
                    Visibility(
                      visible: _builderTabIndex == 1,
                      maintainState: true,
                      child: Builder(builder: (context) {
                        Product? prod(String? n) =>
                            n == null ? null : widget.state.catalog.byName(n);
                        double round10(double v) => (v / 10).round() * 10.0;

                        // 本体(ベース)の使用量を10ml単位に丸め (IN/kcal/PFCはサマリーカードで集計)
                        final aminoMl = round10(zeroMenu.aminoVolumeMl);
                        final gluMl = round10(zeroMenu.glucoseVolumeMl);
                        final lipMl = round10(zeroMenu.lipidVolumeMl);

                        const rowH = 32.0;
                        Widget dataRow(String label, String val,
                                {bool bold = false, Color? color}) =>
                            SizedBox(
                              height: rowH,
                              child: Row(children: [
                                // 長い加注製剤名は折り返さず、末尾を省略(…)して容量の手前で切る
                                Expanded(
                                    child: Text(label,
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: color,
                                            fontWeight: bold
                                                ? FontWeight.bold
                                                : FontWeight.normal))),
                                const SizedBox(width: 6),
                                Text(val,
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: color,
                                        fontWeight: bold
                                            ? FontWeight.bold
                                            : FontWeight.normal)),
                              ]),
                            );

                        // ── 本体タブ: 投与目標設定 ──
                        final bodyCard = Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(
                                    child: Text('投与目標設定',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall),
                                  ),
                                  if (current.conditionTags.isNotEmpty)
                                    TextButton.icon(
                                      onPressed: () {
                                        _applyZeroMenuConditionDefaults(current);
                                        setState(() {});
                                      },
                                      icon: Icon(Icons.auto_fix_high,
                                          size: 15,
                                          color: Colors.teal.shade700),
                                      label: Text('病態の推奨を反映',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.teal.shade700)),
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6),
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                ]),
                                const Divider(),
                                TextField(
                                  controller: targetKcalController,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    labelText: '投与カロリー',
                                    suffixText: targetKcalController.text.isNotEmpty
                                        ? 'kcal'
                                        : null,
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                        vertical: 6, horizontal: 4),
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: npcnController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'タンパク投与量 (NPC/N)',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        vertical: 6, horizontal: 4),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                DropdownButtonFormField<double>(
                                  value: _lipidGPerKg,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '脂質量',
                                    suffixText: 'g/kg/day',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        vertical: 6, horizontal: 4),
                                  ),
                                  items: [
                                    for (int i = 0; i <= 10; i++)
                                      DropdownMenuItem(
                                        value: i / 10.0,
                                        child: Text((i / 10.0).toStringAsFixed(1)),
                                      ),
                                  ],
                                  onChanged: (v) => setState(
                                      () => _lipidGPerKg = v ?? _lipidGPerKg),
                                ),
                                const SizedBox(height: 8),
                                DropdownButtonFormField<String>(
                                  isExpanded: true,
                                  value: glucoseSource,
                                  decoration: const InputDecoration(
                                      labelText: '糖質', isDense: true),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'ハイカリックRF',
                                        child: Text('ハイカリックRF')),
                                    DropdownMenuItem(
                                        value: '70% グルコース',
                                        child: Text('70% グルコース')),
                                    DropdownMenuItem(
                                        value: '8%グルコース',
                                        child: Text('8%グルコース')),
                                  ],
                                  onChanged: (v) => setState(
                                      () => glucoseSource = v ?? glucoseSource),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: () {
                                      current.zeroMenuConfig = ZeroMenuConfig(
                                        targetKcal: double.tryParse(
                                                targetKcalController.text) ??
                                            targetKcal,
                                        npcNRatio: double.tryParse(
                                                npcnController.text) ??
                                            125,
                                        lipidGramPerKg: _lipidGPerKg,
                                        glucoseProductName: glucoseSource,
                                      );
                                      widget.state.persist();
                                      setState(() {});
                                    },
                                    child: const Text('保存'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );

                        // ── 加注タブ: 製剤を1リストから選んで追加 ──
                        final addCard = Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('加注製剤 (電解質・微量元素・ビタミン)',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                const Divider(),
                                _additivePicker(_zeroAdditives),
                              ],
                            ),
                          ),
                        );

                        // ── 製剤構成 (タンパク→脂肪→糖質の順) ──
                        final compCard = Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('製剤構成',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                const Divider(),
                                Text('本体',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600)),
                                dataRow(aminoProduct?.name ?? 'アミノ酸製剤',
                                    '${aminoMl.round()} ml'),
                                dataRow(lipidProduct?.name ?? '脂肪乳剤',
                                    '${lipMl.round()} ml'),
                                dataRow(glucoseSource, '${gluMl.round()} ml'),
                                if (_zeroAdditives.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text('加注',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade600)),
                                  ..._zeroAdditives.map((n) => dataRow(n,
                                      prod(n)?.volumeMl != null
                                          ? '${prod(n)!.volumeMl!.round()} ml'
                                          : '1管')),
                                ],
                                Builder(builder: (_) {
                                  final gluProd =
                                      widget.state.adoptedByBase(glucoseSource);
                                  final gluKcal = (gluProd != null &&
                                          (gluProd.volumeMl ?? 0) > 0)
                                      ? gluMl *
                                          (gluProd.kcal ?? 0) /
                                          gluProd.volumeMl!
                                      : 0.0;
                                  return _infusionAlerts(
                                    glucoseGramPerDay: gluKcal / 4,
                                    lipidGramPerDay: zeroMenu.lipidGram,
                                    weightKg: current.weightKg,
                                    glucoseRestrict: cc
                                            .resolveCoeff(current.conditionTags)
                                            ?.glucoseRestrict ??
                                        false,
                                  );
                                }),
                              ],
                            ),
                          ),
                        );

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // サブタブ: 本体 / 加注 (中央寄せ)
                            Center(
                              child: SegmentedButton<int>(
                                segments: const [
                                  ButtonSegment(value: 0, label: Text('本体')),
                                  ButtonSegment(value: 1, label: Text('加注')),
                                ],
                                selected: {_zeroSubTab},
                                showSelectedIcon: false,
                                onSelectionChanged: (s) =>
                                    setState(() => _zeroSubTab = s.first),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                    child: _zeroSubTab == 0 ? bodyCard : addCard),
                                const SizedBox(width: 8),
                                Expanded(child: compCard),
                              ],
                            ),
                          ],
                        );
                      }),
                    ),
                    // タブ内容: EN/TPN/PPN 選択 (インデックス 0)
                    Visibility(
                      visible: _builderTabIndex == 0,
                      maintainState: true,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('処方ビルダー',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 8),
                              Builder(builder: (context) {
                                final activeCategories = ['EN', 'TPN', 'PPN']
                                    .where((cat) =>
                                        _selectedProductsForCategory(cat)
                                            .isNotEmpty)
                                    .toList();
                                if (activeCategories.isEmpty) {
                                  return const Text('採用製剤を製剤マスタで選択してください');
                                }
                                // 加注・食事タブは常時選択可。EN/TPN/PPNは採用製剤がある時のみ
                                final tabCats = [...activeCategories, '加注', '食事'];
                                final effectiveCategory =
                                    tabCats.contains(category)
                                        ? category
                                        : activeCategories.first;
                                if (effectiveCategory != category) {
                                  WidgetsBinding.instance.addPostFrameCallback(
                                      (_) => setState(
                                          () => category = effectiveCategory));
                                }
                                // EN/TPN/PPN タブ + ドロップダウン（選択中カテゴリに対応）
                                // TPN/PPN流量オプション: 24hかけて(0) + 5〜60ml/h(5刻み)
                                final pnRateOptions = <double>[0,
                                  ...List.generate(12, (i) => (i + 1) * 5.0)];
                                String pnRateLabel(double v) =>
                                    v <= 0 ? '24hかけて' : '${v.toInt()}ml/h';
                                final curPnRate = effectiveCategory == 'TPN'
                                    ? _tpnRateMlPerHour
                                    : _ppnRateMlPerHour;
                                // スイッチを画面中央、DDをスイッチ右端〜右壁の中間に配置
                                return Row(
                                  children: [
                                    const Expanded(child: SizedBox()), // 左スペーサー
                                    SizedBox(
                                      width: 60.0 * tabCats.length,
                                      child: SegmentedButton<String>(
                                        showSelectedIcon: false,
                                        style: ButtonStyle(
                                          visualDensity: VisualDensity.compact,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        segments: tabCats
                                            .map((cat) => ButtonSegment(
                                                value: cat, label: Text(cat)))
                                            .toList(),
                                        selected: {effectiveCategory},
                                        onSelectionChanged: (newSel) =>
                                            setState(() => category = newSel.first),
                                      ),
                                    ),
                                    // 右半分: DDをスイッチ右端〜右壁の中間に配置
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Padding(
                                          padding: const EdgeInsets.only(left: 12),
                                          child: (effectiveCategory == '加注' ||
                                                  effectiveCategory == '食事')
                                            ? const SizedBox.shrink()
                                            : effectiveCategory == 'EN'
                                            ? DropdownButton<double>(
                                              value: _enRateMlPerHour,
                                              isDense: true,
                                              items: _infusionRateOptions
                                                  .map((v) => DropdownMenuItem(
                                                      value: v,
                                                      child: Text(_rateLabel(v),
                                                          style: const TextStyle(fontSize: 13))))
                                                  .toList(),
                                              onChanged: (v) async {
                                                setState(() => _enRateMlPerHour = v ?? 0);
                                                if ((v ?? 0) > 0) {
                                                  await _adjustEnUnitsForRate(current);
                                                  if (mounted) setState(() {});
                                                }
                                              },
                                            )
                                            : DropdownButton<double>(
                                              value: curPnRate,
                                              isDense: true,
                                              items: pnRateOptions
                                                  .map((v) => DropdownMenuItem(
                                                      value: v,
                                                      child: Text(pnRateLabel(v),
                                                          style: const TextStyle(fontSize: 13))))
                                                  .toList(),
                                              onChanged: (v) {
                                                final rate = v ?? 0;
                                                setState(() {
                                                  if (effectiveCategory == 'TPN') {
                                                    _tpnRateMlPerHour = rate;
                                                  } else {
                                                    _ppnRateMlPerHour = rate;
                                                  }
                                                });
                                              },
                                            ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              }),
                              if (category == '加注') ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: OutlinedButton.icon(
                                    onPressed: () => setState(() {
                                      _selectAdditives
                                        ..clear()
                                        ..addAll(
                                            _recommendedSelectAdditives(current));
                                    }),
                                    icon: Icon(Icons.auto_fix_high,
                                        size: 16, color: Colors.indigo.shade600),
                                    label: const Text('推奨加注を自動セット（重複回避）',
                                        style: TextStyle(fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                        visualDensity: VisualDensity.compact),
                                  ),
                                ),
                                Text(
                                    'ベースに微量元素/ビタミンが内蔵なら加注せず、胆汁うっ滞/肝障害ではMn-freeを選択。',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        color: Colors.grey.shade600)),
                                const SizedBox(height: 6),
                                _additivePicker(_selectAdditives),
                              ],
                              if (category == '食事') ...[
                                const SizedBox(height: 4),
                                Text('経口/経腸の食事製剤（濃厚流動食・栄養サポート食品）。朝昼夕の食数(各0〜3pac)を指定',
                                    style: Theme.of(context).textTheme.bodySmall),
                                if (mainProducts.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                        '採用された食事製剤がありません（製剤マスタの「食事」タブで採用してください）',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: Colors.grey)),
                                  ),
                              ],
                              if (category != '加注' && category != '食事') ...[
                                const SizedBox(height: 4),
                                Text('ENは8h毎, TPN/PPNは24h毎に交換',
                                    style: Theme.of(context).textTheme.bodySmall),
                              ],
                              const SizedBox(height: 8),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 380),
                                transitionBuilder: (child, anim) {
                                  final slide = Tween(
                                    begin: const Offset(0, -0.12),
                                    end: Offset.zero,
                                  ).animate(CurvedAnimation(parent: anim, curve: Curves.easeInOutSine));
                                  return SlideTransition(
                                    position: slide,
                                    child: FadeTransition(opacity: anim, child: child),
                                  );
                                },
                                child: Column(
                                  key: ValueKey(products.map((p) => p.id).join(',')),
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                              ...mainProducts.map((product) {
                                final existing = current.regimenItems
                                    .where((e) => e.productId == product.id)
                                    .firstOrNull;
                                final units = existing?.units ?? 0;
                                final partialMl = existing?.partialMl ?? 0;
                                final isFavorite =
                                    widget.state.isFavorite(product.id);
                                final isAutoFav = widget.state
                                    .isAutoFavorite(product.id, current);
                                final classification = product.productType;
                                final attributes =
                                    product.content.trim().isNotEmpty
                                        ? product.content
                                        : '性状不明';
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ListTile(
                                      isThreeLine: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: IconButton(
                                        tooltip: isAutoFav
                                            ? '病態タグにより自動 (タップで固定)'
                                            : null,
                                        onPressed: () async {
                                          await widget.state
                                              .toggleFavorite(product.id);
                                          setState(() {});
                                        },
                                        icon: Icon(
                                            (isFavorite || isAutoFav)
                                                ? Icons.star
                                                : Icons.star_border,
                                            color: isFavorite
                                                ? Colors.orange
                                                : isAutoFav
                                                    ? Colors.teal
                                                    : null),
                                      ),
                                      title: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(product.name),
                                          const SizedBox(height: 2),
                                          Text(
                                            '$classification / $attributes',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ],
                                      ),
                                      subtitle: Text(
                                          '${product.volumeMlString} / ${product.kcalString} / ${product.aminoString}'),
                                      tileColor: (units >= 1 || partialMl > 0)
                                          ? Colors.blue.shade100
                                          : null,
                                      trailing: (product.category == 'EN' || product.category == 'EN_AUX' || product.isFood)
                                          ? _MealPicker(
                                              morning: existing?.morning ?? 0,
                                              noon: existing?.noon ?? 0,
                                              evening: existing?.evening ?? 0,
                                              onChanged: (m, n, e) async {
                                                await widget.state.setMealUnits(current.id, product, m, n, e);
                                                setState(() {});
                                              },
                                            )
                                          : SizedBox(
                                              // 全非EN行で固定幅。部分量スロット(固定80)+本数ステッパー(固定)を
                                              // 同じ並びで配置し、行ごとの横位置のガタつきを構造的に無くす。
                                              width: 176,
                                              child: Row(
                                                mainAxisAlignment: MainAxisAlignment.end,
                                                children: [
                                                  // 部分量スロット(固定幅80): 該当しない行は空でも幅を確保して位置を保持
                                                  SizedBox(
                                                    width: 80,
                                                    child: ((product.category == 'TPN' ||
                                                                product.category == 'PPN') &&
                                                            (product.volumeMl ?? 0) > 50)
                                                        ? Builder(builder: (_) {
                                                            final bagVol =
                                                                (product.volumeMl ?? 0).round();
                                                            final maxPartial =
                                                                ((bagVol - 1) ~/ 50) * 50;
                                                            final opts = <int>[
                                                              0,
                                                              for (int v = 50; v <= maxPartial; v += 50) v
                                                            ];
                                                            final cur =
                                                                partialMl.clamp(0, maxPartial);
                                                            return DropdownButton<int>(
                                                              value: cur,
                                                              isDense: true,
                                                              isExpanded: true, // スロット幅いっぱい=内容で幅が変わらない
                                                              underline:
                                                                  const SizedBox.shrink(),
                                                              items: opts
                                                                  .map((v) => DropdownMenuItem(
                                                                      value: v,
                                                                      child: Text(
                                                                          v == 0 ? '+0' : '+${v}ml',
                                                                          style: const TextStyle(
                                                                              fontSize: 13))))
                                                                  .toList(),
                                                              onChanged: (v) async {
                                                                await widget.state.setPartialMl(
                                                                    current.id, product, v ?? 0);
                                                                setState(() {});
                                                              },
                                                            );
                                                          })
                                                        : null,
                                                  ),
                                                  IconButton(
                                                    visualDensity: VisualDensity.compact,
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(
                                                        minWidth: 28, minHeight: 32),
                                                    onPressed: () async {
                                                      await widget.state.setUnits(current.id, product, (units - 1).clamp(0, 99));
                                                      setState(() {});
                                                    },
                                                    icon: const Icon(Icons.remove_circle_outline),
                                                  ),
                                                  SizedBox(
                                                    width: 24,
                                                    child: Text('$units',
                                                        textAlign: TextAlign.center,
                                                        style: const TextStyle(
                                                            fontSize: 16,
                                                            fontWeight: FontWeight.bold)),
                                                  ),
                                                  IconButton(
                                                    visualDensity: VisualDensity.compact,
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(
                                                        minWidth: 28, minHeight: 32),
                                                    onPressed: () async {
                                                      await widget.state.setUnits(current.id, product, units + 1);
                                                      setState(() {});
                                                    },
                                                    icon: const Icon(Icons.add_circle_outline),
                                                  ),
                                                ],
                                              ),
                                            ),
                                      onTap: () => setState(() {
                                        if (expandedProducts.contains(product.id))
                                          expandedProducts.remove(product.id);
                                        else
                                          expandedProducts.add(product.id);
                                      }),
                                    ),
                                    if (expandedProducts.contains(product.id) &&
                                        product.notes?.trim().isNotEmpty ==
                                            true)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            left: 56.0,
                                            right: 8.0,
                                            bottom: 8.0),
                                        child: Text(product.notes!),
                                      ),
                                  ],
                                );
                              }),
                              if (helperProducts.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Text('EN補助製剤',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 8),
                                ...helperProducts.map((product) {
                                  final existing = current.regimenItems
                                      .where((e) => e.productId == product.id)
                                      .firstOrNull;
                                  final units = existing?.units ?? 0;
                                  final isFavorite =
                                      widget.state.isFavorite(product.id);
                                  final isAutoFav = widget.state
                                      .isAutoFavorite(product.id, current);
                                  final classification = product.productType;
                                  final attributes =
                                      product.content.trim().isNotEmpty
                                          ? product.content
                                          : '性状不明';
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ListTile(
                                        isThreeLine: true,
                                        contentPadding: EdgeInsets.zero,
                                        leading: IconButton(
                                          tooltip: isAutoFav
                                              ? '病態タグにより自動 (タップで固定)'
                                              : null,
                                          onPressed: () async {
                                            await widget.state
                                                .toggleFavorite(product.id);
                                            setState(() {});
                                          },
                                          icon: Icon(
                                              (isFavorite || isAutoFav)
                                                  ? Icons.star
                                                  : Icons.star_border,
                                              color: isFavorite
                                                  ? Colors.orange
                                                  : isAutoFav
                                                      ? Colors.teal
                                                      : null),
                                        ),
                                        title: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(product.name),
                                            const SizedBox(height: 2),
                                            Text(
                                              '$classification / $attributes',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                          ],
                                        ),
                                        subtitle: Text(
                                            '${product.volumeMlString} / ${product.kcalString} / ${product.aminoString}'),
                                        tileColor: units >= 1
                                            ? Colors.blue.shade100
                                            : null,
                                        trailing: _MealPicker(
                                          morning: existing?.morning ?? 0,
                                          noon: existing?.noon ?? 0,
                                          evening: existing?.evening ?? 0,
                                          onChanged: (m, n, e) async {
                                            await widget.state.setMealUnits(current.id, product, m, n, e);
                                            setState(() {});
                                          },
                                        ),
                                        onTap: () => setState(() {
                                          if (expandedProducts.contains(product.id))
                                            expandedProducts.remove(product.id);
                                          else
                                            expandedProducts.add(product.id);
                                        }),
                                      ),
                                      if (expandedProducts
                                              .contains(product.id) &&
                                          product.notes?.trim().isNotEmpty ==
                                              true)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                              left: 56.0,
                                              right: 8.0,
                                              bottom: 8.0),
                                          child: Text(product.notes!),
                                        ),
                                    ],
                                  );
                                }),
                              ],
                            ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // タブ内容: 自動計算 (インデックス 2)
                    Visibility(
                      visible: _builderTabIndex == 2,
                      maintainState: true,
                      child: AutoDesignInline(
                          key: _autoDesignKey,
                          state: widget.state,
                          current: current,
                          onSettingsChanged: () { if (mounted) setState(() {}); }),
                    ),
                  ],
                ),
              ),
        // サマリーパネル（個別選択/ゼロmenuのみ。自動計算タブでは非表示）
        if (_builderTabIndex != 2) SafeArea(
            top: false,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxSummaryH),
                child: Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.4),
                        width: 0.8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    Flexible(
                      fit: FlexFit.loose,
                      child: ClipRect(
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Text('サマリー',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const Spacer(),
                                  IconButton(
                                    icon: Icon(
                                        _summaryCollapsed
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                        size: 22),
                                    tooltip:
                                        _summaryCollapsed ? '展開' : '折りたたむ',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => setState(() =>
                                        _summaryCollapsed = !_summaryCollapsed),
                                  ),
                                ]),
                                if (!_summaryCollapsed) const SizedBox(height: 8),
                                // ── 2カード: 処方+サマリー | 円グラフ（画面幅に応じてレスポンシブ）──
                                if (!_summaryCollapsed)
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                  final availW = constraints.maxWidth;
                                  final scale = (availW / 380).clamp(0.72, 1.0);
                                  final chartSize = (150 * scale).roundToDouble();
                                  final labelFs = (12.5 * scale).clamp(10.0, 12.5);
                                  return ConstrainedBox(
                                  constraints: const BoxConstraints(minHeight: 200),
                                  child: IntrinsicHeight(
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      // 処方カード
                                      Expanded(
                                        flex: 3,
                                        child: Card(
                                          margin: const EdgeInsets.all(0),
                                          color: Colors.pink.shade50,
                                          child: Padding(
                                            padding: const EdgeInsets.all(10),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisAlignment: MainAxisAlignment.start,
                                              children: [
                                                // ── サマリー数値 ──
                                                Builder(builder: (context) {
                                                  final w = current.weightKg;
                                                  final protPerKg = w > 0 ? aggregate.totalProteinG / w : 0.0;
                                                  final fatPerKg = w > 0 ? aggregate.totalFatG / w : 0.0;
                                                    final ss = TextStyle(fontSize: labelFs);
                                                  return Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text('合計', style: TextStyle(fontSize: labelFs, fontWeight: FontWeight.bold)),
                                                      const SizedBox(height: 2),
                                                      Text('IN ${aggregate.totalVolumeMl.round()}ml, 総カロリー ${aggregate.totalKcal.round()}kcal', style: ss),
                                                      Text('タンパク ${aggregate.totalProteinG.toStringAsFixed(1)}g/day (${protPerKg.toStringAsFixed(1)}g/kg)', style: ss),
                                                      Text('NPC/N比 ${aggregate.npcNText}', style: ss),
                                                      Text('脂質 ${fatPerKg.toStringAsFixed(1)}g/kg/day', style: ss),
                                                    ],
                                                  );
                                                }),
                                                const Divider(height: 14),
                                                Text('処方', style: TextStyle(fontSize: labelFs, fontWeight: FontWeight.bold)),
                                                const SizedBox(height: 6),
                                                if (isScratchMode) ...[
                                                  Text('${scratchInfusionRateMlPerHour.round()} ml/h', style: const TextStyle(fontSize: 12.5)),
                                                  const SizedBox(height: 4),
                                                  if (zeroMenu.aminoVolumeMl > 0 && aminoProduct != null)
                                                    Text('${aminoProduct.name}  $scratchAminoUnits', style: const TextStyle(fontSize: 12.5)),
                                                  if (zeroMenu.lipidVolumeMl > 0 && lipidProduct != null)
                                                    Text('${lipidProduct.name}  $scratchLipidUnits', style: const TextStyle(fontSize: 12.5)),
                                                  if (zeroMenu.glucoseVolumeMl > 0 && glucoseProduct != null)
                                                    Text('${glucoseProduct.name}  $scratchGlucoseUnits', style: const TextStyle(fontSize: 12.5)),
                                                  // 加注製剤
                                                  for (final l in scratchAdditiveLines)
                                                    Text(l, style: const TextStyle(fontSize: 12.5)),
                                                ] else ...[
                                                  Builder(builder: (c) {
                                                    final ts = TextStyle(fontSize: labelFs);
                                                    final tpnItems = current.regimenItems.where((i) {
                                                      final p = widget.state.catalog.byId(i.productId);
                                                      return p != null && p.category == 'TPN' && (i.units > 0 || i.partialMl > 0);
                                                    }).toList();
                                                    final ppnItems = current.regimenItems.where((i) {
                                                      final p = widget.state.catalog.byId(i.productId);
                                                      return p != null && p.category == 'PPN' && (i.units > 0 || i.partialMl > 0);
                                                    }).toList();
                                                    String pnAmt(RegimenItem i) {
                                                      if (i.units > 0 && i.partialMl > 0) return '${i.units}本+${i.partialMl}ml';
                                                      if (i.units > 0) return '${i.units}本';
                                                      return '${i.partialMl}ml';
                                                    }
                                                    // EN朝昼夕 (meal timingが設定されているもののみ)
                                                    final enItems = current.regimenItems.where((item) {
                                                      final p = widget.state.catalog.byId(item.productId);
                                                      return p != null && (p.category == 'EN' || p.category == 'EN_AUX') && item.hasMealTiming;
                                                    }).toList();
                                                    // 食事(濃厚流動食・栄養サポート食品): 本数指定のもの
                                                    final foodItems = current.regimenItems.where((item) {
                                                      final p = widget.state.catalog.byId(item.productId);
                                                      return p != null && p.isFood && item.units > 0;
                                                    }).toList();
                                                    Widget mealRow(String label, int Function(RegimenItem) getter) {
                                                      final items = enItems.where((i) => getter(i) > 0).toList();
                                                      if (items.isEmpty) return const SizedBox.shrink();
                                                      final desc = items.map((i) {
                                                        final p = widget.state.catalog.byId(i.productId)!;
                                                        return '${p.name} ${getter(i)}pac';
                                                      }).join(' / ');
                                                      return Padding(
                                                        padding: const EdgeInsets.only(bottom: 2),
                                                        child: Text('$label  $desc', style: ts),
                                                      );
                                                    }
                                                    final hasAny = enItems.isNotEmpty || tpnItems.isNotEmpty || ppnItems.isNotEmpty || foodItems.isNotEmpty || (isScratchMode ? _zeroAdditives : _selectAdditives).isNotEmpty;
                                                    if (!hasAny) return const Text('(未選択)', style: TextStyle(fontSize: 12.5, color: Colors.grey));
                                                    return Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        if (enItems.isNotEmpty) ...[
                                                          mealRow('朝', (i) => i.morning),
                                                          mealRow('昼', (i) => i.noon),
                                                          mealRow('夕', (i) => i.evening),
                                                        ],
                                                        ...tpnItems.map((i) {
                                                          final p = widget.state.catalog.byId(i.productId)!;
                                                          final volMl = (p.volumeMl ?? 0) * i.units + i.partialMl;
                                                          final rateMlH = (_tpnRateMlPerHour > 0 ? _tpnRateMlPerHour : volMl / 24).round();
                                                          return Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('TPN  ${p.name} ${pnAmt(i)}  ${rateMlH}ml/h', style: ts));
                                                        }),
                                                        ...ppnItems.map((i) {
                                                          final p = widget.state.catalog.byId(i.productId)!;
                                                          final volMl = (p.volumeMl ?? 0) * i.units + i.partialMl;
                                                          final rateMlH = (_ppnRateMlPerHour > 0 ? _ppnRateMlPerHour : volMl / 24).round();
                                                          return Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('PPN  ${p.name} ${pnAmt(i)}  ${rateMlH}ml/h', style: ts));
                                                        }),
                                                        ...foodItems.map((i) {
                                                          final p = widget.state.catalog.byId(i.productId)!;
                                                          return Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('食事  ${p.name} ${i.units}本', style: ts));
                                                        }),
                                                        ...scratchAdditiveLines.map((l) => Padding(
                                                            padding: const EdgeInsets.only(bottom: 2),
                                                            child: Text('加注  $l', style: ts))),
                                                      ],
                                                    );
                                                  }),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      // 円グラフ + 凡例 + 縦棒%nut カード
                                      Expanded(
                                        flex: 2,
                                        child: Card(
                                          margin: const EdgeInsets.all(0),
                                          color: Colors.blue.shade50,
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                                            child: Column(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                // ドーナツグラフ: カードの縦中央に配置するため Expanded で空間を埋める
                                                Expanded(
                                                  child: Center(
                                                  child: SizedBox(
                                                  width: chartSize,
                                                  height: chartSize,
                                                  child: Stack(
                                                    alignment: Alignment.center,
                                                    children: [
                                                      PieChart(
                                                        PieChartData(
                                                          startDegreeOffset: 270,
                                                          sectionsSpace: 2,
                                                          centerSpaceRadius: (28 * scale).clamp(18, 28),
                                                          sections: [
                                                            PieChartSectionData(
                                                              value: aggregate.proteinPercent <= 0 ? 0 : aggregate.proteinKcal,
                                                              color: Colors.blue,
                                                              title: aggregate.proteinPercent < 5 ? '' : '${aggregate.proteinPercent.toStringAsFixed(0)}%',
                                                              titleStyle: TextStyle(fontSize: (12 * scale).clamp(9.0, 12.0), color: Colors.black, fontWeight: FontWeight.bold),
                                                              titlePositionPercentageOffset: 0.47,
                                                              radius: (52 * scale).clamp(34, 52),
                                                            ),
                                                            PieChartSectionData(
                                                              value: aggregate.fatPercent <= 0 ? 0 : aggregate.fatKcal,
                                                              color: Colors.orange,
                                                              title: aggregate.fatPercent < 5 ? '' : '${aggregate.fatPercent.toStringAsFixed(0)}%',
                                                              titleStyle: TextStyle(fontSize: (12 * scale).clamp(9.0, 12.0), color: Colors.black, fontWeight: FontWeight.bold),
                                                              titlePositionPercentageOffset: 0.47,
                                                              radius: (52 * scale).clamp(34, 52),
                                                            ),
                                                            PieChartSectionData(
                                                              value: aggregate.carbPercent <= 0 ? 0 : aggregate.carbKcal,
                                                              color: Colors.yellow.shade700,
                                                              title: aggregate.carbPercent < 5 ? '' : '${aggregate.carbPercent.toStringAsFixed(0)}%',
                                                              titleStyle: TextStyle(fontSize: (12 * scale).clamp(9.0, 12.0), color: Colors.black, fontWeight: FontWeight.bold),
                                                              titlePositionPercentageOffset: 0.47,
                                                              radius: (52 * scale).clamp(34, 52),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      // 中央: 目標達成率
                                                      Center(
                                                        child: Text(
                                                          '${aggregate.targetPercent(targetKcal).toStringAsFixed(0)}%',
                                                          style: TextStyle(
                                                              fontSize: (16 * scale).clamp(12.0, 16.0),
                                                              fontWeight: FontWeight.bold),
                                                        ),
                                                      ),
                                                    ],
                                                  ),   // Stack
                                                  ),   // SizedBox
                                                  ),   // Center
                                                ),     // Expanded
                                                // PFC凡例（ドーナツ下端から10px）
                                                const SizedBox(height: 10),
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    _PfcLegendItem(color: Colors.blue, label: 'P'),
                                                    const SizedBox(width: 12),
                                                    _PfcLegendItem(color: Colors.orange, label: 'F'),
                                                    const SizedBox(width: 12),
                                                    _PfcLegendItem(color: Colors.yellow.shade700, label: 'C'),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),   // Row
                                  ),   // IntrinsicHeight
                                  );   // ConstrainedBox (return)
                                  }), // LayoutBuilder
                                // ── アラート（サマリー下部・個別/ゼロ共通）──
                                if (!_summaryCollapsed)
                                Builder(builder: (_) {
                                  double gluG;
                                  double lipidG;
                                  cm.MicroTotals micro;
                                  if (isScratchMode) {
                                    final gluProd =
                                        widget.state.adoptedByBase(glucoseSource);
                                    final gluKcal = (gluProd != null &&
                                            (gluProd.volumeMl ?? 0) > 0)
                                        ? zeroMenu.glucoseVolumeMl *
                                            (gluProd.kcal ?? 0) /
                                            gluProd.volumeMl!
                                        : 0.0;
                                    gluG = gluKcal / 4;
                                    lipidG = zeroMenu.lipidGram;
                                    micro = cm.aggregateMicro([
                                      for (final n in _zeroAdditives)
                                        cm.MicroContribution(
                                            widget.state.catalog.byName(n)?.micro,
                                            1),
                                    ]);
                                  } else {
                                    final pm = _parenteralMacros(current);
                                    gluG = pm.glucoseG;
                                    lipidG = pm.lipidG;
                                    micro = _microWithRates(current);
                                  }
                                  final rows = _summaryAlertWidgets(
                                    current: current,
                                    glucoseGramPerDay: gluG,
                                    lipidGramPerDay: lipidG,
                                    micro: micro,
                                  );
                                  final alerts =
                                      _nutritionAlerts(current, aggregate);
                                  if (rows.isEmpty && alerts.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  final errN = alerts
                                      .where((a) =>
                                          a.severity == ae.AlertSeverity.error)
                                      .length;
                                  final warnN = alerts
                                      .where((a) =>
                                          a.severity == ae.AlertSeverity.warning)
                                      .length;
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        InkWell(
                                          onTap: () => setState(() =>
                                              _riskCollapsed = !_riskCollapsed),
                                          child: Row(children: [
                                            const Icon(
                                                Icons
                                                    .notifications_active_outlined,
                                                size: 16,
                                                color: Colors.deepOrange),
                                            const SizedBox(width: 4),
                                            const Text('リスク・補充サジェスト',
                                                style: TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 13,
                                                    color: Colors.black54)),
                                            const SizedBox(width: 6),
                                            if (errN > 0)
                                              _riskBadge('禁忌$errN',
                                                  Colors.red.shade600),
                                            if (warnN > 0)
                                              _riskBadge('警告$warnN',
                                                  Colors.orange.shade700),
                                            const Spacer(),
                                            Icon(
                                                _riskCollapsed
                                                    ? Icons.expand_more
                                                    : Icons.expand_less,
                                                size: 18,
                                                color: Colors.black45),
                                          ]),
                                        ),
                                        if (!_riskCollapsed) ...[
                                          _nutritionAlertPanel(
                                              current, aggregate),
                                          const SizedBox(height: 4),
                                          ...rows,
                                        ],
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
            // 栄養の推移パネル（自動計算タブのみ。サマリーと同じドラッグ仕様）
            if (_builderTabIndex == 2)
              _buildAutoChartPanel(screenH),
          ],
        ),
    );
  }

  Widget _buildAutoChartPanel(double screenH) {
    final _cqPad = MediaQuery.of(context).padding;
    final maxPanel = (screenH - _cqPad.top - kToolbarHeight - _cqPad.bottom - 16.0)
        .clamp(200.0, screenH);
    if (_chartPanelHeight > maxPanel) _chartPanelHeight = maxPanel;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxPanel),
          child: Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withOpacity(0.4),
                  width: 0.8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ClipRect(
                    child: SingleChildScrollView(
                      controller: _chartScroll,
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Builder(builder: (ctx) {
                        final chart = _autoDesignKey.currentState
                            ?._buildBarChartsForBuilder();
                        if (chart == null) {
                          // 初回フレームで state が未初期化の場合、次フレームで再描画
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) setState(() {});
                          });
                          return const SizedBox.shrink();
                        }
                        return chart;
                      }),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  final _autoDesignKey = GlobalKey<_AutoDesignPageState>();

  /// 患者パラメータをまとめて編集するダイアログ
  Future<void> _editPatientParams(
          BuildContext context, PatientCase current) =>
      showPatientEditDialog(context, widget.state, current, onSaved: () {
        if (mounted) setState(() {});
        widget.refresh();
      });

  /// Phase 4-①: 個別パラメータの編集ヘルパー群
  Future<void> _editIntField(
      BuildContext context,
      PatientCase current,
      String label,
      int initial,
      int min,
      int max,
      void Function(int) setter) async {
    final controller = TextEditingController(text: initial.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: label,
            hintText: '$min 〜 $max',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () {
                final v = int.tryParse(controller.text);
                if (v == null) {
                  Navigator.pop(context);
                  return;
                }
                Navigator.pop(context, v.clamp(min, max));
              },
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    setter(result);
    await widget.state.persist();
    setState(() {});
    widget.refresh();
  }

  Future<void> _editDoubleField(
      BuildContext context,
      PatientCase current,
      String label,
      double initial,
      double min,
      double max,
      double step,
      void Function(double) setter) async {
    final controller = TextEditingController(text: initial.toString());
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: label,
            hintText: '$min 〜 $max',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () {
                final v = double.tryParse(controller.text);
                if (v == null) {
                  Navigator.pop(context);
                  return;
                }
                Navigator.pop(context, v.clamp(min, max));
              },
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    setter(result);
    await widget.state.persist();
    setState(() {});
    widget.refresh();
  }

  Future<void> _editDoubleDropdown(
      BuildContext context,
      PatientCase current,
      String label,
      double initial,
      List<double> options,
      void Function(double) setter) async {
    final result = await showDialog<double>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(label),
        children: [
          for (final v in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, v),
              child: Row(
                children: [
                  Icon((v - initial).abs() < 0.001
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off),
                  const SizedBox(width: 8),
                  Text(v.toStringAsFixed(1)),
                ],
              ),
            ),
        ],
      ),
    );
    if (result == null) return;
    setter(double.parse(result.toStringAsFixed(2)));
    await widget.state.persist();
    setState(() {});
    widget.refresh();
  }

  Future<void> _editSex(BuildContext context, PatientCase current) async {
    final result = await showDialog<Sex>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('性別'),
        children: [
          for (final s in Sex.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, s),
              child: Row(
                children: [
                  Icon(current.sex == s
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off),
                  const SizedBox(width: 8),
                  Text(s == Sex.male ? '男性 (M)' : '女性 (F)'),
                ],
              ),
            ),
        ],
      ),
    );
    if (result == null) return;
    current.sex = result;
    await widget.state.persist();
    setState(() {});
    widget.refresh();
  }
}
