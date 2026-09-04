import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Accounts the user has signed in with, per server, so coming back is one tap.
///
/// Only the server's long-lived bearer token is kept - never a password - and it
/// lives in the iOS Keychain / Android Keystore. A token the server rejects is
/// dropped and the user is asked for the password again with the email prefilled.
class SavedAccount {
  final String server; // normalized base URL, e.g. http://192.168.1.23:8000
  final String email;
  final String token; // '' once the server rejected it
  final DateTime usedAt;

  const SavedAccount({required this.server, required this.email, required this.token, required this.usedAt});

  bool get hasToken => token.isNotEmpty;
  String get initial => email.isEmpty ? '?' : email[0].toUpperCase();
  String get serverLabel => Uri.tryParse(server)?.host ?? server;

  SavedAccount copyWith({String? token, DateTime? usedAt}) =>
      SavedAccount(server: server, email: email, token: token ?? this.token, usedAt: usedAt ?? this.usedAt);

  Map<String, dynamic> toJson() => {'server': server, 'email': email, 'token': token, 'usedAt': usedAt.toIso8601String()};

  factory SavedAccount.fromJson(Map<String, dynamic> j) => SavedAccount(
        server: j['server'] as String,
        email: j['email'] as String,
        token: j['token'] as String? ?? '',
        usedAt: DateTime.tryParse(j['usedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
}

class SavedAccounts {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const _key = 'saved_accounts_v1';

  static String normalize(String server) => server.trim().replaceAll(RegExp(r'/+$'), '');

  static Future<List<SavedAccount>> all() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return [];
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>().map(SavedAccount.fromJson).toList();
      list.sort((a, b) => b.usedAt.compareTo(a.usedAt));
      return list;
    } catch (_) {
      return []; // unreadable store: behave as if nothing was saved
    }
  }

  static Future<void> _write(List<SavedAccount> list) =>
      _storage.write(key: _key, value: jsonEncode(list.map((a) => a.toJson()).toList()));

  /// Most recently used first.
  static Future<List<SavedAccount>> forServer(String server) async {
    final s = normalize(server);
    return (await all()).where((a) => a.server == s).toList();
  }

  /// Distinct servers, most recently used first.
  static Future<List<SavedAccount>> servers() async {
    final seen = <String>{};
    return (await all()).where((a) => seen.add(a.server)).toList();
  }

  static Future<void> remember(SavedAccount account) async {
    final list = await all();
    list.removeWhere((a) => a.server == account.server && a.email == account.email);
    list.insert(0, account);
    await _write(list);
  }

  static Future<void> forget(String server, String email) async {
    final list = await all();
    list.removeWhere((a) => a.server == normalize(server) && a.email == email);
    await _write(list);
  }

  /// The server rejected the token: keep the account (email prefill) without it.
  static Future<void> invalidateToken(String server, String email) async {
    final list = await all();
    final i = list.indexWhere((a) => a.server == normalize(server) && a.email == email);
    if (i >= 0) {
      list[i] = list[i].copyWith(token: '');
      await _write(list);
    }
  }
}
