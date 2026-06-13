# Codex ⇄ Claude 協調ラウンド1 — 合意とハンドオフ

ICU栄養 auto-design リファクタ（handoff: ICU_Nutrition_AutoDesign_Comprehensive_Handoff.md）の
相互レビュー結果と役割分担。**自分の担当ファイルだけを編集**し衝突を避ける。

## 担当境界（最新・特性ベース＋計算契約優先）
観察した強み＋実データで、所有範囲を「ファイル」ではなく「壊れると危険な契約」基準に再定義する。
- **Codex（決定論的ロジック・データ契約・回帰テスト）**:
  `lib/clinical/**`、`auto_design.dart` の計算結線、`PatientCase` の計算に影響するフィールド契約、
  serialization、repair loop、アラート判定、全テスト。UI文言が「計算に使う」と主張する入力は、
  Codexが実計算とテストまで責任を持つ。
- **Claude（周辺UX・説明文・表示編集・レビュー）**:
  `cases_page`/`builder_page`/`note_page`/`master_page` の入力体験、説明文、表面レイアウト、
  ユーザー向けノート、継続QA、Codex成果のレビュー。計算効果をまだ持たないUIは
  「参考表示」と明示するか、Codex側の計算契約が入るまで文言を弱める。
- **共有ハンドシェイク**:
  Claudeが新入力を追加して「栄養計算の参照に使用」と書く場合、Codex側で
  `NutritionCalculator`/engine/テストに同じ契約を入れる。逆にCodexが新しい clinical contract を作ったら、
  Claudeが表示・説明・ヘルプ文言をその契約へ合わせる。
- **現在の適用例**:
  `usualWeightKg` は Codex契約に昇格。AKI/溢水系で現体重が平時体重より明らかに重い場合だけ、
  エネルギー・タンパク計算に平時/入院前体重を渡す。`fluid_overload`/`edema` は
  ConditionCatalogに未登録なので、タグ分類と文言整理はClaudeレビュー対象。
- **衝突回避の鉄則**:
  同じ契約を二重実装しない。`lib/clinical/**` の計算規則と `auto_design.dart` の計算結線はCodexが主導し、
  ClaudeはUX差分・レビュー・docsで貢献する。

### 経緯: R2=auto_design Codex継続 / R3初稿=Claude移管案 → codexの実稼働(+1177行)を確認しR3で再びCodexへ確定。

### 旧・担当境界（R1時点・参考）
- Claude: clinical の純モジュール群 ＋ UI結線 / Codex: auto_design_engine.dart

## ラウンド1で合意した決定

### 1. 微量栄養素の重複 → Claudeの純モジュールをcanonicalに
- Codex提案を採用: `micronutrient_obligations.dart` を唯一のルールロジックとし、
  engine 側がそれを `StructuredNutritionAlert`/`ClinicalObligation` に**ラップ**する。
- **Claude完了**: `assessMaintenanceCoverage` をビタミン/trace分離に修正済み。
  - 旧 `pnContainsMviTrace` → `pnContainsMvi` + `pnContainsTrace`
  - 戻り値 `MaintenanceCoverage{ vitamins, traceElements, reason, sourceTier }`（`band` getterは悪い方）
  - EN green閾値は `fullEnFractionForGreen`（既定1.0）で可変。engineが0.8運用なら引数で渡せる。
- **Codex TODO**: `MicronutrientMaintenanceEngine`(761-843) を削除し、上記 pure 関数を呼んで
  `MicronutrientCoverageResult`/alert に変換するアダプタへ。`MicronutrientAdditionalObligationEngine`/
  `MicronutrientToxicityGuard`(891-1028) も `additionalMicronutrientObligations`/`manganeseGuard` を
  呼ぶ薄いラッパへ寄せる（重複ロジック排除）。

### 2. Refeedingティアの不一致（4段 vs 3段）
- Codex指摘に同意: `moderate→high` の暗黙マップは禁止（cap 15→10で臨床差を隠す）。
- 現状 `refeedingTier()` は `moderate` を**生成しない**（NICEロジックは none/high/extreme のみ）。
- **決定（短期）**: shared `RefeedingTier`(3段) を canonical 継続。engine-local `RefeedingRiskTier`(375) は
  **削除**し、`refeeding.dart` の `RefeedingTier` を import して使用。
- **将来 moderate が必要になったら**: Claudeが `refeeding.dart` を正式4段拡張
  （`RefeedingTier`＋`refeedingKcalPerKgRamp`＋`refeeding_bundle`＋UI＋テスト）。
  その際の moderate ランプ案を Codex から提示してほしい（handoff §10 は moderate のcap値未定義）。
- **Codex TODO**: engine の refeeding cap 重複(533) を `refeeding.dart` の
  `refeedingCapKcalPerKg(tier, feedingDay, fullKcalPerKg)` 再利用に置換（二重計上回避の単一台帳）。

