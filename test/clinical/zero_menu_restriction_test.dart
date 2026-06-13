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

  DesignPlan run(
          {required bool allow,
          required String mode,
          List<String> conditionTags = const []}) =>
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
        conditionTags: conditionTags,
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

  group('ゼロmenu 病態連動(NPC/N)', () {
    double aminoVolumeOf(DesignPlan plan) => plan.items
        .where((it) => it.name == amino.name)
        .fold(0.0, (s, it) => s + it.volumeMl);

    test('renal(NPC/N 350)はデフォルト(125)よりAA(アミノ酸)が少ない', () {
      final def = run(allow: true, mode: 'TPN'); // 病態なし=NPC/N 125
      final renal = run(allow: true, mode: 'TPN', conditionTags: ['renal']);
      expect(def.label, 'ZERO');
      expect(renal.label, 'ZERO');
      final defAmino = aminoVolumeOf(def);
      final renalAmino = aminoVolumeOf(renal);
      expect(defAmino > 0, isTrue);
      // NPC/Nが高い(タンパク節約)ほどアミノ酸量は少なくなる
      expect(renalAmino < defAmino, isTrue);
    });
  });
}
