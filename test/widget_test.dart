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
      expect(product.aminoString, '0.5 g AA');
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
    });
  });
}
