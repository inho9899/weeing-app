import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:weeing_app/widgets/lobby_header.dart';
import 'package:weeing_app/widgets/lobby_webrtc_view.dart';
import 'package:weeing_app/widgets/controls.dart';
import 'package:weeing_app/widgets/trackpad_area.dart';
import 'package:weeing_app/widgets/cycle_control.dart';
import 'package:weeing_app/widgets/start_time_control.dart';
import 'package:weeing_app/mouse_mode.dart';

class LobbyScreen extends StatefulWidget {
  final String basePath; // 예: http://192.168.35.179:8000/
  const LobbyScreen({super.key, required this.basePath});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> with WidgetsBindingObserver {
  // ===== WebRTC 화면 스트림 =====
  RTCPeerConnection? _pc;
  RTCDataChannel? _inputChannel;
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _webrtcConnected = false;
  Timer? _webrtcRetryTimer;
  WebSocketChannel? _signalingChannel;
  StreamSubscription? _signalingSubscription;
  String? _senderPeerId;

  // ===== 상태 값 =====
  int _cycle = 0;
  int _startHour = DateTime.now().hour;
  int _startMinute = DateTime.now().minute;

  List<String> _builds = [];
  String _currentMap = '';
  String? _runningBuildFromStatus;

  final TextEditingController _commandController = TextEditingController();
  Timer? _pollTimer;
  bool _initialStatusFetched = false;

  double _streamScale = 1.0;
  Offset _streamOffset = Offset.zero;

  // ===== Wheel controllers =====
  late FixedExtentScrollController _cycleCtrl;
  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minCtrl;

  // ===== Trackpad mode =====
  bool _trackpadMode = false;

  // ===== API URL =====
  String get _statusUrl => '${widget.basePath}status/';
  String get _buildListUrl => '${widget.basePath}build/list';
  String get _setCycleUrl => '${widget.basePath}status/cycle/set';
  String get _startTimeUrl => '${widget.basePath}status/start_time';
  String get _inputSequenceUrl => '${widget.basePath}input/sequence';
  String get _startUrl =>
      '${widget.basePath}weeing/start/${Uri.encodeComponent(_currentMap)}';
  String get _pauseUrl => '${widget.basePath}weeing/pause';
  String get _resumeUrl => '${widget.basePath}weeing/resume';
  String get _convertUrl => '${widget.basePath}input/convert_mode';

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

    _renderer.initialize().then((_) {
      _connectWebRTC();
    });

    WidgetsBinding.instance.addObserver(this);

    _fetchBuildList();
    _fetchStatus();

    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _fetchStatus(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // 앱이 foreground로 돌아올 때 WebRTC 재연결
      debugPrint('App resumed, reconnecting WebRTC...');
      _reconnectWebRTC();
    }
  }

  void _reconnectWebRTC() async {
    debugPrint('WebRTC: Reconnecting (IP Switching or Resume)...');
    
    // 1. 모든 기존 연결 및 상태를 명시적으로 파괴
    _webrtcRetryTimer?.cancel();
    _webrtcRetryTimer = null;
    
    _signalingSubscription?.cancel();
    _signalingSubscription = null;
    
    _signalingChannel?.sink.close();
    _signalingChannel = null;
    
    _inputChannel?.close();
    _inputChannel = null;
    
    await _pc?.close();
    _pc = null;

    _senderPeerId = null;
    
    setState(() {
      _webrtcConnected = false;
      _renderer.srcObject = null;
    });

    // 2. 약간의 지연 후 새 서버에 연결
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _connectWebRTC();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _webrtcRetryTimer?.cancel();
    _signalingSubscription?.cancel();
    _signalingChannel?.sink.close();
    _inputChannel?.close();
    _pc?.close();
    _renderer.dispose();

    _pollTimer?.cancel();
    _commandController.dispose();
    _cycleCtrl.dispose();
    _hourCtrl.dispose();
    _minCtrl.dispose();
    super.dispose();
  }

  // =========================================================
  // WebRTC Signaling
  // =========================================================

  String get _webrtcSignalingUrl =>
      'ws://${Uri.parse(widget.basePath).host}:8765/ws';

  void _connectWebRTC() async {
    _signalingSubscription?.cancel();
    _signalingChannel?.sink.close();

    try {
      _signalingChannel = WebSocketChannel.connect(Uri.parse(_webrtcSignalingUrl));
      _signalingSubscription = _signalingChannel!.stream.listen(
        (message) => _onSignalingMessage(message),
        onDone: () => _scheduleWebRTCRetry(),
        onError: (_) => _scheduleWebRTCRetry(),
      );

      // Join room
      _signalingChannel!.sink.add(jsonEncode({
        'type': 'join',
        'role': 'receiver',
        'roomId': 'default',
        'peerId': 'receiver_${DateTime.now().millisecondsSinceEpoch}',
      }));
      debugPrint('WebRTC: Join message sent');
    } catch (_) {
      _scheduleWebRTCRetry();
    }
  }

