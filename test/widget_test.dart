import 'package:flutter_test/flutter_test.dart';

import 'package:nutrition_flutter_app/main.dart';

void main() {
  group('栄養計算アプリの基本データ', () {
    test('EN補助製剤は EN補助 と表示される', () {
      final product = Product.fromMap({
        'id': 'aux-1',
        'category': 'EN_AUX',
        'name': '一挙千菜',
        'content': '液状',
        'product_type': '食品',
        'volume_ml': 125,
        'kcal': 80,
        'amino_acid_g': 0.5,
        'nitrogen_g': 0.1,
        'npc_n_ratio': 0,
      });

      expect(product.categoryLabel, 'EN補助');
      expect(product.productType, '食品');
      expect(product.volumeMlString, '125 ml');
      expect(product.kcalString, '80 kcal');
      expect(product.aminoString, 'AA 0.5 g');
    });

    test('旧プロトコルIDは新しい4段階IDへ移行される', () {
      final patient = PatientCase.fromMap({
        'id': 'case-1',
        'caseCode': 'CASE-001',
        'currentBed': '01',
        'age': 70,
        'heightCm': 165.0,
        'weightKg': 55.0,
        'sex': 'male',
        'activityFactor': 1.0,
        'stressFactor': 1.2,
        'proteinGoalPerKg': 1.2,
        'createdAt': '2026-05-30T00:00:00.000Z',
        'bedHistory': [],
        'regimenItems': [],
        'selectedProtocolId': 'standard_4day',
        'zeroMenuConfig': {
          'targetKcal': 1500,
          'npcNRatio': 125,
          'lipidGramPerKg': 0.4,
          'glucoseProductName': '70% グルコース',
        },
      });

      expect(patient.selectedProtocolId, 'four_day');
      expect(patient.displayLabel, 'CASE-001 / 01');
      expect(patient.sexLabel, 'M');
      // 後方互換: refeedingFlags 未保存の旧データは空リスト
      expect(patient.refeedingFlags, isEmpty);
    });

    test('refeedingFlags は toMap/fromMap で往復し後方互換を保つ', () {
      Map<String, dynamic> baseMap() => {
            'id': 'case-2',
            'caseCode': 'CASE-002',
            'currentBed': '02',
            'age': 60,
            'heightCm': 160.0,
            'weightKg': 40.0,
            'sex': 'female',
            'activityFactor': 1.0,
            'stressFactor': 1.0,
            'proteinGoalPerKg': 1.0,
            'createdAt': '2026-05-30T00:00:00.000Z',
            'bedHistory': [],
            'regimenItems': [],
            'selectedProtocolId': 'five_day',
            'zeroMenuConfig': {
              'targetKcal': 1200,
              'npcNRatio': 125,
              'lipidGramPerKg': 0.4,
              'glucoseProductName': '70% グルコース',
            },
          };
      // 手動フラグ付きで往復
      final withFlags = PatientCase.fromMap(
          {...baseMap(), 'refeedingFlags': ['low_electrolyte', 'wtloss_gt15']});
      expect(withFlags.refeedingFlags, ['low_electrolyte', 'wtloss_gt15']);
      final round = PatientCase.fromMap(withFlags.toMap());
      expect(round.refeedingFlags, ['low_electrolyte', 'wtloss_gt15']);
      // 既定は空リスト（refeedingFlags 未保存）
      final empty = PatientCase.fromMap(baseMap());
      expect(empty.refeedingFlags, isEmpty);
      // 再代入で更新できる（実コードは current.refeedingFlags = [...] で更新）
      empty.refeedingFlags = ['alcohol_or_drugs'];
      expect(PatientCase.fromMap(empty.toMap()).refeedingFlags,
          ['alcohol_or_drugs']);
    });
  });
}