### 3. UI結線の単一入口（Codex TODO）
engine は部品（`PhaseTemplateEngine.buildTimeline` / `ClinicalEventOverlayAdapter.derive` /
`EnergyTargetBuilder.build` …）止まりで、UI が叩く入口が無い。以下を追加してほしい:

```dart
class AutoDesignInput { /* weight, conditionTags, events, en/oral start days,
  rampDays, krtFluidCalories…（既存 AutoDesignInline の設定値に対応） */ }

class AutoDesignResult {
  final List<PhaseTemplateDay> templateDays;   // 固定テンプレ（不変）
  final List<EventDerivedDay> derivedDays;     // イベント適用後（§2/§18）
  final List<EnergyTargetBand> energyTargets;  // 日次エネルギー目標バンド（codex R1(b)追加）
  final List<ProteinTargetBand> proteinTargets;// 日次タンパク目標バンド（codex R1(b)追加）
  final List<StructuredNutritionAlert> alerts; // 構造化アラート（§22）
  final List<ClinicalObligation> obligations;  // 微量栄養素/refeeding義務
  final List<String> sourceBadges;             // §23.4
}
// codex R1フィードバック(b): energy/protein を façade に含めることで
// UI が kcal/タンパク方針を二重実装せずに済む（policyはengine集中）。

class AutoDesignEngine {
  AutoDesignResult build(AutoDesignInput input); // timeline全体を解決する façade
}
```
- `ClinicalEventOverlayAdapter.derive` は day-scoped なので、全Dayを束ねる timeline façade を内部に。
- Claudeはこの `AutoDesignResult` を `auto_design.dart` に結線（既存の固定テンプレ/グラフは保持し、
  derived plan・構造化アラート・ソースバッジ・template vs derived 表示を追加）。

## Claude側の確定事項（参考）
- `event_overlay.dart` のバグ修正済み（codexレビュー反映）:
  孤立 `rrt_stop` はRRT捏造しない / CRRT継続日数は連続run開始日起算 / 次モダリティ不明時のレビューノート。
- engine の `_activeRrtDurationDays`(254) は最新startを使っており概ね妥当。ただし
  「停止→同一モダリティ再開」を跨ぐと連続runとして数える点は event_overlay と挙動を揃えると安全。

## ラウンド1 収束ステータス
- Claude実施済み: 微量栄養素API分離 / event_overlayバグ修正 / 本文書。`flutter test` 299緑・analyze 0。
- Codex確認済み(read-only): 分割API異議なし / `AutoDesignResult` に energy・protein 目標を追加 / TODOは
  engine＋テストのみで実装可（Claudeファイル不変）。→ **計画は両者合意（ratified）**。

## ラウンド2 レビュー（Claude → Codex）— auto_design.dart のイベント機能
codexが auto_design.dart に実装済みの臨床イベント機能（`_clinicalEvents`＋serialization＋
`_derived*`＋編集ダイアログ `_showClinicalEventEditor`）をレビュー。**303テスト緑・analyze 0・web build OK**。
良好。以下は次の改善メモ（Claudeは衝突回避で auto_design.dart を編集せず、メモのみ）:
1. `_eventHardKcalCap`(≈929): refeeding低Pの48h制限で `weightKg*10`(=10 kcal/kg)をハードコード。
   `refeedingCapKcalPerKg` 等と整合させ、出典/値の根拠をコメント化すると一貫。
2. `_derivedProteinTarget`(≈918): RRTバンドのみ適用し、非RRTの protein effect(renalRestrict/reviewOnly)は無視。
   review-onlyなので実害は小だが、overlay.protein を参照して説明文に反映すると§7と整合。
3. 編集ダイアログの保存後に `setState`＋`_saveConfig()`（必要なら `_rebuildDays()`）が走り、
   カード/チャート/derivedが即更新されることを確認（特に削除時）。
4. 残りの可視化(§23): イベント有効日のチャート**シェーディング帯**(§23.3)・**ソースバッジ**(§23.4)・
   **template vs derived パネル**(§23.2)。未実装なら次段で（auto_design.dartはcodec担当のまま or Claudeへ移管）。
5. Claude側 `event_overlay.dart` は孤立rrt_stop非捏造/CRRT連続run起算/unknown停止レビューを修正済み。
   engineの `_activeRrtDurationDays` は最新start起算で独立・整合。

## ラウンド2 Claude実行（衝突ゼロ・別ファイル）
- `lib/pages/note_page.dart` の「計算アルゴリズム/仕様」に **◇ 臨床イベントオーバーレイ** 解説を追加
  （種別・効果・優先度・RRTバンド・source_tier）。auto_design.dart には触れていない。

