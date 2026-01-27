import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Lobby API 서비스 클래스
class LobbyApiService {
  final String basePath;

  LobbyApiService({required this.basePath});

  // =========================================================
  // URL Getters
  // =========================================================

  String get _statusUrl => '${basePath}status/';
  String get _buildListUrl => '${basePath}build/list';
  String get _setCycleUrl => '${basePath}status/cycle/set';
  String get _startTimeUrl => '${basePath}status/start_time';
  String get _inputSequenceUrl => '${basePath}input/sequence';
  String get _pauseUrl => '${basePath}weeing/pause';
  String get _resumeUrl => '${basePath}weeing/resume';
  String get _convertUrl => '${basePath}input/convert_mode';
  String get _macrosUrl => '${basePath}weeing/macros';
  String get _mouseMoveToUrl => '${basePath}mouse/MouseMoveTo';
  String get _mouseClickAtUrl => '${basePath}mouse/MouseClickAt';

  String startUrl(String mapName) =>
      '${basePath}weeing/start/${Uri.encodeComponent(mapName)}';

  // =========================================================
  // Build List
  // =========================================================

  Future<List<String>> fetchBuildList() async {
    try {
      final res = await http.get(Uri.parse(_buildListUrl));
      if (res.statusCode != 200) return [];
      final payload = jsonDecode(res.body);
      return (payload['data'] as List?)?.map((e) => e.toString()).toList() ??
          [];
    } catch (_) {
      return [];
    }
  }

  // =========================================================
  // Status
  // =========================================================

  Future<Map<String, String>?> fetchStatus() async {
    try {
      final res = await http.get(Uri.parse(_statusUrl));
      if (res.statusCode != 200) return null;

      final payload = jsonDecode(res.body);
      final dataStr = payload['data'] as String?;
      return _parseStatusData(dataStr);
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _parseStatusData(String? dataStr) {
    final out = <String, String>{};
    if (dataStr == null) return out;
    for (final seg in dataStr.split(',')) {
      final parts = seg.split(':');
      if (parts.isEmpty) continue;
      final key = parts[0].trim();
      final value = parts.sublist(1).join(':').trim();
      if (key.isEmpty) continue;
      out[key] = value;
    }
    return out;
  }

  // =========================================================
  // Cycle / Start Time
  // =========================================================

  Future<void> setCycle(int value) async {
    try {
      await http.post(
        Uri.parse(_setCycleUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(value),
      );
    } catch (_) {}
  }

  Future<void> sendStartTimeDelta(int hDelta, int mDelta) async {
    try {
      await http.post(
        Uri.parse(_startTimeUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'hour': hDelta, 'minute': mDelta}),
      );
    } catch (_) {}
  }

  // =========================================================
  // Start / Pause / Resume
  // =========================================================

  Future<bool> start(String mapName) async {
    if (mapName.isEmpty) return false;
    try {
      final res = await http.post(Uri.parse(startUrl(mapName)));
      if (res.statusCode == 409) {
        final resumeRes = await http.post(Uri.parse(_resumeUrl));
        return resumeRes.statusCode == 200;
      }
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> pause() async {
    try {
      final res = await http.post(Uri.parse(_pauseUrl));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // =========================================================
  // Input
  // =========================================================

  Future<bool> sendInputSequence(String msg) async {
    if (msg.isEmpty) return false;
    try {
      final url = '$_inputSequenceUrl/${Uri.encodeComponent(msg)}';
      final res = await http.post(Uri.parse(url));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> convertMode() async {
    try {
      final res = await http.post(Uri.parse(_convertUrl));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // =========================================================
  // Simple POST
  // =========================================================

  Future<void> callSimplePost(String path) async {
    try {
      await http.post(Uri.parse('$basePath$path'));
    } catch (_) {}
  }

  Future<void> login(String id, String pw) async {
    await callSimplePost('weeing/login?id=$id&pw=$pw');
  }

  // =========================================================
  // Macros
  // =========================================================

  Future<List<Map<String, dynamic>>> fetchMacros() async {
    try {
      final res = await http.get(Uri.parse(_macrosUrl));
      if (res.statusCode == 200) {
        final payload = jsonDecode(res.body);
        final data = payload['data'] as List?;
        if (data != null) {
          return data.map((e) => Map<String, dynamic>.from(e)).toList();
        }
      }
    } catch (_) {}
    return [];
  }

  // =========================================================
  // Mouse API
  // =========================================================

  Future<void> sendMouseMoveTo(
    double touchX,
    double touchY,
    double viewWidth,
    double viewHeight,
  ) async {
    try {
      final uri = Uri.parse(_mouseMoveToUrl).replace(queryParameters: {
        'touch_x': touchX.toString(),
        'touch_y': touchY.toString(),
        'view_width': viewWidth.toString(),
        'view_height': viewHeight.toString(),
      });
      await http.post(uri);
    } catch (e) {
      debugPrint('MouseMoveTo error: $e');
    }
  }

  Future<void> sendMouseClickAt(
    double touchX,
    double touchY,
    double viewWidth,
    double viewHeight,
    String button,
  ) async {
    try {
      final uri = Uri.parse(_mouseClickAtUrl).replace(queryParameters: {
        'touch_x': touchX.toString(),
        'touch_y': touchY.toString(),
        'view_width': viewWidth.toString(),
        'view_height': viewHeight.toString(),
        'button': button,
      });
      await http.post(uri);
    } catch (e) {
      debugPrint('MouseClickAt error: $e');
    }
  }
}
