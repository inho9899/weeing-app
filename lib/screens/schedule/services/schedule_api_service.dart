import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:weeing_app/gateway/gateway.dart';
import '../models/schedule_plan.dart';

/// 프록시 `/schedule/*`. PC 로 프록시되지 않고 프록시 자신의 저장소(app.db schedules)를 읽고 쓴다 —
/// build_mapping 과 같은 부류라 Gateway.call 이 아니라 프록시 주소로 직접 부른다.
///
/// PC 키는 device_id 다 (IP 는 DHCP 로 바뀐다). 구버전에서 올라와 device_id 가 없는 기기는 ip 를 키로 쓴다.
class ScheduleApi {
  ScheduleApi._();

  static Uri _uri(String path) => Uri.parse('${Gateway.cloudflareBase}/schedule/$path');

  static Future<ScheduleInfo?> fetch(String deviceKey) async {
    try {
      final res = await http
          .get(_uri('plan/${Uri.encodeComponent(deviceKey)}'))
          .timeout(const Duration(seconds: 8));
      final resp = Gateway.unwrap(res);
      if (resp is! Map) return null;
      return ScheduleInfo.fromJson(Map<String, dynamic>.from(resp));
    } catch (_) {
      return null;
    }
  }

  /// 성공하면 null, 실패하면 사용자에게 보여줄 메시지.
  static Future<String?> savePlan(String deviceKey, String ip, SchedulePlan plan) async {
    try {
      final res = await http
          .put(
            _uri('plan/${Uri.encodeComponent(deviceKey)}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'ip': ip, 'plan': plan.toJson()}),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return '저장 실패 (HTTP ${res.statusCode})';
      if (Gateway.unwrap(res) == 0) return null;
      return Gateway.message(res) ?? '프록시가 계획을 받지 않았다';
    } catch (_) {
      return '프록시에 연결하지 못했다';
    }
  }

  /// 성공하면 null, 실패하면 메시지.
  static Future<String?> setEnabled(String deviceKey, bool enabled) async {
    try {
      final res = await http
          .post(_uri('enabled/${Uri.encodeComponent(deviceKey)}?enabled=$enabled'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return '전환 실패 (HTTP ${res.statusCode})';
      if (Gateway.unwrap(res) == 0) return null;
      return Gateway.message(res) ?? '프록시가 전환을 받지 않았다';
    } catch (_) {
      return '프록시에 연결하지 못했다';
    }
  }

  static Future<ScheduleStatus?> fetchStatus(String deviceKey) async {
    try {
      final res = await http
          .get(_uri('status/${Uri.encodeComponent(deviceKey)}'))
          .timeout(const Duration(seconds: 5));
      final resp = Gateway.unwrap(res);
      if (resp is! Map) return null;
      return ScheduleStatus.fromJson(Map<String, dynamic>.from(resp));
    } catch (_) {
      return null;
    }
  }
}
