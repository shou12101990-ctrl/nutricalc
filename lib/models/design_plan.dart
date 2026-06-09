/// 自動設計の1製剤分（本数 or 静注ml）。
class DesignItem {
  DesignItem({
    required this.name,
    this.units,
    required this.volumeMl,
    required this.kcal,
    required this.proteinG,
  });
  final String name;
  final int? units; // 本数(pac/本)。静注mlベースのときはnull
  final double volumeMl; // 1日総量ml
  final double kcal;
  final double proteinG;
  double get ratePerHour => volumeMl / 24; // 24h持続換算
}

/// 自動設計の1案（複数製剤の組み合わせ）。
class DesignPlan {
  DesignPlan({required this.label, required this.items, this.enKcal = 0});
  final String label; // 'EN案' / 'TPN案' / 'ゼロmenu案'
  final List<DesignItem> items;
  final double enKcal; // EN由来kcal（designDayが設定、単調増加管理用）
  double get totalKcal => items.fold(0.0, (s, i) => s + i.kcal);
  double get totalProteinG => items.fold(0.0, (s, i) => s + i.proteinG);
  double get totalVolumeMl => items.fold(0.0, (s, i) => s + i.volumeMl);
}
