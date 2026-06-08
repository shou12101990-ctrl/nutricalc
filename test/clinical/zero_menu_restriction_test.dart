import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/main.dart';

/// ゼロmenu使用制限の検証。
/// 仕様: ゼロmenuは「PNのみの栄養が6日続いた翌日(=7日目, i>=6)以降のPN専用日(mode=='TPN')」
///       かつ エルネオパ/ネオパレン未採用 のときのみ許可(allowZeroMenu)。
///       ENを開始していれば(mode!='TPN')採用しない。
void main() {
  final raw = File('assets/product_masters.json').readAsStringSync();
  final products = (jsonDecode(raw)['products'] as List)
      .map((e) => Product.fromMap(Map<String, dynamic>.from(e)))
      .toList();
  Product byName(String n) => products.firstWhere((p) => p.name == n);

  final glucose = byName('70% グルコース');
  final amino = byName('アミパレン');
  final lipid = byName('イントラリポス20%');

  const targetKcal = 1500.0;
  const targetProt = 75.0;
  const weight = 70.0;

  DesignPlan run({required bool allow, required String mode}) =>
      NutritionCalculator.designDay(
        mode: mode,
        dayTargetKcal: targetKcal,
        dayTargetProt: targetProt,
        weightKg: weight,
        enProducts: const [],
        tpnProducts: const [], // エルネオパ/ネオパレン未採用(PN主剤なし)
        ppnProducts: const [],
        glucoseProduct: glucose,
        aminoProduct: amino,
        lipidProduct: lipid,
        allowZeroMenu: allow,
      );

  group('ゼロmenu使用制限', () {
    test('day7以降のPN専用日(allow=true, mode=TPN) → ゼロmenu採用可', () {
      final plan = run(allow: true, mode: 'TPN');
      expect(plan.label, 'ZERO');
    });

    test('day1-6のPN専用日(allow=false) → ゼロmenuは使わない', () {
      final plan = run(allow: false, mode: 'TPN');
      expect(plan.label, isNot('ZERO'));
    });

    test('EN開始済み(mode=TPN+EN)はallow=trueでもゼロmenuを使わない', () {
      final plan = run(allow: true, mode: 'TPN+EN');
      expect(plan.label, isNot('ZERO'));
    });
  });
}
