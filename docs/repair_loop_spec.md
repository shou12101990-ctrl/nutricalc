# Repair Loop 仕様書

## 目的

この機能は、ICU栄養処方を「通常患者の標準制約」から評価し、病態タグによって制約を変化させ、その結果発生するアラートに応じて処方案を自動的に補正する仕組みである。

ユーザー体験としては、処方が「勝手にそうなっている」状態を目指す。ただし医療安全上、何が自動で変更されたかは必ず見えるようにする。

合言葉:

> 自動で病態適合へ寄せる。でも、何を寄せたかは必ず見える。

## スコープ

対象は栄養設計上の実需要が高い項目に限定する。

優先して扱う:

- GIR
- 糖質量
- 脂質 g/kg/day
- 脂質 g/kg/h
- 総kcal
- AA g/kg
- NPC/N
- 総液量
- Na / 食塩相当量
- K / P / Mg
- B1
- Mn / Cu / Zn / Se
- 加注薬の重複・不足・置換
- リフィーディング関連

当面扱わない:

- route制約
- 浸透圧制約
- 末梢投与可否

理由:

- 本アプリの主対象は、経管/経口摂取が進まずPN依存になり、CVまたはPICCが使われる患者である。
- 末梢投与制約は実運用で主要な意思決定点になりにくい。
- route/osmolarityを全製剤へ登録するとマスタ管理工数が増え、UXと保守性が悪化する。
- まずは実際に問題になりやすい糖負荷・電解質・微量元素・加注・水分・蛋白/熱量へ集中する。

## 基本アーキテクチャ

処理は以下の一方向フローにする。

```text
PatientCase + Regimen/Plan
  -> EvalContext
  -> evaluate()
  -> NutritionAlert[]
  -> RepairAction registry
  -> candidate plans
  -> evaluate(candidate)
  -> feasible filter
  -> softScore ranking
  -> RepairedPlan
  -> UI表示 / 採用
```

既存の `lib/clinical/alerts.dart` は評価器として使う。repair loopは評価器の中には入れない。

責務:

- `alerts.dart`: 評価だけ。処方を変更しない。
- `constraints.dart`: 通常患者の制約とスコア重み。
- `conditions.dart`: 病態タグによる制約modifier。
- `repair_actions.dart`（新規想定）: alert codeごとの修復操作。
- `repair_engine.dart`（新規想定）: 候補生成、評価、採点、ランキング。
- UI: 自動補正済みバッジ、差分説明、採用/却下。

## EvalContext

Repair loop前に最優先で太くする。

必須入力:

```dart
class EvalContext {
  double weightKg;
  Set<String> conditionTags;

  double targetKcal;
  double proteinGoalPerKg;

  double totalKcal;
  double totalProteinG;
  double totalVolumeMl;

  double? ivGlucoseGramPerDay;
  double? lipidGramPerDay;
  double lipidHours;
  double? npcN;

  double? naMEq;
  double? kMEq;
  double? pMmol;
  double? mgMEq;

  double? vitaminB1Mg;
  double? mnUmol;
  double? cuUmol;
  double? znUmol;
  double? seUmol;

  bool hasGlucoseLoad;
  bool refeedingRisk;
  bool fastingDaysGE5;

  List<EvalProduct> products;
  double changeMagnitude;
}
```

既存 `EvalContext` に存在しない項目は段階的に追加する。

重要:

- `ivGlucoseGramPerDay` はGIR評価の主役なので最優先で接続する。
- `naMEq` は食塩アラート/repairの主役なので次点。
- 加注薬は必ず `products` と微量栄養素合算へ入れる。
- dataMissingは初期実装ではinfoでよいが、repair loop画面では「未評価」も小さく表示する。

## 通常患者ベースライン

通常成人ICU患者の標準制約。病態タグがない場合はこれを使う。

### Hard constraints

候補の足切り。1つでもerrorなら採用不可。

- GIR > 5 mg/kg/min
- 脂質 > 1.5 g/kg/day
- 脂質速度 > 0.125 g/kg/h
- 総液量 > 80 ml/kg/day（通常患者、CRRT等では緩和）
- 胆汁うっ滞/胆道閉塞 + Mn含有製剤
- 明確な禁忌加注

### Soft targets

候補比較のスコアに使う。warningとして表示する。

- kcal: 目標 ±10-15%
- AA: 目標 g/kg ±15%
- NPC/N: 病態目標 ±15%
- 脂質: 1.0 g/kg/day超でwarning、1.5超でerror
- 食塩相当量:
  - 7 g/day以下: no alert
  - 7-9.6 g/day: yellow
  - 9.6 g/day以上: red
- Na/K/P/Mg: 今後、施設/病態基準で追加
- B1: 糖負荷 + 絶食/低栄養で不足warning
- 微量元素: 重複・欠乏・病態別置換

