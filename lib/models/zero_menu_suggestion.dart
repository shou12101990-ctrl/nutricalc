/// ゼロmenu逆算の結果（各製剤の必要ml・タンパク/脂質g）。
class ZeroMenuSuggestion {
  const ZeroMenuSuggestion({
    required this.aminoVolumeMl,
    required this.glucoseVolumeMl,
    required this.lipidVolumeMl,
    required this.proteinGram,
    required this.lipidGram,
  });

  final double aminoVolumeMl;
  final double glucoseVolumeMl;
  final double lipidVolumeMl;
  final double proteinGram;
  final double lipidGram;
}
