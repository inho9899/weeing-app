import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:weeing_app/gateway/gateway.dart';

/// Lobby API 서비스.
///
/// SoT 는 msaInstaller 의 gateway.py. 각 호출을 해당 MSA 서비스로 직행 라우팅한다.
/// (모든 요청은 [Gateway] → cloudflare → 대상 머신(ip) 의 서비스로 전달)
class LobbyApiService {
  /// 대상 머신 IP (예: "192.168.0.5")
  final String ip;

  LobbyApiService({required this.ip});

  // ── statusChecker ──

  Future<Map<String, String>?> fetchStatus() async {
    try {
      final res = await Gateway.call(ip, 'statusChecker/status/get', method: 'GET');
      final resp = Gateway.unwrap(res);
      if (resp == null) return null;
      return statusMapOf(resp);
    } catch (_) {
      return null;
    }
  }

  /// 통일 봉투의 resp 를 상태 Map 으로 변환. Map 이든 "k:v,k:v" 문자열이든 지원.
  static Map<String, String> statusMapOf(dynamic resp) {
    if (resp is Map) {
      return resp.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    if (resp is String) return _parseStatusData(resp);
    return {};
  }

  static Map<String, String> _parseStatusData(String? dataStr) {
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

  /// gateway.py set_exp_cycle → statusChecker /cycle/set?cycle=
  Future<void> setCycle(int value) async {
    try {
      await Gateway.call(ip, 'statusChecker/cycle/set',
          method: 'POST', params: {'cycle': value});
    } catch (_) {}
  }

  // ── mainAction ──

  Future<List<String>> fetchBuildList() async {
    try {
      final res = await Gateway.call(ip, 'mainAction/build/list', method: 'GET');
      if (res.statusCode != 200) return [];

      final dynamic body = jsonDecode(res.body);

      if (body is List) {
        return body.map((e) => e.toString()).toList();
      }

      if (body is Map) {
        final resp = body['resp'];
        if (resp is List) {
          return resp.map((e) => e.toString()).toList();
        }

        final data = body['data'];
        if (data is List) {
          return data.map((e) => e.toString()).toList();
        }
      }

      return [];
    } catch (_) {
      return [];
    }
  }

  /// 시작. 이미 실행 중(409)이면 재개(intrAction/continue = gateway.py continue_main).
  Future<bool> start(String mapName, int startHour, int startMinute) async {
    if (mapName.isEmpty) return false;
    try {
      final api =
          'mainAction/weeing/start/${Uri.encodeComponent(mapName)}/$startHour/$startMinute';
      final res = await Gateway.call(ip, api, method: 'POST');
      if (res.statusCode == 409) {
        final resumeRes = await Gateway.call(ip, 'intrAction/continue', method: 'POST');
        return resumeRes.statusCode == 200;
      }
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> pause() async {
    try {
      final res = await Gateway.call(ip, 'mainAction/weeing/pause', method: 'POST');
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 현재 실행 중인 빌드명. gateway.py get_running_build → mainAction /weeing/running_build.
  /// 실행 중이 아니면(resp == -1) null.
  Future<String?> fetchRunningBuild() async {
    try {
      final res = await Gateway.call(ip, 'mainAction/weeing/running_build', method: 'GET');
      final resp = Gateway.unwrap(res);
      if (resp is String && resp.isNotEmpty && resp != 'None') return resp;
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── subAction ──

  Future<bool> sendInputSequence(String msg) async {
    if (msg.isEmpty) return false;
    try {
      final api = 'subaction/input/sequence/${Uri.encodeComponent(msg)}';
      final res = await Gateway.call(ip, api, method: 'POST');
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> convertMode() async {
    try {
      final res = await Gateway.call(ip, 'subaction/input/convert_mode', method: 'POST');
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> fetchMacros() async {
    try {
      final res = await Gateway.call(ip, 'subaction/weeing/macros', method: 'GET');
      final resp = Gateway.unwrap(res);
      if (resp is List) {
        return resp.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> login(String id, String pw) async {
    try {
      await Gateway.call(ip, 'subaction/weeing/login',
          method: 'POST', params: {'id': id, 'pw': pw});
    } catch (_) {}
  }

  Future<void> logout() async {
    try {
      await Gateway.call(ip, 'subaction/weeing/logout', method: 'POST');
    } catch (_) {}
  }

  // ── inputHandler (마우스) ──

  /// 영상 절대좌표 이동. gateway.py mouse_move → inputHandler /mouse/move?x=&y=
  Future<void> mouseMove(int x, int y) async {
    try {
      await Gateway.call(ip, 'inputHandler/mouse/move',
          method: 'POST', params: {'x': x, 'y': y});
    } catch (e) {
      debugPrint('mouseMove error: $e');
    }
  }

  /// 영상 절대좌표 클릭. gateway.py mouse_click → inputHandler /mouse/click?click_mode=&delay=&x=&y=
  Future<void> mouseClickAt(String button, int x, int y) async {
    try {
      await Gateway.call(ip, 'inputHandler/mouse/click',
          method: 'POST',
          params: {'click_mode': button, 'delay': 0, 'x': x, 'y': y});
    } catch (e) {
      debugPrint('mouseClickAt error: $e');
    }
  }
}