## 病態modifier

通常患者制約に対して、病態タグで上書き/追加する。

### 耐糖能異常

- GIR上限: 5 -> 4 mg/kg/min
- 急な糖質増量にwarning
- repair:
  - 糖液を減らす
  - kcal不足を脂質/AA側で一部補う
  - それでも不可ならkcal達成率を下げる

### 呼吸器疾患 / 高CO2貯留

- 糖質過多に厳しくする
- GIR上限: 4 mg/kg/min
- 脂質は相対的に許容。ただし脂質速度上限は維持
- repair:
  - 糖質を下げる
  - 脂質を許容範囲で補う

### 腎不全 保存期

- AA上限: 0.6-0.8 g/kg/day目安
- K/P/水分負荷に厳しくする
- repair:
  - AA過量を下げる
  - K/P含有が高い加注を避ける
  - 水分過多なら濃縮方向へ寄せる

### 透析 / CRRT

- AA不足に厳しくする
- K/P/Mg/B1/Se/Znは喪失側に寄せる
- CRRTでは総液量上限を緩和/無効化してよい
- repair:
  - AAを確保
  - B1/Se/Zn補充
  - K/P/Mg不足を補正

### 肝不全 / 胆汁うっ滞

- Mn/Cu過剰に厳しくする
- 胆汁うっ滞/胆道閉塞ではMn含有製剤をerror
- repair:
  - 標準微量元素 -> Mn-freeへ置換
  - Cuはゼロにせず、減量/モニタ前提の表示

### 重症・周術期・高侵襲

- AA不足に厳しくする
- 急性期overfeedingに厳しくする
- repair:
  - kcalは段階増量
  - AAは確保
  - 糖負荷が高ければ糖を下げる

### 褥瘡・創傷治癒・サルコペニア

- AA不足に厳しくする
- Zn/Se/Arg/HMB等の不足サジェスト
- repair:
  - AAを確保
  - Zn/Se補充候補
  - 栄養サポート食品が採用済みなら候補に浮かせる

### 消化吸収障害・短腸・下痢 / 高排出消化管瘻

- Zn/Mg/K/Na/水分喪失に注意
- repair:
  - Zn追加
  - Mg/K/Na補正
  - 消化態/成分栄養を候補に寄せる

### アルコール多飲・低栄養 / Refeeding

- B1不足を強く見る
- 糖負荷前〜同時のB1投与を要求
- repair:
  - B1 100-300 mg/dayを追加
  - 初期kcal cap
  - P/K/Mg補正

## Alert code と RepairAction

repairはアラートコードから逆引きする。無差別探索しない。

想定インターフェース:

```dart
abstract class RepairAction {
  String get id;
  String get label;
  bool canApply(PlanState plan, EvalContext ctx, NutritionAlert alert);
  RepairResult apply(PlanState plan, EvalContext ctx, NutritionAlert alert);
}

class RepairResult {
  PlanState plan;
  List<RepairChange> changes;
}

class RepairChange {
  String code;
  String label;
  String reason;
  String beforeText;
  String afterText;
  RepairChangeKind kind; // add/remove/replace/increase/decrease/cap
  bool autoApplied;
}
```

アクションレジストリ:

```dart
final actionsByAlertCode = <String, List<RepairAction>>{
  'gir_limit': [
    ReduceIvGlucoseAction(),
    ShiftKcalToLipidAction(),
    LowerKcalAchievementAction(),
  ],
  'lipid_day_limit': [
    ReduceLipidAction(),
    ShiftKcalToGlucoseOrAaAction(),
  ],
  'lipid_rate_limit': [
    ExtendLipidHoursAction(),
    ReduceLipidAction(),
  ],
  'na_excess': [
    ReduceNaAdditiveAction(),
    ReplaceNaRichAdditiveAction(),
  ],
  'thiamine_needed': [
    AddVitaminB1Action(),
  ],
  'contraindicated_product': [
    ReplaceMnTraceToMnFreeAction(),
  ],
  'protein_balance': [
    AdjustAminoAcidAction(),
    AdjustNpcNAction(),
  ],
};
```

## Repair loop

### 基本方針

- 1回のrepairで全てを解こうとしない。
- まず1-step repair、必要なら2-stepまで。
- それ以上の深い探索は初期実装では禁止。
- 候補数は最大10-20程度に制限する。
- 最終採用候補は最大3案表示する。

### 疑似コード

