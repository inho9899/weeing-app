import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;

class LobbyScreen extends StatefulWidget {
  final String basePath; // 예: http://192.168.35.179:8000/
  const LobbyScreen({super.key, required this.basePath});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  // ===== WebSocket 화면 스트림 =====
  late WebSocketChannel _channel;
  Uint8List? _imageBytes;
  bool _connected = false;

  // ===== 상태 값 =====
  int _cycle = 0;
  int _startHour = DateTime.now().hour;
  int _startMinute = DateTime.now().minute;

  List<String> _builds = [];
  String _currentMap = '';
  String? _runningBuildFromStatus; // status에서 받은 running_build

  final TextEditingController _commandController = TextEditingController();
  Timer? _pollTimer;

  // ===== Wheel controllers =====
  late FixedExtentScrollController _cycleCtrl;
  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minCtrl;

  // ===== Trackpad mode =====
  bool _trackpadMode = false;
  double _accumDx = 0; // 트랙패드 이동 누적값
  double _accumDy = 0;

  static const double _pointerScale = 2;

  // ===== API URL =====
  String get _statusUrl => '${widget.basePath}status/';
  String get _buildListUrl => '${widget.basePath}build/list';
  String get _setCycleUrl => '${widget.basePath}status/cycle/set';
  String get _startTimeUrl => '${widget.basePath}status/start_time';
  String get _inputSequenceUrl => '${widget.basePath}input/sequence';
  String get _mouseMoveBaseUrl => '${widget.basePath}input/MouseMove';
  String get _mouseClickBaseUrl => '${widget.basePath}input/MouseClick';
  String get _startUrl =>
      '${widget.basePath}weeing/start/${Uri.encodeComponent(_currentMap)}';
  String get _pauseUrl => '${widget.basePath}weeing/pause';
  String get _resumeUrl => '${widget.basePath}weeing/resume';

  String get _hostText {
    try {
      final uri = Uri.parse(widget.basePath);
      if (uri.host.isNotEmpty) return uri.host;
      return widget.basePath;
    } catch (_) {
      return widget.basePath;
    }
  }

