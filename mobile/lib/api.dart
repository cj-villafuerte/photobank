import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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

  /// Returns the subset of [checksums] the server already has.
  Future<Set<String>> existingChecksums(List<String> checksums) async {
    final existing = <String>{};
    // server caps the list at 2000 per request
    for (var i = 0; i < checksums.length; i += 1000) {
      final batch = checksums.sublist(i, i + 1000 > checksums.length ? checksums.length : i + 1000);
      final res = await http.post(
        _u('/api/assets/exists'),
        headers: _headers,
        body: jsonEncode({'checksums': batch}),
      );
      if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
      existing.addAll((jsonDecode(res.body)['existing'] as List).cast<String>());
    }
    return existing;
  }

  /// Uploads one file; returns true if newly stored, false if it was a duplicate.
  Future<bool> upload(File file, String filename, DateTime? takenAt) async {
    final req = http.MultipartRequest('POST', _u('/api/assets'));
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('file', file.path, filename: filename));
    if (takenAt != null) {
      req.fields['last_modified_ms'] = takenAt.millisecondsSinceEpoch.toString();
    }
    final streamed = await req.send().timeout(const Duration(minutes: 10));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode == 201) return true;
    if (res.statusCode == 200) return false; // duplicate
    throw ApiException(res.statusCode, _detail(res));
  }

  String _detail(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['detail'] is String) return body['detail'] as String;
    } catch (_) {}
    return res.reasonPhrase ?? 'HTTP ${res.statusCode}';
  }
}
