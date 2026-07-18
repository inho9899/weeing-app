import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:weeing_app/gateway/gateway.dart';

import '../models/device_info.dart';
import '../../lobby/widgets/start_time_control.dart';

const Color _kBg = Color(0xFFF3F3F5);
const Color _kAccent = Color(0xFF0F766E);
const Color _kBorder = Color(0xFFE4E4EA);
const Color _kMuted = Color(0xFF8A8A8E);
const Color _kText = Color(0xFF1A1A1C);
const Color _kGreen = Color(0xFF16A34A);
const Color _kBuildColor = Color(0xFF7A1B3B);
const Color _kLoginColor = Color(0xFF2563EB);
const Color _kLogoutColor = Color(0xFF64748B);

const double _kRowHeight = 120.0;
const double _kHourLabelWidth = 56.0;
const double _kDeviceHeaderHeight = 44.0;
const double _kMinColumnWidth = 112.0;
const int _kFixedActionMinutes = 5;
const int _kMinutesPerCycle = 30;
const int _kBuildOverheadMinutes = 15;

bool _isValidTime(String? value) {
  if (value == null || value.isEmpty) return false;
  return RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value);
}

TimeOfDay? _parseTimeOfDayStr(String? value) {
  if (!_isValidTime(value)) return null;
  final parts = value!.split(':');
  return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
}

String _hourLabelKorean(int hour) {
  if (hour == 0) return '오전 12';
  if (hour < 12) return '오전 $hour';
  if (hour == 12) return '오후 12';
  return '오후 ${hour - 12}';
}

enum _BlockType { login, logout, buildRun }

Color _blockColor(_BlockType type) {
  switch (type) {
    case _BlockType.login:
      return _kLoginColor;
    case _BlockType.logout:
      return _kLogoutColor;
    case _BlockType.buildRun:
      return _kBuildColor;
  }
}

String _blockTypeLabel(_BlockType type) {
  switch (type) {
    case _BlockType.login:
      return '로그인';
    case _BlockType.logout:
      return '로그아웃';
    case _BlockType.buildRun:
      return '빌드실행';
  }
}

int _blockDurationMinutesFor(_BlockType type, int? cycles) {
  switch (type) {
    case _BlockType.login:
    case _BlockType.logout:
      return _kFixedActionMinutes;
    case _BlockType.buildRun:
      return (cycles ?? 1) * _kMinutesPerCycle + _kBuildOverheadMinutes;
  }
}

int _blockDurationMinutes(_ScheduleBlock block) {
  return _blockDurationMinutesFor(block.type, block.cycles);
}

int _blockStartMinutes(_ScheduleBlock block) {
  final parts = block.time.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

int _blockEndMinutes(_ScheduleBlock block) {
  return _blockStartMinutes(block) + _blockDurationMinutes(block);
}

class _AccountOption {
  final String key;
  final String label;

  const _AccountOption({required this.key, required this.label});

  factory _AccountOption.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    final label = name.isNotEmpty
        ? (id.isNotEmpty && id != name ? '$name ($id)' : name)
        : (id.isNotEmpty ? id : 'Unknown');
    final key = id.isNotEmpty ? id : (name.isNotEmpty ? name : label);
    return _AccountOption(key: key, label: label);
  }
}

class _ScheduleBlock {
  final String deviceIp;
  final _BlockType type;
  final String? account;
  final String time;
  final int? cycles;

  const _ScheduleBlock({
    required this.deviceIp,
    required this.type,
    this.account,
    required this.time,
    this.cycles,
  });

  Map<String, dynamic> toJson() {
    return {
      'deviceIp': deviceIp,
      'type': type.name,
      if (account != null) 'account': account,
      'time': time,
      if (cycles != null) 'cycles': cycles,
    };
  }

