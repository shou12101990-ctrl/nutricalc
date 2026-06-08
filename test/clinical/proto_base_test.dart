import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/main.dart';

/// 不具合: マスタの製剤名に末尾空白('エルネオパNF1号 ')があり、isProtoBaseの完全一致が
/// 常にfalse → pnBases空 → 初期栄養がゼロmenuになっていた。
/// 修正: productBaseName(trim+容量サフィックス除去)で判定。
void main() {
  final raw = File('assets/product_masters.json').readAsStringSync();
  final products = (jsonDecode(raw)['products'] as List)
      .map((e) => Product.fromMap(Map<String, dynamic>.from(e)))
      .toList();
  Product byName(String n) => products.firstWhere((p) => p.name == n);

  // 採用される実データ(マスタはtrim済み)
  final erneopa1 = byName('エルネオパNF1号');
  final amino = byName('アミパレン');
  final glucose = byName('70% グルコース');
  final lipid = byName('イントラリポス20%');

  test('末尾空白のエルネオパNF1号がproto baseとして使われ、初期栄養がゼロmenuにならない', () {
    final plan = NutritionCalculator.designDay(
      mode: 'TPN',
      dayTargetKcal: 1200, // 初期(20kcal/kg相当)
      dayTargetProt: 60,
      weightKg: 60,
      enProducts: const [],
      tpnProducts: [erneopa1], // エルネオパNF1号(末尾空白)を採用
      ppnProducts: [amino],
      glucoseProduct: glucose,
      aminoProduct: amino,
      lipidProduct: lipid,
      allowZeroMenu: true, // 7日目以降相当でもエルネオパ採用ならゼロmenuにしない
    );
    expect(plan.label, isNot('ZERO'), reason: 'エルネオパ採用なのにゼロmenuが選ばれた');
    expect(plan.items.any((i) => i.name.contains('エルネオパNF1号')), isTrue,
        reason: 'エルネオパNF1号がプランに含まれない');
  });

  test('係数step up: 段階目標(20→25→30kcal/kg相当)がエルネオパで段階的に反映される', () {
    double planKcal(double targetKcal) => NutritionCalculator.designDay(
          mode: 'TPN',
          dayTargetKcal: targetKcal,
          dayTargetProt: targetKcal / 20, // 適当な比
          weightKg: 60,
          enProducts: const [],
          tpnProducts: [erneopa1],
          ppnProducts: [amino],
          glucoseProduct: glucose,
          aminoProduct: amino,
          lipidProduct: lipid,
          allowZeroMenu: false,
        ).totalKcal;
    final k20 = planKcal(1200); // 20kcal/kg×60
    final k25 = planKcal(1500); // 25kcal/kg×60
    final k30 = planKcal(1800); // 30kcal/kg×60
    // 各日の目標に追従して段階的に増えること(=step upがプランに反映される)
    expect(k20, lessThan(k25));
    expect(k25, lessThan(k30));
    // 各日とも目標±15%以内に収まる(整数本数で空プランにならない)
    expect(k20, closeTo(1200, 1200 * 0.15));
    expect(k25, closeTo(1500, 1500 * 0.15));
    expect(k30, closeTo(1800, 1800 * 0.15));
  });

  test('エルネオパ未採用ならゼロmenu(allow時)に流れる(対照)', () {
    final plan = NutritionCalculator.designDay(
      mode: 'TPN',
      dayTargetKcal: 1200,
      dayTargetProt: 60,
      weightKg: 60,
      enProducts: const [],
      tpnProducts: const [], // PN主剤なし
      ppnProducts: const [],
      glucoseProduct: glucose,
      aminoProduct: amino,
      lipidProduct: lipid,
      allowZeroMenu: true,
    );
    expect(plan.label, 'ZERO');
  });
}
