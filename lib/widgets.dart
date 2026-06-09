part of 'main.dart';

/// AF / SF ドロップダウン用の説明ラベル（値の toStringAsFixed(1) をキーにする）
const _afHints = {
  '1.0': '寝たきり体動なし',
  '1.1': '寝たきり体動あり',
  '1.2': '車椅子',
  '1.3': '歩行',
  '1.4': '歩行あり',
  '1.5': '積極的リハ',
  '1.6': '積極的リハ',
};
const _sfHints = {
  '0.9': '',
  '1.0': 'ストレスなし',
  '1.1': '手術 / 癌',
  '1.2': '手術 / 癌 / 感染症',
  '1.3': '手術 / 癌 / 感染症',
  '1.4': '感染症 / 発熱',
  '1.5': '感染症 / 発熱',
  '1.6': '敗血症',
  '1.7': '手術',
  '1.8': '手術',
  '1.9': '熱傷',
  '2.0': '熱傷',
  '2.1': '熱傷',
};

/// AF/SF DropdownMenuItem 生成ヘルパー (数値 + 薄い説明ラベル)
DropdownMenuItem<double> _factorItem(double v, Map<String, String> hints) {
  final key = v.toStringAsFixed(1);
  final hint = hints[key] ?? '';
  return DropdownMenuItem<double>(
    value: double.parse(key),
    child: Row(
      children: [
        Text(key, style: const TextStyle(fontSize: 14)),
        if (hint.isNotEmpty) ...[
          const SizedBox(width: 10),
          Text(hint,
              style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                  fontWeight: FontWeight.normal)),
        ],
      ],
    ),
  );
}


/// 加注製剤の「何製剤か」表示順（あいうえお順ではなく種別順）
const _additiveTypeOrder = {
  '電解質': ['Na', 'K', 'Cl', 'Ca', 'Mg', 'P', 'HCO3'],
  '微量元素': ['総合', 'Zn', 'Fe', 'Se'],
  'ビタミン': ['総合', 'B群', '単独'],
};

/// あいうえお順ソート用キー: ひらがな→カタカナに統一して五十音順に揃える
/// (英数字→かな→漢字 の順)
String kanaSortKey(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x3041 && r <= 0x3096) {
      buf.writeCharCode(r + 0x60); // ひらがな→カタカナ
    } else {
      buf.writeCharCode(r);
    }
  }
  return buf.toString();
}

/// 製剤リストを表示用に整列したコピーを返す。
/// 加注(電解質/微量元素/ビタミン)は種別順、それ以外はあいうえお順。
List<Product> sortProductsForDisplay(List<Product> list, {String? additiveCat}) {
  final sorted = [...list];
  final order = additiveCat != null ? _additiveTypeOrder[additiveCat] : null;
  if (order != null) {
    sorted.sort((a, b) {
      var ra = order.indexOf(a.addType ?? '');
      if (ra < 0) ra = 999;
      var rb = order.indexOf(b.addType ?? '');
      if (rb < 0) rb = 999;
      if (ra != rb) return ra.compareTo(rb);
      return kanaSortKey(a.name).compareTo(kanaSortKey(b.name));
    });
  } else {
    sorted.sort((a, b) => kanaSortKey(a.name).compareTo(kanaSortKey(b.name)));
  }
  return sorted;
}

/// 日付を1タップで選択して即閉じるカレンダーダイアログ
Future<DateTime?> _quickPickDate(BuildContext context, DateTime initial) {
  return showDialog<DateTime>(
    context: context,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: CalendarDatePicker(
          initialDate: initial,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
          onDateChanged: (d) => Navigator.pop(ctx, d),
        ),
      ),
    ),
  );
}

