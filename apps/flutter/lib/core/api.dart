import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'billing.dart';

class Session {
  Session({
    required this.api,
    required this.token,
    required this.user,
    required this.branchId,
    required this.organizationId,
    required this.expiresAt,
  });

  final String api;
  final String token;
  Json user;
  final String branchId;
  final String organizationId;
  final String expiresAt;

  String get role => '${user['role'] ?? ''}';
  String get userId => '${user['id'] ?? ''}';

  Json toJson() => {
        'api': api,
        'token': token,
        'user': user,
        'branchId': branchId,
        'organizationId': organizationId,
        'expiresAt': expiresAt,
      };

  static Session? fromJson(Object? value) {
    if (value is! Map) return null;
    return Session(
      api: '${value['api']}',
      token: '${value['token']}',
      user: Map<String, dynamic>.from(value['user'] as Map? ?? {}),
      branchId: '${value['branchId']}',
      organizationId: '${value['organizationId']}',
      expiresAt: '${value['expiresAt']}',
    );
  }

  /// Local data is kept apart for every server, organization, branch and user.
  String get scope =>
      'workspace-${Uri.parse(api).host}-$organizationId-$branchId-${user['id']}'.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '_');
}

class ApiError implements Exception {
  ApiError(this.message, this.status);
  final String message;
  final int status;
  bool get rejected => status >= 400 && status < 500 && !const {401, 408, 425, 429}.contains(status);
  @override
  String toString() => message;
}

/// A network problem, as opposed to the server refusing the request.
class OfflineError implements Exception {
  OfflineError(this.message);
  final String message;
  @override
  String toString() => message;
}

final _client = http.Client();

Future<dynamic> request(String api, String token, String path,
    {Object? body, String? method}) async {
  final uri = Uri.parse('$api$path');
  final verb = method ?? (body == null ? 'GET' : 'POST');
  final headers = {
    if (body != null) 'Content-Type': 'application/json',
    if (token.isNotEmpty) 'Authorization': 'Bearer $token',
  };
  http.Response response;
  try {
    final req = http.Request(verb, uri)..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);
    response = await http.Response.fromStream(
        await _client.send(req).timeout(const Duration(seconds: 15))).timeout(const Duration(seconds: 30));
  } on TimeoutException {
    throw OfflineError('The server took too long to respond. Check the connection.');
  } on http.ClientException {
    throw OfflineError('Cannot reach the server. Check the network connection.');
  }
  dynamic result;
  try {
    result = response.body.isEmpty ? null : jsonDecode(response.body);
  } catch (_) {
    result = {'message': response.body};
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final map = result is Map ? result : const {};
    throw ApiError('${map['error'] ?? map['message'] ?? 'The request failed.'}', response.statusCode);
  }
  return result;
}

/// Reads a small public JSON file, such as the web installation defaults.
Future<dynamic> fetchJson(Uri uri) async {
  final response = await _client.get(uri).timeout(const Duration(seconds: 3));
  if (response.statusCode != 200) return null;
  return jsonDecode(response.body);
}

/// Downloads a file (such as a part photo) from the API.
Future<List<int>> fetchBytes(String api, String token, String path) async {
  try {
    final response = await _client
        .get(Uri.parse('$api$path'), headers: {if (token.isNotEmpty) 'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw ApiError('Could not load the photo.', response.statusCode);
    return response.bodyBytes;
  } on TimeoutException {
    throw OfflineError('The server took too long to respond.');
  } on http.ClientException {
    throw OfflineError('Cannot reach the server.');
  }
}
