import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/core/database/app_database.dart';
import 'package:saturday_futsal/features/importing/domain/player_csv.dart';
import 'package:saturday_futsal/features/importing/data/player_import_repository.dart';

void main() {
  test(
    'CSV supports BOM, CRLF, quoted commas, escaped quotes, and multiline cells',
    () {
      final t = CsvTable.parse(
        '\ufeffFirst name,Last name,Photo\r\nAli,"Khan, Jr.","private\nlink"\r\nSam,"O""Neil",\r\n',
      );
      expect(t.rows[0], ['Ali', 'Khan, Jr.', 'private\nlink']);
      expect(t.rows[1][1], 'O"Neil');
    },
  );
  test(
    'Google Forms columns map names, foot, position, jersey and private photo references',
    () {
      final t = CsvTable.parse(
        'First name,Last name,Preferred foot,Position,Jersey number,Player photo\nAli,Khan,Left foot,Fixo,7,https://drive.google.com/private',
      );
      final r = previewCsv(t, t.suggest(), const []).single;
      expect(r.name, 'Ali Khan');
      expect(r.foot, 'left');
      expect(r.position, 'Defender');
      expect(r.jersey, 7);
      expect(r.photoLink, isTrue);
      expect(r.action, 'create');
    },
  );
  test(
    'normalization uses known futsal roles without inventing unknown values',
    () {
      expect(normalizePosition('ALA'), 'Winger');
      expect(normalizePosition('striker'), 'Pivot');
      expect(normalizeFoot('both feet'), 'both');
      expect(() => normalizePosition('astronaut'), throwsFormatException);
      expect(() => normalizeFoot('sometimes'), throwsFormatException);
    },
  );
  test(
    'malformed quotes, inconsistent columns, empty CSV and excessive cells are rejected',
    () {
      for (final source in [
        '',
        'Name\n"unclosed',
        'Name,Foot\nOne',
        'Name\n"A"text',
        'Name\n${List.filled(5001, 'a').join()}',
      ]) {
        expect(() => CsvTable.parse(source), throwsFormatException);
      }
    },
  );
  test('invalid values stay visible and unselected in preview', () {
    final t = CsvTable.parse(
      'Name,Jersey,Position\n=SCRIPT,4,Winger\nValid,100,Pivot\nOther,7,Unknown role',
    );
    final rows = previewCsv(t, t.suggest(), const []);
    expect(rows.every((r) => r.error != null && r.action == 'skip'), isTrue);
  });
  test('repeated names in one CSV default to skipping the later row', () {
    final t = CsvTable.parse('Name\nAli Khan\n ali   khan '),
        rows = previewCsv(t, t.suggest(), const []);
    expect(rows.first.action, 'create');
    expect(rows.last.repeated, isTrue);
    expect(rows.last.action, 'skip');
  });
  group('transactional import', () {
    late AppDatabase db;
    late String id;
    setUp(() async {
      db = AppDatabase.memory();
      id = await db.savePlayer(
        name: 'Ali Khan',
        position: 'Pivot',
        skillRating: 8,
        photoPath: '/persistent/portrait.jpg',
        preferredFoot: 'right',
      );
    });
    tearDown(() async => db.close());
    test(
      'likely duplicates include archived profiles and require explicit update',
      () async {
        await db.archivePlayer(id);
        final t = CsvTable.parse('Name,Position\nALI KHAN,Winger');
        final r = previewCsv(
          t,
          t.suggest(),
          await db.players(includeArchived: true),
        ).single;
        expect(r.action, 'skip');
        expect(r.duplicates.single.id, id);
        expect(r.target, id);
      },
    );
    test(
      'update preserves identity, photos, ratings, archive state and rating history',
      () async {
        await db.archivePlayer(id);
        final t = CsvTable.parse(
          'Name,Position,Foot,Jersey\nALI KHAN,Winger,Left,9',
        );
        final r = previewCsv(
          t,
          t.suggest(),
          await db.players(includeArchived: true),
        ).single..action = 'update';
        expect(await PlayerImportRepository(db).apply([r]), 1);
        final p = (await db.player(id))!;
        expect(p.name, 'ALI KHAN');
        expect(p.preferredPosition, 'Winger');
        expect(p.preferredFoot, 'left');
        expect(p.skillRating, 8);
        expect(p.photoPath, '/persistent/portrait.jpg');
        expect(p.isArchived, isTrue);
        expect(
          (await db.rows(
            'SELECT * FROM player_rating_history WHERE player_id=?',
            [id],
          )).length,
          1,
        );
      },
    );
    test(
      'new profiles disclose a default rating and do not download photo URLs',
      () async {
        final t = CsvTable.parse(
          'First name,Last name,Photo\nNew,Player,https://drive.google.com/not-public',
        );
        await PlayerImportRepository(
          db,
        ).apply(previewCsv(t, t.suggest(), await db.players()));
        final p = (await db.players()).singleWhere(
          (p) => p.name == 'New Player',
        );
        expect(p.skillRating, 5);
        expect(p.photoPath, isNull);
      },
    );
    test(
      'a stale update rolls back earlier creates in the same import',
      () async {
        final t = CsvTable.parse(
              'Name,Position\nNew Player,Pivot\nAli Khan,Winger',
            ),
            rows = previewCsv(t, t.suggest(), await db.players());
        rows.last.action = 'update';
        await db.savePlayer(
          id: id,
          name: 'Ali Changed',
          position: 'Pivot',
          skillRating: 8,
        );
        await expectLater(
          PlayerImportRepository(db).apply(rows),
          throwsStateError,
        );
        expect((await db.players()).length, 1);
        expect((await db.player(id))!.name, 'Ali Changed');
      },
    );
    test('unmapped optional profile fields remain intact on update', () async {
      final t = CsvTable.parse('Name\nAli Khan'),
          r = previewCsv(t, t.suggest(), await db.players()).single
            ..action = 'update';
      await PlayerImportRepository(db).apply([r]);
      final p = (await db.player(id))!;
      expect(p.preferredPosition, 'Pivot');
      expect(p.preferredFoot, 'right');
      expect(p.skillRating, 8);
    });
  });
}
