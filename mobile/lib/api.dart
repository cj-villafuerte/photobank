import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// MultipartRequest that reports how many bytes have been handed to the
/// HTTP client, so the UI can show per-file upload progress.
class _ProgressMultipartRequest extends http.MultipartRequest {
  final void Function(int sent, int total) onProgress;
  _ProgressMultipartRequest(super.method, super.url, {required this.onProgress});

  @override
  http.ByteStream finalize() {
    final total = contentLength;
    var sent = 0;
    final stream = super.finalize().transform<List<int>>(
      StreamTransformer.fromHandlers(handleData: (chunk, sink) {
        sent += chunk.length;
        onProgress(sent, total);
        sink.add(chunk);
      }),
    );
    return http.ByteStream(stream);
  }
}

class TimelineBucket {
  final String bucket; // "2026-09"
  final int count;
  const TimelineBucket(this.bucket, this.count);
}

class RemoteAsset {
  final String id;
  final String assetType; // image | video
  final DateTime takenAt;
  final bool isFavorite;
  final double? durationSec;
  final bool hasLiveVideo;
  const RemoteAsset(this.id, this.assetType, this.takenAt, this.isFavorite, this.durationSec,
      this.hasLiveVideo);

  factory RemoteAsset.fromJson(Map<String, dynamic> j) => RemoteAsset(
        j['id'] as String,
        j['asset_type'] as String,
        DateTime.parse(j['taken_at'] as String).toLocal(),
        j['is_favorite'] as bool? ?? false,
        (j['duration_sec'] as num?)?.toDouble(),
        j['has_live_video'] as bool? ?? false,
      );
}

class ExistsDetail {
  final String assetId;
  final bool hasLiveVideo;
  const ExistsDetail(this.assetId, this.hasLiveVideo);
}

class UploadOutcome {
  final bool isNew;
  final String? assetId;
  const UploadOutcome(this.isNew, this.assetId);
}

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException($status): $message';
}

class PhotobankApi {
  String baseUrl; // e.g. http://192.168.1.23:8000
  String? token;

  PhotobankApi({required this.baseUrl, this.token});

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Future<void> checkHealth() async {
    final res = await http.get(_u('/api/health')).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'Server responded but health check failed');
    }
  }

  /// Exchanges credentials for a long-lived bearer token.
  Future<String> login(String email, String password) async {
    final res = await http.post(
      _u('/api/auth/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _detail(res));
    }
    token = jsonDecode(res.body)['token'] as String;
    return token!;
  }

  Future<Map<String, dynamic>> me() async {
    final res = await http.get(_u('/api/auth/me'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// For each checksum the server already has: its asset id + live-video state.
  Future<Map<String, ExistsDetail>> existingChecksums(List<String> checksums) async {
    final existing = <String, ExistsDetail>{};
    // server caps the list at 2000 per request
    for (var i = 0; i < checksums.length; i += 1000) {
      final batch = checksums.sublist(i, i + 1000 > checksums.length ? checksums.length : i + 1000);
      final res = await http.post(
        _u('/api/assets/exists'),
        headers: _headers,
        body: jsonEncode({'checksums': batch}),
      );
      if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      for (final d in (body['details'] as List? ?? [])) {
        existing[d['checksum'] as String] =
            ExistsDetail(d['asset_id'] as String, d['has_live_video'] as bool? ?? false);
      }
      // older servers only send 'existing' checksums without details
      for (final c in (body['existing'] as List? ?? []).cast<String>()) {
        existing.putIfAbsent(c, () => const ExistsDetail('', true));
      }
    }
    return existing;
  }

  /// Uploads one file; reports whether it was newly stored and its server id.
  Future<UploadOutcome> upload(
    File file,
    String filename,
    DateTime? takenAt, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final req = onProgress != null
        ? _ProgressMultipartRequest('POST', _u('/api/assets'), onProgress: onProgress)
        : http.MultipartRequest('POST', _u('/api/assets'));
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('file', file.path, filename: filename));
    if (takenAt != null) {
      req.fields['last_modified_ms'] = takenAt.millisecondsSinceEpoch.toString();
    }
    final streamed = await req.send().timeout(const Duration(minutes: 10));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode == 201 || res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return UploadOutcome(res.statusCode == 201, body['asset_id'] as String?);
    }
    throw ApiException(res.statusCode, _detail(res));
  }

  /// Attaches the video half of a Live Photo to an already-uploaded still.
  Future<void> uploadLiveVideo(String assetId, File file) async {
    final req = http.MultipartRequest('POST', _u('/api/assets/$assetId/live-video'));
    req.headers.addAll(authHeaders);
    req.files.add(await http.MultipartFile.fromPath('file', file.path, filename: 'live.mov'));
    final streamed = await req.send().timeout(const Duration(minutes: 10));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ApiException(res.statusCode, _detail(res));
    }
  }

  String liveVideoUrl(String id) => '$baseUrl/api/assets/$id/live-video';
  String originalUrl(String id) => '$baseUrl/api/assets/$id/original';

  Map<String, String> get authHeaders =>
      {if (token != null) 'Authorization': 'Bearer $token'};

  String thumbUrl(String id) => '$baseUrl/api/assets/$id/thumbnail';
  String previewUrl(String id) => '$baseUrl/api/assets/$id/preview';

  Future<List<TimelineBucket>> buckets() async {
    final res = await http.get(_u('/api/timeline/buckets'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((b) => TimelineBucket(b['bucket'] as String, b['count'] as int))
        .toList();
  }

  Future<List<RemoteAsset>> bucketAssets(String bucket) async {
    final res = await http.get(_u('/api/timeline/bucket/$bucket'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((j) => RemoteAsset.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<String> originalFilename(String id) async {
    final res = await http.get(_u('/api/assets/$id'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as Map<String, dynamic>)['original_filename'] as String;
  }

  /// Streams the original file to [dest] without buffering it in memory.
  Future<void> downloadOriginal(String id, File dest,
      {void Function(int received, int total)? onProgress}) async {
    final req = http.Request('GET', _u('/api/assets/$id/original'));
    req.headers.addAll(authHeaders);
    final res = await http.Client().send(req);
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'Download failed');
    }
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = dest.openWrite();
    try {
      await for (final chunk in res.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
    }
  }

  String _detail(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['detail'] is String) return body['detail'] as String;
    } catch (_) {}
    return res.reasonPhrase ?? 'HTTP ${res.statusCode}';
  }
}
