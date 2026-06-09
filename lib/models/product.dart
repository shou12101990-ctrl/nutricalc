/// 栄養製剤（マスタ1件）。
class Product {
  Product({
    required this.id,
    required this.category,
    required this.name,
    required this.content,
    required this.productType,
    required this.volumeMl,
    required this.kcal,
    required this.aminoAcidG,
    required this.nitrogenG,
    required this.npcNRatio,
    required this.fatBase,
    required this.carbBase,
    required this.notes,
    this.micro,
    this.alsoEn = false,
    this.addType,
    this.conditionTags = const [],
  });

  final String id;
  String category; // EN / EN_AUX / TPN / PPN (mutable for master edit)
  String name; // mutable for future name editing
  String content; // 性状(成分/消化態/半消化態 など)
  String productType; // 食品 / 医薬品
  double? volumeMl;
  double? kcal;
  double? aminoAcidG;
  double? nitrogenG;
  double? npcNRatio;
  double? fatBase;
  double? carbBase;
  String? notes;
  // 微量栄養素(1袋あたり): {elec:{Na,K,Cl,Ca,Mg,P}, trace:{Zn,Fe,Mn,Cu,I,Se}, vit:{...}}
  // elec: Na/K/Cl/Ca/Mg=mEq, P=mmol / trace=μmol / vit=各単位
  Map<String, dynamic>? micro;
  // 両用フラグ: trueなら「食事」カテゴリの製剤をENマスタにも表示（同一製剤として採用共有）
  bool alsoEn;
  // 加注製剤の種別 (電解質:Na/K/Ca/Mg/P/HCO3, 微量元素:総合/Zn/Se, ビタミン:総合/B群/単独)
  String? addType;
  // 病態タグ (病態別製剤): ConditionCatalog の id 群 (renal/dialysis/liver/diabetes/respiratory/immune/heart)
  List<String> conditionTags;

  /// この製剤を「食事」タブに表示するか（濃厚流動食 or 栄養サポート食品）
  bool get isFood =>
      category == '濃厚流動食' || category == '栄養サポート食品';

  /// 「食事」タブ内のサブセクション名（濃厚流動食 / 栄養サポート食品）
  String? get foodClass => isFood ? category : null;

  /// ENマスタ（タブ）に表示するか（EN本体/補助 or 両用food）
  bool get inEnTab => category == 'EN' || category == 'EN_AUX' || alsoEn;

  // ── 組成判定（MVI/trace 自動付替え用。micro由来）──
  /// 複合微量元素（Zn+Cu を含む＝多元素）を内蔵するか
  bool get kitHasFullTrace {
    final tr = micro?['trace'];
    return tr is Map && tr.containsKey('Zn') && tr.containsKey('Cu');
  }

  /// 総合ビタミン（B1 or A を含む）を内蔵するか
  bool get kitHasVitamins {
    final v = micro?['vit'];
    return v is Map && (v.containsKey('B1') || v.containsKey('A'));
  }

  /// 含有Mn量（μmol）
  double get mnAmount {
    final tr = micro?['trace'];
    if (tr is! Map) return 0;
    final m = tr['Mn'];
    return m is num ? m.toDouble() : 0;
  }

  /// 複合微量元素製剤か（加注用）
  bool get isCombinedTrace => category == '微量元素' && kitHasFullTrace;

  /// Mn-free 複合微量元素製剤か
  bool get isMnFreeTrace => isCombinedTrace && mnAmount <= 0;

  /// 総合ビタミン製剤か（加注用）
  bool get isFullMvi => category == 'ビタミン' && kitHasVitamins;

  /// カテゴリ表示名（EN_AUXは「EN補助」と表示）
  String get categoryLabel {
    switch (category) {
      case 'EN_AUX':
        return 'EN補助';
      default:
        return category;
    }
  }

  factory Product.fromMap(Map<String, dynamic> map) {
    double? toDouble(dynamic value) {
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    return Product(
      id: map['id'] as String,
      category: map['category'] as String,
      name: map['name'] as String,
      content: (map['content'] ?? '') as String,
      productType: (map['product_type'] ?? '食品') as String,
      volumeMl: toDouble(map['volume_ml']),
      kcal: toDouble(map['kcal']),
      aminoAcidG: toDouble(map['amino_acid_g']),
      nitrogenG: toDouble(map['nitrogen_g']),
      npcNRatio: toDouble(map['npc_n_ratio']),
      fatBase: toDouble(map['fat_g_or_kcal_basis']),
      carbBase: toDouble(map['carb_g_or_kcal_basis']),
      notes: map['notes'] as String?,
      micro: (map['micro'] as Map?)?.cast<String, dynamic>(),
      alsoEn: (map['also_en'] as bool?) ?? false,
      addType: map['add_type'] as String?,
      conditionTags: (map['condition_tags'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'category': category,
        'name': name,
        'content': content,
        'product_type': productType,
        'volume_ml': volumeMl,
        'kcal': kcal,
        'amino_acid_g': aminoAcidG,
        'nitrogen_g': nitrogenG,
        'npc_n_ratio': npcNRatio,
        'fat_g_or_kcal_basis': fatBase,
        'carb_g_or_kcal_basis': carbBase,
        'notes': notes,
        'micro': micro,
        if (alsoEn) 'also_en': true,
        if (addType != null) 'add_type': addType,
        if (conditionTags.isNotEmpty) 'condition_tags': conditionTags,
      };

  String get volumeMlString => volumeMl == null
      ? '-'
      : '${volumeMl!.toStringAsFixed(volumeMl! % 1 == 0 ? 0 : 1)} ml';
  String get kcalString => kcal == null
      ? '-'
      : '${kcal!.toStringAsFixed(kcal! % 1 == 0 ? 0 : 1)} kcal';
  String get aminoString =>
      aminoAcidG == null ? '-' : 'AA ${aminoAcidG!.toStringAsFixed(1)} g';
}

/// 製品名から容量サフィックス・剤型語を除いた「ベース名」を返す。
/// 例: "ツインパル輸液(500mL)" → "ツインパル", "エルネオパNF1号輸液(1500mL)" → "エルネオパNF1号"
/// 同一ベース名＝同一製剤(容量違い)としてマスタで1項目に集約する。
String productBaseName(String name) {
  var n = name.trim();
  n = n.replaceAll(RegExp(r'「[^」]*」'), ''); // メーカー注記
  n = n.replaceAll(RegExp(r'[\(（][^\)）]*[\)）]'), ''); // (容量) 等
  for (final s in ['配合経腸用液', '配合内用剤', '配合散', '経腸用液', '点滴静注', '注射液', '輸液']) {
    n = n.replaceAll(s, '');
  }
  return n.trim();
}
