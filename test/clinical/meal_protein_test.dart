import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/main.dart';

/// 経口リハ(食事フェーズ)でAA(タンパク)投与量が目標を満たすことを検証する。
/// 不具合: エルネオパ等のPN中止+食事(低タンパク)で経口リハ後にAAが激減していた。
void main() {
  final raw = File('assets/product_masters.json').readAsStringSync();
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final products = (decoded['products'] as List)
      .map((e) => Product.fromMap(Map<String, dynamic>.from(e)))
      .toList();

  Product byName(String n) => products.firstWhere((p) => p.name == n);
  final meals = products.where((p) => p.isFood).toList();
  final ppns = products.where((p) => p.category == 'PPN').toList();
  final amino = byName('アミパレン'); // 純高濃度AA(50g/500ml)

  const targetKcal = 1800.0;
  const targetProt = 90.0; // 1.2 g/kg × 75kg
  const weight = 75.0;

  group('経口リハ(食事)フェーズのタンパク補充', () {
    test('PPN採用あり: 食事フェーズで目標タンパクを満たす', () {
      final plan = NutritionCalculator.designDay(
        mode: '食事',
        dayTargetKcal: targetKcal,
        dayTargetProt: targetProt,
        weightKg: weight,
        enProducts: const [],
        tpnProducts: const [],
        ppnProducts: ppns,
        aminoProduct: amino,
        mealProducts: meals,
        mealPac: 3,
      );
      expect(plan.totalProteinG, greaterThanOrEqualTo(targetProt),
          reason: '食事フェーズのAAが目標未満: ${plan.totalProteinG}');
    });

    test('PPN未採用(エルネオパ中心施設)でも aminoProduct で目標を満たす', () {
      final plan = NutritionCalculator.designDay(
        mode: '食事',
        dayTargetKcal: targetKcal,
        dayTargetProt: targetProt,
        weightKg: weight,
        enProducts: const [],
        tpnProducts: const [],
        ppnProducts: const [], // PPN未採用
        aminoProduct: amino, // adoptedAminoForZero()はアミパレンにfallback
        mealProducts: meals,
        mealPac: 3,
      );
      expect(plan.totalProteinG, greaterThanOrEqualTo(targetProt),
          reason: 'PPN未採用時のAAが目標未満: ${plan.totalProteinG}');
    });

    test('自動計算ポリシー: アミパレン補充は合計500ml上限・不足は埋めきらない', () {
      final plan = NutritionCalculator.designDay(
        mode: '食事',
        dayTargetKcal: 1500,
        dayTargetProt: 120, // 高め=大きく不足させる
        weightKg: 60,
        enProducts: const [],
        tpnProducts: const [],
        ppnProducts: const [], // PPN無し→補充は aminoProduct のみ
        aminoProduct: amino,
        mealProducts: meals,
        mealPac: 3,
        aaSupplementBelowFrac: 0.90,
        aaSupplementMaxMl: 500,
      );
      final amiMl = plan.items
          .where((i) => i.name.contains('アミパレン'))
          .fold<double>(0, (s, i) => s + i.volumeMl);
      expect(amiMl, lessThanOrEqualTo(500.0 + 1e-6),
          reason: 'アミパレン補充が500ml超: $amiMl');
      // 500ml上限のため目標(120g)までは埋めない
      expect(plan.totalProteinG, lessThan(120));
    });

    test('自動計算ポリシー: 目標90%以上を満たすなら補充しない', () {
      final plan = NutritionCalculator.designDay(
        mode: '食事',
        dayTargetKcal: 1500,
        dayTargetProt: 5, // 低目標→食事だけで90%以上
        weightKg: 60,
        enProducts: const [],
        tpnProducts: const [],
        ppnProducts: const [],
        aminoProduct: amino,
        mealProducts: meals,
        mealPac: 3,
        aaSupplementBelowFrac: 0.90,
        aaSupplementMaxMl: 500,
      );
      expect(plan.items.any((i) => i.name.contains('アミパレン')), isFalse,
          reason: '目標を満たすのにアミパレンが補充された');
    });

    test('食事のみ(PPN/AAとも無し)では補充できない=回帰の対照', () {
      final plan = NutritionCalculator.designDay(
        mode: '食事',
        dayTargetKcal: targetKcal,
        dayTargetProt: targetProt,
        weightKg: weight,
        enProducts: const [],
        tpnProducts: const [],
        ppnProducts: const [],
        aminoProduct: null,
        mealProducts: meals,
        mealPac: 3,
      );
      // AA源が無いので目標未満になりうる(=この状況を作らないことが重要)。
      expect(plan.totalProteinG, isNotNull);
    });
  });

  group('EN-only(製剤選択): タンパクのへこみを高濃度AAで補う', () {
    test('EN-onlyで大きく不足→500ml上限に縛られず目標±15%下限(85%)を満たす', () {
      // 低AAのEN製剤(100ml=100kcal, AA 3.33g)を 1200ml/day 持続。
      //   EN由来 AA ≈ 40g(=高タンパク目標120gの33%)。500ml(=1本50g)上限では85%に届かない。
      final enLow = Product.fromMap({
        'id': 'en-low',
        'category': 'EN',
        'name': '低AA-EN',
        'content': '半消化態',
        'product_type': '食品',
        'volume_ml': 100,
        'kcal': 100,
        'amino_acid_g': 3.33,
        'nitrogen_g': 0.53,
        'npc_n_ratio': 180,
      });
      const tProt = 120.0; // 2.0 g/kg × 60kg(あえて高タンパク目標)
      final plan = NutritionCalculator.designDay(
        mode: 'EN',
        dayTargetKcal: 1200,
        dayTargetProt: tProt,
        weightKg: 60,
        enProducts: [enLow],
        enRateMlH: 50, // 1200ml/day
        tpnProducts: const [],
        ppnProducts: const [],
        aminoProduct: amino, // アミパレン 50g/500ml
        aaSupplementBelowFrac: 0.90,
        aaSupplementMaxMl: 500,
      );
      expect(plan.totalProteinG, greaterThanOrEqualTo(tProt * 0.85),
          reason: 'EN-onlyでタンパクが下限85%未満(=ヘコみ): ${plan.totalProteinG}');
      expect(plan.items.any((i) => i.name.contains('アミパレン')), isTrue,
          reason: '高濃度AAで補充されていない');
    });

    test('EN-onlyで目標90%以上なら補充しない', () {
      // EN由来 AA ≈ 84g(=目標90gの93%, ≥90%)。補充しない。
      final enMid = Product.fromMap({
        'id': 'en-mid',
        'category': 'EN',
        'name': '中AA-EN',
        'content': '半消化態',
        'product_type': '食品',
        'volume_ml': 100,
        'kcal': 100,
        'amino_acid_g': 7.0,
        'nitrogen_g': 1.12,
        'npc_n_ratio': 125,
      });
      final plan = NutritionCalculator.designDay(
        mode: 'EN',
        dayTargetKcal: 1200,
        dayTargetProt: 90, // 1.5 g/kg × 60kg
        weightKg: 60,
        enProducts: [enMid],
        enRateMlH: 50, // 1200ml/day → AA ≈ 84g(93%)
        tpnProducts: const [],
        ppnProducts: const [],
        aminoProduct: amino,
        aaSupplementBelowFrac: 0.90,
        aaSupplementMaxMl: 500,
      );
      expect(plan.items.any((i) => i.name.contains('アミパレン')), isFalse,
          reason: '許容内(≥85%)なのに補充された');
    });
  });
}
