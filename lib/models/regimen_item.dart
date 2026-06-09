/// 処方の1製剤分（本数＋食事タイミング＋部分使用ml）。
class RegimenItem {
  RegimenItem({
    required this.productId,
    required this.units,
    this.morning = 0,
    this.noon = 0,
    this.evening = 0,
    this.partialMl = 0,
  });
  final String productId;
  int units;
  int morning;
  int noon;
  int evening;
  // TPN/PPN: 本数(units)に上乗せする部分使用量(ml, 100ml単位)。実投与量=units×bagVol+partialMl。
  int partialMl;

  bool get hasMealTiming => morning > 0 || noon > 0 || evening > 0;

  Map<String, dynamic> toMap() => {
        'productId': productId,
        'units': units,
        'morning': morning,
        'noon': noon,
        'evening': evening,
        'partialMl': partialMl,
      };
  factory RegimenItem.fromMap(Map<String, dynamic> map) => RegimenItem(
        productId: map['productId'] as String,
        units: map['units'] as int,
        morning: (map['morning'] as int?) ?? 0,
        noon: (map['noon'] as int?) ?? 0,
        evening: (map['evening'] as int?) ?? 0,
        partialMl: (map['partialMl'] as int?) ?? 0,
      );
}
