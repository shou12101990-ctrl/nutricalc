/// 栄養計算ロジック（処方合計・ゼロmenu逆算・自動設計 designDay 等）。
/// Flutter非依存・純粋関数。型は lib/models/、臨床式は energy/protein を参照。
library;

import '../models/models.dart';
import 'energy.dart' as ce;
import 'protein.dart' as cp;

class NutritionCalculator {
  static double bmi(PatientCase item) => item.bmi;

  /// 目標エネルギー（kcal/day）。選択モデル＋補正体重を内部適用（clinical/energy.dart に委譲）。
  static ce.EnergyResult targetEnergyResult(PatientCase item) => ce.targetEnergy(
        model: ce.energyModelFromId(item.energyModel),
        isMale: item.sex == Sex.male,
        weightKg: item.weightKg,
        heightCm: item.heightCm,
        age: item.age,
        activityFactor: item.activityFactor,
        stressFactor: item.stressFactor,
        kcalPerKgValue: item.kcalPerKgValue ?? 25,
        measuredREE: item.measuredREE,
      );

  static double targetEnergy(PatientCase item) =>
      targetEnergyResult(item).kcal;

  /// 目標タンパク（g/day）。肥満は理想体重基準（clinical/protein.dart に委譲）。
  static double targetProtein(PatientCase item) => cp.targetProtein(
        actualKg: item.weightKg,
        heightCm: item.heightCm,
        isMale: item.sex == Sex.male,
        gramPerKg: item.proteinGoalPerKg,
      );

