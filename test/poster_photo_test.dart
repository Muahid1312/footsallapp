import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:saturday_futsal/features/players/domain/player.dart';
import 'package:saturday_futsal/features/players/data/photo_store.dart';
import 'package:saturday_futsal/features/posters/domain/winner_poster.dart';
import 'package:saturday_futsal/features/posters/data/poster_renderer.dart';
import 'support/test_photo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File photo;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('poster-test-');
    photo = await testPhoto(File('${root.path}/portrait.png'));
  });
  tearDown(() async => root.delete(recursive: true));
  WinnerPoster data(int n, {bool photos = true, bool shared = false}) =>
      WinnerPoster(
        competitionId: 'c',
        sessionId: 's',
        date: DateTime.utc(2026, 11, 14),
        teamId: 't',
        teamName: 'The Emeralds',
        teamColor: 0xff39e5a1,
        summary: '3 played · 3 wins · 9 points · 8 goals',
        shared: shared,
        players: [
          for (var i = 0; i < n; i++)
            Player(
              id: 'p$i',
              name: 'Champion $i',
              photoPath: photos ? photo.path : null,
              preferredPosition: 'Winger',
              skillRating: 5,
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
            ),
        ],
      );
  test(
    'all three original styles render complete player photos as sharp portrait PNGs',
    () async {
      final outputs = <List<int>>[];
      for (final style in PosterStyle.values) {
        final png = await PosterRenderer().render(data(5), style: style),
            header = ByteData.sublistView(png);
        expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(header.getUint32(16), 1080);
        expect(header.getUint32(20), 1350);
        outputs.add(png);
      }
      expect(outputs[0], isNot(outputs[1]));
      expect(outputs[1], isNot(outputs[2]));
    },
  );
  test(
    'missing and damaged photos use initials without preventing export',
    () async {
      await photo.writeAsBytes([1, 2, 3]);
      expect((await PosterRenderer().render(data(3))).isNotEmpty, isTrue);
      expect(
        (await PosterRenderer().render(data(2, photos: false))).isNotEmpty,
        isTrue,
      );
    },
  );
  test('story export dimensions are exactly 1080 by 1920', () async {
    final header = ByteData.sublistView(
      await PosterRenderer().render(data(1), story: true),
    );
    expect(header.getUint32(16), 1080);
    expect(header.getUint32(20), 1920);
  });
  test(
    'different squad sizes paginate without losing or duplicating anyone',
    () {
      for (final n in [1, 2, 3, 5, 9, 10, 15, 27]) {
        final poster = data(n), pages = poster.pages();
        expect(pages.expand((p) => p).map((p) => p.id).toSet().length, n);
        expect(pages.every((p) => p.length <= 9), isTrue);
        expect(poster.pages(story: true).every((p) => p.length <= 15), isTrue);
      }
    },
  );
  test(
    'manual order preserves champion metadata and validates exact membership',
    () {
      final poster = data(3, shared: true);
      expect(poster.pages(order: ['p2', 'p0', 'p1']).first.first.id, 'p2');
      expect(poster.shared, isTrue);
      expect(poster.date, DateTime.utc(2026, 11, 14));
      expect(poster.teamName, 'The Emeralds');
      expect(
        () => poster.pages(order: ['p0', 'p0', 'p1']),
        throwsArgumentError,
      );
    },
  );
  test(
    'photo crops preserve proportions and clamp adjustments inside the source',
    () async {
      final image = await SafePhoto.read(photo);
      try {
        final crop = SafePhoto.crop(image, zoom: 2, x: 1, y: 0);
        expect(crop.width, crop.height);
        expect(crop.right, lessThanOrEqualTo(image.width));
        expect(crop.top, 0);
      } finally {
        image.dispose();
      }
    },
  );
  test(
    'cropped photo persists as a bounded 1000-pixel managed asset',
    () async {
      final image = await SafePhoto.read(photo);
      late String saved;
      try {
        saved = await PhotoStore(
          root: () async => root,
        ).saveCrop(image, SafePhoto.crop(image));
      } finally {
        image.dispose();
      }
      final reloaded = await SafePhoto.read(File(saved));
      try {
        expect(reloaded.width, 1000);
        expect(reloaded.height, 1000);
        expect(saved, contains('player_photos'));
      } finally {
        reloaded.dispose();
      }
    },
  );
  test(
    'malformed image bytes are rejected before persisting a photo',
    () async {
      await expectLater(
        SafePhoto.decode(Uint8List.fromList([0, 1, 2, 3])),
        throwsFormatException,
      );
      expect(await Directory('${root.path}/player_photos').exists(), isFalse);
    },
  );
}
