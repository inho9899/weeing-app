import 'package:flutter/material.dart';

class DeviceInfo {
  final String ip;
  final Color color;
  final bool enabled;

  const DeviceInfo({
    required this.ip,
    this.color = Colors.grey,
    this.enabled = false,
  });

  DeviceInfo copyWith({
    String? ip,
    Color? color,
    bool? enabled,
  }) {
    return DeviceInfo(
      ip: ip ?? this.ip,
      color: color ?? this.color,
      enabled: enabled ?? this.enabled,
    );
  }
}