  static AggregateResult aggregate(List<RegimenItem> items,
      Product? Function(String id) resolveProduct) {
    double totalVolumeMl = 0;
    double totalKcal = 0;
    double totalProteinG = 0;
    double totalFatG = 0;
    double fatKcal = 0;
    double carbKcal = 0;
    double proteinKcal = 0;
    for (final item in items) {
      final product = resolveProduct(item.productId);
      if (product == null || item.units <= 0) continue;
      totalVolumeMl += (product.volumeMl ?? 0) * item.units;
      totalKcal += (product.kcal ?? 0) * item.units;
      totalProteinG += (product.aminoAcidG ?? 0) * item.units;
      totalFatG += (product.fatBase ?? 0) * item.units;
      fatKcal += (product.fatBase ?? 0) * 9 * item.units;
      carbKcal += (product.carbBase ?? 0) * 4 * item.units;
      proteinKcal += (product.aminoAcidG ?? 0) * 4 * item.units;
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

  static ZeroMenuSuggestion zeroMenuSuggestion({
    required double targetKcal,
    required double npcNRatio,
    required double lipidGramPerKg,
    required double weightKg,
    required Product? glucoseProduct,
    required Product? aminoProduct,
    required Product? lipidProduct,
    double? girLimitMgKgMin, // 指定時: GIR上限でブドウ糖をcapし余剰kcalを脂質へ再配分(自動設計用)
    double? maxLipidGramPerKgDay, // 脂質再配分の上限(g/kg/day)
  }) {
    final aminoMlPerGram = (aminoProduct?.volumeMl ?? 500) /
        ((aminoProduct?.aminoAcidG ?? 50) == 0
            ? 50
            : (aminoProduct?.aminoAcidG ?? 50));
    final proteinGram = (6.25 * targetKcal) / (npcNRatio + 6.25 * 4);
    final aminoVolumeMl = proteinGram * aminoMlPerGram;
    double lipidGram = lipidGramPerKg * weightKg;
    double glucoseKcal = (targetKcal - proteinGram * 4 - lipidGram * 9)
        .clamp(0, double.infinity)
        .toDouble();
    // GIR上限でブドウ糖を制限し、余剰kcalを脂質へ再配分（自動設計でのみ有効）
    if (girLimitMgKgMin != null && weightKg > 0) {
      final maxGluGram = girLimitMgKgMin * weightKg * 1440 / 1000;
      double glucoseGram = glucoseKcal / 4;
      if (glucoseGram > maxGluGram) {
        final deficitKcal = (glucoseGram - maxGluGram) * 4;
        glucoseGram = maxGluGram;
        glucoseKcal = glucoseGram * 4;
        if (maxLipidGramPerKgDay != null) {
          final maxLipidGram = maxLipidGramPerKgDay * weightKg;
          final addable = maxLipidGram - lipidGram;
          if (addable > 0) {
            final extra = deficitKcal / 9;
            lipidGram += extra < addable ? extra : addable;
          }
        }
      }
    }
    final lipidVolumeMl = lipidProduct == null
        ? 0.0
        : lipidGram /
            ((lipidProduct.fatBase ?? 20) / (lipidProduct.volumeMl ?? 100));
    final glucoseDensity =
        glucoseProduct == null || (glucoseProduct.volumeMl ?? 0) == 0
            ? 1
            : (glucoseProduct.kcal ?? 0) / (glucoseProduct.volumeMl ?? 1);
    final glucoseVolumeMl =
        glucoseDensity == 0 ? 0.0 : glucoseKcal / glucoseDensity;
    return ZeroMenuSuggestion(
      aminoVolumeMl: aminoVolumeMl,
      glucoseVolumeMl: glucoseVolumeMl,
      lipidVolumeMl: lipidVolumeMl,
      proteinGram: proteinGram,
      lipidGram: lipidGram,
    );
  }

  /// 自動設計。
  /// ルール: カロリーは目標の90〜100%(オーバー不可)、タンパクは90〜100%(オーバー不可)。
  /// mode: 'EN'(EN最大2剤+PPN補正) / 'TPN'(TPN単剤+PPN補正) / 'BOTH'(両案) / 'ZERO'(静注ブレンド)
  static List<DesignPlan> autoDesign({
    required String mode,
    required double targetKcal,
    required double targetProtein,
    required double weightKg,
    required List<Product> enProducts,
    required List<Product> tpnProducts,
    required List<Product> ppnProducts,
    Product? glucoseProduct,
    Product? aminoProduct,
    Product? lipidProduct,
  }) {
    final plans = <DesignPlan>[];
    if (mode == 'EN' || mode == 'BOTH') {
      final p = _designWithBase(
          enProducts, ppnProducts, targetKcal, targetProtein, 'EN案',
          maxBase: 2);
      if (p != null) plans.add(p);
    }
    if (mode == 'TPN' || mode == 'BOTH') {
      final p = _designWithBase(
          tpnProducts, ppnProducts, targetKcal, targetProtein, 'TPN案',
          maxBase: 1);
      if (p != null) plans.add(p);
    }
    if (mode == 'ZERO') {
      final z = zeroMenuSuggestion(
        targetKcal: targetKcal,
        npcNRatio: 125,
        lipidGramPerKg: 0.4,
        weightKg: weightKg,
        glucoseProduct: glucoseProduct,
        aminoProduct: aminoProduct,
        lipidProduct: lipidProduct,
      );
      final items = <DesignItem>[];
      double densKcal(Product? p, double ml) =>
          p == null || (p.volumeMl ?? 0) == 0 ? 0 : (p.kcal ?? 0) * ml / p.volumeMl!;
      double densProt(Product? p, double ml) =>
          p == null || (p.volumeMl ?? 0) == 0 ? 0 : (p.aminoAcidG ?? 0) * ml / p.volumeMl!;
      if (aminoProduct != null && z.aminoVolumeMl > 0) {
        items.add(DesignItem(
            name: aminoProduct.name,
            volumeMl: z.aminoVolumeMl,
            kcal: densKcal(aminoProduct, z.aminoVolumeMl),
            proteinG: densProt(aminoProduct, z.aminoVolumeMl)));
      }
      if (glucoseProduct != null && z.glucoseVolumeMl > 0) {
        items.add(DesignItem(
            name: glucoseProduct.name,
            volumeMl: z.glucoseVolumeMl,
            kcal: densKcal(glucoseProduct, z.glucoseVolumeMl),
            proteinG: 0));
      }
      if (lipidProduct != null && z.lipidVolumeMl > 0) {
        items.add(DesignItem(
            name: lipidProduct.name,
            volumeMl: z.lipidVolumeMl,
            kcal: z.lipidGram * 9,
            proteinG: 0));
      }
      plans.add(DesignPlan(label: 'ゼロmenu案', items: items));
    }
    return plans;
  }

  /// 主軸製剤(base)を maxBase 剤まで使い、PPNでタンパク補正する設計を1案返す。
  static DesignPlan? _designWithBase(List<Product> bases, List<Product> ppns,
      double targetKcal, double targetProtein, String label,
      {required int maxBase}) {
    final minKcal = targetKcal * 0.9;
    List<MapEntry<Product, int>>? best;
    double bestIn = double.infinity;

    void consider(List<MapEntry<Product, int>> combo) {
      double kcal = 0, prot = 0, inMl = 0;
      for (final e in combo) {
        kcal += (e.key.kcal ?? 0) * e.value;
        prot += (e.key.aminoAcidG ?? 0) * e.value;
        inMl += (e.key.volumeMl ?? 0) * e.value;
      }
      if (kcal > targetKcal) return; // カロリーオーバー不可
      if (kcal < minKcal) return; // -10%未満は不採用
      if (prot > targetProtein) return; // タンパクオーバー不可
      // カロリー条件を満たす中で IN(投与量) 最小を採用
      if (inMl < bestIn) {
        bestIn = inMl;
        best = combo;
      }
    }

    final valid = bases.where((b) => (b.kcal ?? 0) > 0).toList();
    // 単剤
    for (final b in valid) {
      final k = b.kcal!;
      for (int n = 1; n * k <= targetKcal; n++) {
        consider([MapEntry(b, n)]);
      }
    }
    // 2剤
    if (maxBase >= 2) {
      for (int i = 0; i < valid.length; i++) {
        for (int j = i + 1; j < valid.length; j++) {
          final a = valid[i], c = valid[j];
          for (int n1 = 1; n1 * a.kcal! <= targetKcal; n1++) {
            for (int n2 = 1; n1 * a.kcal! + n2 * c.kcal! <= targetKcal; n2++) {
              consider([MapEntry(a, n1), MapEntry(c, n2)]);
            }
          }
        }
      }
    }

    if (best == null) return null;

    final items = best!
        .map((e) => DesignItem(
              name: e.key.name,
              units: e.value,
              volumeMl: (e.key.volumeMl ?? 0) * e.value,
              kcal: (e.key.kcal ?? 0) * e.value,
              proteinG: (e.key.aminoAcidG ?? 0) * e.value,
            ))
        .toList();

    // タンパク補正: 達成タンパクが目標の90%未満ならPPNアミノ酸を追加
    double curKcal = items.fold(0.0, (s, i) => s + i.kcal);
    double curProt = items.fold(0.0, (s, i) => s + i.proteinG);
    if (curProt < targetProtein * 0.9) {
      final aminos = ppns.where((p) => (p.aminoAcidG ?? 0) > 0).toList()
        ..sort((a, b) => ((b.aminoAcidG ?? 0) / (b.volumeMl ?? 1))
            .compareTo((a.aminoAcidG ?? 0) / (a.volumeMl ?? 1)));
      if (aminos.isNotEmpty) {
        final pp = aminos.first;
        int add = 0;
        while (curProt < targetProtein * 0.9 &&
            curProt + (pp.aminoAcidG ?? 0) <= targetProtein &&
            curKcal + (pp.kcal ?? 0) <= targetKcal) {
          curProt += pp.aminoAcidG ?? 0;
          curKcal += pp.kcal ?? 0;
          add++;
        }
        if (add > 0) {
          items.add(DesignItem(
              name: pp.name,
              units: add,
              volumeMl: (pp.volumeMl ?? 0) * add,
              kcal: (pp.kcal ?? 0) * add,
              proteinG: (pp.aminoAcidG ?? 0) * add));
        }
      }
    }

    return DesignPlan(label: label, items: items);
  }

  /// Refeeding/Wernicke予防の高用量チアミン(B1)自動加注の本数（純粋関数）。
  /// 条件: 絶食(不十分摂取)≥fastingThresholdDays(既定5) かつ 糖質投与あり かつ
  ///       栄養開始からの初期frontLoadDays(既定10日)以内 かつ B1合計<targetMg(既定200)。
  /// 満たすとき目標mgに到達する最小本数(1..10)を返す。非該当は0。
  /// 出典: NICE CG32(5日以上の不十分摂取=refeedingリスク) / JSPEN(チアミン200–300mg, 糖負荷前〜10日)。
  static int thiamineUnitsToAdd({
    required int fastingDays,
    required int feedingDay,
    required bool carbPresent,
    required double currentB1Mg,
    required double b1PerUnitMg,
    double targetMg = 200,
    int fastingThresholdDays = 5,
    int frontLoadDays = 10,
  }) {
    if (fastingDays < fastingThresholdDays) return 0;
    if (feedingDay < 1 || feedingDay > frontLoadDays) return 0;
    if (!carbPresent) return 0;
    if (b1PerUnitMg <= 0) return 0;
    if (currentB1Mg >= targetMg) return 0;
    return ((targetMg - currentB1Mg) / b1PerUnitMg).ceil().clamp(1, 10);
  }

  /// Day別設計: そのDayの目標(kcal/タンパク)を、選んだクラスとEN速度でサジェスト。
  /// mode: 'TPN' / 'TPN+EN' / 'EN' / 'ZERO'
  static DesignPlan designDay({
    required String mode,
    required double dayTargetKcal,
    required double dayTargetProt,
    required double weightKg,
    required List<Product> enProducts,
    double enRateMlH = 0,
    int enPac = 0,
    Product? pnProduct,
    double pnRateMlH = 0,
    required List<Product> tpnProducts,
    required List<Product> ppnProducts,
    Product? glucoseProduct,
    Product? aminoProduct,
    Product? lipidProduct,
    double minEnKcal = 0, // 単調増加制約: 前日のEN kcal以上を要求
    List<Product> mealProducts = const [], // 食事(濃厚流動食/栄養サポート)
    int mealPac = 0, // 食事 朝昼夕あたりpac数(1..3, 経口リハ期に使用)
    int mealSlots = 3, // 経口リハ移行: 経口にするスロット数(1..3)。残りはEN。既定3=全て経口
    double? girLimitMgKgMin, // 自動設計: GIR上限(糖質制限病態は4, 既定5)
    double? maxLipidGramPerKgDay, // 脂質再配分の上限
    bool allowZeroMenu = false, // ゼロmenu許可(PNのみ7日目以降・EN未開始時のみtrue)
    double? hardKcalCap, // 総kcalの絶対上限(refeeding時=その日のcap)。AA補充もこれを超えない。
    // タンパク補充ポリシー(自動計算): タンパクがこの割合未満の時だけAA補充(既定1.0=常に目標まで)。
    double aaSupplementBelowFrac = 1.0,
    double? aaSupplementMaxMl, // AA補充の合計ml上限(自動計算=500)。null=無制限。
  }) {
    // ゼロmenu(静注ブレンド)のitem群を構築
    List<DesignItem> buildZeroItems(double tKcal) {
      final items = <DesignItem>[];
      final z = zeroMenuSuggestion(
        targetKcal: tKcal,
        npcNRatio: 125,
        lipidGramPerKg: 0.4,
        weightKg: weightKg,
        glucoseProduct: glucoseProduct,
        aminoProduct: aminoProduct,
        lipidProduct: lipidProduct,
        girLimitMgKgMin: girLimitMgKgMin,
        maxLipidGramPerKgDay: maxLipidGramPerKgDay,
      );
      double dKcal(Product? p, double ml) =>
          p == null || (p.volumeMl ?? 0) == 0 ? 0 : (p.kcal ?? 0) * ml / p.volumeMl!;
      double dProt(Product? p, double ml) =>
          p == null || (p.volumeMl ?? 0) == 0 ? 0 : (p.aminoAcidG ?? 0) * ml / p.volumeMl!;
      if (aminoProduct != null && z.aminoVolumeMl > 0) {
        items.add(DesignItem(name: aminoProduct.name, volumeMl: z.aminoVolumeMl, kcal: dKcal(aminoProduct, z.aminoVolumeMl), proteinG: dProt(aminoProduct, z.aminoVolumeMl)));
      }
      if (glucoseProduct != null && z.glucoseVolumeMl > 0) {
        items.add(DesignItem(name: glucoseProduct.name, volumeMl: z.glucoseVolumeMl, kcal: dKcal(glucoseProduct, z.glucoseVolumeMl), proteinG: 0));
      }
      if (lipidProduct != null && z.lipidVolumeMl > 0) {
        items.add(DesignItem(name: lipidProduct.name, volumeMl: z.lipidVolumeMl, kcal: z.lipidGram * 9, proteinG: 0));
      }
      items.add(DesignItem(name: 'ビタミン製剤', volumeMl: 2, kcal: 0, proteinG: 0));
      items.add(DesignItem(name: '微量元素製剤', volumeMl: 2, kcal: 0, proteinG: 0));
      items.add(DesignItem(name: '電解質製剤', volumeMl: 2, kcal: 0, proteinG: 0));
      return items;
    }

    // ZERO: 静注ブレンド（EN不要）
    if (mode == 'ZERO') {
      return DesignPlan(label: 'Day', items: buildZeroItems(dayTargetKcal));
    }

    // タンパク不足を高濃度AA製剤で補正してitemsに追加するヘルパー。
    //   ベース製剤由来を優先し、タンパクが目標の aaSupplementBelowFrac 未満(自動計算=90%)の
    //   時だけ、高濃度AA(aminoProduct=純AA, アミパレンfallback)で補う。
    //   補充の合計mlは aaSupplementMaxMl(自動計算=500ml)を超えない(不足はそれ以上埋めない)。
    void addPpnProtein(List<DesignItem> items, double curKcal, double curProt,
        {bool fillToTolerance = false}) {
      if (curProt >= dayTargetProt * aaSupplementBelowFrac) return;
      // 高濃度AA製剤: 純AA(aminoProduct) > 採用PPNの最高AA密度。
      Product? aa = (aminoProduct != null && (aminoProduct.aminoAcidG ?? 0) > 0)
          ? aminoProduct
          : null;
      if (aa == null) {
        final aminos = ppnProducts.where((p) => (p.aminoAcidG ?? 0) > 0).toList()
          ..sort((a, b) => ((b.aminoAcidG ?? 0) / (b.volumeMl ?? 1))
              .compareTo((a.aminoAcidG ?? 0) / (a.volumeMl ?? 1)));
        aa = aminos.isNotEmpty ? aminos.first : null;
      }
      final aaG = aa?.aminoAcidG ?? 0;
      final aaVol = aa?.volumeMl ?? 0;
      if (aa == null || aaG <= 0) return;
      // 補充本数を決定。
      int add;
      if (fillToTolerance) {
        // EN-only: 高濃度AAで目標まで補う(合計mlソフト上限なし=へこませない)。
        //   refeeding cap(hardKcalCap)のみ安全上限として後段で適用。
        add = ((dayTargetProt - curProt) / aaG).ceil().clamp(1, 20);
      } else {
        // 早期/PN併用/食事: 控えめに(端数切上)＋合計mlソフト上限(自動=500)で頭打ち(埋めきらない)。
        add = ((dayTargetProt - curProt) / aaG).ceil().clamp(1, 20);
        if (aaSupplementMaxMl != null && aaVol > 0) {
          final maxBags = (aaSupplementMaxMl / aaVol).floor();
          if (maxBags < add) add = maxBags;
        }
      }
      // refeeding等で総kcal上限がある場合は、AA由来kcal込みで超えない本数に抑える(安全優先)。
      final aaKcal = aa.kcal ?? 0;
      if (hardKcalCap != null && aaKcal > 0) {
        final maxByKcal = ((hardKcalCap - curKcal) / aaKcal).floor();
        if (maxByKcal < add) add = maxByKcal;
      }
      if (add <= 0) return;
      items.add(DesignItem(
          name: aa.name,
          units: add,
          volumeMl: aaVol * add,
          kcal: aaKcal * add,
          proteinG: aaG * add));
    }

    // 食事(経口リハ): 経口スロット(mealSlots, 朝→昼→夕)に食事を mealPac本ずつ投与。
    //   移行期は残り(3-mealSlots)スロットをENで補い(1スロット2pac相当)、不足はPPN/PNで補う。
    //   kcalが当日目標を超えない範囲にcapする。
    if (mode == '食事') {
      final meals = mealProducts
          .where((p) => (p.kcal ?? 0) > 0 && (p.volumeMl ?? 0) > 0)
          .toList();
      final items = <DesignItem>[];
      final oralSlots = mealSlots.clamp(0, 3);
      double mealKcal = 0, mealProt = 0;
      if (meals.isNotEmpty && mealPac > 0 && oralSlots > 0) {
        // 主食 = kcal/pacが最大の食事製剤(高栄養の濃厚流動食)を一貫採用
        final sorted = [...meals]
          ..sort((a, b) => (b.kcal ?? 0).compareTo(a.kcal ?? 0));
        final p = sorted.first;
        final pk = (p.kcal ?? 0).toDouble();
        if (pk > 0) {
          final capPac = oralSlots * mealPac; // 経口スロット数 × pac数
          // kcalが当日目標を超えない範囲にcap
          final byKcal = (dayTargetKcal / pk).floor();
          final pac = (capPac < byKcal ? capPac : byKcal).clamp(0, capPac);
          if (pac > 0) {
            mealKcal = pk * pac;
            mealProt = (p.aminoAcidG ?? 0) * pac;
            items.add(DesignItem(
                name: p.name,
                units: pac,
                volumeMl: (p.volumeMl ?? 0) * pac,
                kcal: mealKcal,
                proteinG: mealProt));
          }
        }
      }
      // 経口リハ移行期: 非経口スロット(3-oralSlots)をENで埋める(1スロット2pac相当)。
      //   meal+EN が当日目標kcalを超えない範囲にcap。
      double enKcalAdded = 0, enProtAdded = 0;
      final enSlots = (3 - oralSlots).clamp(0, 3);
      final ens = enProducts
          .where((p) => (p.kcal ?? 0) > 0 && (p.volumeMl ?? 0) > 0)
          .toList();
      if (enSlots > 0 && ens.isNotEmpty) {
        final enP =
            ([...ens]..sort((a, b) => (b.kcal ?? 0).compareTo(a.kcal ?? 0)))
                .first;
        final epk = (enP.kcal ?? 0).toDouble();
        if (epk > 0) {
          final wantPac = enSlots * 2; // 1スロット2pac(確立したEN bolus相当)
          final remainKcal =
              (dayTargetKcal - mealKcal).clamp(0, double.infinity).toDouble();
          final byKcal = (remainKcal / epk).floor();
          final enPac = (wantPac < byKcal ? wantPac : byKcal).clamp(0, wantPac);
          if (enPac > 0) {
            enKcalAdded = epk * enPac;
            enProtAdded = (enP.aminoAcidG ?? 0) * enPac;
            items.add(DesignItem(
                name: enP.name,
                units: enPac,
                volumeMl: (enP.volumeMl ?? 0) * enPac,
                kcal: enKcalAdded,
                proteinG: enProtAdded));
          }
        }
      }
      // 不足分(kcal・タンパク)をPPN製剤で補う
      final restKcal = (dayTargetKcal - mealKcal - enKcalAdded)
          .clamp(0, double.infinity)
          .toDouble();
      final restProt = (dayTargetProt - mealProt - enProtAdded)
          .clamp(0, double.infinity)
          .toDouble();
      if (restKcal > 80 && ppnProducts.isNotEmpty) {
        final sub = _designWithBase(
            ppnProducts, ppnProducts, restKcal, restProt, 'PPN',
            maxBase: 2);
        if (sub != null) items.addAll(sub.items);
      }
      // 経口リハ期のタンパク低下を補充。ベース(食事/PPN)由来を優先し、目標の
      //   aaSupplementBelowFrac 未満(自動計算=90%)の時だけ、純AA(aminoProduct)で補う。
      //   補充の合計mlは aaSupplementMaxMl(自動計算=500ml)を超えない。
      {
        final curProt = items.fold(0.0, (s, it) => s + it.proteinG);
        // 高濃度AA製剤の選定: 純AA(aminoProduct) > 採用PPNの最高AA密度。
        Product? aa = (aminoProduct != null && (aminoProduct.aminoAcidG ?? 0) > 0)
            ? aminoProduct
            : null;
        if (aa == null) {
          final aminos =
              ppnProducts.where((p) => (p.aminoAcidG ?? 0) > 0).toList()
                ..sort((a, b) => ((b.aminoAcidG ?? 0) / (b.volumeMl ?? 1))
                    .compareTo((a.aminoAcidG ?? 0) / (a.volumeMl ?? 1)));
          aa = aminos.isNotEmpty ? aminos.first : null;
        }
        final aaG = aa?.aminoAcidG ?? 0;
        final aaVol = aa?.volumeMl ?? 0;
        if (aa != null &&
            aaG > 0 &&
            curProt < dayTargetProt * aaSupplementBelowFrac) {
          // 不足分を満たす最小本数(端数切り上げ)。安全上限20本。
          var add = ((dayTargetProt - curProt) / aaG).ceil().clamp(1, 20);
          // AA補充の合計ml上限(自動計算=500ml)。
          if (aaSupplementMaxMl != null && aaVol > 0) {
            final maxBags = (aaSupplementMaxMl / aaVol).floor();
            if (maxBags < add) add = maxBags;
          }
          // refeeding等の総kcal上限がある場合はAA由来kcal込みで超えない本数に抑える。
          final aaKcal = aa.kcal ?? 0;
          final curKcal = items.fold(0.0, (s, it) => s + it.kcal);
          if (hardKcalCap != null && aaKcal > 0) {
            final maxByKcal = ((hardKcalCap - curKcal) / aaKcal).floor();
            if (maxByKcal < add) add = maxByKcal;
          }
          if (add > 0) {
            items.add(DesignItem(
                name: aa.name,
                units: add,
                volumeMl: (aa.volumeMl ?? 0) * add,
                kcal: aaKcal * add,
                proteinG: aaG * add));
          }
        }
      }
      return DesignPlan(label: 'Day', items: items);
    }

    // EN baseのitem群＋PN主剤(pnBase)を渡して、PN自動減量＋PPN補正で1日プランを完成
    DesignPlan completePlan(List<DesignItem> enItems, Product? pnBase) {
      final items = <DesignItem>[...enItems];
      final enKcal = enItems.fold<double>(0, (s, it) => s + it.kcal);
      final enProt = enItems.fold<double>(0, (s, it) => s + it.proteinG);
      if (mode == 'EN') {
        addPpnProtein(items, enKcal, enProt, fillToTolerance: true);
        return DesignPlan(label: 'Day', items: items);
      }
      // PN自動減量: 残りkcalをPNで埋める(over回避)
      final restKcal =
          (dayTargetKcal - enKcal).clamp(0, double.infinity).toDouble();
      final restProt =
          (dayTargetProt - enProt).clamp(0, double.infinity).toDouble();
      if (pnBase != null && (pnBase.volumeMl ?? 0) > 0 && restKcal > 0) {
        final bagVol = pnBase.volumeMl!; // 1袋の容量ml
        final bagKcal = pnBase.kcal ?? 0; // 1袋のkcal
        final pnDensity = bagVol > 0 ? bagKcal / bagVol : 0.0; // kcal/ml
        // 袋数調整: under feeding許容 + INの段差を緩和するため、端数が≥50%なら開封OK
        //   ≤1袋分 → 速度調整で部分使用(目標ちょうど)
        //   >1袋分 → 整数袋 + 端数が袋容量の50%以上なら+1袋(部分使用)、未満は切り捨て
        const fracThreshold = 0.50; // 端数50%以上なら開封
        double pnMl = 0;
        int? pnUnits;
        if (pnDensity > 0) {
          if (restKcal <= bagKcal) {
            pnMl = restKcal / pnDensity;
            if ((bagVol - pnMl).abs() < 1.0) {
              pnMl = bagVol;
              pnUnits = 1;
            }
          } else {
            final wholeBags = (restKcal / bagKcal).floor();
            final fracKcal = restKcal - wholeBags * bagKcal;
            if (fracKcal / bagKcal >= fracThreshold) {
              // 端数袋を開封(部分使用)
              pnMl = wholeBags * bagVol + fracKcal / pnDensity;
              pnUnits = wholeBags + 1;
            } else {
              // 端数は切り捨て
              pnMl = wholeBags * bagVol;
              pnUnits = wholeBags;
            }
          }
        }
        // TPN(PN主剤)の使用量を100ml単位に丸める。
        // 過剰栄養は禁忌のため、丸めで残りkcalを超える場合は100ml切り下げる。
        if (pnMl > 0 && pnDensity > 0) {
          double rounded = (pnMl / 100).round() * 100.0;
          while (rounded > 0 && pnDensity * rounded > restKcal + 1e-6) {
            rounded -= 100;
          }
          pnMl = rounded;
          pnUnits = pnMl > 0 ? (pnMl / bagVol).ceil() : null;
        }
        final pnKcal = pnDensity * pnMl;
        final pnProt = (pnBase.aminoAcidG ?? 0) * pnMl / bagVol;
        if (pnMl > 0) {
          items.add(DesignItem(
              name: pnBase.name,
              units: pnUnits,
              volumeMl: pnMl,
              kcal: pnKcal,
              proteinG: pnProt));
        }
        addPpnProtein(items, enKcal + pnKcal, enProt + pnProt);
        return DesignPlan(label: 'Day', items: items);
      }
      // PN主剤なし: 残りをTPN単剤+PPNで本数最適
      if (restKcal > 0) {
        final sub = _designWithBase(
            tpnProducts, ppnProducts, restKcal, restProt, 'TPN', maxBase: 1);
        if (sub != null) items.addAll(sub.items);
      }
      return DesignPlan(label: 'Day', items: items);
    }

    // EN製剤を pac本 のitemに
    DesignItem enPacItem(Product p, int pac) {
      final double vol = pac * (p.volumeMl ?? 0.0);
      return DesignItem(
          name: p.name,
          units: pac,
          volumeMl: vol,
          kcal: (p.kcal ?? 0) * vol / (p.volumeMl ?? 1),
          proteinG: (p.aminoAcidG ?? 0) * vol / (p.volumeMl ?? 1));
    }

    // EN製剤名の集合(輸液=経静脈分の容量を切り分けるために使用)
    final enNameSet = enProducts.map((p) => p.name).toSet();
    // 評価(under feeding基準): kcalは当日目標の90-100%、タンパク90-100%、
    //   over nutritionは厳禁、INは~1000ml/dayを確保したい。スコア小が良。
    //   planEnKcal: ENアイテム由来kcal（候補ループ側で計算して渡す）
    double scoreOf(DesignPlan plan, double planEnKcal) {
      final tK = dayTargetKcal, tP = dayTargetProt;
      final k = plan.totalKcal, pr = plan.totalProteinG, vol = plan.totalVolumeMl;
      double s = 0;
      if (tK > 0) {
        final r = k / tK;
        if (r > 1.0) {
          s += (r - 1.0) * 100; // over厳禁
        } else if (r < 0.9) {
          s += (0.9 - r) * 50; // 90%未満の下振れ
        } else {
          s += (1.0 - r) * 5; // 90-100%窓内は目標寄りを微優先
        }
      }
      if (tP > 0) {
        final r = pr / tP;
        if (r > 1.0) {
          s += (r - 1.0) * 80;
        } else if (r < 0.9) {
          s += (0.9 - r) * 40;
        } else {
          s += (1.0 - r) * 4;
        }
      }
      // IN ~1000ml/day確保。絞りすぎ回避＆2500ml超は強くペナルティ(ゼロmenu等へ誘導)
      if (vol < 1000) {
        s += (1000 - vol) / 1000 * 10;
      } else if (vol <= 2500) {
        s += (vol - 1000) / 1000 * 1;
      } else {
        s += 1.5 + (vol - 2500) / 1000 * 50;
      }
      // 輸液(経静脈)上限: 3000ml/day を超えないようハードキャップ。
      //   EN(経腸)分は含めず、PN/PPN/IV分のみで判定する。
      double ivVol = 0;
      for (final it in plan.items) {
        if (!enNameSet.contains(it.name)) ivVol += it.volumeMl;
      }
      if (ivVol > 3000) {
        // 実質的に3000ml超を回避(代替が無い場合のみ許容＝段階的劣化)
        s += 1000 + (ivVol - 3000) * 2;
      }
      // 単調増加制約: ENカロリーが前日より少ない場合は重くペナルティ
      if (minEnKcal > 0 && planEnKcal < minEnKcal * 0.98) {
        s += (minEnKcal - planEnKcal) / (tK + 1) * 80;
      }
      return s;
    }

    final ens = enProducts
        .where((p) => (p.kcal ?? 0) > 0 && (p.volumeMl ?? 0) > 0)
        .toList();

    // EN候補(食単位で最大2製剤まで混合)を列挙。1食内は1製剤のみ。
    List<List<DesignItem>> enCandidates() {
      if (mode == 'TPN' || ens.isEmpty) return [<DesignItem>[]];
      if (enPac > 0) {
        // 朝昼夕の3食。食あたりpac数=mealPac。3食を最大2製剤に振り分け
        final mealPac = (enPac / 3).round().clamp(1, enPac);
        final out = <List<DesignItem>>[];
        for (var i = 0; i < ens.length; i++) {
          final prod = ens[i];
          final pacKcal = (prod.kcal ?? 0).toDouble();
          // 単調増加制約: minEnKcal を満たす最小pac数まで単剤候補を切り上げ
          // (連続投与→ボーラス切替時の凹みを防ぐ)
          int totalPacs = 3 * mealPac;
          if (minEnKcal > 0 && pacKcal > 0) {
            final needed = (minEnKcal / pacKcal).ceil();
            if (needed > totalPacs) {
              // 目標kcalを超えない範囲で増やす
              final hardMax = dayTargetKcal > 0
                  ? (dayTargetKcal / pacKcal).floor().clamp(totalPacs, 99)
                  : 99;
              totalPacs = needed.clamp(totalPacs, hardMax);
            }
          }
          out.add([enPacItem(prod, totalPacs)]); // 単剤(単調増加対応)
          for (var j = i + 1; j < ens.length; j++) {
            for (final a in const [1, 2]) {
              // a食をens[i]、(3-a)食をens[j] (食単位混合)
              out.add([
                enPacItem(ens[i], a * mealPac),
                enPacItem(ens[j], (3 - a) * mealPac),
              ]);
            }
          }
        }
        return out;
      }
      if (enRateMlH > 0) {
        // 速度(ml/h)は持続投与=単剤のみ
        final ml = enRateMlH * 24;
        return ens
            .map((p) => [
                  DesignItem(
                      name: p.name,
                      volumeMl: ml,
                      kcal: (p.kcal ?? 0) * ml / (p.volumeMl ?? 1),
                      proteinG: (p.aminoAcidG ?? 0) * ml / (p.volumeMl ?? 1)),
                ])
            .toList();
      }
      return [<DesignItem>[]];
    }

    // PN主剤候補: 導入プロトコルの 1号/2号(エルネオパ or ネオパレン)のみを使用。
    // どちらも未採用ならゼロmenuで構築する(他TPNは自動設計のPN主剤に使わない)。
    // マスタ名は末尾空白や容量サフィックス付きの場合があるため productBaseName で正規化して判定。
    bool isProtoBase(Product p) {
      final b = productBaseName(p.name);
      return b == 'エルネオパNF1号' ||
          b == 'エルネオパNF2号' ||
          b == 'ネオパレン1号' ||
          b == 'ネオパレン2号';
    }
    final pnBases = tpnProducts
        .where((p) =>
            isProtoBase(p) && (p.kcal ?? 0) > 0 && (p.volumeMl ?? 0) > 0)
        .toList();

    DesignPlan? best;
    double bestScore = double.infinity;
    double bestEnKcal = 0; // 勝者のEN由来kcal
    void consider(DesignPlan plan, double planEnKcal) {
      final sc = scoreOf(plan, planEnKcal);
      if (sc < bestScore) {
        bestScore = sc;
        best = plan;
        bestEnKcal = planEnKcal;
      }
    }

    for (final enItems in enCandidates()) {
      // EN由来kcalをitemから集計（単調増加スコアリング用）
      final enKcal =
          enItems.fold<double>(0, (s, it) => s + it.kcal);
      if (mode == 'EN') {
        consider(completePlan(enItems, null), enKcal);
      } else if (pnBases.isEmpty) {
        consider(completePlan(enItems, null), enKcal);
      } else {
        // PN主剤の選定: エルネオパ1号→2号 の導入プロトコルを優先する。
        //   初期導入は1号、必要量が過大(>2000ml相当)になれば2号へ切替。
        //   エルネオパ未採用時は従来どおり IN/kcal 最適で選ぶ。
        for (final pb in pnBases) {
          final plan = completePlan(enItems, pb);
          double planScore = scoreOf(plan, enKcal);
          final bagVol = pb.volumeMl ?? 1;
          double pnVol = 0;
          for (final it in plan.items) {
            if (it.units == null && it.name == pb.name) {
              pnVol = it.volumeMl;
              final usageRatio = it.volumeMl / bagVol;
              if (usageRatio < 0.5) {
                // 50%未満の端数使用 → 別製剤があれば乗り換えを促す
                planScore += (0.5 - usageRatio) * 20;
              }
            }
          }
          // 導入プロトコル: 1号を強く優先。1号で必要量が過大なら2号を次点優先。
          final pbBase = productBaseName(pb.name);
          final is1go =
              pbBase == 'エルネオパNF1号' || pbBase == 'ネオパレン1号';
          final is2go =
              pbBase == 'エルネオパNF2号' || pbBase == 'ネオパレン2号';
          if (is1go) {
            // 1号は希釈。約3000ml(輸液上限)までは1号を優先、超えれば2号へ
            if (pnVol <= 3000) planScore -= 1000.0;
          } else if (is2go) {
            planScore -= 500.0;
          }
          if (planScore < bestScore) {
            bestScore = planScore;
            best = plan;
            bestEnKcal = enKcal;
          }
        }
      }
    }
    // ゼロmenu(高濃度静注ブレンド)の使用制限:
    //  ・エルネオパ/ネオパレン 1号/2号 が未採用の施設のみ(採用施設は1号→2号を使用)。
    //  ・PNのみの栄養が6日続いた翌日(7日目)以降のPN専用日のみ(allowZeroMenu)。
    //  ・ENを開始していれば採用しない(mode=='TPN'のPN専用日に限る)。
    if (allowZeroMenu && pnBases.isEmpty && mode == 'TPN') {
      consider(DesignPlan(label: 'ZERO', items: buildZeroItems(dayTargetKcal)), 0);
    }
    // 勝者のEN kcalをDesignPlanに記録して返す（逐次生成時の単調増加追跡に使用）
    if (best == null) return DesignPlan(label: 'Day', items: const []);
    return DesignPlan(label: best!.label, items: best!.items, enKcal: bestEnKcal);
  }
}