  factory _ScheduleBlock.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type']?.toString();
    final type = _BlockType.values.firstWhere(
      (t) => t.name == typeStr,
      orElse: () => _BlockType.login,
    );
    final rawCycles = json['cycles'];
    return _ScheduleBlock(
      deviceIp: json['deviceIp']?.toString() ?? '',
      type: type,
      account: json['account']?.toString(),
      time: json['time']?.toString() ?? '',
      cycles: rawCycles is int ? rawCycles : int.tryParse('$rawCycles'),
    );
  }
}

class BuildSchedulerDialog extends StatefulWidget {
  final List<DeviceInfo> devices;
  final Map<String, String> buildMappings;
  final Map<String, List<Map<String, dynamic>>> initialSchedules;

  const BuildSchedulerDialog({
    super.key,
    required this.devices,
    required this.buildMappings,
    required this.initialSchedules,
  });

  @override
  State<BuildSchedulerDialog> createState() => _BuildSchedulerDialogState();
}

class _BuildSchedulerDialogState extends State<BuildSchedulerDialog> {
  bool _isLoading = true;
  String? _errorText;
  final Map<String, List<_AccountOption>> _accountsByDevice = {};
  final Map<String, List<_ScheduleBlock>> _schedulesByDate = {};
  DateTime _selectedDate = DateTime.now();
  DateTime _visibleMonth = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    try {
      final results = await Future.wait(
        widget.devices.map((device) async {
          final accounts = await _fetchAccounts(device.ip);
          return MapEntry(device.ip, accounts);
        }),
      );

      if (!mounted) return;

      for (final entry in results) {
        _accountsByDevice[entry.key] = entry.value;
      }

      _applyInitialSelections();

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = e.toString();
        _isLoading = false;
      });
    }
  }

  void _applyInitialSelections() {
    for (final entry in widget.initialSchedules.entries) {
      final blocks = <_ScheduleBlock>[];
      for (final raw in entry.value) {
        final block = _ScheduleBlock.fromJson(raw);
        if (_isValidTime(block.time) && block.deviceIp.isNotEmpty) {
          blocks.add(block);
        }
      }
      if (blocks.isNotEmpty) {
        _schedulesByDate[entry.key] = blocks;
      }
    }
  }

  Future<List<_AccountOption>> _fetchAccounts(String ip) async {
    try {
      final res = await Gateway.call(
        ip,
        'subaction/weeing/macros',
        method: 'GET',
      );
      if (res.statusCode != 200) return [];

      final body = jsonDecode(res.body);
      final dynamic rawAccounts = body is Map
          ? (body['resp'] ?? body['data'])
          : body;

      if (rawAccounts is List) {
        return rawAccounts
            .whereType<Map>()
            .map(
              (item) =>
                  _AccountOption.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Map<String, List<Map<String, dynamic>>> _buildResult() {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final entry in _schedulesByDate.entries) {
      final valid = entry.value
          .where((b) => _isValidTime(b.time))
          .map((b) => b.toJson())
          .toList();
      if (valid.isNotEmpty) {
        result[entry.key] = valid;
      }
    }
    return result;
  }

  String _dateKey(DateTime date) {
    final normalized = DateTime(date.year, date.month, date.day);
    final month = normalized.month.toString().padLeft(2, '0');
    final day = normalized.day.toString().padLeft(2, '0');
    return '${normalized.year}-$month-$day';
  }

  Future<void> _openDayTimeline(DateTime date) async {
    final dateKey = _dateKey(date);
    final initialBlocks = List<_ScheduleBlock>.from(
      _schedulesByDate[dateKey] ?? const <_ScheduleBlock>[],
    );

    final result = await Navigator.of(context).push<List<Map<String, dynamic>>>(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) {
          return _DayTimelineScreen(
            date: date,
            devices: widget.devices,
            accountsByDevice: _accountsByDevice,
            buildMappings: widget.buildMappings,
            initialBlocks: initialBlocks,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final tween = Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );

    if (result == null || !mounted) return;

    setState(() {
      final blocks = result.map((e) => _ScheduleBlock.fromJson(e)).toList();
      if (blocks.isEmpty) {
        _schedulesByDate.remove(dateKey);
      } else {
        _schedulesByDate[dateKey] = blocks;
      }
      _selectedDate = date;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        title: const Text(
          '빌드 스케줄러',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.white,
        foregroundColor: _kText,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        actions: [
          TextButton.icon(
            onPressed: _isLoading ? null : _resetAll,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('초기화'),
            style: TextButton.styleFrom(foregroundColor: _kMuted),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _helperBanner(),
            Expanded(child: _calendarPanel()),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _helperBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _kAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: _kAccent),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '예약이 있는 날짜는 점으로 표시됩니다. 날짜를 누르면 타임라인이 열립니다.',
              style: TextStyle(fontSize: 12.5, color: _kText, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  void _changeMonth(int delta) {
    setState(() {
      _visibleMonth = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    });
  }

  void _goToToday() {
    final now = DateTime.now();
    setState(() {
      _visibleMonth = DateTime(now.year, now.month);
      _selectedDate = now;
    });
  }

  String _formatMonthLabel(DateTime month) {
    return '${month.year}년 ${month.month}월';
  }

  List<DateTime> _daysGridFor(DateTime month) {
    final firstOfMonth = DateTime(month.year, month.month);
    final leading = firstOfMonth.weekday - DateTime.monday;
    final start = firstOfMonth.subtract(Duration(days: leading));
    return List.generate(42, (i) => start.add(Duration(days: i)));
  }

  Widget _calendarPanel() {
    if (_errorText != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 44,
                  color: Color(0xFFDC2626),
                ),
                const SizedBox(height: 12),
                Text(
                  _errorText!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFDC2626)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final days = _daysGridFor(_visibleMonth);
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final today = DateTime.now();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => _changeMonth(-1),
                icon: const Icon(Icons.chevron_left),
                color: _kMuted,
              ),
              Expanded(
                child: Text(
                  _formatMonthLabel(_visibleMonth),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _kText,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _changeMonth(1),
                icon: const Icon(Icons.chevron_right),
                color: _kMuted,
              ),
              TextButton(
                onPressed: _goToToday,
                style: TextButton.styleFrom(foregroundColor: _kAccent),
                child: const Text('오늘'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: weekdays
                .map(
                  (label) => Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: label == '토'
                              ? const Color(0xFF2563EB)
                              : label == '일'
                              ? const Color(0xFFDC2626)
                              : _kMuted,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const Divider(height: 14, color: _kBorder),
          Expanded(
            child: GridView.builder(
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
              ),
              itemCount: days.length,
              itemBuilder: (context, index) {
                final date = days[index];
                final inMonth = date.month == _visibleMonth.month;
                final isSelected = _isSameDay(date, _selectedDate);
                final isToday = _isSameDay(date, today);
                final hasSchedule =
                    (_schedulesByDate[_dateKey(date)] ??
                            const <_ScheduleBlock>[])
                        .isNotEmpty;
                final weekday = date.weekday;

                Color textColor;
                if (!inMonth) {
                  textColor = _kMuted.withValues(alpha: 0.5);
                } else if (weekday == DateTime.sunday) {
                  textColor = const Color(0xFFDC2626);
                } else if (weekday == DateTime.saturday) {
                  textColor = const Color(0xFF2563EB);
                } else {
                  textColor = _kText;
                }
                if (isSelected) textColor = Colors.white;

                return InkWell(
                  onTap: _isLoading
                      ? null
                      : () {
                          setState(() {
                            _selectedDate = date;
                            if (!inMonth) {
                              _visibleMonth = DateTime(date.year, date.month);
                            }
                          });
                          _openDayTimeline(date);
                        },
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected ? _kAccent : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: isToday && !isSelected
                            ? Border.all(color: _kAccent, width: 1.4)
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${date.day}',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: isToday || isSelected
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: hasSchedule
                                  ? (isSelected ? Colors.white : _kGreen)
                                  : Colors.transparent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _resetAll() {
    setState(() {
      _schedulesByDate.clear();
    });
  }

  Widget _bottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _kBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: _kMuted,
                side: const BorderSide(color: _kBorder),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('취소'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: FilledButton(
              onPressed: _isLoading
                  ? null
                  : () => Navigator.of(context).pop(_buildResult()),
              style: FilledButton.styleFrom(
                backgroundColor: _kAccent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                '저장',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayTimelineScreen extends StatefulWidget {
  final DateTime date;
  final List<DeviceInfo> devices;
  final Map<String, List<_AccountOption>> accountsByDevice;
  final Map<String, String> buildMappings;
  final List<_ScheduleBlock> initialBlocks;

  const _DayTimelineScreen({
    required this.date,
    required this.devices,
    required this.accountsByDevice,
    required this.buildMappings,
    required this.initialBlocks,
  });

  @override
  State<_DayTimelineScreen> createState() => _DayTimelineScreenState();
}

class _DayTimelineScreenState extends State<_DayTimelineScreen> {
  late List<_ScheduleBlock> _blocks;

  @override
  void initState() {
    super.initState();
    _blocks = List<_ScheduleBlock>.from(widget.initialBlocks);
  }

  List<_ScheduleBlock> _blocksForDevice(String ip) {
    return _blocks
        .where((b) => b.deviceIp == ip && _isValidTime(b.time))
        .toList();
  }

  bool _hasLoginBefore(String deviceIp, String account, String time) {
    return _blocks.any(
      (b) =>
          b.deviceIp == deviceIp &&
          b.type == _BlockType.login &&
          b.account == account &&
          b.time.compareTo(time) <= 0,
    );
  }

  bool _hasOverlap(
    String deviceIp,
    int startMinutes,
    int endMinutes, {
    _ScheduleBlock? exclude,
  }) {
    for (final b in _blocks) {
      if (b.deviceIp != deviceIp) continue;
      if (exclude != null && identical(b, exclude)) continue;
      if (!_isValidTime(b.time)) continue;
      final bStart = _blockStartMinutes(b);
      final bEnd = _blockEndMinutes(b);
      if (startMinutes < bEnd && bStart < endMinutes) return true;
    }
    return false;
  }

  TimeOfDay _defaultTimeForDevice(String deviceIp) {
    var latestEnd = -1;
    for (final b in _blocks) {
      if (b.deviceIp != deviceIp || !_isValidTime(b.time)) continue;
      final end = _blockEndMinutes(b);
      if (end > latestEnd) latestEnd = end;
    }
    if (latestEnd < 0) return TimeOfDay.now();
    final capped = latestEnd > 1439 ? 1439 : latestEnd;
    return TimeOfDay(hour: capped ~/ 60, minute: capped % 60);
  }

  String _accountLabelFor(String deviceIp, String? accountKey) {
    if (accountKey == null) return '';
    final accounts =
        widget.accountsByDevice[deviceIp] ?? const <_AccountOption>[];
    for (final account in accounts) {
      if (account.key == accountKey) return account.label;
    }
    return accountKey;
  }

  String _blockLabel(_ScheduleBlock block) {
    final accountLabel = _accountLabelFor(block.deviceIp, block.account);
    switch (block.type) {
      case _BlockType.login:
        return '로그인\n$accountLabel';
      case _BlockType.logout:
        return '로그아웃';
      case _BlockType.buildRun:
        return '빌드 · $accountLabel\n${block.cycles ?? 1}회';
    }
  }

  List<Map<String, dynamic>> _buildResult() {
    return _blocks
        .where((b) => _isValidTime(b.time))
        .map((b) => b.toJson())
        .toList();
  }

  Future<void> _openAddBlockSheet(String deviceIp, {_ScheduleBlock? existing}) async {
    final accounts =
        widget.accountsByDevice[deviceIp] ?? const <_AccountOption>[];

    final result = await showModalBottomSheet<_BlockSheetResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return _AddBlockSheet(
          deviceIp: deviceIp,
          accounts: accounts,
          buildMappings: widget.buildMappings,
          existing: existing,
          defaultTime: existing != null
              ? (_parseTimeOfDayStr(existing.time) ?? TimeOfDay.now())
              : _defaultTimeForDevice(deviceIp),
          hasLoginBefore: (account, time) =>
              _hasLoginBefore(deviceIp, account, time),
          hasOverlap: (start, end) =>
              _hasOverlap(deviceIp, start, end, exclude: existing),
        );
      },
    );

    if (result == null || !mounted) return;

    setState(() {
      if (existing != null) {
        _blocks.remove(existing);
      }
      if (!result.delete && result.block != null) {
        _blocks.add(result.block!);
      }
    });
  }

  Widget _hourLabelCell(int hour) {
    return SizedBox(
      height: _kRowHeight,
      child: Column(
        children: [
          _dashedDivider(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6, left: 16, right: 6),
              child: Text(
                _hourLabelKorean(hour),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _kMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateHeader() {
    const weekdays = ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'];
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.date.day}',
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w800,
              color: _kBuildColor,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            weekdays[widget.date.weekday - 1],
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _kBuildColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dashedDivider() {
    return LayoutBuilder(
      builder: (context, constraints) {
        const dashWidth = 5.0;
        const dashGap = 4.0;
        final count = (constraints.maxWidth / (dashWidth + dashGap)).floor();
        return Row(
          children: List.generate(
            count,
            (_) => Padding(
              padding: const EdgeInsets.only(right: dashGap),
              child: Container(width: dashWidth, height: 1, color: _kBorder),
            ),
          ),
        );
      },
    );
  }

  Widget _deviceHeaderCell(DeviceInfo device) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: _kBorder)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(color: device.color, shape: BoxShape.circle),
          ),
          Expanded(
            child: Text(
              device.ip,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: _kText,
              ),
            ),
          ),
          InkWell(
            onTap: () => _openAddBlockSheet(device.ip),
            borderRadius: BorderRadius.circular(20),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.add_circle_outline, size: 18, color: _kAccent),
            ),
          ),
        ],
      ),
    );
  }

  List<_LaneBlock> _assignLanes(List<_ScheduleBlock> blocks) {
    final sorted = [...blocks]..sort((a, b) => a.time.compareTo(b.time));
    final laneEnds = <int>[];
    final laneOfBlock = <int>[];

    for (final block in sorted) {
      final start = _blockStartMinutes(block);
      final end = _blockEndMinutes(block);

      var assigned = -1;
      for (var i = 0; i < laneEnds.length; i++) {
        if (laneEnds[i] <= start) {
          assigned = i;
          break;
        }
      }
      if (assigned == -1) {
        assigned = laneEnds.length;
        laneEnds.add(end);
      } else {
        laneEnds[assigned] = end;
      }
      laneOfBlock.add(assigned);
    }

    final laneCount = laneEnds.length;
    return List.generate(
      sorted.length,
      (i) => _LaneBlock(
        block: sorted[i],
        lane: laneOfBlock[i],
        laneCount: laneCount,
      ),
    );
  }

  // Every block spans the full day column at a consistent pixels-per-minute
  // scale (columnIndex picks the horizontal slot; no per-hour clamping so
  // block length always stays proportional to its real duration).
  List<Widget> _deviceBlocksOverlay(String deviceIp, int columnIndex, double colWidth) {
    final laneBlocks = _assignLanes(_blocksForDevice(deviceIp));

    return laneBlocks.map((laneBlock) {
      final block = laneBlock.block;
      final top = (_blockStartMinutes(block) / 60) * _kRowHeight;
      final height = (_blockDurationMinutes(block) / 60) * _kRowHeight;
      final laneWidth = colWidth / laneBlock.laneCount;
      final left = columnIndex * colWidth + laneBlock.lane * laneWidth;
      final width = laneWidth > 6 ? laneWidth - 6 : laneWidth;
      final color = _blockColor(block.type);

      return Positioned(
        top: top,
        left: left,
        width: width,
        height: height,
        child: GestureDetector(
          onTap: () => _openAddBlockSheet(deviceIp, existing: block),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.topLeft,
            child: height >= 26
                ? Text(
                    _blockLabel(block),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  )
                : null,
          ),
        ),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.devices;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _kText,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        actions: [
          TextButton.icon(
            onPressed: _blocks.isEmpty
                ? null
                : () {
                    setState(() {
                      _blocks.clear();
                    });
                  },
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('초기화'),
            style: TextButton.styleFrom(foregroundColor: _kMuted),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Container(height: 3, color: _kBuildColor),
            _dateHeader(),
            Expanded(
              child: devices.isEmpty
                  ? const Center(
                      child: Text(
                        '등록된 기기가 없습니다.',
                        style: TextStyle(color: _kMuted),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final availableWidth =
                            constraints.maxWidth - _kHourLabelWidth;
                        final equalWidth = availableWidth / devices.length;
                        final colWidth = equalWidth >= _kMinColumnWidth
                            ? equalWidth
                            : _kMinColumnWidth;
                        final totalColsWidth = colWidth * devices.length;

                        return SingleChildScrollView(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: _kHourLabelWidth,
                                child: Column(
                                  children: [
                                    const SizedBox(height: _kDeviceHeaderHeight),
                                    for (var hour = 0; hour < 24; hour++)
                                      _hourLabelCell(hour),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: SizedBox(
                                    width: totalColsWidth,
                                    child: Column(
                                      children: [
                                        SizedBox(
                                          height: _kDeviceHeaderHeight,
                                          child: Row(
                                            children: devices
                                                .map(
                                                  (device) => SizedBox(
                                                    width: colWidth,
                                                    child: _deviceHeaderCell(
                                                      device,
                                                    ),
                                                  ),
                                                )
                                                .toList(),
                                          ),
                                        ),
                                        SizedBox(
                                          height: _kRowHeight * 24,
                                          child: Stack(
                                            children: [
                                              Column(
                                                children: [
                                                  for (var hour = 0; hour < 24; hour++)
                                                    SizedBox(
                                                      height: _kRowHeight,
                                                      child: Align(
                                                        alignment: Alignment.topCenter,
                                                        child: _dashedDivider(),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                              for (var i = 1; i < devices.length; i++)
                                                Positioned(
                                                  left: i * colWidth,
                                                  top: 0,
                                                  bottom: 0,
                                                  width: 1,
                                                  child: Container(color: _kBorder),
                                                ),
                                              for (var i = 0; i < devices.length; i++)
                                                ..._deviceBlocksOverlay(
                                                  devices[i].ip,
                                                  i,
                                                  colWidth,
                                                ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _kBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: _kMuted,
                side: const BorderSide(color: _kBorder),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('취소'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_buildResult()),
              style: FilledButton.styleFrom(
                backgroundColor: _kAccent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                '저장',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LaneBlock {
  final _ScheduleBlock block;
  final int lane;
  final int laneCount;

  const _LaneBlock({
    required this.block,
    required this.lane,
    required this.laneCount,
  });
}

class _BlockSheetResult {
  final _ScheduleBlock? block;
  final bool delete;

  const _BlockSheetResult.save(this.block) : delete = false;
  const _BlockSheetResult.delete() : block = null, delete = true;
}

class _AddBlockSheet extends StatefulWidget {
  final String deviceIp;
  final List<_AccountOption> accounts;
  final Map<String, String> buildMappings;
  final _ScheduleBlock? existing;
  final TimeOfDay defaultTime;
  final bool Function(String account, String time) hasLoginBefore;
  final bool Function(int startMinutes, int endMinutes) hasOverlap;

  const _AddBlockSheet({
    required this.deviceIp,
    required this.accounts,
    required this.buildMappings,
    required this.defaultTime,
    required this.hasLoginBefore,
    required this.hasOverlap,
    this.existing,
  });

  @override
  State<_AddBlockSheet> createState() => _AddBlockSheetState();
}

class _AddBlockSheetState extends State<_AddBlockSheet> {
  _BlockType? _type;
  String? _account;
  late int _hour;
  late int _minute;
  int _cycles = 1;
  late final FixedExtentScrollController _hourCtrl;
  late final FixedExtentScrollController _minCtrl;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final initialTime =
        (existing != null ? _parseTimeOfDayStr(existing.time) : null) ??
        widget.defaultTime;
    _hour = initialTime.hour;
    _minute = initialTime.minute;
    if (existing != null) {
      _type = existing.type;
      _account = existing.account;
      _cycles = existing.cycles ?? 1;
    }
    _hourCtrl = FixedExtentScrollController(initialItem: _hour);
    _minCtrl = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minCtrl.dispose();
    super.dispose();
  }

  String get _timeStr =>
      '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}';

  int get _previewDuration => _blockDurationMinutesFor(_type!, _cycles);

  bool get _hasOverlapNow {
    final start = _hour * 60 + _minute;
    return widget.hasOverlap(start, start + _previewDuration);
  }

  bool get _canSubmit {
    final type = _type;
    if (type == null) return false;
    if (type != _BlockType.logout && (_account == null || _account!.isEmpty)) {
      return false;
    }
    if (type == _BlockType.buildRun) {
      final ok = widget.hasLoginBefore(_account!, _timeStr);
      if (!ok) return false;
    }
    if (_hasOverlapNow) return false;
    return true;
  }

  void _submit() {
    final type = _type!;
    final block = _ScheduleBlock(
      deviceIp: widget.deviceIp,
      type: type,
      account: type == _BlockType.logout ? null : _account,
      time: _timeStr,
      cycles: type == _BlockType.buildRun ? _cycles : null,
    );
    Navigator.of(context).pop(_BlockSheetResult.save(block));
  }

  void _delete() {
    Navigator.of(context).pop(const _BlockSheetResult.delete());
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: _kBorder,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              if (_type == null) ..._typeChooser() else ..._form(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _typeChooser() {
    return [
      const Text(
        '블록 추가',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText),
      ),
      const SizedBox(height: 4),
      const Text(
        '추가할 블록 종류를 선택하세요.',
        style: TextStyle(fontSize: 12.5, color: _kMuted),
      ),
      const SizedBox(height: 16),
      _typeCard(
        _BlockType.login,
        Icons.login,
        '로그인',
        '계정과 로그인 시각 지정 · 5분 고정',
      ),
      const SizedBox(height: 10),
      _typeCard(
        _BlockType.logout,
        Icons.logout,
        '로그아웃',
        '로그아웃 시각만 지정 · 5분 고정',
      ),
      const SizedBox(height: 10),
      _typeCard(
        _BlockType.buildRun,
        Icons.play_circle_outline,
        '빌드실행',
        '계정 · 시작 시각 · 사이클 수 지정',
      ),
      const SizedBox(height: 8),
    ];
  }

  Widget _typeCard(_BlockType type, IconData icon, String title, String subtitle) {
    final color = _blockColor(type);
    return InkWell(
      onTap: () => setState(() => _type = type),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _kText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 11.5, color: _kMuted),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: _kMuted),
          ],
        ),
      ),
    );
  }

  Widget _stepButton(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF6F6F8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kBorder),
        ),
        child: Icon(icon, size: 18, color: _kText),
      ),
    );
  }

  List<Widget> _form() {
    final type = _type!;
    final showAccount = type != _BlockType.logout;
    final showCycles = type == _BlockType.buildRun;
    final mappedBuild = _account != null
        ? widget.buildMappings[_account]
        : null;

    String? loginWarning;
    if (type == _BlockType.buildRun && _account != null) {
      final ok = widget.hasLoginBefore(_account!, _timeStr);
      if (!ok) {
        loginWarning = '이 계정의 "로그인" 일정이 이 시각 이전에 먼저 등록되어야 합니다.';
      }
    }

    final overlapWarning = _hasOverlapNow ? '이 기기에서 다른 블록과 시간이 겹칩니다.' : null;

    return [
      Row(
        children: [
          if (!_isEditing) ...[
            IconButton(
              onPressed: () => setState(() => _type = null),
              icon: const Icon(Icons.arrow_back, size: 20),
              color: _kMuted,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
          ],
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: _blockColor(type), shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            _blockTypeLabel(type),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _kText,
            ),
          ),
          if (type != _BlockType.buildRun) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _kMuted.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                '5분 고정',
                style: TextStyle(
                  fontSize: 10.5,
                  color: _kMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 18),
      if (showAccount) ...[
        const Text(
          '계정',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _kMuted),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F6F8),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kBorder),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _account,
              isExpanded: true,
              hint: const Text(
                '계정을 선택하세요',
                style: TextStyle(fontSize: 13, color: _kMuted),
              ),
              items: widget.accounts
                  .map(
                    (a) => DropdownMenuItem(
                      value: a.key,
                      child: Text(
                        a.label,
                        style: const TextStyle(fontSize: 13, color: _kText),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _account = v),
            ),
          ),
        ),
        if (type == _BlockType.buildRun && _account != null) ...[
          const SizedBox(height: 6),
          Text(
            (mappedBuild == null || mappedBuild.isEmpty)
                ? '매핑된 빌드가 없습니다. 빌드 매핑에서 먼저 설정하세요.'
                : '매핑된 빌드: $mappedBuild',
            style: TextStyle(
              fontSize: 11.5,
              color: (mappedBuild == null || mappedBuild.isEmpty)
                  ? const Color(0xFFDC2626)
                  : _kMuted,
            ),
          ),
        ],
        const SizedBox(height: 16),
      ],
      Text(
        type == _BlockType.buildRun
            ? '시작 시각'
            : (type == _BlockType.login ? '로그인 시각' : '로그아웃 시각'),
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _kMuted),
      ),
      const SizedBox(height: 6),
      StartTimeControl(
        hour: _hour,
        minute: _minute,
        hourController: _hourCtrl,
        minuteController: _minCtrl,
        onHourChanged: (v) => setState(() => _hour = v),
        onMinuteChanged: (v) => setState(() => _minute = v),
      ),
      if (showCycles) ...[
        const SizedBox(height: 16),
        const Text(
          '사이클 수',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _kMuted),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _stepButton(Icons.remove, () {
              if (_cycles > 0) setState(() => _cycles--);
            }),
            Expanded(
              child: Center(
                child: Text(
                  '$_cycles회',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _kText,
                  ),
                ),
              ),
            ),
            _stepButton(Icons.add, () {
              if (_cycles < 99) setState(() => _cycles++);
            }),
          ],
        ),
      ],
      if (loginWarning != null) ...[
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                loginWarning,
                style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
              ),
            ),
          ],
        ),
      ],
      if (overlapWarning != null) ...[
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                overlapWarning,
                style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 20),
      Row(
        children: [
          if (_isEditing) ...[
            Expanded(
              child: OutlinedButton(
                onPressed: _delete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDC2626),
                  side: const BorderSide(color: Color(0xFFDC2626)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('삭제'),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            flex: _isEditing ? 2 : 1,
            child: FilledButton(
              onPressed: _canSubmit ? _submit : null,
              style: FilledButton.styleFrom(
                backgroundColor: _blockColor(type),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                _isEditing ? '저장' : '추가',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    ];
  }
}