## ラウンド3 レビュー（Claude → Codex の全範囲）
対象: `auto_design_engine.dart` / `clinical_event.dart`(serialization) / `auto_design.dart`(イベント機能)。
ベースライン: **303テスト緑 / analyze 0 / web build OK**。

### 良い点
- engine: §1パイプライン層構成が明快。template/derived保持(EventDerivedDay)、band scoring(§9)、
  product filter(§19/20)、explanation(§23.2/23.4) が仕様準拠。event_overlay/clinical_event を正しく再利用。
- serialization: `ClinicalEvent.toMap/fromMap` 堅牢（fallback・未知フィールド許容）。テストが open-ended/
  params型/sourceTier round-trip/legacy許容まで網羅し高品質。
- auto_design イベント機能: 編集ダイアログ(§23.1)に edit/delete 完備。`_derived*` がカード/チャート両経路の
  build に結線。保存/削除とも `setState→_rebuildDays→_saveConfig→onSettingsChanged` で derived/チャートが即更新。

### 要対応（優先度順）
1. **【重要】engine が本番UIで休眠**: `auto_design.dart` は自前の軽量 `_derived*`/`_overlayForDay` で derived を作っており、
   engine の `EnergyTargetBuilder`/`ProteinTargetBuilder`/`MicronutrientMaintenanceEngine`/`BandBasedOptimizer` を
   **実際には使っていない**。リッチな band ロジックが production で死蔵。→ R1合意の `AutoDesignEngine.build` façade を作り、
   auto_design.dart がそれを消費する形に寄せるのが本筋（UI結線はcodex担当）。
2. **R1 dedup TODO 未適用**: engine に `RefeedingRiskTier`(375) 残存（shared `RefeedingTier`へ）/
   微量栄養素 `MicronutrientMaintenanceEngine`等(761-1028) が Claude の `micronutrient_obligations.dart` と重複
   （wrapへ）/ `_refeedingCapKcalPerKg`(533) が `refeedingCapKcalPerKg` と重複。
3. **シリアライザ二重**: `auto_design.dart` の `_clinicalEventToMap`/`_clinicalEventFromMap` が
   `ClinicalEvent.toMap/fromMap` と重複（drift要因。例: 前者は `parameters` を直接代入、後者はコピー）。
   → auto_design.dart は `ClinicalEvent.toMap()/fromMap()` を使うのが安全。
4. `_eventHardKcalCap`(≈929): refeeding低Pの48h制限が `weightKg*10` ハードコード。命名定数/出典コメント化を。
5. `_derivedProteinTarget`(≈918): RRTバンド中央値のみ。非RRTの protein effect(renalRestrict/reviewOnly) は未適用（review-only想定なら可）。

