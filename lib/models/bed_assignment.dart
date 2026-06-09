/// ベッド割り当て履歴（入室・移動）。fromBed==null が入室レコード。
class BedAssignment {
  BedAssignment(
      {required this.changedAt,
      required this.fromBed,
      required this.toBed,
      required this.note});
  String changedAt;
  final String? fromBed;
  final String toBed;
  final String note;

  Map<String, dynamic> toMap() => {
        'changedAt': changedAt,
        'fromBed': fromBed,
        'toBed': toBed,
        'note': note
      };
  factory BedAssignment.fromMap(Map<String, dynamic> map) => BedAssignment(
        changedAt: map['changedAt'] as String,
        fromBed: map['fromBed'] as String?,
        toBed: map['toBed'] as String,
        note: (map['note'] ?? '') as String,
      );
}
