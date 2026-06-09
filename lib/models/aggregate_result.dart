/// 複数製剤の合計（IN・kcal・タンパク・PFC・対目標比）。
class AggregateResult {
  const AggregateResult({
    required this.totalVolumeMl,
    required this.totalKcal,
    required this.totalProteinG,
    required this.totalFatG,
    required this.fatKcal,
    required this.carbKcal,
    required this.proteinKcal,
  });

  final double totalVolumeMl;
  final double totalKcal;
  final double totalProteinG;
  final double totalFatG;
  final double fatKcal;
  final double carbKcal;
  final double proteinKcal;

  double targetPercent(double targetKcal) =>
      targetKcal == 0 ? 0 : (totalKcal / targetKcal) * 100;
  double get totalMacroKcal => fatKcal + carbKcal + proteinKcal;
  double get fatPercent =>
      totalMacroKcal == 0 ? 0 : fatKcal / totalMacroKcal * 100;
  double get carbPercent =>
      totalMacroKcal == 0 ? 0 : carbKcal / totalMacroKcal * 100;
  double get proteinPercent =>
      totalMacroKcal == 0 ? 0 : proteinKcal / totalMacroKcal * 100;
  String get npcNText {
    if (totalProteinG <= 0) return '-';
    final n = totalProteinG / 6.25;
    if (n == 0) return '-';
    final value = (totalKcal - totalProteinG * 4) / n;
    if (value.isNaN || value.isInfinite) return '-';
    return value.round().toString();
  }
}