```dart
RepairOutcome repair(PlanState original, PatientCase patient) {
  final baseCtx = buildEvalContext(original, patient);
  final baseAlerts = evaluate(baseCtx, constraintsFor(patient));

  var candidates = <RepairCandidate>[
    RepairCandidate(plan: original, changes: [], alerts: baseAlerts),
  ];

  for (final alert in baseAlerts) {
    final actions = actionsByAlertCode[alert.code] ?? const [];
    for (final action in actions) {
      if (!action.canApply(original, baseCtx, alert)) continue;
      final result = action.apply(original, baseCtx, alert);
      final ctx = buildEvalContext(result.plan, patient);
      final alerts = evaluate(ctx, constraintsFor(patient));
      candidates.add(RepairCandidate(
        plan: result.plan,
        changes: result.changes,
        alerts: alerts,
        score: softScore(ctx, constraints, weights),
      ));
    }
  }

  final feasible = candidates.where((c) => isFeasible(c.alerts)).toList();
  feasible.sortBy(scoreThenChangeMagnitude);
  return RepairOutcome(
    original: original,
    recommended: feasible.take(3).toList(),
    unrepairedReasons: collectUnresolved(baseAlerts, feasible),
  );
}
```

## 自動適用のルール

ユーザー体験としては、初期表示を補正済み案にしてよい。

ただし、元入力は破壊しない。

```text
raw plan
  -> repaired recommended plan
  -> UI shows repaired plan by default
  -> user can inspect changes
  -> user can adopt / override / reset to raw
```

禁止:

- ユーザーの入力値を無説明に上書き保存する。
- 自動repairを永続化する前に差分説明を消す。
- 病態衝突を一意に断定して強制修正する。

許可:

- 表示上の初期案をrepaired planにする。
- 低リスク補充（B1追加、Mn-free置換など）を自動適用済みに見せる。
- ただしバッジと差分説明を表示する。

## バッジ仕様

自動補正が入った箇所には小さなバッジを表示する。

### バッジ種別

| 種別 | 表示 | 色 | 例 |
|---|---|---|---|
| 自動補正 | 自動補正 | indigo | GIR超過のため糖液減量 |
| 病態タグ由来 | 病態タグ | teal | 胆汁うっ滞によりMn-free選択 |
| 安全補充 | 補充 | green | 糖負荷前B1追加 |
| 置換 | 置換 | amber | 標準微量元素 -> Mn-free |
| 残存警告 | 未解決 | red/orange | Na過多が残存 |
| 医師判断 | 医師判断 | gray | 腎不全+重症で蛋白目標衝突 |

### 表示位置

- 患者カード下: 全体の自動補正サマリー
- 処方カードの各製剤行: 該当製剤のバッジ
- 自動計算のDay詳細: その日の補正理由
- リスクと補充サジェスト: 展開時に補正内容を列挙

### 文言例

- `自動補正: GIR超過のため70%Gluを減量`
- `病態タグ: 胆汁うっ滞のためMn-free微量元素へ置換`
- `補充: 絶食5日以上+糖負荷のためB1を追加`
- `未解決: Na 9.8g相当。低Na案なし`
- `医師判断: 腎保存期と重症で蛋白目標が衝突`

## 差分説明仕様

repair前後の差分を必ず表示する。

### 差分モデル

```dart
class RepairDiff {
  String title;
  List<RepairChange> changes;
  List<NutritionAlert> beforeAlerts;
  List<NutritionAlert> afterAlerts;
  double beforeScore;
  double afterScore;
}
```

### 差分表示

患者カードまたはサマリーに折りたたみパネルを置く。

タイトル:

```text
自動補正 3件
```

本文:

```text
1. 糖液を減量
   理由: GIR 5.8 > 4.0 mg/kg/min（耐糖能異常）
   変更: 70%Glu 300ml -> 200ml

2. 脂質を追加
   理由: 糖液減量後のkcal不足を補正
   変更: イントラリポス20% 0ml -> 100ml

3. B1を追加
   理由: 絶食5日以上 + 糖負荷
   変更: ビタミンB1 100mg/day 追加
```

残存警告:

```text
残存: Na 9.8g相当（低Na候補なし）
```

## UIフロー

### 個別選択

1. ユーザーが製剤/加注/食事を選ぶ。
2. `rawPlan` を作る。
3. `evaluate(rawPlan)` で警告表示。
4. repair可能な警告があれば `repairedPlan` を生成。
5. 画面上は `repairedPlan` を推奨として表示。
6. 差分パネルで変更内容を見せる。
7. ユーザーが「この補正を採用」した時だけ保存状態へ反映。

### ゼロmenu

1. NPC/N・脂質g/kg・目標kcalから初期案。
2. 病態タグでNPC/N・脂質・糖質制限を自動設定。
3. GIR/脂質/Na/加注不足を評価。
4. repair actionで糖液・脂質・加注を補正。
5. 製剤構成にバッジ表示。

### 自動計算

