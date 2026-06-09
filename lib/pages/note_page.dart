part of '../main.dart';

class _NoteSection {
  final String category;
  final String title;
  final String body;
  final Color color;
  const _NoteSection({
    required this.category,
    required this.title,
    required this.body,
    required this.color,
  });
}

class NotePage extends StatefulWidget {
  const NotePage({super.key, required this.state});
  final AppState state;

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage>
    with SingleTickerProviderStateMixin {
  String _selected = 'すべて表示';
  static const _allLabel = 'すべて表示';
  // 本文パネル(ドラッグで上に展開。処方ビルダーのサマリと同仕様)
  static const double _panelMin = 200.0;
  double _panelHeight = 360.0;
  double _snapFrom = 360.0;
  double _snapToTarget = 360.0;
  late AnimationController _snapCtrl;
  final ScrollController _noteScroll = ScrollController();
  // mutable sections (starts with defaults, supports add/edit)
  late List<_NoteSection> _editableSections;

  static final _sections = <_NoteSection>[
    _NoteSection(
      category: 'つかいかた',
      title: 'できること / つかいかた',
      color: Color(0xFF4A90D9),
      body: '■ できること（めざすもの）\n①複数患者の栄養製剤の処方設計を同時に個別管理. 臨床ワークフローに近い処方設計ができる. \n②製剤マスタデータをアプリの中心に据え, 各施設での採用/非採用・ユーザーのお気に入りに合わせてカスタマイズ. 特殊病態には製品タグを付与し, 患者タグに応じてサジェスト. \n③複数製剤を組み合わせた合計(IN・熱量kcal・タンパクg・対目標比%・PFCバランス)を計算し, どの製剤を何本処方すべきか, 電子カルテのオーダー/記載に向けたサマリーを出力. \n④ENができず長期PNになる場合の逆引き計算(ゼロmenu)もほぼ自動化. \n⑤微量栄養素はアラートを介して投与漏れ/過量投与を可視化し予防. \n⑥絶食〜栄養療法開始〜経腸栄養開始〜経口リハ開始までを統合して管理/設計. \n\n★未実装の機能\n・投与履歴\n・アラート機能を独立させ, アラートを出さない処方へ自動修正する機能\n・検査値との連携(腎機能・肝機能・血糖・電解質 ほか)\n\n■ つかいかた\nICUの栄養処方を「個別計算・逆引き・自動設計」の3方式で支援し, トレンドとリスクを可視化する. \n\n①TOP画面（ベッド管理）\n・右上の「新規入室」から患者を登録(患者ID・ベッド・年齢・身長・体重・性別). カードをタップで再編集, 「計算」で計算画面へ, 「退室」で退室. \n・エネルギー式(簡易式kcal/kg〔既定〕/Harris-Benedict/Mifflin/間接熱量測定), 目標タンパク(g/kg), 絶食開始日, 病態タグを設定. 肥満(BMI≥30)は補正体重で自動補正. \n\n②計算画面（上中下の3エリア）\n(i) 患者カード(上)… 患者情報・目標を表示. 病態タグを付けると, 病態別の栄養設計の注意点・推奨が見られる. \n(ii) 個別選択 / ゼロmenu / 自動設計(中・3タブ)\n・「個別選択」… 各製剤の使用量に応じて栄養素を合算するモード(EN/TPN/PPN/食事/加注を横断集計). \n・「ゼロmenu」… 合計の熱量とタンパク・脂質投与量を設定したとき, 各成分製剤の使用量を逆引き計算するモード(ゼロから組むメニューなので便宜的にゼロmenuとした). \n・「自動設計」… 絶食〜経口リハ開始までのイベント時期を設定すると, 毎日の処方をフェーズに応じて自動設計し提案するモード(急性期20→EN導入25→回復30 kcal/kg, Refeedingは初期kcalを自動cap). \n(iii) サマリー / トレンド(下)\n・「サマリー」… 合計IN・総カロリー・タンパク投与量, 各製剤の必要処方数と流量指示を, カルテ記載/処方向けに表示. \n・「トレンド」… 日々のIN・タンパク投与量・カロリーやその内訳の変化を可視化. \n\n■ 製剤選択アルゴリズム（病態連動）\n・病態を選ぶと, 目標タンパクの推奨範囲, ゼロmenuのNPC/N比・脂質量を自動調整. \n・GIR(糖)>5(糖質制限病態は>4), 脂質>1.0–1.5 g/kg/dayでアラート. 自動設計は上限を超えない製剤選定. \n・微量栄養素は全ソース合算し耐容上限超過を警告. 胆汁うっ滞/肝障害はMn-free製剤へ切替提案, CRRTはSe/B1補充, 高排出消化管はZn補充, 糖負荷前のB1未投与はWernicke警告. \n・加注はベース製剤の内蔵成分と重複しないよう自動付替え(オールインワンTPNには加注しない 等). \n\n■ アイコン・色の意味\n・入室(緑・login) / 絶食開始(赤・no_meals) / 栄養開始(青・water_drop) / 経口リハ導入(食事・restaurant). \n・日付の丸囲み＝入室からday5の倍数. \n・グラフ棒: 下から PN→EN→食事 の積み上げ. 青の折れ線＝IN(水分量), IN最高点に水平線＋_ml表記. 赤線＝アミノ酸(AA). \n・グラフ下の「リスクと補充サジェスト」をタップで各種アラートを展開. ',
    ),
    _NoteSection(
      category: 'EN',
      title: '経腸栄養 (EN)',
      color: Color(0xFF2E7D32),
      body: '■ 開始のタイミング\n'
          '・入室48時間以内に開始し, 約1週間で目標量まで漸増する. ENはBacterial Translocationを抑制するため, 禁忌がなければ第一選択. \n'
          '・カテコラミンは用量依存性に腸管虚血を起こし, EN自体も腸管の酸素需要を増やす. ノルアドレナリン ≦0.1γ程度までテーパーできればEN開始を検討してよい(蠕動音・排便排ガスがなくても安全に開始できる). \n\n'
          '■ 速度調整と合併症\n'
          '・胃残量(GRV)<500 mLなら速度を上げる. GRVが多ければ蠕動促進薬や幽門後(空腸)投与で誤嚥を予防する. \n'
          '・下痢対策(優先順): ①とろみを付ける ②整腸剤・食物繊維の追加・浸透圧を等張に ③滴下速度を100 mL/h以下に. \n'
          '・ダンピング症候群: 空腸投与は10〜50 mL/hから開始し, 最大100 mL/hまで. \n\n'
          '■ Refeeding症候群\n'
          '・低栄養・絶食後の栄養再開でP・K・Mg・ビタミンB1が急減する. 補正しながら開始する(詳細はRefeedingの項). ',
    ),
    _NoteSection(
      category: 'EN',
      title: 'EN製剤の選択',
      color: Color(0xFF2E7D32),
      body: '■ 分類\n'
          '窒素源の形態により, 成分・消化態・半消化態に分類される. \n'
          '①成分栄養剤: 脂肪含有が極めて低い製剤があり, 2週間以上単独で使う場合は必須脂肪酸の補充が必要. \n'
          '②消化態栄養剤: ペプチドを含み, 成分栄養より吸収効率がよい. \n'
          '③半消化態栄養剤: バランス・栄養に優れ, 消化機能に問題がなければ第一選択. \n\n'
          '■ 選択の方法\n'
          '実効吸収面積の減少による吸収不良　：成分◯ 消化態△ 半消化態✕\n'
          '膵外分泌機能低下による消化不良　　：成分◯ 消化態◯ 半消化態△\n'
          '胆汁分泌障害による消化不良　　　　：成分◯ 消化態◯ 半消化態△\n'
          '食塊と消化液分泌のタイミング不調　：成分◯ 消化態△ 半消化態✕\n'
          '（◯重症例でも可 / △中等症まで / ✕不適）\n\n'
          '・消化吸収に問題があれば消化態, なければ半消化態を選ぶ. \n'
          '・個々の病態に応じて病態別栄養剤(*)も考慮する. \n'
          '・水分制限があれば2 kcal/mL前後の高濃度製剤を選ぶ. \n'
          '・1,000 kcal/日未満では微量元素・ビタミンが必要量に届かず, 長期化で欠乏症を来すため採血を見て補正する. \n\n'
          '＊病態別栄養剤: 糖尿病・肝疾患・腎疾患・呼吸不全・腫瘍・免疫調整に向けた製剤. ',
    ),
    _NoteSection(
      category: 'TPN',
      title: '中心静脈栄養 (TPN)',
      color: Color(0xFF1565C0),
      body: '・EN禁忌の患者は入室後7日目までにTPNまたはPPNを開始する. 栄養リスクが高い患者(NRS-2002 ≧5点, NUTRIC score ≧6点)は速やかに開始する. \n'
          '・PPNが7日以上に及ぶならPICC等のCVC留置を検討する. \n'
          '・腸管は最大級の免疫組織であり, 腸管を使わないPNは感染性合併症が増える. 一方で確実に投与できる分, 過剰栄養(=高血糖)になりやすく, これも感染を増やす. \n'
          '・重症患者では体タンパク崩壊などによる内因性エネルギー供給が多いため, これを見込んで投与設計する. ',
    ),
    _NoteSection(
      category: 'PPN',
      title: '末梢静脈栄養 (PPN)',
      color: Color(0xFF00838F),
      body: '・1,000 kcal/日程度まで投与でき, 2週間以内の短期間なら考慮する. \n'
          '・栄養障害が高度な場合は, 水分制限もできるTPNを選択する. \n'
          '・PPN単独での栄養状態の改善は難しいため, 経口やENと併用する. ',
    ),
    _NoteSection(
      category: 'エネルギー\n算出法',
      title: 'エネルギー算出法',
      color: Color(0xFFE67E22),
      body: '目標エネルギー量をどう決めるか――その考え方は歴史的に変遷してきた. \n\n'
          '■ Harris-Benedictの式 (1919)\n'
          '基礎代謝量(BEE)を体重・身長・年齢から推定する古典的回帰式. 健常者の実測がもとで, 臨床では Long(1979) が「BEE×活動係数×侵害(ストレス)係数」を掛けて必要量とする方法を広めた. \n'
          '　女性 BEE = 655 + 9.6×体重kg + 1.8×身長cm − 4.7×年齢\n'
          '　男性 BEE =  66 + 13.7×体重kg + 5.0×身長cm − 6.8×年齢\n'
          '　（※女性定数は 655. 665 は広く出回る誤記）\n'
          '長所: 個別の体格を反映. 短所: もとが健常者由来で, 重症・浮腫・肥満では系統的に過大評価しやすく, 係数の掛け算がさらに過剰栄養を招くとされ, ICUでは支持を失っていった. \n\n'
          '■ 簡易式 (25〜30 kcal/kg/day)\n'
          '「複雑な式でも実測より正確とは限らない」という反省から, 体重あたりの簡便な目安が普及. ASPEN/SCCM 2016・ESPEN 2019・JSPEN が採用. 肥満では低めの係数(11〜14 kcal/kg)や理想体重を用いる. \n'
          '長所: 簡便で過剰栄養を避けやすい. 短所: 体組成や代謝亢進の個別差は反映しにくい. \n\n'
          '■ 間接熱量測定 (indirect calorimetry)\n'
          '呼気のO₂消費・CO₂産生から実際の安静時エネルギー消費(REE)を測る, 現在のゴールドスタンダード. ESPEN/ASPEN は「可能なら測定」を推奨. 機器・人手・リーク等の制約で全例には使えないのが現実. \n\n'
          '■ いま何がエビデンスか\n'
          '・正確さ: 間接熱量測定 ＞ 体重あたり簡易式 ≧ 予測式(H-B等). 予測式は誤差が大きい. \n'
          '・急性期はむしろ不足を許容(permissive underfeeding)し過剰栄養を避けるのが主流(ESPEN). \n'
          '・どの式でも, 重症・浮腫・肥満では体重指標(実体重/理想体重/補正体重)の選択が結果を大きく左右する. \n\n'
          '本アプリでは患者情報編集で式を選べ(H-B / Mifflin-St Jeor / 簡易kcal·kg / 間接熱量測定), 補正体重は内部で自動採用する. ',
    ),
    _NoteSection(
      category: '活動係数\n侵害係数',
      title: '活動係数 AF',
      color: Color(0xFFE91E8C),
      body: '寝たきり体動なし            1.0 – 1.1\n'
          '寝たきり体動あり            1.1 – 1.2\n'
          'ベッド外活動 (車椅子)   1.2 – 1.3\n'
          'ベッド外活動 (歩行)       1.3 – 1.4\n'
          '積極的なリハビリ            1.5以上\n'
          '\n'
          '■背景\n'
          '・Harris-Benedictは基礎代謝量(BEE)の推定式. これに活動係数(AF)×侵害係数(SF)を掛けて'
          '1日の総エネルギー消費量(TEE)を概算する(Longの式, 1979). \n'
          '・AFは身体活動による上乗せ分. ICUでは安静〜リハ進行に応じて概ね1.0〜1.4. \n'
          '・AFとSFを掛け合わせるほど推定値は大きくなるため, 両係数が高いと過大評価に傾く'
          '(→侵害係数の項を参照). ',
    ),
    _NoteSection(
      category: '活動係数\n侵害係数',
      title: '侵害 (ストレス) 係数 SF',
      color: Color(0xFFE91E8C),
      body: '低栄養                                                              1.0未満\n'
          'ストレスなし (術前, 退院直前などの状態)   1.0\n'
          '手術                                                                1.1 – 1.8　(外傷 1.35)\n'
          '癌                                                                   1.1 – 1.3\n'
          '感染症                                                            1.2 – 1.5　(敗血症 1.6)\n'
          '発熱                                                                1.2 – 1.5\n'
          '熱傷                                                                1.2 – 2.0　(広範囲熱傷 2.1)\n'
          '\n'
          '■背景\n'
          '・SFは疾患・侵襲による代謝亢進(hypermetabolism)の上乗せ係数(Longの式, 1979). '
          '敗血症・外傷・熱傷などで基礎代謝が増える. \n'
          '\n'
          '■「SF≧1.5で過大栄養になりうる」根拠\n'
          '・BEE×AF×SFの予測式は, 重症患者では実測エネルギー消費量(間接熱量測定)を'
          '過大評価しやすいことが報告されている. \n'
          '・急性期は異化による内因性エネルギー供給があるため, 計算値どおりフル投与すると'
          '過剰栄養(overfeeding)になりやすい. \n'
          '・過剰栄養は高血糖・高TG血症・脂肪肝・CO2産生増加(換気負担)・感染・'
          '人工呼吸期間の延長などのリスクと関連する. \n'
          '・ASPEN/SCCM(2016)・ESPEN(2019)は, 間接熱量測定が使えない場合は'
          '25–30 kcal/kg/day を目安とし, 急性期は計算値の100%投与を急がない'
          '(段階的に増量)ことを推奨している. \n'
          '・目安として, 侵害係数が高い(SF≧1.5)とAFと相まって目標が概ね'
          '>30 kcal/kg/day に達し, 過剰栄養域に入りやすい'
          '(本アプリも該当時に注意表示). \n'
          '※いずれも目安であり, 最終判断は患者の病態と主治医の評価による. ',
    ),
    _NoteSection(
      category: 'タンパク',
      title: 'タンパクの投与量',
      color: Color(0xFFE53935),
      body: '■ 考え方\n'
          '・全エネルギーの10〜20%をタンパクで補う. \n'
          '・手術・敗血症などの高侵襲時はインスリン・カテコラミンが上昇し, 脂肪分解とケトーシスが抑制されるため, エネルギー源として筋タンパクが主に利用される. →侵襲時はアミノ酸製剤の併用が必要. \n\n'
          '式) 必要タンパク量(アミノ酸g) = 6.25 × 必要窒素量g = 6.25 × 必要熱量kcal ÷ (NPC/N)\n\n'
          '■ NPC/N比\n'
          '・「タンパクに対し脂質と炭水化物がどの程度あればタンパクが効率よく利用されるか」の指標(窒素1 g = タンパク質6.25 gとして計算). \n'
          '・通常 150 / 敗血症 100〜150 / 外科手術 150〜200 / 飢餓 400〜600 / 腎不全 500〜1,000. \n\n'
          '■ 投与量の目安\n'
          '・重症患者: 1.2〜2.0 g/kg/日(タンパク異化亢進のため). \n'
          '・その他: 最低1 g/kg/日, 目標1.2〜1.5 g/kg/日. \n'
          '・CKD(非AKI): 0.6〜0.8 g/kg/日. \n'
          '・肝硬変: 1.0〜1.2 g/kg/日. \n\n'
          '■ 注意\n'
          '・投与速度が速すぎると悪心・嘔吐が出る. \n'
          '・アミノ酸とグルコースはメイラード反応で褐変するため, 投与直前に混合する. ',
    ),
    _NoteSection(
      category: '炭水化物',
      title: '炭水化物の投与量',
      color: Color(0xFF8BC34A),
      body: '・全エネルギーの60〜70%を炭水化物で補う. \n'
          '・末梢から投与できる加糖液の濃度限界は10%. \n'
          '・糖質負荷(GIR)は概ね5 mg/kg/分以下に留める(過剰で高血糖・CO2産生増加・脂肪肝. 糖質制限を要する病態では>4でアラート). ',
    ),
    _NoteSection(
      category: '脂質',
      title: '脂質の投与量',
      color: Color(0xFF009688),
      body: '・全エネルギーの10〜20%を脂質で補う. NPC/N比や糖質負荷量を適正化する目的でも用いる. \n'
          '・投与量は1.0 g/kg/日以下, 投与速度は0.1 g/kg/時以下を厳守する. 速度が速いと肺に蓄積し, 呼吸不全・免疫機能低下を来す. \n'
          '・肝機能悪化・TG上昇・胆嚢炎・膵炎に注意して投与する. \n'
          '・初期から投与する必要は必ずしもない. 2週間程度で必須脂肪酸が欠乏してくるため, その時点で投与を考慮する. ',
    ),
    _NoteSection(
      category: '電解質',
      title: '電解質',
      color: Color(0xFF3F51B5),
      body: '■ Na（ナトリウム）\n・厚労省 食事摂取基準2025 食塩相当量 目標量: 男性<7.5 / 女性<6.5 g/日. 高血圧・CKD治療目標<6 g/日. \n・換算: 食塩1 g = Na 17.1 mEq（6 g=102.7 / 7 g=119.8 / 7.5 g=128.3 / 9.6 g=164.3 mEq）. \n・静脈栄養(ASPEN/JSPEN)標準: 1〜2 mEq/kg/日. 本アプリは 食塩7 g/日(Na≈119.8 mEq, HTなし成人の目標値)超で黄, 9.6 g/日(Na≈164.3 mEq, 日本人の平均食塩摂取量)以上で赤の塩分負荷アラート. \n\n■ K（カリウム）\n・食事摂取基準2025 目安量 男2,500/女2,000 mg/日(目標量 男3,000/女2,600 mg以上). 耐容上限なし. \n・PN標準 1〜2 mEq/kg/日. 1日100 mEq超は注意. 投与速度≤20 mEq/h・濃度≤40 mEq/L(原則中心静脈・心電図監視). \n\n■ Ca（カルシウム）\n・推奨量 650〜800 mg/日, 耐容上限 2,500 mg/日(≒125 mEq). PN標準 10〜15 mEq/日. P製剤との配合変化(沈殿)に注意. \n\n■ Mg（マグネシウム）\n・推奨量 男340〜380/女280〜290 mg/日(サプリ等の上限350 mg). PN標準 8〜20 mEq/日. 腎機能低下で高Mg血症に注意. \n\n■ P（リン）\n・目安量 男1,000/女800 mg/日, 耐容上限 3,000 mg/日(≒97 mmol). PN標準 20〜40 mmol/日. Refeedingで低下しやすく要モニタ. \n\n出典: 厚労省「日本人の食事摂取基準2025」/ ASPEN 2019 / JSPEN 静脈経腸栄養ガイドライン',
    ),
    _NoteSection(
      category: 'ビタミン',
      title: 'ビタミン',
      color: Color(0xFF9C27B0),
      body: '■ ビタミンB1（チアミン）\n・体内貯蔵量が約30 mgと少なく早期に欠乏. 糖負荷で需要増. Refeeding/Wernicke予防に投与前〜10日 200〜300 mg/日(NICE/JSPEN). \n\n■ 耐容上限(UL)が臨床上重要なもの（食事摂取基準2025）\n・ビタミンA: 推奨 650〜900 µgRAE, UL 2,700 µgRAE/日. 過剰で肝障害・頭蓋内圧亢進. \n・ビタミンD: 目安 9.0 µg, UL 100 µg(4,000 IU)/日. 過剰で高Ca血症. \n・ビタミンB6: 推奨 1.2〜1.5 mg, UL 45〜60 mg/日. 過剰で感覚性ニューロパチー. \n・葉酸(強化食品/サプリ) UL 900〜1,000 µg/日. ナイアシン UL 300〜350 mg/日. \n\n■ 静脈栄養の総合ビタミン(ASPEN成人/国内オーツカMV・ビタジェクト相当・1日量)\n・B1 3〜6・B2 3.6・B6 4〜6 mg, B12 5 µg, ナイアシン 40 mg, 葉酸 400〜600 µg, C 100〜200 mg, A 3,300 IU, D 200 IU, E 10 mg, K 150 µg. \n・TPNでは水溶性ビタミンが不足しやすく, 毎日の総合ビタミン投与が基本. \n\n出典: 厚労省「日本人の食事摂取基準2025」/ ASPEN 2019 / JSPEN',
    ),
    _NoteSection(
      category: '微量元素',
      title: '微量元素',
      color: Color(0xFFFF7043),
      body: '微量元素は長期TPNで欠乏・過剰の両方が問題になる. 経口/経腸はDRI, 静脈はASPEN/JSPENで必要量が異なる. \n\n■ 必要量と耐容上限（食事摂取基準2025 / 括弧は内部単位µmol）\n・亜鉛 Zn: 推奨 8〜9.5 mg, UL 男45/女35 mg(≒688/535 µmol). 創傷治癒・味覚に重要. \n・銅 Cu: 推奨 0.7〜0.9 mg, UL 7 mg(≒110 µmol). Zn過剰投与でCu欠乏を招く. \n・セレン Se: 推奨 25〜35 µg, UL 男450/女350 µg(≒5.7/4.4 µmol). 長期TPNで欠乏(心筋症). \n・マンガン Mn: 目安 3〜3.5 mg, UL 11 mg(≒200 µmol). 胆汁うっ滞・長期TPNで脳(淡蒼球)蓄積→パーキンソン様神経毒性. 減量/中止を検討. \n・ヨウ素 I: 推奨 140 µg, UL 3,000 µg(≒23.6 µmol). \n・鉄 Fe: 推奨 男7.5/女(月経)10.5 mg. PNには通常ルーチン添加しない(鉄過剰リスク). \n\n■ 静脈栄養の標準（ASPEN成人 / 国内エレジェクト等・1日量）\n・Zn 3〜5 mg, Cu 0.3〜0.5 mg, Se 60〜100 µg. Mn 国内製剤は約1.1 mg(ASPEN推奨55 µgの約20倍→長期は要注意). \n・1,000 kcal/日未満が長期化すると不足しやすく, 採血で過不足を確認し補正. \n\n出典: 厚労省「日本人の食事摂取基準2025」/ ASPEN 2019 / JSPEN / 食品安全委員会(Mn)',
    ),
    _NoteSection(
      category: 'ガイドライン',
      title: 'ASPEN/SCCM・ESPEN 概説',
      color: Color(0xFF6D4C41),
      body: 'ICU栄養の二大ガイドライン. 要点を対比して概説する. \n\n■ ASPEN/SCCM 2016（米・McClaveら, 2022更新）\n・開始: 血行動態が安定すれば 24〜48時間以内に経腸栄養(EN)を開始. \n・エネルギー: 間接熱量測定が第一. なければ 25〜30 kcal/kg/日. \n・タンパク: 1.2〜2.0 g/kg/日. 肥満は BMI30〜40で2.0, ≥40で2.5 g/kg(理想体重). \n・肥満の許容的低カロリー: BMI30〜50は11〜14 kcal/kg(実体重), >50は22〜25 kcal/kg(理想体重). \n・第1週はEN優先, 栄養リスクが低ければ早期PNは急がない. \n\n■ ESPEN 2019（欧・Singerら, 2023実践版）\n・エネルギー: 間接熱量測定を推奨. なければ 20〜25 kcal/kg/日. \n・急性期早期(〜3日)は permissive underfeeding（目標の<70%）→以後80〜100%へ漸増. 過剰栄養を避ける. \n・タンパク: 1.3 g/kg/日を漸増. 糖質≤5 mg/kg/min, 脂質≤1.5 g/kg/日. \n\n■ 近年の潮流\n・「早期の積極的フルフィード」より「過剰栄養を避け漸増」へ. \n・精度は 間接熱量測定 ＞ 体重あたり簡易式 ＞ 予測式. \n・電解質(特にRefeeding)・血糖(140〜180 mg/dL)を厳格に管理. \n\n出典: McClave et al. JPEN 2016 / Compher et al. JPEN 2022 / Singer et al. Clin Nutr 2019・2023',
    ),
    _NoteSection(
      category: 'Refeeding',
      title: 'Refeeding症候群 (NICE)',
      color: Color(0xFFC2185B),
      body: '低栄養・絶食後に栄養(特に糖質)を再開すると, 細胞内へK・P・Mgが移動し致死的な低下を来す病態. インスリン分泌再開とビタミンB1需要増が引き金. \n\n■ 高リスク基準（NICE CG32, 2006）\n・次のいずれか1つ: BMI<16 / 3〜6か月で>15%体重減 / 10日以上のほぼ絶食 / 投与前からK・P・Mg低値. \n・または次のいずれか2つ: BMI<18.5 / >10%体重減 / 5日以上のほぼ絶食 / アルコール・薬物(インスリン・化学療法・制酸薬・利尿薬)歴. \n・超高リスク: BMI<14 または 15日以上の絶食. \n\n■ 対処\n・開始エネルギー: 高リスク 10 kcal/kg/日(超高リスクは5, 心電図監視). 4〜7日かけて必要量へ漸増. \n・チアミン(B1) 200〜300 mg/日を糖負荷の前〜10日. 総合ビタミンB群も. \n・電解質は補充しながら投与(正常化を待って開始を遅らせない): K 2〜4 / P 0.3〜0.6 / Mg 0.2〜0.4 mmol/kg/日. \n・血清P≥2.0 mg/dL維持. K・P・Mg・血糖を頻回モニタ. \n\n本アプリは絶食開始日・BMIからリスク階層を判定し, 自動設計の初期kcalを上記rampで自動cap, 対処サジェストを表示する. \n\n出典: NICE CG32「Nutrition support for adults」(2006) / JSPEN',
    ),
    _NoteSection(
      category: '微量元素\n病態調整',
      title: '微量元素の病態別調整',
      color: Color(0xFF5E35B1),
      body: '微量元素・ビタミンは「過剰(蓄積)」と「不足(喪失)」の両方が問題になり, 病態で方向が変わる. \n\n■ 通常患者: 非重複が原則\nベースが内蔵する成分は加注しない(二重投与回避). \n・エルネオパNF/ワンパル(電解質+微量元素+ビタミン内蔵)→加注なし(Seのみ条件付き)\n・フルカリック(ビタミンのみ)→微量元素のみ追加\n・ミキシッド/ゼロmenu→MVI+微量元素\n\n■ 胆汁うっ滞・肝不全・肝性脳症: Cu/Mn過剰回避\nMnは胆汁排泄80%→淡蒼球に蓄積しパーキンソン様(不可逆あり). 胆道閉塞はMn製剤禁忌. \n→標準微量元素(Mn 20μmol)をMn-free「ボルビサール」へ切替. Cuは減量しつつ残す(ゼロにしない). \nモニタ: 全血Mn(基準0.52–2.4μg/dL), 血清Cu+セルロプラスミン(月2回). \n\n■ 腎不全(非透析): Cr/Mn蓄積\nCrは輸液汚染で充足し追加不要(腎障害助長). 複合微量元素を減量し血中濃度をモニタ. \n\n■ CRRT・持続透析: 喪失側→補充\n水溶性(Se・B1・Cu・葉酸・VitC・カルニチン)が透析液へ喪失. Se・B1を2倍目安で補充, 複合traceは継続. VitC高用量はシュウ酸で避ける. \n\n■ 高排出消化管瘻・大量下痢: Zn喪失\nZn 腸液+12mg/L・便/ストマ+17mg/Lを上乗せ. Mg/K/Na・水分も補正. \n\n■ チアミン×糖負荷(安全インターロック)\nB1欠乏者に糖を先行するとWernicke脳症・乳酸アシドーシス. 糖の前〜同時にB1 100–300mg. 標準MVIのB1 3mgは予防に不足→高用量B1製剤を別途. \n\n■ 単剤 add / replace\n・ADD: 創傷・高GI損失でZn追加, CRRT/長期でSe(アセレンド)追加. \n・REPLACE: Mn回避が必要な胆汁うっ滞で 標準複合→Mn-free複合+Se単剤. \n・注意: 国内にIV亜鉛単剤がほぼ無く, Zn増量は複合もう1管/院内調製/経口併用. \n\n■ 栄養開始時セット vs 補正後増量セット\n・開始時(refeeding慎重): B1高用量を糖前にフロントロード+標準MVI+標準微量元素(胆汁うっ滞ならMn-free). Se/Zn追加なし, 10–15kcal/kgで慎重, K/PO4/Mg頻回. \n・補正後増量: Se(CRRT/長期/熱傷/創傷)・Zn(高排出/創傷)追加, Mn再評価, 採血ベースで増量. \n\n出典: ESPEN micronutrient guideline 2022 / ASPEN / JSPEN / NICE CG32 / 各添付文書',
    ),
  ];

  static final _categoryColors = <String, Color>{
    _allLabel: Color(0xFF4CAF50),
    'つかいかた': Color(0xFF4A90D9),
    'EN': Color(0xFF2E7D32),
    'TPN': Color(0xFF1565C0),
    'PPN': Color(0xFF00838F),
    'エネルギー\n算出法': Color(0xFFE67E22),
    'ガイドライン': Color(0xFF6D4C41),
    'Refeeding': Color(0xFFC2185B),
    '微量元素\n病態調整': Color(0xFF5E35B1),
    '活動係数\n侵害係数': Color(0xFFE91E8C),
    'タンパク': Color(0xFFE53935),
    '炭水化物': Color(0xFF8BC34A),
    '脂質': Color(0xFF009688),
    '電解質': Color(0xFF3F51B5),
    'ビタミン': Color(0xFF9C27B0),
    '微量元素': Color(0xFFFF7043),
  };

  @override
  void initState() {
    super.initState();
    _editableSections = List.from(_sections);
    _snapCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 260));
    _snapCtrl.addListener(() {
      if (!mounted) return;
      final t = Curves.easeOut.transform(_snapCtrl.value);
      setState(() =>
          _panelHeight = _snapFrom + (_snapToTarget - _snapFrom) * t);
    });
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    _noteScroll.dispose();
    super.dispose();
  }

  void _snapTo(double target) {
    _snapFrom = _panelHeight;
    _snapToTarget = target;
    _snapCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _selected == _allLabel
        ? _editableSections
        : _editableSections.where((s) => s.category == _selected).toList();
    final screenH = MediaQuery.of(context).size.height;
    final _nqPad = MediaQuery.of(context).padding;
    // ノートページはHomePageのScaffold内（AppBar+NavigationBar(80)を除く）
    const _navBarH = 80.0;
    final maxPanel = (screenH - _nqPad.top - kToolbarHeight - _navBarH - _nqPad.bottom)
        .clamp(200.0, screenH);
    if (_panelHeight > maxPanel) _panelHeight = maxPanel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上部(カテゴリー + 新規作成)。本文展開時は縮んでスクロール
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // カテゴリーグリッド
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 3.8,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                    children: _categoryColors.entries.map((e) {
                      final selected = _selected == e.key;
                      return GestureDetector(
                        onTap: () => setState(() => _selected = e.key),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          decoration: BoxDecoration(
                            color: selected ? e.value : e.value.withOpacity(0.68),
                            borderRadius: BorderRadius.circular(6),
                            border: selected ? Border.all(color: Colors.white, width: 2.5) : null,
                            boxShadow: selected
                                ? [BoxShadow(color: e.value.withOpacity(0.4), blurRadius: 4, offset: const Offset(0, 2))]
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Text(e.key,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                // 新規作成ボタン
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => _createNote(context),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('新規作成'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // 本文パネル(ドラッグで上に展開。処方ビルダーのサマリと同仕様)
        SafeArea(
          top: false,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: SizedBox(
              width: double.infinity,
              height: _panelHeight,
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withOpacity(0.4),
                      width: 0.8),
                ),
                child: Column(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragUpdate: (d) {
                        setState(() {
                          _panelHeight = (_panelHeight - d.delta.dy)
                              .clamp(_panelMin, maxPanel);
                        });
                      },
                      onVerticalDragEnd: (_) {
                        // 上端まで引っ張ったら下端に戻す。それ以外は離した位置で止まる。
                        if (_panelHeight >= maxPanel) _snapTo(_panelMin);
                      },
                      child: Container(
                        color: Colors.transparent,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Center(
                          child: Container(
                            height: 4,
                            width: 48,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade400,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: _noteScroll,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        children: filtered
                            .map((s) => _buildSection(s, filtered.indexOf(s)))
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _createNote(BuildContext context) async {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新規ノート作成'),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'タイトル')),
            const SizedBox(height: 8),
            TextField(controller: bodyCtrl, maxLines: 8, minLines: 4,
                decoration: const InputDecoration(labelText: '本文', border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('追加')),
        ],
      ),
    );
    if (saved != true || titleCtrl.text.trim().isEmpty) return;
    setState(() {
      _editableSections.add(_NoteSection(
        category: _selected == _allLabel ? 'つかいかた' : _selected,
        title: titleCtrl.text.trim(),
        body: bodyCtrl.text,
        color: _categoryColors[_selected] ?? const Color(0xFF607D8B),
      ));
    });
  }

  Future<void> _editNote(BuildContext context, _NoteSection s, int index) async {
    final titleCtrl = TextEditingController(text: s.title);
    final bodyCtrl = TextEditingController(text: s.body);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ノートを編集'),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'タイトル')),
            const SizedBox(height: 8),
            TextField(controller: bodyCtrl, maxLines: 12, minLines: 4,
                decoration: const InputDecoration(labelText: '本文', border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    setState(() {
      final globalIdx = _editableSections.indexOf(s);
      if (globalIdx >= 0) {
        _editableSections[globalIdx] = _NoteSection(
          category: s.category, title: titleCtrl.text.trim(),
          body: bodyCtrl.text, color: s.color,
        );
      }
    });
  }

  Widget _buildSection(_NoteSection s, int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        // カードを画面いっぱい(全幅)に揃える
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: '■ ',
                      style: TextStyle(
                          color: s.color,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                    TextSpan(
                      text: s.title,
                      style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _editNote(context, s, index),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('編集', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.4),
                  width: 0.8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(s.body, style: const TextStyle(height: 1.7, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }
}