  void _scheduleWebRTCRetry() {
    setState(() => _webrtcConnected = false);
    _webrtcRetryTimer?.cancel();
    _webrtcRetryTimer = Timer(const Duration(seconds: 3), () => _connectWebRTC());
  }

  void _onSignalingMessage(String message) async {
    try {
      final data = jsonDecode(message);
      final type = data['type'];

      if (type == 'joined') {
        // Successfully joined
      } else if (type == 'peer_joined') {
        if (data['role'] == 'sender') {
          _senderPeerId = data['peerId'];
          debugPrint('WebRTC: Sender joined: $_senderPeerId');
          await _createPeerConnection();
        }
      } else if (type == 'offer') {
        _senderPeerId = data['fromPeerId'];
        debugPrint('WebRTC: Received offer from $_senderPeerId');
        if (_pc == null) await _createPeerConnection();
        await _pc!.setRemoteDescription(RTCSessionDescription(data['sdp'], 'offer'));
        final answer = await _pc!.createAnswer();
        await _pc!.setLocalDescription(answer);
        _signalingChannel!.sink.add(jsonEncode({
          'type': 'answer',
          'toPeerId': _senderPeerId,
          'sdp': answer.sdp,
        }));
        debugPrint('WebRTC: Answer sent');
      } else if (type == 'candidate') {
        final candidate = data['candidate'];
        await _pc?.addCandidate(RTCIceCandidate(
          candidate['candidate'],
          candidate['sdpMid'],
          candidate['sdpMLineIndex'],
        ));
      } else if (type == 'peer_left') {
        if (data['peerId'] == _senderPeerId) {
          _pc?.close();
          _pc = null;
          setState(() => _webrtcConnected = false);
        }
      }
    } catch (_) {}
  }

