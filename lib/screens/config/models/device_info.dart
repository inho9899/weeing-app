import 'package:flutter/material.dart';

class DeviceInfo {
  final String ip;
  final String name;
  /// cloudflare 의 device_names.json 매핑 키. PC 핸드셰이크로 얻은 값이라
  /// 구버전에서 마이그레이션된 기기는 없을 수 있다(null) — 그런 기기는
  /// 이름 수정/삭제 시 cloudflare 쪽 매핑을 건드릴 수 없다.
  final String? deviceId;
  final Color color;
  final bool enabled;

  const DeviceInfo({
    required this.ip,
    String? name,
    this.deviceId,
    this.color = Colors.grey,
    this.enabled = false,
  }) : name = name ?? ip;

  DeviceInfo copyWith({
    String? ip,
    String? name,
    String? deviceId,
    Color? color,
    bool? enabled,
  }) {
    return DeviceInfo(
      ip: ip ?? this.ip,
      name: name ?? this.name,
      deviceId: deviceId ?? this.deviceId,
      color: color ?? this.color,
      enabled: enabled ?? this.enabled,
    );
  }
}