/// 患者情報編集ダイアログ（TOP画面・ビルダー画面で共通利用）
/// 患者/入室日は固定表示。絶食開始日・ベッド・AF/SF・目標タンパク・病態タグ・メモを編集。
/// エネルギー式セレクタ（患者編集/新規入室で共用）。
/// kcal/kg選択時は kcal/kg ドロップダウン、間接熱量測定時はREE入力欄を出す。
List<Widget> _energyModelFields({
  required String energyModel,
  required double kcalPerKgValue,
  required TextEditingController reeCtrl,
  required ValueChanged<String> onModel,
  required ValueChanged<double> onKcalPerKg,
}) {
  // 簡易式の目標 kcal/kg: 10・15 と 20–30(1刻み)。保存済みの端数値があっても
  // Dropdownが壊れないよう、現在値も候補に含める。
  final kkItems = <double>{
    10, 15,
    for (int i = 20; i <= 30; i++) i.toDouble(),
    kcalPerKgValue,
  }.toList()
    ..sort();
  return [
    DropdownButtonFormField<String>(
      initialValue: energyModel,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'エネルギー式', isDense: true),
      items: const [
        DropdownMenuItem(
            value: 'harrisBenedict', child: Text('Harris-Benedict ×係数')),
        DropdownMenuItem(
            value: 'mifflinStJeor', child: Text('Mifflin-St Jeor ×係数')),
        DropdownMenuItem(value: 'kcalPerKg', child: Text('簡易式 (kcal/kg)')),
        DropdownMenuItem(
            value: 'indirectCalorimetry', child: Text('間接熱量測定 (実測REE)')),
      ],
      onChanged: (v) {
        if (v != null) onModel(v);
      },
    ),
    if (energyModel == 'kcalPerKg') ...[
      const SizedBox(height: 8),
      DropdownButtonFormField<double>(
        initialValue: kcalPerKgValue,
        isExpanded: true,
        decoration:
            const InputDecoration(labelText: '目標 kcal/kg/day', isDense: true),
        items: kkItems
            .map((v) => DropdownMenuItem(
                value: v,
                child: Text(v == v.roundToDouble()
                    ? v.toStringAsFixed(0)
                    : v.toStringAsFixed(1))))
            .toList(),
        onChanged: (v) {
          if (v != null) onKcalPerKg(v);
        },
      ),
    ],
    if (energyModel == 'indirectCalorimetry') ...[
      const SizedBox(height: 8),
      TextField(
        controller: reeCtrl,
        keyboardType: TextInputType.number,
        decoration:
            const InputDecoration(labelText: '実測REE (kcal/day)', isDense: true),
      ),
    ],
  ];
}

/// 過剰栄養アラート（表示のみ・非強制）。
/// H-B / Mifflin など「基礎代謝×活動係数×侵害係数」のモデルで、侵害係数が高く(≥1.5)、
/// 目標が 30 kcal/kg/day を超える場合に、過剰栄養(overfeeding)の可能性を控えめに注意する。
/// 簡易式(kcal/kg)・間接熱量測定は対象外。該当なしは null。
Widget? _energyOverfeedAlert(PatientCase item) {
  final model = item.energyModel;
  if (model != 'harrisBenedict' && model != 'mifflinStJeor') return null;
  final er = NutritionCalculator.targetEnergyResult(item);
  if (er.feedingWeightKg <= 0) return null;
  final kcalPerKg = er.kcal / er.feedingWeightKg;
  if (!(item.stressFactor >= 1.5 && kcalPerKg > 30)) return null;
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.orange.shade50,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.orange.shade300),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded,
            size: 14, color: Colors.orange.shade800),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            '約${kcalPerKg.round()} kcal/kg/day と過剰栄養の可能性。'
            '侵害係数が高く H-B×係数は過大評価しがちです。'
            '25–30 kcal/kg（簡易式）も検討してください。',
            style: TextStyle(
                fontSize: 11, color: Colors.orange.shade900, height: 1.3),
          ),
        ),
      ],
    ),
  );
}

