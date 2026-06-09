part of 'main.dart';

class ProductCatalog {
  ProductCatalog(this.products) {
    instance = this;
  }

  static late ProductCatalog instance;
  final List<Product> products;

  static Future<ProductCatalog> load() async {
    final raw = await rootBundle.loadString('assets/product_masters.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final items = (decoded['products'] as List)
        .map((e) => Product.fromMap(Map<String, dynamic>.from(e)))
        .toList();
    return ProductCatalog(items);
  }

  List<Product> byCategory(String category) =>
      products.where((e) => e.category == category).toList();
  Product? byName(String name) {
    try {
      return products.firstWhere((e) => e.name == name);
    } catch (_) {
      return null;
    }
  }

  Product? byId(String id) {
    try {
      return products.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }
}

class AppState {
  AppState(
      {required this.catalog,
      required this.store,
      required this.cases,
      required this.protocols,
      required this.selectedCaseId,
      required this.favoriteProductIds,
      required this.adoptedProductIds,
      required this.noteText});

  /// 初回起動時にデフォルトで採用済みにする製剤名（院内採用の標準セット）
  static const List<String> _defaultAdoptedNames = [
    // ── EN / 食事（再編後の名称に合わせる） ──
    'F2α(エフツーアルファ)', 'テルミール2.0α', 'グルセルナ-REX', 'リーナレンMP',
    'ヘパス', 'ペプチーノ', 'ペプタメン AF', 'ペプタメン スタンダード',
    'エネーボ', 'エレンタール', 'アミノレバン',
    // ── EN補助（6種すべて） ──
    'REF P1', 'GFO', 'サンファイバー', 'オルニュート', 'ブイ・クレスゼリー', '一挙千菜',
    // ── PPN 採用薬 ──
    'ビーフリード', 'アミパレン', 'キドミン',
    'イントラリポス20%', '8%グルコース', '5%グルコース',
    // ── TPN 採用薬 ──
    'エルネオパNF1号', 'エルネオパNF2号',
    'フルカリック1号', 'フルカリック2号', 'フルカリック3号',
    'ハイカリックRF', '70% グルコース',
    // ── 加注(電解質/微量元素/ビタミン) プリセット ──
    '1モル塩化ナトリウム注射液', 'KCL補正液1mEq/mL', 'カルチコール注射液8.5%',
    '硫酸Mg補正液 1mEq/mL', 'リン酸Na補正液 0.5mmol/mL', 'メイロン静注8.4%',
    'エレジェクト注シリンジ', '硫酸亜鉛', 'アセレンド注 (セレン)',
    'オーツカMV注', 'ビタメジン静注用',
    // ── EN/食事 プリセット追加 ──
    'エンシュアリキッド', 'プルモケア-EX', 'ペプタメン スタンダード', 'ペプタメン AF',
    'メイバランス1.5', 'メイバランス2.0',
  ];

  /// デフォルト採用から外す製剤（同名で容量違いがあるため name+volume で指定）。
  static const List<(String, double)> _defaultExcluded = [
    ('メイバランス1.5', 333.0),
    ('カルチコール注射液8.5%', 5.0),
    ('グルセルナ-REX', 400.0),
  ];

  final ProductCatalog catalog;
  final LocalStore store;
  final List<PatientCase> cases;
  final List<ProtocolTemplate> protocols;
  final List<String> favoriteProductIds;
  final List<String> adoptedProductIds;
  String? selectedCaseId;
  String noteText;

  /// 製剤オーバーライドをローカル保存し、カタログにも反映させる
  Future<void> updateProductOverride(
    Product product, {
    String? notes,
    String? content,
    String? productType,
    double? volumeMl,
    double? kcal,
    double? aminoAcidG,
    double? nitrogenG,
    double? npcNRatio,
    double? fatBase,
    double? carbBase,
  }) async {
    if (notes != null) product.notes = notes;
    if (content != null) product.content = content;
    if (productType != null) product.productType = productType;
    if (volumeMl != null) product.volumeMl = volumeMl;
    if (kcal != null) product.kcal = kcal;
    if (aminoAcidG != null) product.aminoAcidG = aminoAcidG;
    if (nitrogenG != null) product.nitrogenG = nitrogenG;
    if (npcNRatio != null) product.npcNRatio = npcNRatio;
    if (fatBase != null) product.fatBase = fatBase;
    if (carbBase != null) product.carbBase = carbBase;

    final overrides = await store.loadProductOverrides();
    overrides[product.id] = {
      'notes': product.notes,
      'content': product.content,
      'product_type': product.productType,
      'volume_ml': product.volumeMl,
      'kcal': product.kcal,
      'amino_acid_g': product.aminoAcidG,
      'nitrogen_g': product.nitrogenG,
      'npc_n_ratio': product.npcNRatio,
      'fat_g_or_kcal_basis': product.fatBase,
      'carb_g_or_kcal_basis': product.carbBase,
    };
    await store.saveProductOverrides(overrides);
  }

  PatientCase? get selectedCase {
    if (selectedCaseId == null && cases.isNotEmpty)
      selectedCaseId = cases.first.id;
    return cases.where((e) => e.id == selectedCaseId).firstOrNull;
  }

  bool isFavorite(String productId) => favoriteProductIds.contains(productId);

  Future<void> toggleFavorite(String productId) async {
    if (favoriteProductIds.contains(productId)) {
      favoriteProductIds.remove(productId);
    } else {
      favoriteProductIds.add(productId);
    }
    await store.saveFavorites(favoriteProductIds);
  }

  /// 現在(または指定)患者の病態タグに対応する「採用済み病態別製剤」のid集合。
  /// 手動★とは別に処方画面で上位(★)に浮かせるための動的算出（非永続）。
  /// → タグOFFで自動的に消え、患者を切り替えても混入しない。
  Set<String> autoFavoriteIds([PatientCase? forCase]) {
    final c = forCase ?? selectedCase;
    final tags = c?.conditionTags ?? const <String>[];
    if (tags.isEmpty) return const <String>{};
    final tagSet = tags.toSet();
    final ids = <String>{};
    for (final p in catalog.products) {
      if (!isAdopted(p.id)) continue;
      if (p.conditionTags.any(tagSet.contains)) ids.add(p.id);
    }
    return ids;
  }

  /// 病態タグ由来の自動★か（手動★は除く）。★アイコンの色分け用。
  bool isAutoFavorite(String productId, [PatientCase? forCase]) =>
      !favoriteProductIds.contains(productId) &&
      autoFavoriteIds(forCase).contains(productId);

  /// 手動★ ∪ 病態タグ由来の自動★。ソート/上位表示はこれを使う。
  bool isEffectiveFavorite(String productId, [PatientCase? forCase]) =>
      favoriteProductIds.contains(productId) ||
      autoFavoriteIds(forCase).contains(productId);

  bool isAdopted(String productId) => adoptedProductIds.contains(productId);

  /// ベース名(容量違いを集約した名前)に対応する製剤を、採用容量を優先して返す。
  /// 計算画面はこれを使い「マスタで選んだ容量」で計算する。
  Product? adoptedByBase(String baseName) {
    final matches =
        catalog.products.where((p) => productBaseName(p.name) == baseName);
    for (final p in matches) {
      if (isAdopted(p.id)) return p;
    }
    return matches.isEmpty ? null : matches.first;
  }

  /// ゼロmenu用: 採用中の純アミノ酸製剤(糖・脂質を含まない高濃度AA)を自動選択。
  /// 採用が無ければアミパレンにフォールバック。
  Product? adoptedAminoForZero() {
    final c = catalog
        .byCategory('PPN')
        .where((p) =>
            isAdopted(p.id) &&
            (p.aminoAcidG ?? 0) > 0 &&
            (p.fatBase ?? 0) <= 0 &&
            (p.carbBase ?? 0) <= 0)
        .toList()
      ..sort((a, b) => ((b.aminoAcidG ?? 0) / (b.volumeMl ?? 1))
          .compareTo((a.aminoAcidG ?? 0) / (a.volumeMl ?? 1)));
    return c.isNotEmpty ? c.first : adoptedByBase('アミパレン');
  }

  /// ゼロmenu用: 採用中の脂肪乳剤(高濃度優先)を自動選択。
  /// 採用が無ければイントラリポス20%にフォールバック。
  Product? adoptedLipidForZero() {
    final c = catalog
        .byCategory('PPN')
        .where((p) => isAdopted(p.id) && (p.fatBase ?? 0) > 0)
        .toList()
      ..sort((a, b) => ((b.fatBase ?? 0) / (b.volumeMl ?? 1))
          .compareTo((a.fatBase ?? 0) / (a.volumeMl ?? 1)));
    return c.isNotEmpty ? c.first : adoptedByBase('イントラリポス20%');
  }

  Future<void> toggleAdopted(String productId) async {
    if (adoptedProductIds.contains(productId)) {
      adoptedProductIds.remove(productId);
    } else {
      adoptedProductIds.add(productId);
    }
    await store.saveAdoptedProducts(adoptedProductIds);
  }

  static Future<AppState> bootstrap(
      ProductCatalog catalog, LocalStore store) async {
    final loaded = await store.loadCases();
    final cases = loaded.map(PatientCase.fromMap).toList();
    // Phase 3-①: 旧ベッド表記 (ICU-XX) を数字のみにマイグレーション
    var migrated = false;
    String _normalizeBed(String raw) {
      final m = RegExp(r'(\d+)').firstMatch(raw);
      if (m == null) return raw;
      return m.group(1)!.padLeft(2, '0');
    }

    for (final c in cases) {
      final newBed = _normalizeBed(c.currentBed);
      if (newBed != c.currentBed) {
        c.currentBed = newBed;
        migrated = true;
      }
      for (final b in c.bedHistory) {
        final newTo = _normalizeBed(b.toBed);
        if (newTo != b.toBed) {
          // BedAssignment.toBedは final なので 新要素に差し替え
          // と思ったが final だと代入できない → BedAssignmentをmutableに修正済みはないので
          // ここではインデックスで置換する
          final idx = c.bedHistory.indexOf(b);
          c.bedHistory[idx] = BedAssignment(
            changedAt: b.changedAt,
            fromBed: b.fromBed == null ? null : _normalizeBed(b.fromBed!),
            toBed: newTo,
            note: b.note,
          );
          migrated = true;
        } else if (b.fromBed != null) {
          final newFrom = _normalizeBed(b.fromBed!);
          if (newFrom != b.fromBed) {
            final idx = c.bedHistory.indexOf(b);
            c.bedHistory[idx] = BedAssignment(
              changedAt: b.changedAt,
              fromBed: newFrom,
              toBed: b.toBed,
              note: b.note,
            );
            migrated = true;
          }
        }
      }
    }
    if (migrated) await store.saveCases(cases);

    // EN製剤の旧形式マイグレーション: 朝昼夕未設定 (morning=noon=evening=0) かつ units>0 の EN/EN_AUX アイテムを削除
    var enMigrated = false;
    for (final c in cases) {
      final before = c.regimenItems.length;
      c.regimenItems.removeWhere((item) {
        final p = catalog.byId(item.productId);
        if (p == null) return false;
        if (p.category != 'EN' && p.category != 'EN_AUX') return false;
        return item.morning + item.noon + item.evening == 0 && item.units > 0;
      });
      if (c.regimenItems.length != before) enMigrated = true;
    }
    if (enMigrated) await store.saveCases(cases);

    final favorites = await store.loadFavorites();

    // 製剤オーバーライドをカタログに適用
    final overrides = await store.loadProductOverrides();
    for (final p in catalog.products) {
      final ov = overrides[p.id];
      if (ov == null) continue;
      if (ov['notes'] != null) p.notes = ov['notes'] as String?;
      if (ov['content'] != null) p.content = ov['content'] as String;
      if (ov['product_type'] != null) {
        p.productType = ov['product_type'] as String;
      }
      if (ov['volume_ml'] != null) {
        p.volumeMl = (ov['volume_ml'] as num).toDouble();
      }
      if (ov['kcal'] != null) {
        p.kcal = (ov['kcal'] as num).toDouble();
      }
      if (ov['amino_acid_g'] != null) {
        p.aminoAcidG = (ov['amino_acid_g'] as num).toDouble();
      }
      if (ov['nitrogen_g'] != null) {
        p.nitrogenG = (ov['nitrogen_g'] as num).toDouble();
      }
      if (ov['npc_n_ratio'] != null) {
        p.npcNRatio = (ov['npc_n_ratio'] as num).toDouble();
      }
      if (ov['fat_g_or_kcal_basis'] != null) {
        p.fatBase = (ov['fat_g_or_kcal_basis'] as num).toDouble();
      }
      if (ov['carb_g_or_kcal_basis'] != null) {
        p.carbBase = (ov['carb_g_or_kcal_basis'] as num).toDouble();
      }
    }
    // 初期患者は作らない(患者数0がデフォルト)。新規入室で追加する。

    var adopted = await store.loadAdoptedProducts();
    // デフォルト採用セットを一度だけ既存の採用リストにマージする
    if (!await store.loadDefaultsApplied()) {
      final defaults = _defaultAdoptedNames.map((n) => n.trim()).toSet();
      bool isExcluded(Product p) => _defaultExcluded
          .any((e) => e.$1 == p.name.trim() && (p.volumeMl ?? 0) == e.$2);
      final defaultIds = catalog.products
          .where((p) => defaults.contains(p.name.trim()) && !isExcluded(p))
          .map((p) => p.id);
      final excludedIds =
          catalog.products.where(isExcluded).map((p) => p.id).toSet();
      adopted = (<String>{...adopted, ...defaultIds}..removeAll(excludedIds))
          .toList();
      await store.saveAdoptedProducts(adopted);
      await store.saveDefaultsApplied();
    }
    final note = await store.loadNote();

    return AppState(
      catalog: catalog,
      store: store,
      cases: cases,
      protocols: const [
        ProtocolTemplate(
            id: 'three_day',
            name: '3日',
            percentages: [33, 67, 100],
            description: '最短3日で full nutrition を目指す'),
        ProtocolTemplate(
            id: 'four_day',
            name: '4日',
            percentages: [25, 50, 75, 100],
            description: '標準的な4日階段導入'),
        ProtocolTemplate(
            id: 'five_day',
            name: '5日',
            percentages: [20, 40, 60, 80, 100],
            description: 'ICU重症例向けの5日階段導入'),
      ],
      selectedCaseId: cases.isNotEmpty ? cases.first.id : null,
      favoriteProductIds: favorites,
      adoptedProductIds: adopted,
      noteText: note,
    );
  }

  Future<void> addCase(PatientCase item) async {
    cases.insert(0, item);
    selectedCaseId = item.id;
    await persist();
  }

  Future<void> removeCase(String caseId) async {
    cases.removeWhere((e) => e.id == caseId);
    if (selectedCaseId == caseId) {
      selectedCaseId = cases.isNotEmpty ? cases.first.id : null;
    }
    await persist();
  }

  Future<void> setUnits(String caseId, Product product, int units) async {
    final current = cases.firstWhere((e) => e.id == caseId);
    final existingIndex =
        current.regimenItems.indexWhere((e) => e.productId == product.id);
    if (existingIndex == -1 && units > 0) {
      current.regimenItems
          .add(RegimenItem(productId: product.id, units: units));
    } else if (existingIndex != -1) {
      final partial = current.regimenItems[existingIndex].partialMl;
      if (units <= 0 && partial <= 0) {
        current.regimenItems.removeAt(existingIndex);
      } else {
        current.regimenItems[existingIndex].units = units < 0 ? 0 : units;
        // 朝昼夕をリセット（シンプルカウントに戻す）
        current.regimenItems[existingIndex].morning = 0;
        current.regimenItems[existingIndex].noon = 0;
        current.regimenItems[existingIndex].evening = 0;
      }
    }
    await persist();
  }

  Future<void> setMealUnits(
      String caseId, Product product, int morning, int noon, int evening) async {
    final current = cases.firstWhere((e) => e.id == caseId);
    final total = morning + noon + evening;
    final existingIndex =
        current.regimenItems.indexWhere((e) => e.productId == product.id);
    if (existingIndex == -1 && total > 0) {
      current.regimenItems.add(RegimenItem(
          productId: product.id,
          units: total,
          morning: morning,
          noon: noon,
          evening: evening));
    } else if (existingIndex != -1) {
      if (total <= 0) {
        current.regimenItems.removeAt(existingIndex);
      } else {
        current.regimenItems[existingIndex]
          ..units = total
          ..morning = morning
          ..noon = noon
          ..evening = evening;
      }
    }
    await persist();
  }

  /// TPN/PPN製剤の部分使用量(ml)を設定。本数(units)はそのまま、部分量のみ更新。
  /// units==0 かつ partialMl==0 になったらアイテム削除。
  Future<void> setPartialMl(String caseId, Product product, int partialMl) async {
    final current = cases.firstWhere((e) => e.id == caseId);
    final idx =
        current.regimenItems.indexWhere((e) => e.productId == product.id);
    final ml = partialMl < 0 ? 0 : partialMl;
    if (idx == -1) {
      if (ml > 0) {
        current.regimenItems
            .add(RegimenItem(productId: product.id, units: 0, partialMl: ml));
      }
    } else {
      current.regimenItems[idx].partialMl = ml;
      if (current.regimenItems[idx].units <= 0 && ml <= 0) {
        current.regimenItems.removeAt(idx);
      }
    }
    await persist();
  }

  Future<void> persist() => store.saveCases(cases);

  Future<void> saveNote(String text) async {
    noteText = text;
    await store.saveNote(text);
  }
}
