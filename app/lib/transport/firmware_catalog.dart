/// Remote firmware release feed + image download. See SPEC §27.7.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import '../data/exceptions.dart';

/// GitHub `owner/repo` slug the app pulls firmware releases from.
///
/// Placeholder until the firmware repo is split out under the `saucyeng`
/// org (design §3/§4). Changing the firmware host is a one-line edit here.
const String kFirmwareRepoSlug = 'saucyeng/idl0-firmware';

/// Release channel the user follows; maps onto the GitHub prerelease flag.
enum FirmwareChannel {
  /// Latest non-prerelease build.
  stable,

  /// Latest build including prereleases (bleeding edge).
  beta,
}

/// One published firmware build, normalized from a GitHub release.
class FirmwareRelease {
  /// Semantic version parsed from the release tag (leading `v` stripped).
  final Version version;

  /// Channel this release was selected for.
  final FirmwareChannel channel;

  /// Direct download URL of the `.bin` asset.
  final Uri binUrl;

  /// Size of the `.bin` asset in bytes (drives the download progress bar).
  final int sizeBytes;

  /// URL of the `*.sha256` checksum asset, or null if none was published.
  /// Fetched lazily at download time so [FirmwareCatalog.latest] stays a
  /// single request.
  final Uri? sha256Url;

  /// Release notes (the GitHub release body), shown in the update prompt.
  final String notes;

  /// Creates a [FirmwareRelease].
  const FirmwareRelease({
    required this.version,
    required this.channel,
    required this.binUrl,
    required this.sizeBytes,
    required this.sha256Url,
    required this.notes,
  });
}

/// Remote source of published firmware builds.
abstract class FirmwareCatalog {
  /// Latest published build on [channel], or null when none exists.
  ///
  /// Throws [FirmwareCatalogException] only on a hard transport/parse
  /// failure; an absent or asset-less release resolves to null.
  Future<FirmwareRelease?> latest(FirmwareChannel channel);

  /// Downloads [release]'s `.bin` into memory, reporting `(received, total)`
  /// via [onProgress]. When [release.sha256Url] is non-null the bytes are
  /// verified; a mismatch throws [FirmwareDownloadException].
  Future<Uint8List> download(
    FirmwareRelease release, {
    void Function(int received, int total)? onProgress,
  });
}

/// [FirmwareCatalog] backed by the public GitHub Releases REST API.
///
/// Because the firmware repo holds nothing else, stable reads
/// `/releases/latest` directly and beta lists `/releases`. No auth token —
/// the repo is public; unauthenticated traffic is well under the 60 req/hr
/// limit for update checks.
class GitHubReleasesCatalog implements FirmwareCatalog {
  final http.Client _client;
  final String _slug;

  /// Creates a catalog for [slug] (`owner/repo`) over [client].
  GitHubReleasesCatalog(http.Client client, {String slug = kFirmwareRepoSlug})
      : _client = client,
        _slug = slug;

  static const _accept = {'Accept': 'application/vnd.github+json'};

  @override
  Future<FirmwareRelease?> latest(FirmwareChannel channel) async {
    final Map<String, dynamic>? release = switch (channel) {
      FirmwareChannel.stable => await _latestStable(),
      FirmwareChannel.beta => await _latestBeta(),
    };
    if (release == null) return null;
    return _toRelease(release, channel);
  }

  Future<Map<String, dynamic>?> _latestStable() async {
    final uri = Uri.https('api.github.com', '/repos/$_slug/releases/latest');
    final resp = await _get(uri);
    if (resp.statusCode == 404) return null; // no published release yet
    _ensureOk(resp);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> _latestBeta() async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$_slug/releases',
      {'per_page': '20'},
    );
    final resp = await _get(uri);
    if (resp.statusCode == 404) return null;
    _ensureOk(resp);
    final list = (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
    for (final r in list) {
      if (r['draft'] == true) continue;
      return r; // newest non-draft, prerelease or not
    }
    return null;
  }

  Future<http.Response> _get(Uri uri) async {
    try {
      return await _client.get(uri, headers: _accept);
    } on Object catch (e) {
      throw FirmwareCatalogException('firmware feed unreachable: $e');
    }
  }

  void _ensureOk(http.Response resp) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw FirmwareCatalogException('firmware feed HTTP ${resp.statusCode}');
    }
  }

  /// Builds a [FirmwareRelease] from one release JSON object, or null when it
  /// has no `.bin` asset or an unparseable tag.
  FirmwareRelease? _toRelease(Map<String, dynamic> r, FirmwareChannel channel) {
    final tag = (r['tag_name'] as String?) ?? '';
    final Version version;
    try {
      version = Version.parse(tag.startsWith('v') ? tag.substring(1) : tag);
    } on FormatException {
      return null;
    }
    final assets = (r['assets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    Map<String, dynamic>? bin;
    Map<String, dynamic>? sha;
    for (final a in assets) {
      final name = (a['name'] as String?) ?? '';
      if (name.endsWith('.sha256')) {
        sha = a;
      } else if (name.endsWith('.bin')) {
        bin = a;
      }
    }
    if (bin == null) return null;
    return FirmwareRelease(
      version: version,
      channel: channel,
      binUrl: Uri.parse(bin['browser_download_url'] as String),
      sizeBytes: (bin['size'] as num?)?.toInt() ?? 0,
      sha256Url:
          sha == null ? null : Uri.parse(sha['browser_download_url'] as String),
      notes: (r['body'] as String?) ?? '',
    );
  }

  @override
  Future<Uint8List> download(
    FirmwareRelease release, {
    void Function(int received, int total)? onProgress,
  }) async {
    final http.StreamedResponse resp;
    try {
      resp = await _client.send(http.Request('GET', release.binUrl));
    } on Object catch (e) {
      throw FirmwareDownloadException('download failed: $e');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw FirmwareDownloadException('download HTTP ${resp.statusCode}');
    }
    final total = resp.contentLength ?? release.sizeBytes;
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in resp.stream) {
      builder.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    final bytes = builder.toBytes();

    final shaUrl = release.sha256Url;
    if (shaUrl != null) {
      final http.Response shaResp;
      try {
        shaResp = await _client.get(shaUrl);
      } on Object catch (e) {
        throw FirmwareDownloadException('checksum fetch failed: $e');
      }
      // `<hex>  <filename>` is the sha256sum format; take the first token.
      final expected =
          shaResp.body.trim().split(RegExp(r'\s')).first.toLowerCase();
      final actual = sha256.convert(bytes).toString();
      if (actual != expected) {
        throw const FirmwareDownloadException(
          'firmware checksum mismatch — download corrupt',
        );
      }
    }
    return bytes;
  }
}
