import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:weeing_app/gateway/gateway.dart';
import 'package:weeing_app/screens/lobby/services/lobby_api_service.dart';
import 'package:weeing_app/screens/lobby/widgets/run_options_sheet.dart';
import 'models/schedule_plan.dart';
import 'services/schedule_api_service.dart';

/// PC 하나의 하루치 스케줄. 로그인·사이클·로그아웃 블록을 쌓고, 앱바 스위치로 켜고 끈다.
///
/// 계획은 프록시에 저장되고 실행도 프록시가 한다 — 이 화면은 계획을 고치고 진행 상태를 볼 뿐이다.
/// 계정 목록은 그 PC(subAction macros)에서, 캐릭터·빌드는 빌드 매핑에서, 끈 단계는 로비와 같은
/// 이 폰의 저장값(run_skip)에서 가져와 블록에 복사한다.
class ScheduleScreen extends StatefulWidget {
  final String ip;

  /// 프록시 저장 키. device_id, 없으면 ip.
  final String deviceKey;

  const ScheduleScreen({super.key, required this.ip, required this.deviceKey});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  static const _bg = Color(0xFFF3F3F5);
  static const _panel = Color(0xFFE6E6E9);
  static const _dark = Color(0xFF5A5A5A);
  static const _button = Color(0xFF757575);

  late final LobbyApiService _api;

  SchedulePlan _plan = SchedulePlan();
  bool _enabled = false;
  bool _loaded = false;
  bool _dirty = false; // 저장 안 한 변경이 있음
  bool _busy = false; // 저장·전환 요청이 나가 있는 동안 버튼을 막는다
  ScheduleStatus? _status;
  Timer? _statusTimer;

  List<String> _accounts = [];
  Map<String, String> _characterToBuild = {};
  Map<String, List<String>> _skipByCharacter = {};

  @override
  void initState() {
    super.initState();
    _api = LobbyApiService(ip: widget.ip);
    _load();
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final info = await ScheduleApi.fetch(widget.deviceKey);
    final macros = await _api.fetchMacros();
    final names = macros
        .map((m) => (m['name'] ?? '').toString().trim())
        .where((n) => n.isNotEmpty)
        .toList();
    final remoteMapping = await Gateway.fetchBuildMapping() ?? {};
    // 로비와 같은 기준: 이 PC 의 계정 이름과 같은 캐릭터만
    final mapping = <String, String>{
      for (final name in names)
        if ((remoteMapping[name] ?? '').isNotEmpty) name: remoteMapping[name]!,
    };
    final skips = await _loadRunSkips();
    final status = await ScheduleApi.fetchStatus(widget.deviceKey);

    if (!mounted) return;
    setState(() {
      _plan = info?.plan ?? SchedulePlan();
      _enabled = info?.enabled ?? false;
      _accounts = names;
      _characterToBuild = mapping;
      _skipByCharacter = skips;
      _status = status;
      _loaded = true;
    });
  }

