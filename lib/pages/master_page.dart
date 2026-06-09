part of '../main.dart';

class MasterPage extends StatefulWidget {
  const MasterPage({super.key, required this.state});
  final AppState state;

  @override
  State<MasterPage> createState() => _MasterPageState();
}

class _MasterPageState extends State<MasterPage> {
  String category = 'EN';
  String _query = '';

  static const _masterCats = [
    'EN', 'TPN', 'PPN', '食事', '電解質', '微量元素', 'ビタミン'
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // EN: EN本体/補助 + 両用food(alsoEn) を表示 / 食事: 濃厚流動食+栄養サポートを統合
    final all = category == 'EN'
        ? widget.state.catalog.products.where((p) => p.inEnTab).toList()
        : category == '食事'
            ? widget.state.catalog.products.where((p) => p.isFood).toList()
            : widget.state.catalog.byCategory(category);
    final q = _query.trim().toLowerCase();
    final items = q.isEmpty
        ? all
        : all
            .where((p) =>
                p.name.toLowerCase().contains(q) ||
                p.content.toLowerCase().contains(q))
            .toList();
    final total = widget.state.catalog.products.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── ヘッダ: タイトル + 製剤数合計 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
          child: Row(
            children: [
              Text('製剤マスタ',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('全 $total 製剤',
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        // ── 検索 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: '製剤名・性状で検索',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
            ),
          ),
        ),
        // ── カテゴリチップ (横スクロール) ──
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final c in _masterCats)
                _catChip(c, category == c,
                    () => setState(() => category = c)),
            ],
          ),
        ),
        // ── 説明 + 件数 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                    category == '食事'
                        ? '食事(経口リハ)期の製剤。EN印は経腸でも使用可'
                        : '院内採用薬を選択（容量はチップで選択）',
                    style: theme.textTheme.bodySmall),
              ),
              Text('${items.length}件',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.black45)),
            ],
          ),
        ),
        // ── リスト ──
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text('該当する製剤がありません',
                      style: TextStyle(color: Colors.black45)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    // 「食事」タブは 濃厚流動食 / 栄養サポート食品 に分割表示
                    if (category == '食事') ...[
                      for (final sub in const ['濃厚流動食', '栄養サポート食品'])
                        ...(() {
                          final subItems =
                              items.where((p) => p.category == sub).toList();
                          if (subItems.isEmpty) return <Widget>[];
                          return [
                            _foodSectionHeader(sub),
                            ..._groupCards(subItems),
                          ];
                        })(),
                    ] else
                      ..._groupCards(items),
                  ],
                ),
        ),
      ],
    );
  }

  /// 麻酔薬リファレンス風 カテゴリ選択チップ
  Widget _catChip(String label, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        selectedColor: scheme.primary,
        labelStyle: TextStyle(
          color: selected ? Colors.white : Colors.black87,
          fontSize: 13,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
        backgroundColor: Colors.white,
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.3)),
      ),
    );
  }

  /// 製剤を同一ベース名(容量違い)でまとめてカード化。
  /// 加注(電解質/微量元素/ビタミン)は種別順、それ以外はあいうえお順。
  List<Widget> _groupCards(List<Product> list) {
    final groups = <String, List<Product>>{};
    for (final p in list) {
      groups.putIfAbsent(productBaseName(p.name), () => []).add(p);
    }
    final cat = list.isNotEmpty ? list.first.category : '';
    final order = _additiveTypeOrder[cat];
    final keys = groups.keys.toList();
    if (order != null) {
      int rank(String k) {
        final i = order.indexOf(groups[k]!.first.addType ?? '');
        return i < 0 ? 999 : i;
      }
      keys.sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : kanaSortKey(a).compareTo(kanaSortKey(b));
      });
    } else {
      keys.sort((a, b) => kanaSortKey(a).compareTo(kanaSortKey(b)));
    }
    return keys.map((k) => _productGroupCard(k, groups[k]!)).toList();
  }

  /// 「食事」タブのサブセクション見出し（----濃厚流動食---- 等）
  Widget _foodSectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Row(
          children: [
            const Expanded(child: Divider(thickness: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(title,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal.shade700)),
            ),
            const Expanded(child: Divider(thickness: 1)),
          ],
        ),
      );

  // ビタミンの単位 (1袋あたり)
  static const _vitUnits = {
    'B1': 'mg', 'B2': 'mg', 'B6': 'mg', 'B12': 'μg',
    'ナイアシン': 'mg', 'パントテン酸': 'mg', '葉酸': 'mg', 'ビオチン': 'μg',
    'C': 'mg', 'A': 'VA単位', 'D': 'μg', 'E': 'mg', 'K': 'mg',
  };

  String _numFmt(dynamic v) {
    if (v is num) {
      return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    }
    return '$v';
  }

  /// 微量栄養素セクション (電解質/微量元素/ビタミン)
  /// perL=true: 濃度(per L)表記 [PPN] / false: 1袋あたり [TPN等]
  Widget _microSection(Map<String, dynamic> micro, {bool perL = false}) {
    final per = perL ? '/L' : '/袋';
    final rows = <Widget>[];
    Widget line(String head, String body, Color c) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.4),
              children: [
                TextSpan(
                    text: '$head  ',
                    style: TextStyle(fontWeight: FontWeight.bold, color: c)),
                TextSpan(text: body),
              ],
            ),
          ),
        );

    final elec = (micro['elec'] as Map?)?.cast<String, dynamic>();
    if (elec != null && elec.isNotEmpty) {
      final parts = <String>[];
      for (final k in ['Na', 'K', 'Cl', 'Ca', 'Mg']) {
        if (elec[k] != null) parts.add('$k ${_numFmt(elec[k])}');
      }
      var body = parts.isEmpty ? '' : '${parts.join(' / ')} mEq$per';
      if (elec['P'] != null) {
        body += '${body.isEmpty ? '' : ', '}P ${_numFmt(elec['P'])} mmol$per';
      }
      rows.add(line('電解質', body, Colors.indigo.shade700));
    }

    final trace = (micro['trace'] as Map?)?.cast<String, dynamic>();
    if (trace != null && trace.isNotEmpty) {
      final parts = <String>[];
      for (final k in ['Zn', 'Fe', 'Mn', 'Cu', 'I']) {
        if (trace[k] != null) parts.add('$k ${_numFmt(trace[k])}');
      }
      var body = parts.isEmpty ? '' : '${parts.join(' / ')} μmol$per';
      if (trace['Se'] != null) {
        // Se は μg 表記
        body += '${body.isEmpty ? '' : ', '}Se ${_numFmt(trace['Se'])} μg$per';
      }
      rows.add(line('微量元素', body, Colors.deepOrange.shade700));
    }

    final vit = (micro['vit'] as Map?)?.cast<String, dynamic>();
    if (vit != null && vit.isNotEmpty) {
      final parts = <String>[];
      vit.forEach((k, v) {
        final u = _vitUnits[k] ?? '';
        parts.add('$k ${_numFmt(v)}$u');
      });
      rows.add(line('ビタミン', parts.join(' / '), Colors.purple.shade700));
    }

    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(perL ? '含有量 (mEq/L = 1L中の濃度)' : '含有量 (1袋あたり)',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey.shade400)),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }

  String _volLabel(Product p) {
    final v = p.volumeMl;
    if (v == null) return '—';
    final s = v % 1 == 0 ? v.toInt().toString() : v.toString();
    return '${s}mL';
  }

  /// 同一ベース名(容量違い)を1項目に集約したカード。容量チップで採用を選択。
  Widget _productGroupCard(String base, List<Product> variants) {
    variants.sort((a, b) => (a.volumeMl ?? 0).compareTo(b.volumeMl ?? 0));
    final adoptedAny = variants.any((p) => widget.state.isAdopted(p.id));
    final rep = variants.firstWhere((p) => widget.state.isAdopted(p.id),
        orElse: () => variants.first);
    final typeColor =
        rep.productType == '医薬品' ? Colors.red.shade100 : Colors.green.shade100;
    final typeTextColor =
        rep.productType == '医薬品' ? Colors.red.shade900 : Colors.green.shade900;

    return Card(
      child: ExpansionTile(
        leading: Icon(adoptedAny ? Icons.circle : Icons.circle_outlined,
            color: adoptedAny ? Colors.blue : null),
        title: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(base,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            _miniTag(rep.productType, bg: typeColor, fg: typeTextColor),
            if (rep.content.isNotEmpty)
              _miniTag(rep.content,
                  bg: Colors.blueGrey.shade50, fg: Colors.blueGrey.shade900),
            // 両用(食事⇔EN)製剤バッジ
            if (rep.alsoEn)
              _miniTag('EN両用',
                  bg: Colors.green.shade50, fg: Colors.green.shade800),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 容量チップ (タップで採用ON/OFF・複数可)
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: variants.map((p) {
                  final on = widget.state.isAdopted(p.id);
                  return FilterChip(
                    label: Text(_volLabel(p),
                        style: const TextStyle(fontSize: 12)),
                    selected: on,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) async {
                      await widget.state.toggleAdopted(p.id);
                      setState(() {});
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 2),
              Text('${rep.kcalString} / ${rep.aminoString}',
                  style:
                      const TextStyle(fontSize: 12.5, color: Colors.black54)),
            ],
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (variants.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('▼ 組成は ${_volLabel(rep)} のもの',
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ),
          ..._productDetailChildren(rep),
        ],
      ),
    );
  }

  /// 製剤詳細(要素/NPC/脂質/糖質・含有量・コメント)を返す共通部品。
  List<Widget> _productDetailChildren(Product p) {
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (p.category != 'TPN' && p.category != 'PPN')
            InfoChip(
                label: '分類',
                value: p.productType,
                onTap: () => _editProductType(p)),
          InfoChip(
              label: '要素',
              value: p.content.isEmpty ? '-' : p.content,
              onTap: () => _editContent(p)),
          InfoChip(label: 'NPC/N', value: p.npcNRatio?.toString() ?? '-'),
          InfoChip(
              label: '脂質',
              value: (p.fatBase == null || p.fatBase == 0)
                  ? '-'
                  : '${p.fatBase!.toStringAsFixed(p.fatBase! % 1 == 0 ? 0 : 1)}g'),
          InfoChip(
              label: '糖質',
              value: (p.carbBase == null || p.carbBase == 0)
                  ? '-'
                  : '${p.carbBase!.toStringAsFixed(p.carbBase! % 1 == 0 ? 0 : 1)}g'),
        ],
      ),
      if (p.micro != null) ...[
        const SizedBox(height: 10),
        _microSection(p.micro!, perL: p.category == 'PPN'),
      ],
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              p.notes?.trim().isNotEmpty == true ? p.notes! : 'コメントなし',
              style: const TextStyle(height: 1.5),
            ),
          ),
          IconButton(
            tooltip: 'コメントを編集',
            icon: const Icon(Icons.edit_note),
            onPressed: () => _editNotes(p),
          ),
        ],
      ),
    ];
  }

  Widget _miniTag(String text, {required Color bg, required Color fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style:
              TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  Future<void> _editNotes(Product p) async {
    final controller = TextEditingController(text: p.notes ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${p.name} のコメントを編集'),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 12,
            minLines: 5,
            decoration: const InputDecoration(
              hintText: 'コメントを入力してください',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    await widget.state.updateProductOverride(p, notes: result);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${p.name} のコメントを保存しました')));
    }
  }

  Future<void> _editProductVolume(Product p) async {
    final controller =
        TextEditingController(text: p.volumeMl?.toString() ?? '');
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${p.name} の容量を編集'),
        content: SizedBox(
          width: 300,
          child: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              hintText: '容量（ml）を入力',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () {
                final newVolume = double.tryParse(controller.text);
                Navigator.pop(context, newVolume);
              },
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null || result <= 0) return;
    final originalVolume = (p.volumeMl ?? 0) <= 0 ? result : p.volumeMl!;
    final ratio = result / originalVolume;
    await widget.state.updateProductOverride(
      p,
      volumeMl: result,
      kcal: (p.kcal ?? 0) * ratio,
      aminoAcidG: (p.aminoAcidG ?? 0) * ratio,
      nitrogenG: (p.nitrogenG ?? 0) * ratio,
      fatBase: (p.fatBase ?? 0) * ratio,
      carbBase: (p.carbBase ?? 0) * ratio,
      npcNRatio: p.npcNRatio,
    );
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${p.name} の容量を ${result}ml に更新しました')));
    }
  }

  Future<void> _editProductType(Product p) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${p.name} の分類'),
        children: [
          for (final t in ['食品', '医薬品'])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, t),
              child: Row(
                children: [
                  Icon(p.productType == t
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off),
                  const SizedBox(width: 8),
                  Text(t),
                ],
              ),
            ),
        ],
      ),
    );
    if (result == null) return;
    await widget.state.updateProductOverride(p, productType: result);
    if (mounted) setState(() {});
  }

  Future<void> _editContent(Product p) async {
    final controller = TextEditingController(text: p.content);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${p.name} の性状'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例: 半消化態 / 成分栄養 / 高濃度AA など',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    await widget.state.updateProductOverride(p, content: result);
    if (mounted) setState(() {});
  }
}
