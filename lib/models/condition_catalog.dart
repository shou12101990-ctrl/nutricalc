/// 病態タグの定義。患者に付けた病態タグに応じて、対応する病態別製剤を
/// 処方画面で上位(お気に入り扱い)に浮かせ、処方サジェストを表示する。
class ConditionDef {
  const ConditionDef({
    required this.id,
    required this.label,
    required this.suggestion,
    this.proteinCapPerKg,
  });

  final String id; // glucose_intolerance/renal/liver/respiratory/critical/wound/malabsorption/dysphagia
  final String label; // 表示名
  final String suggestion; // 💡 処方サジェスト本文
  final double? proteinCapPerKg; // 蛋白の目安上限(g/kg/day)。超過時に控えめなテキスト(現状は未設定=オフ)
}

/// 病態カタログ(選択アルゴリズム)。各病態の「考え方」と推奨製剤を紐づける。
/// 文言・割り当ては現場でレビュー・調整して使う。
class ConditionCatalog {
  static const List<ConditionDef> all = [
    ConditionDef(
      id: 'glucose_intolerance',
      label: '耐糖能異常',
      suggestion: '急な糖質負荷を避け、血糖変動を大きくしない。'
          '必要なら食物繊維や低GI設計を用いる。',
    ),
    ConditionDef(
      id: 'renal',
      label: '腎不全(保存期)',
      suggestion: '保存期: 低蛋白(0.6–0.8 g/kg/day)・低K・低P で腎負荷を軽減。'
          '十分なエネルギーを確保し異化を防ぐ。',
    ),
    ConditionDef(
      id: 'aki',
      label: '急性腎障害(AKI)',
      suggestion: 'AKI: 急性/重症病態が無ければ 0.8–1.0 g/kg/day。'
          '急性・重症やRRTがあれば蛋白を下げず増やす(蛋白制限でRRT開始を遅らせない)。',
    ),
    ConditionDef(
      id: 'fluid_overload',
      label: '溢水・体液過剰',
      suggestion: '現体重が水分で過大評価されやすい。平時/入院前体重が分かる場合は'
          '栄養計算の参照体重として使い、IN量・Na・水分負荷も合わせて確認する。',
    ),
    ConditionDef(
      id: 'edema',
      label: '浮腫',
      suggestion: '浮腫が強い場合は現体重だけで必要量を見積もると過大になりうる。'
          '平時/入院前体重を参照し、過大栄養と水分負荷を避ける。',
    ),
    ConditionDef(
      id: 'renal_dialysis',
      label: '腎不全(間欠RRT/透析)',
      suggestion: '間欠RRT/維持透析: 1.3–1.5 g/kg/day を確保しつつ'
          'K/P・水分負荷に配慮（蛋白制限でRRT開始を遅らせない）。',
    ),
    ConditionDef(
      id: 'liver',
      label: '肝不全/肝性脳症',
      suggestion: '蛋白 1.0–1.2 g/kg/day を目安に低栄養を避け、BCAAを意識。'
          '肝性脳症悪化リスクに配慮(過度な蛋白制限は避ける)。',
    ),
    ConditionDef(
      id: 'respiratory',
      label: '呼吸器疾患/高CO2貯留',
      suggestion: '糖質過多でCO2産生を増やしすぎない。',
    ),
    ConditionDef(
      id: 'critical',
      label: '重症・周術期・高侵襲',
      suggestion: '蛋白 1.2–2.0 g/kg/day と十分なエネルギーを確保。'
          '必要に応じEPA/DHA・アルギニン等の免疫栄養を補充。',
    ),
    ConditionDef(
      id: 'wound',
      label: '褥瘡・創傷治癒・サルコペニア',
      suggestion: '蛋白 1.2–1.5 g/kg/day・十分なエネルギーを確保。'
          'アルギニン・HMB・微量元素(Zn等)の補充を検討。',
    ),
    ConditionDef(
      id: 'malabsorption',
      label: '消化吸収障害・短腸・下痢',
      suggestion: '消化態/成分栄養の要否、脂肪・浸透圧耐性、'
          '吸収のしやすさ・低残渣性に配慮。',
    ),
    ConditionDef(
      id: 'dysphagia',
      label: '嚥下障害・逆流・胃瘻',
      suggestion: '誤嚥・逆流・注入時間・半固形化の要否に配慮。'
          '液体で問題があれば半固形・とろみへの切替を検討。',
    ),
    ConditionDef(
      id: 'cholestasis',
      label: '胆汁うっ滞・胆道閉塞',
      suggestion: 'Mnは胆汁排泄のため蓄積し神経毒性(淡蒼球)。Mn含有微量元素はMn-free(ボルビサール)へ切替。'
          'Cuも減量しつつモニタ(血清Cu・セルロプラスミン)。胆道閉塞ではMn製剤は禁忌。',
    ),
    ConditionDef(
      id: 'crrt',
      label: 'CKRT(CRRT/PIRRT)稼働中',
      suggestion: 'active CKRTは水溶性ビタミン・微量元素の喪失を想定し、'
          'monitor(Se/Zn/Cu/VitC/葉酸/B1/CRP/Alb)+補充のobligationを立てる。'
          '高優先はB1/Se/Zn、>2週ではCu欠乏に注意し血中銅測定。'
          '終了条件: CKRT終了/間欠透析移行/検査・臨床的安定(医師判断)。',
    ),
    ConditionDef(
      id: 'burn',
      label: '熱傷(>20%TBSA)',
      suggestion: 'ENグルタミン 0.3–0.5 g/kg/day を10–15日。'
          'Zn 30–35mg/day IVを2–3週、Se/Cu等の微量元素需要も増大。',
    ),
    ConditionDef(
      id: 'trauma',
      label: '外傷(ICU)',
      suggestion: 'ENグルタミン 0.2–0.3 g/kg/day を5日'
          '(創傷治癒不良なら10–15日)。',
    ),
    ConditionDef(
      id: 'gi_loss',
      label: '高排出消化管瘻・大量下痢',
      suggestion: 'Zn喪失大。腸液+12mg/L・便/ストマ+17mg/Lを上乗せ。Mg/K/Na・水分も補正。',
    ),
    ConditionDef(
      id: 'alcohol',
      label: 'アルコール多飲・低栄養',
      suggestion: 'ビタミンB1欠乏のハイリスク。糖負荷の前〜同時にチアミン100–300mgを投与し'
          'Wernicke脳症・乳酸アシドーシスを予防。Refeedingにも注意。',
    ),
  ];

  static ConditionDef? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  static String labelOf(String id) => byId(id)?.label ?? id;
}