/// 病態に基づくタンパク推奨範囲サジェスト（非強制・表示のみ）。該当なしは null。
Widget? _proteinSuggestion(Iterable<String> tags, double currentGoal) {
  final ranges = cc.proteinRangesFor(tags);
  if (ranges.isEmpty) return null;
  final inter = cc.intersectedProteinRange(tags);
  final outside =
      inter != null && (currentGoal < inter.min || currentGoal > inter.max);
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.teal.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.teal.shade200),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('💡 推奨タンパク',
            style: TextStyle(
                fontSize: 11,
                color: Colors.teal.shade800,
                fontWeight: FontWeight.bold)),
        for (final c in ranges)
          Text(
            '${ConditionCatalog.labelOf(c.id)}: '
            '${c.proteinMinPerKg}–${c.proteinMaxPerKg} g/kg',
            style: TextStyle(fontSize: 11.5, color: Colors.teal.shade900),
          ),
        if (outside)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '現在値 ${currentGoal.toStringAsFixed(1)} g/kg は推奨範囲外（医師判断で許容可）',
              style: TextStyle(fontSize: 11, color: Colors.deepOrange.shade400),
            ),
          ),
      ],
    ),
  );
}

/// 病態タグ→微量栄養素アラートのコンテキストフラグ。
({
  bool cholestasis,
  bool liver,
  bool renal,
  bool crrt,
  bool giLoss,
  bool wernicke
}) _microFlags(Iterable<String> tags,
    {required double bmi, bool refeedingHigh = false}) {
  final t = tags.toSet();
  return (
    cholestasis: t.contains('cholestasis'),
    liver: t.contains('liver'),
    renal: t.contains('renal'),
    crrt: t.contains('crrt'),
    giLoss: t.contains('gi_loss') || t.contains('malabsorption'),
    wernicke: t.contains('alcohol') || bmi < 16 || refeedingHigh,
  );
}

class SliderWithLabel extends StatelessWidget {
  const SliderWithLabel(
      {super.key,
      required this.label,
      required this.value,
      required this.min,
      required this.max,
      required this.onChanged});
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toStringAsFixed(1)}'),
        Slider(value: value, min: min, max: max, onChanged: onChanged),
      ],
    );
  }
}

class InfoChip extends StatelessWidget {
  const InfoChip(
      {super.key, required this.label, required this.value, this.onTap});
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$label: $value'),
    );
    if (onTap == null) return child;
    return InkWell(
        onTap: onTap, borderRadius: BorderRadius.circular(999), child: child);
  }
}

class ResultLegend extends StatelessWidget {
  const ResultLegend(
      {super.key,
      required this.color,
      required this.label,
      required this.value});
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(value),
        ],
      ),
    );
  }
}

extension FirstWhereOrNullExtension<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

/// 円グラフ下の横並び凡例アイテム
class _PfcLegendItem extends StatelessWidget {
  const _PfcLegendItem({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12, height: 12,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

/// 朝/昼/夕ドロップダウン (0〜3)
class _MealPicker extends StatelessWidget {
  const _MealPicker({
    required this.morning,
    required this.noon,
    required this.evening,
    required this.onChanged,
  });

  final int morning;
  final int noon;
  final int evening;
  final void Function(int morning, int noon, int evening) onChanged;

  static const _options = [0, 1, 2, 3];

  Widget _drop(String label, int value, void Function(int) onChange) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
        DropdownButton<int>(
          value: value,
          isDense: true,
          underline: const SizedBox.shrink(),
          items: _options
              .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
              .toList(),
          onChanged: (v) => onChange(v ?? 0),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _drop('朝', morning, (v) => onChanged(v, noon, evening)),
        const SizedBox(width: 6),
        _drop('昼', noon, (v) => onChanged(morning, v, evening)),
        const SizedBox(width: 6),
        _drop('夕', evening, (v) => onChanged(morning, noon, v)),
      ],
    );
  }
}

/// Day別 投与設計画面
// インライン版(BuilderPageタブ内)とページ版で共用するウィジェット
class _LegendChip extends StatelessWidget {
  const _LegendChip(
      {required this.color, required this.label, required this.line});
  final Color color;
  final String label;
  final bool line;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: line ? 16 : 12,
            height: line ? 3 : 12,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}
