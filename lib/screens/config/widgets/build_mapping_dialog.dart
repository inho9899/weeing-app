import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:weeing_app/gateway/gateway.dart';

import '../models/device_info.dart';

// ── 공통 팔레트 (config 화면과 통일) ──
const Color _kBg = Color(0xFFF3F3F5);
const Color _kAccent = Color(0xFF3B82F6);
const Color _kBorder = Color(0xFFE4E4EA);
const Color _kMuted = Color(0xFF8A8A8E);
const Color _kText = Color(0xFF1A1A1C);
const Color _kGreen = Color(0xFF16A34A);
const Color _kFill = Color(0xFFF6F6F8);

class BuildMappingDialog extends StatefulWidget {
  final List<DeviceInfo> devices;
  final Map<String, String> initialMappings;

  const BuildMappingDialog({
    super.key,
    required this.devices,
    required this.initialMappings,
  });

  @override
  State<BuildMappingDialog> createState() => _BuildMappingDialogState();
}

class _BuildMappingDialogState extends State<BuildMappingDialog> {
  static const String _noMatchedValue = 'No matched';

  bool _isLoading = true;
  String? _errorText;
  final Map<String, List<_MacroOption>> _accountsByDevice = {};
  final Map<String, List<String>> _buildsByDevice = {};
  final Map<String, String> _selectedBuildByAccount = {};

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
          final builds = await _fetchBuilds(device.ip);
          return MapEntry(
            device.ip,
            _DeviceOptions(accounts: accounts, builds: builds),
          );
        }),
      );

      if (!mounted) return;

      for (final entry in results) {
        _accountsByDevice[entry.key] = entry.value.accounts;
        _buildsByDevice[entry.key] = entry.value.builds;
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
    // initialMappings expected to be Map<accountKey, buildName>
    for (final device in widget.devices) {
      final accounts = _accountsByDevice[device.ip] ?? const <_MacroOption>[];
      final builds = _buildsByDevice[device.ip] ?? const <String>[];

      for (final account in accounts) {
        final candidate = widget.initialMappings[account.key];
        String selected = _noMatchedValue;

        if (candidate != null &&
            candidate.isNotEmpty &&
            candidate != _noMatchedValue) {
          // Accept the candidate if it exists in this device's builds
          if (builds.contains(candidate)) {
            selected = candidate;
          }
        }

        _selectedBuildByAccount[account.key] = selected;
      }
    }
  }

  Future<List<_MacroOption>> _fetchAccounts(String ip) async {
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
              (item) => _MacroOption.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Future<List<String>> _fetchBuilds(String ip) async {
    try {
      final res = await Gateway.call(
        ip,
        'mainAction/build/list',
        method: 'GET',
      );
      if (res.statusCode != 200) return [];

      final body = jsonDecode(res.body);
      final dynamic rawBuilds = body is Map
          ? (body['data'] ?? body['resp'])
          : body;

      if (rawBuilds is List) {
        return rawBuilds.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return [];
  }

  void _resetAll() {
    setState(() {
      _selectedBuildByAccount.clear();
      for (final device in widget.devices) {
        final accounts = _accountsByDevice[device.ip] ?? const <_MacroOption>[];
        for (final account in accounts) {
          _selectedBuildByAccount[account.key] = _noMatchedValue;
        }
      }
    });
  }

  Map<String, String> _buildResult() {
    // Return mapping keyed by account key -> build name
    final result = <String, String>{};
    for (final device in widget.devices) {
      final accounts = _accountsByDevice[device.ip] ?? const <_MacroOption>[];
      for (final account in accounts) {
        result[account.key] =
            _selectedBuildByAccount[account.key] ?? _noMatchedValue;
      }
    }
    return result;
  }

  int _mappedCount(List<_MacroOption> accounts) => accounts
      .where(
        (a) =>
            (_selectedBuildByAccount[a.key] ?? _noMatchedValue) !=
            _noMatchedValue,
      )
      .length;

  // =========================================================
  // UI
  // =========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        title: const Text(
          '빌드 매핑',
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
            Expanded(child: _content()),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _kAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: _kAccent),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '각 기기의 계정에 사용할 빌드를 지정하세요. 계정은 고정, 빌드만 선택합니다.',
              style: TextStyle(fontSize: 12.5, color: _kText, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(height: 14),
            Text(
              '계정·빌드 목록 불러오는 중...',
              style: TextStyle(color: _kMuted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (_errorText != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Color(0xFFDC2626),
                size: 40,
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
      );
    }

    if (widget.devices.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.devices_other_outlined, size: 44, color: _kMuted),
            SizedBox(height: 12),
            Text('등록된 원격 기기가 없습니다.', style: TextStyle(color: _kMuted)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      itemCount: widget.devices.length,
      itemBuilder: (context, index) => _deviceCard(widget.devices[index]),
    );
  }

  Widget _deviceCard(DeviceInfo device) {
    final accounts = _accountsByDevice[device.ip] ?? const <_MacroOption>[];
    final builds = _buildsByDevice[device.ip] ?? const <String>[];
    final mapped = _mappedCount(accounts);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _kAccent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.desktop_windows_outlined,
                    size: 20,
                    color: _kAccent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.ip,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: _kText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '계정 ${accounts.length}개 · 빌드 ${builds.length}개',
                        style: const TextStyle(fontSize: 12, color: _kMuted),
                      ),
                    ],
                  ),
                ),
                if (accounts.isNotEmpty) _countChip(mapped, accounts.length),
              ],
            ),
          ),
          const Divider(height: 1, color: _kBorder),
          // 계정 목록
          if (accounts.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 14, 14, 16),
              child: Text('계정 정보가 없습니다.', style: TextStyle(color: _kMuted)),
            )
          else
            ...List.generate(
              accounts.length,
              (idx) => _accountRow(
                accounts[idx],
                builds,
                isLast: idx == accounts.length - 1,
              ),
            ),
        ],
      ),
    );
  }

  Widget _countChip(int mapped, int total) {
    final done = mapped == total && total > 0;
    final color = done ? _kGreen : _kMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            done ? Icons.check_circle : Icons.remove_circle_outline,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '$mapped/$total',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountRow(
    _MacroOption account,
    List<String> builds, {
    required bool isLast,
  }) {
    final selected = _selectedBuildByAccount[account.key] ?? _noMatchedValue;
    final isMapped = selected != _noMatchedValue;

    return Padding(
      padding: EdgeInsets.fromLTRB(14, 12, 14, isLast ? 14 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isMapped ? _kGreen : const Color(0xFFCFCFD4),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  account.label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: _kText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildDropdown(account, builds, selected),
          if (!isLast)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Divider(height: 1, color: _kBorder),
            ),
        ],
      ),
    );
  }

  Widget _buildDropdown(
    _MacroOption account,
    List<String> builds,
    String selected,
  ) {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: _noMatchedValue,
        child: Text('선택 안 함', style: TextStyle(color: _kMuted)),
      ),
      ...builds.map(
        (b) => DropdownMenuItem<String>(
          value: b,
          child: Text(b, overflow: TextOverflow.ellipsis),
        ),
      ),
    ];

    return DropdownButtonFormField<String>(
      value: selected,
      isExpanded: true,
      icon: const Icon(Icons.expand_more, color: _kMuted),
      style: const TextStyle(fontSize: 14, color: _kText),
      decoration: InputDecoration(
        prefixIcon: const Icon(
          Icons.widgets_outlined,
          size: 18,
          color: _kMuted,
        ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
        filled: true,
        fillColor: _kFill,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _kAccent, width: 1.5),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _kBorder),
        ),
      ),
      items: items,
      onChanged: (value) {
        setState(() {
          _selectedBuildByAccount[account.key] = value ?? _noMatchedValue;
        });
      },
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

class _DeviceOptions {
  final List<_MacroOption> accounts;
  final List<String> builds;

  const _DeviceOptions({required this.accounts, required this.builds});
}

class _MacroOption {
  final String key;
  final String label;

  const _MacroOption({required this.key, required this.label});

  factory _MacroOption.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    final label = name.isNotEmpty
        ? (id.isNotEmpty && id != name ? '$name ($id)' : name)
        : (id.isNotEmpty ? id : 'Unknown');
    final key = id.isNotEmpty ? id : (name.isNotEmpty ? name : label);

    return _MacroOption(key: key, label: label);
  }
}