  Future<void> _createPeerConnection() async {
    if (_pc != null) await _pc!.close();

    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    });

    _pc!.onIceCandidate = (candidate) {
      if (_senderPeerId != null) {
        _signalingChannel!.sink.add(jsonEncode({
          'type': 'candidate',
          'toPeerId': _senderPeerId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        }));
      }
    };

    _pc!.onConnectionState = (state) {
      debugPrint('WebRTC: Connection state changed: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        setState(() => _webrtcConnected = true);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        setState(() => _webrtcConnected = false);
      }
    };

    _pc!.onTrack = (event) {
      debugPrint('WebRTC: onTrack kind=${event.track.kind} streams=${event.streams.length}');
      if (event.track.kind == 'video') {
        setState(() {
          _renderer.srcObject = event.streams.isNotEmpty ? event.streams[0] : null;
        });
      }
    };

    _pc!.onDataChannel = (channel) {
      _inputChannel = channel;
    };
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
    } catch (_) {}
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
            _currentMap = runningBuild;
          }
        }
      });

      // 초기 1회만 스크롤 위치를 맞춤 (사용자 조작 방해 방지)
      if (!_initialStatusFetched) {
        if (expCycle != null) _cycleCtrl.jumpToItem(_cycle);
        if (startH != null) _hourCtrl.jumpToItem(_startHour);
        if (startM != null) _minCtrl.jumpToItem(_startMinute);
        _initialStatusFetched = true;
      }
    } catch (_) {}
  }

  Future<void> _setCycleOnServer(int value) async {
    try {
      final uri = Uri.parse(_setCycleUrl);
      await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(value),
      );
    } catch (_) {}
  }

  Future<void> _sendStartTimeDelta(int hDelta, int mDelta) async {
    try {
      await http.post(
        Uri.parse(_startTimeUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'hour': hDelta, 'minute': mDelta}),
      );
    } catch (_) {}
  }

  Future<void> _handleStart() async {
    if (_currentMap.isEmpty) return;
    try {
      final res = await http.post(Uri.parse(_startUrl));
      if (res.statusCode == 409) {
        final resumeRes = await http.post(Uri.parse(_resumeUrl));
        if (resumeRes.statusCode != 200) {
          throw Exception('Resume failed');
        }
      } else if (res.statusCode != 200) {
        throw Exception('Start failed (${res.statusCode})');
      }
    } catch (_) {}
    _fetchStatus();
  }

  Future<void> _handlePause() async {
    try {
      final res = await http.post(Uri.parse(_pauseUrl));
      if (res.statusCode != 200) throw Exception('Pause failed');
    } catch (_) {}
    _fetchStatus();
  }

  Future<void> _handleSend() async {
    final msg = _commandController.text.trim();
    if (msg.isEmpty) return;
    try {
      final url = '$_inputSequenceUrl/${Uri.encodeComponent(msg)}';
      final res = await http.post(Uri.parse(url));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    } catch (_) {}
  }

  Future<void> _handle_convert() async {
    try {
      final res = await http.post(Uri.parse(_convertUrl));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    } catch (_) {}
  }

  Future<void> _callSimplePost(String path) async {
    try {
      final url = '${widget.basePath}$path';
      await http.post(Uri.parse(url));
    } catch (_) {}
  }

  Future<void> _callLogin(String id, String pw) async {
    try {
      _callSimplePost('weeing/login?id=$id&pw=$pw');
    } catch (_) {}
  }

  void _showLoginDialog() {
    final idController = TextEditingController();
    final pwController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('로그인'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: idController,
                decoration: const InputDecoration(
                  labelText: 'ID',
                  hintText: '아이디 입력',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pwController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  hintText: '비밀번호 입력',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('취소'),
            ),
            ElevatedButton(
              onPressed: () {
                final id = idController.text.trim();
                final pw = pwController.text.trim();
                if (id.isNotEmpty && pw.isNotEmpty) {
                  Navigator.of(ctx).pop();
                  _callLogin(id, pw);
                }
              },
              child: const Text('로그인'),
            ),
          ],
        );
      },
    );
  }

  void _openInfoSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.info_outline, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Info / Tools ($_hostText)',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.bolt_outlined),
                  title: const Text('부스터 적용'),
                  subtitle: const Text('부스터 아이템 사용'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _callSimplePost('weeing/booster');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('로그아웃'),
                  subtitle: const Text('현재 계정에서 로그아웃'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _callSimplePost('weeing/logout');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.login),
                  title: const Text('로그인'),
                  subtitle: const Text('ID/PW로 로그인'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showLoginDialog();
                  },
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '※ 나중에 여기 ListTile을 복사해서\n 원하는 엔드포인트로 onTap만 바꾸면 됨.',
                    style: TextStyle(fontSize: 11, color: Colors.black45),
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===== Mouse APIs =====
  // Delegated to MouseMode widget

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

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LobbyHeader(
                    hostText: _hostText,
                    onInfoTap: _openInfoSheet,
                  ),
                  const SizedBox(height: 8),
                  LobbyWebRTCView(
                    renderer: _renderer,
                    connected: _webrtcConnected,
                    scale: _streamScale,
                    offset: _streamOffset,
                  ),
                  const SizedBox(height: 16),
                  if (!_trackpadMode)
                    LobbyControls(
                      builds: _builds,
                      currentMap: _currentMap,
                      onMapChanged: (v) {
                        if (v == null) return;
                        setState(() => _currentMap = v);
                      },
                      onStart: _handleStart,
                      onPause: _handlePause,
                      cycle: CycleControl(
                        value: _cycle,
                        controller: _cycleCtrl,
                        onChanged: (v) {
                          setState(() => _cycle = v);
                          _setCycleOnServer(v);
                        },
                      ),
                      startTime: StartTimeControl(
                        hour: _startHour,
                        minute: _startMinute,
                        hourController: _hourCtrl,
                        minuteController: _minCtrl,
                        onHourChanged: _onHourChanged,
                        onMinuteChanged: _onMinuteChanged,
                      ),
                      commandController: _commandController,
                      onSend: _handleSend,
                      onConvertMode: _handle_convert,
                    )
                  else
                    MouseMode(
                      basePath: widget.basePath,
                      initialScale: _streamScale,
                      initialOffset: _streamOffset,
                      onScaleChanged: (s) => setState(() => _streamScale = s),
                      onOffsetChanged: (o) => setState(() => _streamOffset = o),
                    ),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _trackpadMode = !_trackpadMode;
                          // 마우스 모드 진입/해제 시 확대 및 이동 초기화
                          _streamScale = 1.0;
                          _streamOffset = Offset.zero;
                        });

                        // 트랙패드 모드에서 돌아올 때 휠 위치 복구
                        if (!_trackpadMode) {
                          _initialStatusFetched = false; // 다음 fetchStatus에서 다시 맞추도록 허용
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (_cycleCtrl.hasClients) _cycleCtrl.jumpToItem(_cycle);
                            if (_hourCtrl.hasClients) _hourCtrl.jumpToItem(_startHour);
                            if (_minCtrl.hasClients) _minCtrl.jumpToItem(_startMinute);
                          });
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: _trackpadMode ? Colors.blueAccent : Colors.pinkAccent,
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
}
