import 'package:flutter/material.dart';

import 'package:weeing_app/gateway/gateway.dart';

import '../models/device_info.dart';

const Color _kBg = Color(0xFFF3F3F5);
const Color _kAccent = Color(0xFF0F766E);
const Color _kBorder = Color(0xFFE4E4EA);
const Color _kMuted = Color(0xFF8A8A8E);
const Color _kText = Color(0xFF1A1A1C);

const Color _kInfo = Color(0xFF64748B);
const Color _kWarn = Color(0xFFD97706);
const Color _kError = Color(0xFFDC2626);

class _LogEvent {
  final DateTime time;
  final String build;
  final String eventType;
  final String? message;
  final String level;
  final Map<String, dynamic>? meta;

  const _LogEvent({
    required this.time,
    required this.build,
    required this.eventType,
    required this.message,
    required this.level,
    required this.meta,
  });

  factory _LogEvent.fromJson(Map<String, dynamic> json) {
    final tsRaw = json['ts'];
    final tsSeconds =
        tsRaw is num ? tsRaw.toDouble() : double.tryParse('$tsRaw') ?? 0.0;
    return _LogEvent(
      time: DateTime.fromMillisecondsSinceEpoch((tsSeconds * 1000).round()),
      build: json['build']?.toString() ?? '',
      eventType: json['event_type']?.toString() ?? '',
      message: json['message']?.toString(),
      level: json['level']?.toString() ?? 'info',
      meta: json['meta'] is Map ? Map<String, dynamic>.from(json['meta']) : null,
    );
  }
}

String _eventTypeLabel(String type) {
  switch (type) {
    case 'build_start':
      return '빌드 시작';
    case 'build_stop':
      return '빌드 종료';
    case 'cycle':
      return '사이클';
    case 'gohome':
      return '귀환';
    case 'error':
      return '오류';
    case 'intr':
      return '인터럽트';
    default:
      return type;
  }
}

Color _levelColor(String level) {
  switch (level) {
    case 'error':
      return _kError;
    case 'warn':
      return _kWarn;
    default:
      return _kInfo;
  }
}

IconData _levelIcon(String level) {
  switch (level) {
    case 'error':
      return Icons.error;
    case 'warn':
      return Icons.warning_amber_rounded;
    default:
      return Icons.info_outline;
  }
}

class _DeviceBuildTarget {
  final String ip;
  final String build;

  const _DeviceBuildTarget({required this.ip, required this.build});
}

/// 당일 스케줄에 예약된 buildRun 블록들의 buildLogger 이벤트를 조회해 보여주는 검토 화면.
///
/// [blocks]는 `_ScheduleBlock.toJson()` 형태(deviceIp/type/account/time/cycles)의
/// 맵 목록을 그대로 받는다 (build_scheduler_dialog.dart의 private 타입에 직접 의존하지 않기 위함).
class BuildReviewScreen extends StatefulWidget {
  final DateTime date;
  final List<DeviceInfo> devices;
  final Map<String, String> buildMappings;
  final List<Map<String, dynamic>> blocks;

  const BuildReviewScreen({
    super.key,
    required this.date,
    required this.devices,
    required this.buildMappings,
    required this.blocks,
  });

  @override
  State<BuildReviewScreen> createState() => _BuildReviewScreenState();
}

class _BuildReviewScreenState extends State<BuildReviewScreen> {
  bool _isLoading = true;
  final Map<String, List<_LogEvent>> _eventsByDevice = {};
  late final List<_DeviceBuildTarget> _targets;

  @override
  void initState() {
    super.initState();
    _targets = _resolveTargets();
    _loadLogs();
  }

  List<_DeviceBuildTarget> _resolveTargets() {
    final seen = <String>{};
    final targets = <_DeviceBuildTarget>[];
    for (final raw in widget.blocks) {
      if (raw['type'] != 'buildRun') continue;
      final ip = raw['deviceIp']?.toString() ?? '';
      final account = raw['account']?.toString();
      if (ip.isEmpty || account == null) continue;

      final build = widget.buildMappings[account];
      if (build == null || build.isEmpty) continue;

      final key = '$ip|$build';
      if (!seen.add(key)) continue;
      targets.add(_DeviceBuildTarget(ip: ip, build: build));
    }
    return targets;
  }

  Future<void> _loadLogs() async {
    final dayStart = DateTime(widget.date.year, widget.date.month, widget.date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final since = dayStart.millisecondsSinceEpoch ~/ 1000;
    final until = dayEnd.millisecondsSinceEpoch ~/ 1000;

    final results = await Future.wait(_targets.map((target) async {
      final events = await _fetchLogs(target.ip, target.build, since, until);
      return MapEntry(target.ip, events);
    }));

    if (!mounted) return;

    for (final entry in results) {
      final list = _eventsByDevice.putIfAbsent(entry.key, () => []);
      list.addAll(entry.value);
    }
    for (final list in _eventsByDevice.values) {
      list.sort((a, b) => a.time.compareTo(b.time));
    }

    setState(() => _isLoading = false);
  }

  Future<List<_LogEvent>> _fetchLogs(
    String ip,
    String build,
    int since,
    int until,
  ) async {
    try {
      final res = await Gateway.call(
        ip,
        'buildLogger/logs',
        method: 'GET',
        params: {'build': build, 'since': since, 'until': until},
      );
      final resp = Gateway.unwrap(res);
      if (resp is List) {
        return resp
            .whereType<Map>()
            .map((e) => _LogEvent.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  String _formatDate(DateTime date) =>
      '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';

  String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        title: Text(
          '빌드 검토 · ${_formatDate(widget.date)}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.white,
        foregroundColor: _kText,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
      ),
      body: SafeArea(top: false, child: _content()),
    );
  }

  Widget _content() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }

    if (_targets.isEmpty) {
      return _emptyState(
        icon: Icons.event_busy_outlined,
        text: '이 날짜에 예약된 빌드가 없습니다.',
      );
    }

    final hasAnyEvents = _eventsByDevice.values.any((list) => list.isNotEmpty);
    if (!hasAnyEvents) {
      return _emptyState(
        icon: Icons.inbox_outlined,
        text: '기록된 이벤트가 없습니다.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        for (final target in _targets)
          if ((_eventsByDevice[target.ip] ?? const []).isNotEmpty)
            _deviceSection(target, _eventsByDevice[target.ip]!),
      ],
    );
  }

  Widget _emptyState({required IconData icon, required String text}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: _kMuted),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(color: _kMuted)),
        ],
      ),
    );
  }

  Widget _deviceSection(_DeviceBuildTarget target, List<_LogEvent> events) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Row(
              children: [
                const Icon(Icons.desktop_windows_outlined, size: 18, color: _kAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${target.ip}  ·  ${target.build}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      color: _kText,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _kBorder),
          for (var i = 0; i < events.length; i++)
            _eventTile(events[i], isLast: i == events.length - 1),
        ],
      ),
    );
  }

  Widget _eventTile(_LogEvent event, {required bool isLast}) {
    final color = _levelColor(event.level);
    final icon = _levelIcon(event.level);
    String? intrName;
    if (event.eventType == 'intr') {
      intrName = event.meta?['intr_name']?.toString();
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(14, 10, 14, isLast ? 12 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      intrName == null
                          ? _eventTypeLabel(event.eventType)
                          : '${_eventTypeLabel(event.eventType)} · $intrName',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: color,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatTime(event.time),
                      style: const TextStyle(fontSize: 12, color: _kMuted),
                    ),
                  ],
                ),
                if (event.message != null && event.message!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.message!,
                    style: const TextStyle(fontSize: 12.5, color: _kText),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