  @override
  void initState() {
    super.initState();

    _cycleCtrl = FixedExtentScrollController();
    _hourCtrl = FixedExtentScrollController();
    _minCtrl = FixedExtentScrollController();

    // WebSocket 화면 스트림
    _channel = WebSocketChannel.connect(
      Uri.parse('ws://${Uri.parse(widget.basePath).host}:8765'),
    );

    _channel.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message);
          if (data is Map && data['type'] == 'frame') {
            final bytes = base64Decode(data['data'] as String);
            setState(() {
              _imageBytes = bytes;
              _connected = true;
            });
          }
        } catch (e) {
          debugPrint('WebSocket parse error: $e');
        }
      },
      onDone: () {
        debugPrint('WebSocket closed');
        setState(() => _connected = false);
      },
      onError: (error) {
        debugPrint('WebSocket error: $error');
        setState(() => _connected = false);
      },
    );

    _fetchBuildList();
    _fetchStatus();

    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _fetchStatus(),
    );
  }

  @override
  void dispose() {
    _channel.sink.close();
    _pollTimer?.cancel();
    _commandController.dispose();
    _cycleCtrl.dispose();
    _hourCtrl.dispose();
    _minCtrl.dispose();
    super.dispose();
  }

  // =========================================================
  // API helpers
  // =========================================================

  Future<void> _fetchBuildList() async {
    try {
      final res = await http.get(Uri.parse(_buildListUrl));
      if (res.statusCode != 200) return;
      final payload = jsonDecode(res.body);
      final list =
          (payload['data'] as List?)?.map((e) => e.toString()).toList() ?? [];

      setState(() {
        _builds = list;
        if (_runningBuildFromStatus != null &&
            _runningBuildFromStatus!.isNotEmpty &&
            _runningBuildFromStatus != 'None' &&
            _builds.contains(_runningBuildFromStatus)) {
          _currentMap = _runningBuildFromStatus!;
        } else if (_currentMap.isEmpty && _builds.isNotEmpty) {
          _currentMap = _builds[0];
        }
      });
    } catch (e) {
      debugPrint('fetchBuildList error: $e');
    }
  }

  Map<String, String> _parseStatusData(String? dataStr) {
    debugPrint('STATUS raw data: $dataStr');
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

  Future<void> _fetchStatus() async {
    try {
      final res = await http.get(Uri.parse(_statusUrl));
      if (res.statusCode != 200) return;

      final payload = jsonDecode(res.body);
      final dataStr = payload['data'] as String?;
      final parsed = _parseStatusData(dataStr);

      int? expCycle;
      int? startH;
      int? startM;
      String? runningBuild;

      if (parsed.containsKey('exp_cycle')) {
        final raw = (parsed['exp_cycle'] ?? '').trim();
        final n = int.tryParse(raw) ?? double.tryParse(raw)?.round();
        if (n != null) expCycle = n.clamp(0, 99).toInt();
      }
      if (parsed.containsKey('start_time')) {
        final raw = parsed['start_time'] ?? '';
        final parts = raw.split(':');
        if (parts.length >= 2) {
          final hRaw = parts[0].trim();
          final mRaw = parts[1].trim();
          final h = int.tryParse(hRaw) ?? double.tryParse(hRaw)?.round();
          final m = int.tryParse(mRaw) ?? double.tryParse(mRaw)?.round();
          if (h != null && m != null) {
            startH = h.clamp(0, 23).toInt();
            startM = m.clamp(0, 59).toInt();
          }
        }
      }
      if (parsed.containsKey('running_build')) {
        final rb = (parsed['running_build'] ?? '').trim();
        if (rb.isNotEmpty && rb != 'None') {
          runningBuild = rb;
        }
      }

      setState(() {
        if (expCycle != null) _cycle = expCycle;
        if (startH != null) _startHour = startH;
        if (startM != null) _startMinute = startM;
        if (runningBuild != null) {
          _runningBuildFromStatus = runningBuild;
          if (_builds.contains(runningBuild)) {
            _currentMap = runningBuild!;
          }
        }
      });

      if (expCycle != null) _cycleCtrl.jumpToItem(_cycle);
      if (startH != null) _hourCtrl.jumpToItem(_startHour);
      if (startM != null) _minCtrl.jumpToItem(_startMinute);

      debugPrint(
          'STATUS parsed -> cycle=$_cycle, time=${_startHour}:${_startMinute}, running_build=$_runningBuildFromStatus');
    } catch (e) {
      debugPrint('fetchStatus error: $e');
    }
  }

  Future<void> _setCycleOnServer(int value) async {
    try {
      final uri = Uri.parse(_setCycleUrl);
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(value),
      );
      if (res.statusCode != 200) {
        debugPrint('set_cycle failed: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('set_cycle error: $e');
    }
  }

  Future<void> _sendStartTimeDelta(int hDelta, int mDelta) async {
    try {
      final res = await http.post(
        Uri.parse(_startTimeUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'hour': hDelta, 'minute': mDelta}),
      );
      if (res.statusCode != 200) {
        debugPrint('start_time delta failed: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('start_time delta error: $e');
    }
  }

  Future<void> _handleStart() async {
    if (_currentMap.isEmpty) {
      debugPrint('No build available to start');
      return;
    }
    try {
      debugPrint('Starting build: $_currentMap');
      final res = await http.post(Uri.parse(_startUrl));
      if (res.statusCode == 409) {
        debugPrint('Weeing already running. Trying resume...');
        final resumeRes = await http.post(Uri.parse(_resumeUrl));
        if (resumeRes.statusCode != 200) {
          throw Exception('Resume failed');
        }
        debugPrint('Weeing resumed.');
      } else if (res.statusCode == 200) {
        debugPrint('Weeing started.');
      } else {
        throw Exception('Start failed (${res.statusCode})');
      }
    } catch (e) {
      debugPrint('Start/resume request failed: $e');
    }
    _fetchStatus();
  }

  Future<void> _handlePause() async {
    try {
      final res = await http.post(Uri.parse(_pauseUrl));
      if (res.statusCode != 200) throw Exception('Pause failed');
      debugPrint('Pause requested successfully');
    } catch (e) {
      debugPrint('Pause request failed: $e');
    }
    _fetchStatus();
  }

  Future<void> _handleSend() async {
    final msg = _commandController.text.trim();
    if (msg.isEmpty) return;
    try {
      final url = '$_inputSequenceUrl/${Uri.encodeComponent(msg)}';
      final res = await http.post(Uri.parse(url));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      debugPrint('Sent sequence: "$msg"');
    } catch (e) {
      debugPrint('Send failed: $e');
    }
  }

  // ===== Mouse APIs =====

  Future<void> _sendMouseMove(int dx, int dy) async {
    try {
      final url = '$_mouseMoveBaseUrl/$dx/$dy';
      final res = await http.post(Uri.parse(url));
      if (res.statusCode != 200) {
        debugPrint('mouse_move failed: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('mouse_move error: $e');
    }
  }

  Future<void> _sendMouseClick(String button) async {
    try {
      final url = '$_mouseClickBaseUrl/$button';
      final res = await http.post(Uri.parse(url));
      if (res.statusCode != 200) {
        debugPrint('mouse_click failed: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('mouse_click error: $e');
    }
  }

  // =========================================================
  // StartTime 휠 → delta 계산
  // =========================================================

  void _onHourChanged(int newVal) {
    final old = _startHour;
    if (newVal == old) return;

    final forward = (newVal - old + 24) % 24;
    final backward = (old - newVal + 24) % 24;
    final delta = forward <= backward ? forward : -backward;

    setState(() => _startHour = newVal);
    _sendStartTimeDelta(delta, 0);
  }

  void _onMinuteChanged(int newVal) {
    final old = _startMinute;
    if (newVal == old) return;

    final forward = (newVal - old + 60) % 60;
    final backward = (old - newVal + 60) % 60;
    final delta = forward <= backward ? forward : -backward;

    setState(() => _startMinute = newVal);
    _sendStartTimeDelta(0, delta);
  }

  // =========================================================
  // UI
  // =========================================================

  @override
  Widget build(BuildContext context) {
    const bgColor = Color(0xFFF3F3F5);
    const darkGrey = Color(0xFF5A5A5A);

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 상단 IP + info
                  Row(
                    children: [
                      Text(
                        _hostText,
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.info_outline),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // 화면 스트림
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _imageBytes == null
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const CircularProgressIndicator(),
                                  const SizedBox(height: 12),
                                  Text(
                                    _connected
                                        ? '첫 프레임 대기 중...'
                                        : '서버 연결 없음...',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              )
                            : Image.memory(
                                _imageBytes!,
                                gaplessPlayback: true,
                                fit: BoxFit.cover,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 스트림 아래 영역: 컨트롤 or 트랙패드
                  if (!_trackpadMode) ...[
                    _buildControlArea(darkGrey),
                  ] else ...[
                    _buildTrackpadArea(),
                  ],

                  const SizedBox(height: 24),

                  // 트랙패드 토글 버튼 (오른쪽 아래)
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _trackpadMode = !_trackpadMode;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color:
                              _trackpadMode ? Colors.blueAccent : Colors.pinkAccent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.error_outline,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ===== 컨트롤 모드 UI =====
  Widget _buildControlArea(Color darkGrey) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Build Picker
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: darkGrey,
            borderRadius: BorderRadius.circular(6),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _currentMap.isNotEmpty ? _currentMap : null,
              isExpanded: true,
              dropdownColor: Colors.grey[850],
              iconEnabledColor: Colors.white,
              style: const TextStyle(color: Colors.white),
              items: _builds
                  .map(
                    (b) => DropdownMenuItem(
                      value: b,
                      child: Text(b),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => _currentMap = v);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Start / Pause
        Row(
          children: [
            Expanded(
              child: _greyButton(label: 'Start', onTap: _handleStart),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _greyButton(label: 'Pause', onTap: _handlePause),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Cycle + StartTime
        Row(
          children: [
            Expanded(child: _cycleControl()),
            const SizedBox(width: 8),
            Expanded(child: _startTimeControl()),
          ],
        ),
        const SizedBox(height: 20),

        // 메시지 입력
        TextField(
          controller: _commandController,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            hintText: '메시지 입력...',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: _greyButton(
                label: 'Send',
                onTap: _handleSend,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _greyButton(
                label: 'Clear',
                onTap: () => _commandController.clear(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ===== 트랙패드 모드 UI =====
  Widget _buildTrackpadArea() {
    return Column(
      children: [
        Container(
          height: 260,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              // 좌클릭
              _sendMouseClick('left');
            },
            onDoubleTap: () {
              // 우클릭
              _sendMouseClick('right');
            },
            onPanStart: (_) {
              _accumDx = 0;
              _accumDy = 0;
            },
            onPanUpdate: (details) {
              // 드래그한 픽셀 * 민감도 로 누적
              _accumDx += details.delta.dx * _pointerScale;
              _accumDy += details.delta.dy * _pointerScale;

              int dxInt = _accumDx.round();
              int dyInt = _accumDy.round();

              // 아직 1픽셀 이하라면 전송 안 함
              if (dxInt == 0 && dyInt == 0) return;

              // 보낸 만큼 누적값에서 빼주기 (소수 부분은 계속 쌓이게)
              _accumDx -= dxInt;
              _accumDy -= dyInt;

              _sendMouseMove(dxInt, dyInt);
            },
            onPanEnd: (_) {
              _accumDx = 0;
              _accumDy = 0;
            },
            child: const Center(
              child: Text(
                'Trackpad mode\n(탭=좌클릭, 더블탭=우클릭, 드래그=이동)',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.black26,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ===== 공통 helpers =====
  Widget _greyButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF757575),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
          padding: EdgeInsets.zero,
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _numberPicker({
    required int max,
    required int selected,
    required ValueChanged<int> onChanged,
    required FixedExtentScrollController controller,
    double width = 60,
  }) {
    final safeSelected = selected.clamp(0, max);

    return SizedBox(
      width: width,
      height: 110,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 32,
            width: width - 8,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.9),
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
          ListWheelScrollView.useDelegate(
            controller: controller,
            physics: const FixedExtentScrollPhysics(),
            perspective: 0.003,
            itemExtent: 32,
            onSelectedItemChanged: (index) {
              if (index < 0 || index > max) return;
              onChanged(index);
            },
            childDelegate: ListWheelChildBuilderDelegate(
              builder: (context, index) {
                if (index < 0 || index > max) return null;
                final bool isSelected = index == safeSelected;
                return Center(
                  child: Text(
                    index.toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: isSelected ? 18 : 16,
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected ? Colors.black : Colors.black45,
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

  Widget _cycleControl() {
    return SizedBox(
      height: 160,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFE6E6E9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cycle',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Center(
                child: _numberPicker(
                  max: 99,
                  selected: _cycle,
                  controller: _cycleCtrl,
                  width: 70,
                  onChanged: (v) {
                    if (v == _cycle) return;
                    setState(() => _cycle = v);
                    _setCycleOnServer(v);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _startTimeControl() {
    return SizedBox(
      height: 170,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFE6E6E9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        '시',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      _numberPicker(
                        max: 23,
                        selected: _startHour,
                        controller: _hourCtrl,
                        width: 60,
                        onChanged: _onHourChanged,
                      ),
                    ],
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        '분',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      _numberPicker(
                        max: 59,
                        selected: _startMinute,
                        controller: _minCtrl,
                        width: 60,
                        onChanged: _onMinuteChanged,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
