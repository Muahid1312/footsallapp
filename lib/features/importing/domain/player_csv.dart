import '../../players/domain/player.dart';

class CsvTable {
  CsvTable(this.headers, this.rows);
  final List<String> headers;
  final List<List<String>> rows;
  static CsvTable parse(String source) {
    if (source.length > 2 * 1024 * 1024 || source.contains('\u0000')) {
      throw const FormatException('CSV must be plain text and at most 2 MB.');
    }
    final text = source.startsWith('\ufeff') ? source.substring(1) : source;
    final rows = <List<String>>[], row = <String>[];
    var field = StringBuffer(), quoted = false, closed = false;
    void cell() {
      if (field.length > 5000) {
        throw const FormatException('CSV cell is too long.');
      }
      row.add(field.toString().trim());
      field = StringBuffer();
      closed = false;
      if (row.length > 100) {
        throw const FormatException('CSV has too many columns.');
      }
    }

    void line() {
      cell();
      if (row.any((v) => v.isNotEmpty)) {
        rows.add([...row]);
      }
      row.clear();
      if (rows.length > 5001) {
        throw const FormatException('Import up to 5,000 records at a time.');
      }
    }

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
            closed = true;
          }
        } else {
          field.write(ch);
        }
      } else if (ch == '"') {
        if (field.isNotEmpty || closed) {
          throw const FormatException('CSV contains malformed quotes.');
        }
        quoted = true;
      } else if (ch == ',') {
        cell();
      } else if (ch == '\n' || ch == '\r') {
        line();
        if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
          i++;
        }
      } else {
        if (closed && ch.trim().isNotEmpty) {
          throw const FormatException(
            'Unexpected text after a quoted CSV cell.',
          );
        }
        if (!closed) {
          field.write(ch);
        }
      }
    }
    if (quoted) {
      throw const FormatException('CSV has an unclosed quoted field.');
    }
    if (field.isNotEmpty || row.isNotEmpty || closed) {
      line();
    }
    if (rows.length < 2 ||
        rows.first.isEmpty ||
        rows.skip(1).any((r) => r.length != rows.first.length)) {
      throw const FormatException(
        'CSV needs a header, at least one record, and consistent columns.',
      );
    }
    return CsvTable(rows.first, rows.skip(1).toList());
  }

  Map<String, int?> suggest() {
    const aliases = {
      'name': ['full name', 'player name', 'name'],
      'first': ['first name', 'firstname', 'given name'],
      'last': ['last name', 'lastname', 'surname', 'family name'],
      'foot': ['preferred foot', 'foot', 'dominant foot'],
      'position': ['position', 'preferred position', 'playing position'],
      'jersey': ['jersey number', 'jersey', 'shirt number'],
      'photo': ['player photo', 'photo', 'upload photo', 'photo upload'],
    };
    return {
      for (final e in aliases.entries)
        e.key:
            headers.indexWhere(
                  (h) => e.value.contains(h.trim().toLowerCase()),
                ) <
                0
            ? null
            : headers.indexWhere(
                (h) => e.value.contains(h.trim().toLowerCase()),
              ),
    };
  }
}

String playerNameKey(String name) =>
    name.toLowerCase().trim().replaceAll(RegExp(r'[\s.,_-]+'), ' ');
String normalizeFoot(String value) => switch (value.trim().toLowerCase()) {
  'left' || 'left foot' || 'left-footed' || 'l' => 'left',
  'right' || 'right foot' || 'right-footed' || 'r' => 'right',
  'both' || 'both feet' || 'ambidextrous' => 'both',
  '' || 'unknown' || 'not specified' => 'unknown',
  _ => throw const FormatException('Unrecognized preferred foot.'),
};
String normalizePosition(String value) => switch (value.trim().toLowerCase()) {
  '' ||
  'all rounder' ||
  'all-rounder' ||
  'allrounder' ||
  'any' ||
  'utility' => 'All-rounder',
  'goalkeeper' || 'goal keeper' || 'keeper' || 'gk' => 'Goalkeeper',
  'defender' || 'defence' || 'defense' || 'fixo' => 'Defender',
  'winger' || 'wing' || 'ala' => 'Winger',
  'pivot' || 'forward' || 'striker' => 'Pivot',
  _ => throw const FormatException(
    'Unrecognized position. Correct or map this column before import.',
  ),
};

class PlayerImportRow {
  PlayerImportRow({
    required this.number,
    required this.name,
    required this.position,
    required this.foot,
    this.jersey,
    this.hasFoot = false,
    this.hasPosition = false,
    this.photoLink = false,
    this.error,
    this.duplicates = const [],
    this.repeated = false,
  });
  final int number;
  final String name, position, foot;
  final int? jersey;
  final bool hasFoot, hasPosition, photoLink, repeated;
  final String? error;
  final List<Player> duplicates;
  String action = 'skip';
  String? target;
}

List<PlayerImportRow> previewCsv(
  CsvTable table,
  Map<String, int?> mapping,
  List<Player> existing,
) {
  if (mapping['name'] == null && mapping['first'] == null) {
    throw const FormatException('Map Full name or First name.');
  }
  if (mapping.values.whereType<int>().any(
    (i) => i < 0 || i >= table.headers.length,
  )) {
    throw const FormatException('Invalid column mapping.');
  }
  final seen = <String>{}, result = <PlayerImportRow>[];
  final byName = <String, List<Player>>{};
  for (final player in existing) {
    (byName[playerNameKey(player.name)] ??= []).add(player);
  }
  for (var i = 0; i < table.rows.length; i++) {
    final row = table.rows[i];
    String value(String key) =>
        mapping[key] == null ? '' : row[mapping[key]!].trim();
    final name =
        (mapping['name'] != null
                ? value('name')
                : '${value('first')} ${value('last')}')
            .trim()
            .replaceAll(RegExp(r'\s+'), ' ');
    var position = 'All-rounder', foot = 'unknown';
    int? jersey;
    String? error;
    try {
      if (name.isEmpty ||
          name.length > 80 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
          RegExp(r'^[=+@]').hasMatch(name)) {
        throw const FormatException('Name must be 1–80 plain-text characters.');
      }
      position = normalizePosition(value('position'));
      foot = normalizeFoot(value('foot'));
      if (value('jersey').isNotEmpty) {
        jersey = int.tryParse(value('jersey'));
        if (jersey == null || jersey < 0 || jersey > 99) {
          throw const FormatException('Jersey must be 0–99 or empty.');
        }
      }
    } on FormatException catch (e) {
      error = e.message;
    }
    final key = playerNameKey(name),
        repeated = !seen.add(key),
        duplicates = byName[key] ?? const <Player>[];
    final entry = PlayerImportRow(
      number: i + 2,
      name: name,
      position: position,
      foot: foot,
      jersey: jersey,
      hasFoot: value('foot').isNotEmpty,
      hasPosition: value('position').isNotEmpty,
      photoLink: value('photo').isNotEmpty,
      error: error,
      duplicates: duplicates,
      repeated: repeated,
    );
    if (error == null && !repeated && duplicates.isEmpty) {
      entry.action = 'create';
    }
    if (duplicates.length == 1) {
      entry.target = duplicates.single.id;
    }
    result.add(entry);
  }
  return result;
}