  Future<Map<String, List<String>>> _loadRunSkips() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('run_skip');
      if (raw == null) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {for (final e in decoded.entries) e.key: List<String>.from(e.value as List)};
    } catch (_) {
      return {};
    }
  }

  Future<void> _refreshStatus() async {
    final status = await ScheduleApi.fetchStatus(widget.deviceKey);
    if (!mounted || status == null) return;
    setState(() {
      _status = status;
      _enabled = status.enabled;
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String? _validate() {
    for (var i = 0; i < _plan.blocks.length; i++) {
      final b = _plan.blocks[i];
      if (b.type == ScheduleBlock.login && b.account.isEmpty) return '${i + 1}번 로그인 블록의 계정을 고르세요';
      if (b.type == ScheduleBlock.cycle && (b.character.isEmpty || b.build.isEmpty)) {
        return '${i + 1}번 사이클 블록의 빌드를 고르세요';
      }
    }
    return null;
  }

  /// 성공하면 true.
  Future<bool> _save() async {
    final problem = _validate();
    if (problem != null) {
      _snack(problem);
      return false;
    }
    setState(() => _busy = true);
    final error = await ScheduleApi.savePlan(widget.deviceKey, widget.ip, _plan);
    if (!mounted) return false;
    setState(() => _busy = false);
    if (error != null) {
      _snack(error);
      return false;
    }
    setState(() => _dirty = false);
    _snack('저장했다. 켜져 있으면 다음 실행부터 반영된다');
    _refreshStatus();
    return true;
  }

  Future<void> _toggle(bool on) async {
    if (on && _plan.blocks.isEmpty) {
      _snack('블록을 먼저 추가하세요');
      return;
    }
    if (on && (_dirty || _status?.exists != true)) {
      if (!await _save()) return;
    }
    setState(() => _busy = true);
    final error = await ScheduleApi.setEnabled(widget.deviceKey, on);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      _snack(error);
      return;
    }
    setState(() => _enabled = on);
    _snack(on ? '스케줄을 켰다. 시작 시각이 지났으면 바로 돈다' : '스케줄을 껐다. 진행 중인 블록까지만 하고 멈춘다');
    _refreshStatus();
  }

  Future<void> _pickStart() async {
    final parts = _plan.start.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 9,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() {
      _plan.start = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      _dirty = true;
    });
  }

  void _addBlock(String type) {
    final block = ScheduleBlock(type: type);
    if (type == ScheduleBlock.login && _accounts.isNotEmpty) block.account = _accounts.first;
    if (type == ScheduleBlock.cycle && _characterToBuild.isNotEmpty) {
      _setCharacter(block, _characterToBuild.keys.first);
    }
    setState(() {
      _plan.blocks.add(block);
      _dirty = true;
    });
  }

  void _setCharacter(ScheduleBlock block, String character) {
    block.character = character;
    block.build = _characterToBuild[character] ?? '';
    block.skip = List<String>.from(_skipByCharacter[character] ?? const []);
  }

  void _remove(int index) {
    setState(() {
      _plan.blocks.removeAt(index);
      _dirty = true;
    });
  }

  void _openOptions(ScheduleBlock block) {
    showRunOptionsSheet(
      context,
      character: block.character,
      skip: block.skip,
      onChanged: (skip) => setState(() {
        block.skip = skip;
        _dirty = true;
      }),
    );
  }

  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text('스케줄 · ${widget.ip}', style: const TextStyle(fontSize: 18)),
        actions: [
          Text(
            _enabled ? '스케줄 ON' : '스케줄 OFF',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _enabled ? Colors.green : Colors.grey,
            ),
          ),
          Switch(
            value: _enabled,
            onChanged: (_loaded && !_busy) ? _toggle : null,
            activeColor: Colors.green,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                          children: [
                            if (_status != null && _status!.exists) ...[
                              _statusCard(_status!),
                              const SizedBox(height: 10),
                            ],
                            _startCard(),
                            const SizedBox(height: 10),
                            for (var i = 0; i < _plan.blocks.length; i++) ...[
                              _blockCard(i, _plan.blocks[i]),
                              const SizedBox(height: 10),
                            ],
                            if (_plan.blocks.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: Text(
                                  '아래에서 블록을 추가해 하루 계획을 쌓는다',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 14, color: Color(0xFF6B6B6B)),
                                ),
                              ),
                          ],
                        ),
                      ),
                      _bottomBar(),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _statusCard(ScheduleStatus status) {
    final on = status.enabled;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: on ? const Color(0xFF1F1F1F) : _panel,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            status.headline,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? Colors.white : const Color(0xFF1F1F1F)),
          ),
          const SizedBox(height: 4),
          Text(
            status.detail,
            style: TextStyle(fontSize: 12, color: on ? const Color(0xFFCFCFD4) : _dark),
          ),
          if (status.running) ...[
            const SizedBox(height: 6),
            Text(
              '실행 중엔 고친 계획이 다음 실행부터 반영된다. OFF 로 바꾸면 지금 블록까지만 하고 멈춘다',
              style: TextStyle(fontSize: 11, color: on ? const Color(0xFF9A9AA0) : _dark),
            ),
          ],
        ],
      ),
    );
  }

  Widget _startCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('첫 블록 시작', style: TextStyle(fontSize: 12, color: _dark)),
                const SizedBox(height: 2),
                InkWell(
                  onTap: _pickStart,
                  child: Text(
                    _plan.start.replaceFirst(':', ' : '),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 1),
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('끝나면 OFF', style: TextStyle(fontSize: 12, color: _dark)),
              const SizedBox(height: 2),
              Text(
                '사이클 ${_plan.totalCycles} · 약 ${ScheduleBlock.hoursText(_plan.totalCycles)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              Text('종료 예상 ${_plan.endTimeText}', style: const TextStyle(fontSize: 12, color: _dark)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _blockCard(int index, ScheduleBlock block) {
    final iconColor = switch (block.type) {
      ScheduleBlock.login => const Color(0xFF2E7D32),
      ScheduleBlock.cycle => const Color(0xFF1565C0),
      _ => const Color(0xFFD84315),
    };
    final icon = switch (block.type) {
      ScheduleBlock.login => Icons.login,
      ScheduleBlock.cycle => Icons.autorenew,
      _ => Icons.logout,
    };

    // ListView 안에서는 세로 제약이 무한이라, 번호 아래 연결선을 Expanded 로 늘리려면 Row 의 높이를
    // 카드 높이로 먼저 묶어야 한다 — 안 그러면 stretch·Expanded 가 무한 높이를 받아 레이아웃이 깨진다
    // (0.1.0+21 에서 블록 카드가 서로 겹쳐 보인 원인).
    return IntrinsicHeight(
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 24,
          child: Column(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: _dark, shape: BoxShape.circle),
                child: Text('${index + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              Expanded(child: Container(width: 2, margin: const EdgeInsets.only(top: 4), color: const Color(0xFFC9C9CE))),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFDDDDE0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(color: iconColor, shape: BoxShape.circle),
                      child: Icon(icon, size: 16, color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(block.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: Color(0xFF6B6B6B)),
                      tooltip: '블록 삭제',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _remove(index),
                    ),
                  ],
                ),
                if (block.type == ScheduleBlock.login) ...[
                  const SizedBox(height: 8),
                  _labeled('계정', _dropdown(
                    value: _accounts.contains(block.account) ? block.account : null,
                    items: _accounts,
                    hint: _accounts.isEmpty ? 'PC 에서 계정 목록을 못 받았다' : '계정 선택',
                    onChanged: (v) => setState(() {
                      block.account = v ?? '';
                      _dirty = true;
                    }),
                  )),
                ],
                if (block.type == ScheduleBlock.cycle) ...[
                  const SizedBox(height: 8),
                  _labeled(
                    '빌드',
                    Row(
                      children: [
                        Expanded(
                          child: _dropdown(
                            value: _characterToBuild.containsKey(block.character) ? block.character : null,
                            items: _characterToBuild.keys.toList(),
                            labels: {for (final e in _characterToBuild.entries) e.key: '${e.key} - ${e.value}'},
                            hint: _characterToBuild.isEmpty ? '빌드 매핑이 없다' : '빌드 선택',
                            onChanged: (v) => setState(() {
                              if (v != null) _setCharacter(block, v);
                              _dirty = true;
                            }),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 36,
                          height: 36,
                          child: Material(
                            color: block.character.isEmpty ? Colors.grey[400] : _dark,
                            borderRadius: BorderRadius.circular(6),
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.settings, size: 18, color: Colors.white),
                              tooltip: '준비·정리 단계 설정',
                              onPressed: block.character.isEmpty ? null : () => _openOptions(block),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _labeled(
                    '사이클',
                    Row(
                      children: [
                        _stepButton('−', () => setState(() {
                              block.cycles = (block.cycles - 1).clamp(1, 99);
                              _dirty = true;
                            })),
                        SizedBox(
                          width: 40,
                          child: Text('${block.cycles}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        ),
                        _stepButton('+', () => setState(() {
                              block.cycles = (block.cycles + 1).clamp(1, 99);
                              _dirty = true;
                            })),
                        Expanded(
                          child: Text('약 ${block.durationText}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: _dark)),
                        ),
                      ],
                    ),
                  ),
                  if (block.skip.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text('꺼짐: ${runStepLabels(block.skip).join(', ')}', style: const TextStyle(fontSize: 12, color: Colors.deepOrange)),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
      ),
    );
  }

  Widget _labeled(String label, Widget child) {
    return Row(
      children: [
        SizedBox(width: 40, child: Text(label, style: const TextStyle(fontSize: 13, color: _dark))),
        Expanded(child: child),
      ],
    );
  }

  Widget _dropdown({
    required String? value,
    required List<String> items,
    required String hint,
    required ValueChanged<String?> onChanged,
    Map<String, String>? labels,
  }) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: _dark, borderRadius: BorderRadius.circular(6)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: Text(hint, style: TextStyle(color: Colors.grey[400], fontSize: 13), overflow: TextOverflow.ellipsis),
          isExpanded: true,
          dropdownColor: Colors.grey[850],
          iconEnabledColor: Colors.white,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          items: [
            for (final item in items)
              DropdownMenuItem(value: item, child: Text(labels?[item] ?? item, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: items.isEmpty ? null : onChanged,
        ),
      ),
    );
  }

  Widget _stepButton(String label, VoidCallback onTap) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Material(
        color: _panel,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Center(child: Text(label, style: const TextStyle(fontSize: 18))),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Color(0xFFDDDDE0), offset: Offset(0, -1), blurRadius: 0)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('블록 추가', style: TextStyle(fontSize: 12, color: _dark)),
          const SizedBox(height: 8),
          Row(
            children: [
              _addButton('로그인', const Color(0xFF2E7D32), () => _addBlock(ScheduleBlock.login)),
              const SizedBox(width: 8),
              _addButton('사이클', const Color(0xFF1565C0), () => _addBlock(ScheduleBlock.cycle)),
              const SizedBox(width: 8),
              _addButton('로그아웃', const Color(0xFFD84315), () => _addBlock(ScheduleBlock.logout)),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _dirty ? _button : Colors.grey[400],
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: _busy ? null : _save,
              child: Text(
                _dirty ? '저장' : '저장됨',
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _addButton(String label, Color dot, VoidCallback onTap) {
    return Expanded(
      child: SizedBox(
        height: 44,
        child: Material(
          color: _panel,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
