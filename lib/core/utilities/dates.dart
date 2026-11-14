import 'package:intl/intl.dart';

DateTime nextSaturday([DateTime? from]) {
  final now = from ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  return day.add(Duration(days: (DateTime.saturday - day.weekday + 7) % 7));
}

String sessionDate(DateTime date) => DateFormat('EEE, d MMM yyyy').format(date);
String rotationLabel(String mode) =>
    mode == 'winner_stays' ? 'Winner stays' : 'Round robin';
