/// ゼロmenu(静脈栄養のみ逆算)の保存設定。
class ZeroMenuConfig {
  ZeroMenuConfig(
      {required this.targetKcal,
      required this.npcNRatio,
      required this.lipidGramPerKg,
      required this.glucoseProductName});
  final double targetKcal;
  final double npcNRatio;
  final double lipidGramPerKg;
  final String glucoseProductName;

  factory ZeroMenuConfig.defaultConfig() => ZeroMenuConfig(
      targetKcal: 1500,
      npcNRatio: 125,
      lipidGramPerKg: 0.4,
      glucoseProductName: '70% グルコース');

  Map<String, dynamic> toMap() => {
        'targetKcal': targetKcal,
        'npcNRatio': npcNRatio,
        'lipidGramPerKg': lipidGramPerKg,
        'glucoseProductName': glucoseProductName,
      };

  factory ZeroMenuConfig.fromMap(Map<String, dynamic> map) => ZeroMenuConfig(
        targetKcal: (map['targetKcal'] as num).toDouble(),
        npcNRatio: (map['npcNRatio'] as num).toDouble(),
        lipidGramPerKg: (map['lipidGramPerKg'] as num).toDouble(),
        glucoseProductName: map['glucoseProductName'] as String,
      );
}