### 結論
イベント機能(入力→derived→表示)は**実用上完成・整合**。次の山は「engineを本番に通す」façade化(要対応#1)＋dedup(#2)。
これらは全て `lib/clinical/` ＋ `auto_design.dart`＝**Codex担当**。Claudeは façade完成後に `AutoDesignResult` 消費の
UIブラッシュアップ(§23.2/23.3 シェーディング等)を、移管時に担当可能。

## ラウンド3 Claude実行（衝突ゼロ・別ファイル）
- §8 参照体重: `PatientCase.usualWeightKg`(model) ＋ 編集ダイアログ入力(cases_page) ＋ builder ガイダンス表示。
  codex の `ClinicalStateNormalizer`(usualOrPrehospitalWeightKg を消費) と整合する入力を供給。auto_design.dart 不変。

## ラウンド4 レビュー（Claude → Codex 完了バッチ）
QA: **310テスト緑 / analyze エラー0・警告0 / web build OK**。codexは大量バッチを高品質で完了。

### 適用確認（R1合意 → 実装済み）✅
- `RefeedingRiskTier` 除去 → shared `RefeedingTier` ＋ `refeedingCapKcalPerKg`（cap dedup 完了）。
- **façade 追加**: `AutoDesignEngine.build(AutoDesignInput)→AutoDesignResult`（**`energyTargets`/`proteinTargets` 含む**＝R1(b)反映）。
  §18 の順序（template→overlay→energy→protein→micro→obligations→alerts）を忠実に実装。
- 微量栄養素 dedup: 旧 `MicronutrientMaintenanceEngine.assess` が私の `assessMaintenanceCoverage`
  （`fullEnFractionForGreen:0.8` ＝合意通り）を **wrap** する薄いアダプタ化。
- **§8 参照体重**: `NutritionCalculator.referenceWeightKg()` を targetEnergy/targetProtein に結線し
  浮腫/AKI/溢水＋(実−平時>1kg)で平時体重を**自動採用**。`fluid_overload`/`edema` タグ追加。
  → Claudeの `PatientCase.usualWeightKg`＋入力UI と**重複でなく補完統合**。テストも追加。

### 残課題（優先度順）
1. **【最重要】engine が本番UIで依然休眠**: `auto_design.dart` は `AutoDesignEngine.build` を**呼んでいない**
   （自前の `_derived*`/`_overlayForDay` のまま）。→ façadeのリッチな band目標/構造化アラート/ソースバッジ/obligation が
   **ユーザーに出ていない**。façade完成済みなので、次は auto_design.dart で `AutoDesignResult` を消費するのが本筋（codex担当）。
2. シリアライザ二重（auto_design `_clinicalEvent*Map` vs `ClinicalEvent.toMap/fromMap`）未解消（drift要因）。
3. §8副作用: `EnergyResult.actualWeightKg` が `referenceWeightKg` を受けるため真の実体重と乖離しうる。
   builderの「実」表示が平時体重を指す可能性（showWで概ね隠れるが）。EnergyResultに「真実体重」と「参照体重」を
   両方持たせると表示が明確。**Claudeは builder ガイダンスを「自動採用中」表記へ修正済み**（自分レーン）。
4. §23 可視化（template vs derived パネル/チャートシェーディング/ソースバッジ）はまだ軽い。

### 総括
ロジック・dedup・façade・§8 は高品質で収束。**ユーザー価値の最大要素は #1「façade を auto_design.dart に結線して engine を本番に通す」**。

## ラウンド4 Claude実行（自レーン）
- builder §8 ガイダンスを codex の自動適用に整合（「推奨」→「自動採用中」、条件を `referenceWeightKg` と一致）。

## ラウンド5 方針決定（codex協議）＋ 実装状況
ユーザー指示でレビュー#1〜#4の方針を codex と協議し確定:
- **#1 engine役割 → 案(b)採用**: `auto_design.dart` の軽量オーバーレイ(`_derived*`/`_overlayForDay`)＋既存solverを
  **本番のまま維持**（solver drift回避＝ユーザー同意の「auto_designベース＋clinical_event上乗せ」設計）。
  engineは **メタデータ専用のキャッシュ読み取りモデル** として additive に使う:
  - `AutoDesignResult` を「設定/イベント/患者」変化で無効化する memoized getter で1回だけ構築（毎helper呼び出ししない）。
  - surface: `alerts`(day別)/`energyTargets[i].classify(plan.totalKcal)`/
    `proteinTargets[i].classify(plan.totalProteinG / referenceWeightKg)`/`sourceBadges`/(後で)`obligations`。
- **#2 シリアライザ二重**: オーバーレイ設計上は許容。dedup は任意（低優先）。
- **#3 EnergyResult 両体重 → 実装済(Claude)**: `actualWeightKg`=真の実体重 / `referenceWeightKg`=計算参照体重。
  `targetEnergy(trueActualWeightKg:)` 追加・`targetEnergyResult` で `item.weightKg` を真実体重として渡す。310緑。
  ※ codex指摘（actualWeightKg が参照体重を指す問題）はこれで解消。proteinバンド分母は `referenceWeightKg` を使うこと。
- **#4 §23可視化 → 軽量方針**:
  1. チャート: バー/線の下に決定論的 `Stack` シェード層（1日1セル）。イベント有効日を優先度で淡色化
     （RRT > route/EN hold > energy/protein/fluid）。日付軸に小マーカー、可視数上限＋`+n`。
  2. カード: route/dose/meal/target が変わった日だけ `Template → Derived` ピル＋詳細はダイアログで before/after。
  3. ソースバッジ: source tier のソート済みチップ（自由文でなく）。

### 実装状況（R5時点）
- **済(codex)**: カードのイベントバッジ＋ソースバッジ(§23.4)＋`Template → Derived` パネル(§23.2)
  （`_eventBadgesForDay`/`_hasTemplateDerivedRouteDelta`）。
- **済(Claude)**: #3 EnergyResult 両体重 ＋ builder「実」表示の整合。
- **残(codex担当・auto_design.dart/lib/clinical)**: #1(b) engine read-model 結線（band分類/alerts/obligationsのsurface）＋
  #4-1 チャートシェード層。Claudeは衝突回避で auto_design.dart は編集せず、QA/レビューで支援。

## 次ラウンドの進め方
1. Codex: 上記 §1〜§3 の TODO を `auto_design_engine.dart` に実装＋テスト更新。
2. Claude: `AutoDesignEngine.build` が出たら `auto_design.dart` へ結線（Phase 2）。
3. 双方 `dart analyze` 0エラー / `flutter test` 全緑を維持。コミット・デプロイはユーザー指示時のみ。

## R6実装済み
- Codex: `auto_design.dart` に engine read-model キャッシュを結線し、band dots / day別 structured alerts / source badge legend / chart event shade・markers を additive に表示。
