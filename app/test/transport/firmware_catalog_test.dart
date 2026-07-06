import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/transport/firmware_catalog.dart';
import 'package:pub_semver/pub_semver.dart';

String _releaseJson({
  required String tag,
  required bool prerelease,
  bool withBin = true,
}) {
  final assets = <Map<String, dynamic>>[
    if (withBin)
      {
        'name': 'idl0.bin',
        'size': 2048,
        'browser_download_url': 'https://dl/$tag/idl0.bin',
      },
    {
      'name': 'firmware.bin.sha256',
      'size': 80,
      'browser_download_url': 'https://dl/$tag/firmware.bin.sha256',
    },
  ];
  return jsonEncode({
    'tag_name': tag,
    'prerelease': prerelease,
    'draft': false,
    'body': 'notes for $tag',
    'assets': assets,
  });
}

void main() {
  group('FirmwareRelease', () {
    test('holds its parsed version and channel', () {
      // Arrange
      final rel = FirmwareRelease(
        version: Version.parse('1.5.0'),
        channel: FirmwareChannel.stable,
        binUrl: Uri.parse('https://example/idl0.bin'),
        sizeBytes: 1024,
        sha256Url: null,
        notes: 'notes',
      );

      // Assert
      expect(rel.version, equals(Version.parse('1.5.0')));
      expect(rel.channel, equals(FirmwareChannel.stable));
      expect(rel.sizeBytes, equals(1024));
    });

    test(
      'kFirmwareRepoSlug — firmware repo split is complete — points at '
      'saucyeng/idl0-firmware',
      () {
        // Assert
        expect(kFirmwareRepoSlug, equals('saucyeng/idl0-firmware'));
      },
    );
  });

  group('GitHubReleasesCatalog.latest', () {
    test('stable hits /releases/latest and strips the leading v', () async {
      // Arrange
      final client = MockClient((req) async {
        expect(req.url.path, endsWith('/releases/latest'));
        return http.Response(
          _releaseJson(tag: 'v1.5.0', prerelease: false),
          200,
        );
      });
      final catalog = GitHubReleasesCatalog(client, slug: 'o/r');

      // Act
      final rel = await catalog.latest(FirmwareChannel.stable);

      // Assert
      expect(rel!.version, equals(Version.parse('1.5.0')));
      expect(rel.binUrl, equals(Uri.parse('https://dl/v1.5.0/idl0.bin')));
      expect(rel.sizeBytes, equals(2048));
      expect(
        rel.sha256Url,
        equals(Uri.parse('https://dl/v1.5.0/firmware.bin.sha256')),
      );
    });

    test('beta lists releases and takes the newest non-draft', () async {
      // Arrange
      final client = MockClient((req) async {
        expect(req.url.path, endsWith('/releases'));
        return http.Response(
          jsonEncode([
            jsonDecode(_releaseJson(tag: 'v1.6.0-beta.1', prerelease: true)),
            jsonDecode(_releaseJson(tag: 'v1.5.0', prerelease: false)),
          ]),
          200,
        );
      });
      final catalog = GitHubReleasesCatalog(client, slug: 'o/r');

      // Act
      final rel = await catalog.latest(FirmwareChannel.beta);

      // Assert
      expect(rel!.version, equals(Version.parse('1.6.0-beta.1')));
      expect(rel.channel, equals(FirmwareChannel.beta));
    });

    test('returns null when stable endpoint 404s (no releases)', () async {
      // Arrange
      final client = MockClient((_) async => http.Response('not found', 404));
      final catalog = GitHubReleasesCatalog(client, slug: 'o/r');

      // Act / Assert
      expect(await catalog.latest(FirmwareChannel.stable), isNull);
    });

    test('skips a release with no .bin asset', () async {
      // Arrange
      final client = MockClient(
        (_) async => http.Response(
          _releaseJson(tag: 'v1.5.0', prerelease: false, withBin: false),
          200,
        ),
      );
      final catalog = GitHubReleasesCatalog(client, slug: 'o/r');

      // Act / Assert
      expect(await catalog.latest(FirmwareChannel.stable), isNull);
    });

    test(
      'latest — versioned asset names idl0-firmware-v0.1.0.bin and '
      '.bin.sha256 — parses bin and sha URLs',
      () async {
        // Arrange
        final release = jsonEncode({
          'tag_name': 'v0.1.0',
          'prerelease': false,
          'draft': false,
          'body': 'notes for v0.1.0',
          'assets': [
            {
              'name': 'idl0-firmware-v0.1.0.bin',
              'size': 4096,
              'browser_download_url':
                  'https://dl/v0.1.0/idl0-firmware-v0.1.0.bin',
            },
            {
              'name': 'idl0-firmware-v0.1.0.bin.sha256',
              'size': 90,
              'browser_download_url':
                  'https://dl/v0.1.0/idl0-firmware-v0.1.0.bin.sha256',
            },
          ],
        });
        final client = MockClient((_) async => http.Response(release, 200));
        final catalog = GitHubReleasesCatalog(client, slug: 'o/r');

        // Act
        final rel = await catalog.latest(FirmwareChannel.stable);

        // Assert
        expect(
          rel!.binUrl,
          equals(Uri.parse('https://dl/v0.1.0/idl0-firmware-v0.1.0.bin')),
        );
        expect(
          rel.sha256Url,
          equals(
            Uri.parse('https://dl/v0.1.0/idl0-firmware-v0.1.0.bin.sha256'),
          ),
        );
      },
    );

    test('throws FirmwareCatalogException on a 500', () async {
      // Arrange
      final client = MockClient((_) async => http.Response('boom', 500));
      final catalog = GitHubReleasesCatalog(client, slug: 'o/r');

      // Act / Assert
      expect(
        () => catalog.latest(FirmwareChannel.stable),
        throwsA(isA<FirmwareCatalogException>()),
      );
    });
  });

  group('GitHubReleasesCatalog.download', () {
    final bytes = Uint8List.fromList(List<int>.generate(2048, (i) => i % 256));

    FirmwareRelease relWith({Uri? shaUrl}) => FirmwareRelease(
          version: Version.parse('1.5.0'),
          channel: FirmwareChannel.stable,
          binUrl: Uri.parse('https://dl/idl0.bin'),
          sizeBytes: bytes.length,
          sha256Url: shaUrl,
          notes: '',
        );

    test('returns the bytes and reports final progress', () async {
      // Arrange
      var lastReceived = 0;
      var lastTotal = 0;
      final client = MockClient((req) async => http.Response.bytes(bytes, 200));
      final catalog = GitHubReleasesCatalog(client, slug: 'o/r');

      // Act
      final out = await catalog.download(
        relWith(),
        onProgress: (r, t) {
          lastReceived = r;
          lastTotal = t;
        },
      );

      // Assert
      expect(out, equals(bytes));
      expect(lastReceived, equals(bytes.length));
      expect(lastTotal, equals(bytes.length));
    });

    test('verifies a matching sha256 and returns the bytes', () async {
      // Arrange
      final hex = sha256.convert(bytes).toString();
      final client = MockClient((req) async {
        if (req.url.path.endsWith('.sha256')) {
          return http.Response('$hex  idl0.bin\n', 200);
        }
        return http.Response.bytes(bytes, 200);
      });
      final catalog = GitHubReleasesCatalog(client, slug: 'o/r');

      // Act
      final out = await catalog.download(
        relWith(shaUrl: Uri.parse('https://dl/firmware.bin.sha256')),
      );

      // Assert
      expect(out, equals(bytes));
    });

    test('throws FirmwareDownloadException on sha256 mismatch', () async {
      // Arrange
      final client = MockClient((req) async {
        if (req.url.path.endsWith('.sha256')) {
          return http.Response('deadbeef  idl0.bin\n', 200);
        }
        return http.Response.bytes(bytes, 200);
      });
      final catalog = GitHubReleasesCatalog(client, slug: 'o/r');

      // Act / Assert
      expect(
        () => catalog.download(
          relWith(shaUrl: Uri.parse('https://dl/firmware.bin.sha256')),
        ),
        throwsA(isA<FirmwareDownloadException>()),
      );
    });
  });
}