1. Dayごとに初期plan。
2. Dayごとにevaluate。
3. Dayごとにrepair。
4. グラフとDay詳細に補正バッジ。
5. 「リスクと補充サジェスト」にDayごとの補正理由を表示。

## Score設計

初期の `ScoreWeights.standard()` は単純でよいが、将来的にはalert code別重みにする。

問題:

- warning 1件 = 1000点は強すぎる可能性がある。
- `kcal_dev` と `na_excess` と `protein_balance` を同じ重みで扱うのは粗い。

改善案:

```dart
final alertWeights = {
  'gir_limit': 10000, // 本来error
  'contraindicated_product': 10000,
  'na_excess': 1500,
  'protein_balance': 1200,
  'kcal_dev': 800,
  'lipid_day_target': 900,
  'thiamine_needed': 2000,
};
```

採点順:

1. Hard errorがない
2. 残存warningが少ない
3. alert code別重みが低い
4. kcal/protein達成率が良い
5. 変更幅が小さい
6. 製剤数が少ない
7. 総液量が少ない

## 病態衝突

自動で一意に決めない。

例:

- 腎保存期 + 重症
- 肝性脳症 + 褥瘡
- 耐糖能異常 + kcal不足

扱い:

- 自動修正ではなく「医師判断」バッジ。
- `conflict_alert` warningを出す。
- repair候補は保守的案と攻める案を並べる。

表示例:

```text
医師判断: 腎保存期(蛋白0.6-0.8)と重症(1.2-2.0)で蛋白目標が衝突。
自動で蛋白量を決めず、現在値を維持しています。
```

## 実装フェーズ

### Phase 1: EvalContext完全接続

- GIR
- Na/食塩
- K/P/Mg
- B1
- Mn/Cu/Zn/Se
- 加注薬
- DayごとのEvalContext

完了条件:

- 主要アラートが `dataMissing` にならず実値で評価される。
- 個別選択/ゼロmenu/自動計算で同じ評価器を使える。

### Phase 2: Modifier engine

- 通常制約 + 病態modifier
- 糖質制限
- 腎保存期/透析/CRRT
- 肝不全/胆汁うっ滞
- Refeeding
- GI loss

完了条件:

- 同じ処方でも病態タグでalertが変わる。

### Phase 3: RepairAction registry

- `gir_limit`
- `lipid_day_limit`
- `lipid_rate_limit`
- `na_excess`
- `thiamine_needed`
- `contraindicated_product`
- `protein_balance`

完了条件:

- alert codeから修復操作が逆引きされる。

### Phase 4: Candidate generation / ranking

- 1-step repair
- 2-step repair
- feasible filter
- softScore ranking
- 最大3案

完了条件:

- 元処方、補正案1-3、残存警告が比較できる。

### Phase 5: UI

- 自動補正バッジ
- 差分説明
- 採用/却下
- 元入力へ戻す
- Day詳細で補正理由表示

完了条件:

- ユーザーが「何が勝手に変わったか」を理解できる。

## テスト方針

### Unit test

- `evaluate()`
- `constraintsFor(conditionTags)`
- `resolveCoeff()`
- 各 `RepairAction.canApply/apply`
- `repair()` ranking

### Scenario test

1. 耐糖能異常 + GIR超過
   - 糖液減量
   - kcal不足補填
   - 差分説明

2. 胆汁うっ滞 + 標準微量元素
   - Mn-freeへ置換
   - contraindicated_product消失

3. 絶食5日以上 + 糖負荷 + B1なし
   - B1追加
   - thiamine alert消失

4. Na過多
   - Na加注減量/除外
   - 残存時は未解決表示

5. 腎保存期 + 重症
   - 自動決定しない
   - 医師判断バッジ

6. CRRT
   - fluid hard cap無効
   - B1/Se/Zn補充サジェスト

### UI test

- 自動補正バッジが出る。
- 差分説明を展開できる。
- 採用ボタンで保存状態へ反映。
- 元入力へ戻せる。

## 非目標

初期repair loopでは以下をしない。

- 検査値を用いた自動判断
- route/osmolarity制約
- 深い組み合わせ最適化
- ユーザー保存値の無断上書き
- 複雑な施設別プロトコル
- 全製剤の最大投与量マスタ完備

## Claude実装メモ

最初にやるべきこと:

1. `EvalContext` アダプタを太くする。
2. `RepairAction` と `RepairResult` の型だけ作る。
3. `thiamine_needed` と `contraindicated_product` から始める。

理由:

- B1追加とMn-free置換は、変更が小さく、説明しやすく、臨床的にもrepairの価値が見えやすい。
- GIRや糖液/脂質のrepairは計算影響が大きいので次フェーズに回す。

避けること:

- いきなり万能repair loopを作らない。
- softScoreだけでブラックボックスに選ばせない。
- 病態衝突を勝手に解釈しない。

