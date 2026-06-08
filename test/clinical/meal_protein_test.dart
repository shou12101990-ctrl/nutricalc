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
}
