import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:weeing_app/gateway/gateway.dart';
import 'widgets/lobby_header.dart';
import 'widgets/lobby_webrtc_view.dart';
import 'widgets/lobby_controls.dart';
import 'widgets/cycle_control.dart';
import 'widgets/start_time_control.dart';
import 'widgets/mouse_mode.dart';
import 'services/lobby_api_service.dart';

class LobbyScreen extends StatefulWidget {
  /// 대상 머신 IP (예: "192.168.0.5")
  final String ip;

  /// 캡차 도움 탭에 사람 입력이 필요한 상태가 있는지 — 마우스 모드 화면에
  /// 빨간 느낌표로 표시한다 (PcTabsScreen이 캡차 도움 탭 상태를 보고 넘겨줌).
  final bool captchaNeedsAttention;

  /// 트랙패드(마우스 모드) 전환 시 호출 — PcTabsScreen이 이걸로 상단
  /// 제어/캡차도움 탭바를 마우스 모드일 때만 보여준다.
  final ValueChanged<bool>? onTrackpadModeChanged;

  const LobbyScreen({
    super.key,
    required this.ip,
    this.captchaNeedsAttention = false,
    this.onTrackpadModeChanged,
  });

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> with WidgetsBindingObserver {
  // ===== WebRTC =====
  RTCPeerConnection? _pc;
  RTCDataChannel? _inputChannel;
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _webrtcConnected = false;
  Timer? _webrtcRetryTimer;
  WebSocketChannel? _signalingChannel;
  StreamSubscription? _signalingSubscription;
  String? _senderPeerId;

  // ===== API Service =====
  late final LobbyApiService _api;

  // ===== State =====
  int _cycle = 0;
  int _startHour = DateTime.now().hour;
  int _startMinute = DateTime.now().minute;

  List<String> _builds = [];
  String _currentMap = '';
  String? _runningBuildFromStatus;

  // 캐릭터명 : 빌드 매핑 (config 화면에서 저장, cloudflare 가 SoT).
  // 이 기기(macros)에 있는 캐릭터로만 좁혀서 사용한다.
  Map<String, String> _characterToBuild = {};
  Map<String, String> _buildToCharacter = {};
  String _currentCharacter = '';

  final TextEditingController _commandController = TextEditingController();
  Timer? _pollTimer;      // cycle 폴링 (1초)
  Timer? _timeSyncTimer;  // 시간 동기화 (1분)
  bool _initialStatusFetched = false;

  double _streamScale = 1.0;
  Offset _streamOffset = Offset.zero;
  Size _streamViewSize = const Size(400, 225); // 16:9 기본값

  // 스트리머 캡처 영역 오프셋 (streaming/main.py POST /streamer/start 기본값 x=0,y=30 과 고정 동일)
  static const int _captureOffsetX = 0;
  static const int _captureOffsetY = 30;

  // ===== Wheel controllers =====
  late FixedExtentScrollController _cycleCtrl;
  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minCtrl;

  // ===== Trackpad mode =====
  bool _trackpadMode = false;

  String get _hostText => widget.ip;

  /// 드롭다운에 보여줄 목록. 캐릭터 매핑이 있으면 캐릭터명 목록, 매핑이
  /// 아예 없으면 raw 빌드명 목록을 그대로 보여준다 (매핑 전에도 뭔가 고를 수 있게).
  List<String> get _characterDropdownItems {
    if (_characterToBuild.isNotEmpty) return _characterToBuild.keys.toList();
    return _builds;
  }

  @override
  void initState() {
    super.initState();
    _api = LobbyApiService(ip: widget.ip);

    _cycleCtrl = FixedExtentScrollController();
    _hourCtrl = FixedExtentScrollController(initialItem: _startHour);
    _minCtrl = FixedExtentScrollController(initialItem: _startMinute);

    _renderer.initialize().then((_) {
      _connectWebRTC();
    });

    WidgetsBinding.instance.addObserver(this);

    // 부모(PcTabsScreen)에 초기 트랙패드 모드 상태를 알려 탭바 표시 여부를 맞춘다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onTrackpadModeChanged?.call(_trackpadMode);
    });

    _fetchBuildList();
    _fetchCharacterMapping();
    _fetchCycleAndBuild();
    _syncTime();

    // cycle 폴링: 1초마다
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _fetchCycleAndBuild(),
    );

    // 시간 동기화: 1분마다
    _timeSyncTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _syncTime(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      debugPrint('App resumed, reconnecting WebRTC and syncing time...');
      _reconnectWebRTC();
      _syncTime();  // 화면 켤 때 시간 동기화
    }
  }

  void _reconnectWebRTC() async {
    debugPrint('WebRTC: Reconnecting...');

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
    _timeSyncTimer?.cancel();
    _commandController.dispose();
    _cycleCtrl.dispose();
    _hourCtrl.dispose();
    _minCtrl.dispose();
    super.dispose();
  }

  // =========================================================
  // WebRTC Signaling
  // =========================================================

  // 스트리밍 시그널링도 cloudflare 를 경유한다.
  Uri get _webrtcSignalingUri => Gateway.signalingUri(widget.ip);

  void _connectWebRTC() async {
    _signalingSubscription?.cancel();
    _signalingChannel?.sink.close();

    try {
      _signalingChannel =
          WebSocketChannel.connect(_webrtcSignalingUri);
      _signalingSubscription = _signalingChannel!.stream.listen(
        (message) => _onSignalingMessage(message),
        onDone: () => _scheduleWebRTCRetry(),
        onError: (_) => _scheduleWebRTCRetry(),
      );

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
    _webrtcRetryTimer =
        Timer(const Duration(seconds: 3), () => _connectWebRTC());
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
        await _pc!
            .setRemoteDescription(RTCSessionDescription(data['sdp'], 'offer'));
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
        {
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
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
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        setState(() => _webrtcConnected = false);
      }
    };

    _pc!.onTrack = (event) {
      debugPrint(
          'WebRTC: onTrack kind=${event.track.kind} streams=${event.streams.length}');
      if (event.track.kind == 'video') {
        setState(() {
          _renderer.srcObject =
              event.streams.isNotEmpty ? event.streams[0] : null;
        });
      }
    };

    _pc!.onDataChannel = (channel) {
      _inputChannel = channel;
    };
  }

  // =========================================================
  // API calls
  // =========================================================

  Future<void> _fetchBuildList() async {
    final list = await _api.fetchBuildList();
    if (!mounted) return;
    setState(() {
      _builds = list;
      if (_runningBuildFromStatus != null &&
          _runningBuildFromStatus!.isNotEmpty &&
          _runningBuildFromStatus != 'None' &&
          _builds.contains(_runningBuildFromStatus)) {
        _currentMap = _runningBuildFromStatus!;
      }
      // 실행 중이 아니면 _resolveCurrentCharacter()가 매핑된 첫 캐릭터로
      // 기본값을 잡는다 (여기서 raw 빌드로 기본값을 잡으면 매핑 안 된 빌드가
      // 걸려 "알 수 없음"으로 빠지는 문제가 있었다).
      _resolveCurrentCharacter();
    });
  }

  /// 이 기기(macros)의 캐릭터명으로 좁힌 캐릭터명:빌드 매핑을 가져온다.
  /// SoT는 cloudflare(scheduler/build_mapping) — config 화면의 빌드 매핑 다이얼로그와 동일한 값.
  Future<void> _fetchCharacterMapping() async {
    final macros = await _api.fetchMacros();
    final localNames = macros
        .map((m) => (m['name'] ?? '').toString().trim())
        .where((n) => n.isNotEmpty)
        .toSet();

    final remoteMapping = await Gateway.fetchBuildMapping() ?? {};

    final mapping = <String, String>{};
    for (final name in localNames) {
      final build = remoteMapping[name];
      if (build != null && build.isNotEmpty) mapping[name] = build;
    }

    if (!mounted) return;
    setState(() {
      _characterToBuild = mapping;
      _buildToCharacter = {for (final e in mapping.entries) e.value: e.key};
      _resolveCurrentCharacter();
    });
  }

  /// _currentMap(실제 빌드명) 기준으로 드롭다운에 표시할 캐릭터명을 다시 계산한다.
  /// 실행 중인 빌드가 로컬 매핑에 없어도(수동 실행 등) "알 수 없음"으로 비우지
  /// 않고, 매핑된 첫 캐릭터 → (매핑이 아예 없으면) 첫 빌드 순으로 항상 뭔가
  /// 표시되게 한다.
  void _resolveCurrentCharacter() {
    if (_currentMap.isNotEmpty && _buildToCharacter.containsKey(_currentMap)) {
      _currentCharacter = _buildToCharacter[_currentMap]!;
    } else if (_characterToBuild.isNotEmpty) {
      _currentCharacter = _characterToBuild.keys.first;
      _currentMap = _characterToBuild[_currentCharacter]!;
    } else if (_builds.isNotEmpty) {
      _currentCharacter = _builds.first;
      _currentMap = _builds.first;
    } else {
      _currentCharacter = '';
    }
  }

  /// cycle(statusChecker) 과 running_build(mainAction) 폴링 (1초마다, 진입 시 1회 포함)
  Future<void> _fetchCycleAndBuild() async {
    // cycle 은 statusChecker/status/get, running_build 는 mainAction/weeing/running_build
    final parsed = await _api.fetchStatus();
    final runningBuild = await _api.fetchRunningBuild();

    int? expCycle;
    if (parsed != null && parsed.containsKey('exp_cycle')) {
      final raw = (parsed['exp_cycle'] ?? '').trim();
      final n = int.tryParse(raw) ?? double.tryParse(raw)?.round();
      if (n != null) expCycle = n.clamp(0, 99).toInt();
    }

    if (!mounted) return;

    setState(() {
      if (expCycle != null) _cycle = expCycle;
      
      if (runningBuild != null) {
        _runningBuildFromStatus = runningBuild;
        if (_builds.contains(runningBuild)) {
          _currentMap = runningBuild;
        }
      } else {
        _runningBuildFromStatus = null;
      }
      _resolveCurrentCharacter();
    });

    if (!_initialStatusFetched) {
      if (expCycle != null) _cycleCtrl.jumpToItem(_cycle);
      _initialStatusFetched = true;
    }
  }

  /// 시간 동기화 (1분마다) - running thread가 없을 때만 현재 시간으로 업데이트
  void _syncTime() {
    // running thread가 없을 때만 현재 시간으로 업데이트
    if (_runningBuildFromStatus == null) {
      final now = DateTime.now();
      setState(() {
        _startHour = now.hour;
        _startMinute = now.minute;
      });
      
      // 휠 위치도 업데이트
      if (_hourCtrl.hasClients) _hourCtrl.jumpToItem(_startHour);
      if (_minCtrl.hasClients) _minCtrl.jumpToItem(_startMinute);
    }
  }

  Future<void> _handleStart() async {
    if (_currentMap.isEmpty) return;
    await _api.start(_currentMap, _startHour, _startMinute);
    _fetchCycleAndBuild();
  }

  Future<void> _handlePause() async {
    await _api.pause();
    _fetchCycleAndBuild();
  }

  Future<void> _handleSend() async {
    final msg = _commandController.text.trim();
    await _api.sendInputSequence(msg);
  }

  Future<void> _handleConvert() async {
    await _api.convertMode();
  }

  void _onHourChanged(int newVal) {
    if (newVal == _startHour) return;
    setState(() => _startHour = newVal);
  }

  void _onMinuteChanged(int newVal) {
    if (newVal == _startMinute) return;
    setState(() => _startMinute = newVal);
  }

  // =========================================================
  // 스트리밍 영역 터치 → 마우스 이동
  // =========================================================

  Offset _transformTouchToStreamCoord(
    double touchX,
    double touchY,
    double viewWidth,
    double viewHeight,
  ) {
    final centerX = viewWidth / 2;
    final centerY = viewHeight / 2;

    final streamX =
        (touchX - centerX - _streamOffset.dx) / _streamScale + centerX;
    final streamY =
        (touchY - centerY - _streamOffset.dy) / _streamScale + centerY;

    return Offset(streamX, streamY);
  }

  /// 스트림 좌표(뷰 기준) → 영상 원본 해상도의 절대 픽셀로 환산해 SoT 마우스 호출.
  /// gateway.py mouse_move / mouse_click 은 절대좌표(x,y)를 받으므로 클라이언트에서 변환한다.
  void _sendVideoMouse(
    Offset streamPt,
    double viewWidth,
    double viewHeight, {
    String? clickButton,
  }) {
    final sw = _renderer.value.width;
    final sh = _renderer.value.height;
    if (sw <= 0 || sh <= 0 || viewWidth <= 0 || viewHeight <= 0) return;

    final nx = (streamPt.dx / viewWidth).clamp(0.0, 1.0);
    final ny = (streamPt.dy / viewHeight).clamp(0.0, 1.0);
    final x = (nx * sw).round() + _captureOffsetX;
    final y = (ny * sh).round() + _captureOffsetY;

    if (clickButton != null) {
      _api.mouseClickAt(clickButton, x, y);
    } else {
      _api.mouseMove(x, y);
    }
  }

  Widget _buildTouchableStreamView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewWidth = constraints.maxWidth;
        final viewHeight = viewWidth * 9 / 16;
        
        // 스트림 뷰 사이즈 업데이트 (MouseMode에서 사용)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_streamViewSize.width != viewWidth || _streamViewSize.height != viewHeight) {
            setState(() {
              _streamViewSize = Size(viewWidth, viewHeight);
            });
          }
        });

        return GestureDetector(
          onTapDown: (details) {
            final transformed = _transformTouchToStreamCoord(
              details.localPosition.dx,
              details.localPosition.dy,
              viewWidth,
              viewHeight,
            );
            _sendVideoMouse(transformed, viewWidth, viewHeight);
          },
          onDoubleTap: () {},
          onLongPressStart: (details) {
            final transformed = _transformTouchToStreamCoord(
              details.localPosition.dx,
              details.localPosition.dy,
              viewWidth,
              viewHeight,
            );
            _sendVideoMouse(transformed, viewWidth, viewHeight,
                clickButton: 'right');
          },
          child: LobbyWebRTCView(
            renderer: _renderer,
            connected: _webrtcConnected,
            scale: _streamScale,
            offset: _streamOffset,
          ),
        );
      },
    );
  }

  // =========================================================
  // Info Sheet & Login Dialog
  // =========================================================

  void _showLoginDialog() async {
    final idController = TextEditingController();
    final pwController = TextEditingController();

    List<Map<String, dynamic>> macros = await _api.fetchMacros();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('로그인'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (macros.isNotEmpty) ...[
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '빠른 선택',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: macros.map((macro) {
                      return ActionChip(
                        label: Text(macro['name'] ?? 'Unknown'),
                        onPressed: () {
                          idController.text = macro['id'] ?? '';
                          pwController.text = macro['pw'] ?? '';
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                ],
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
                  _api.login(id, pw);
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
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: SingleChildScrollView(
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
                    leading: const Icon(Icons.logout),
                    title: const Text('로그아웃'),
                    subtitle: const Text('현재 계정에서 로그아웃'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _api.logout();
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
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
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
                  _trackpadMode
                      ? _buildTouchableStreamView()
                      : LobbyWebRTCView(
                          renderer: _renderer,
                          connected: _webrtcConnected,
                          scale: _streamScale,
                          offset: _streamOffset,
                        ),
                  const SizedBox(height: 16),
                  if (!_trackpadMode)
                    LobbyControls(
                      builds: _characterDropdownItems,
                      currentMap: _currentCharacter,
                      onMapChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _currentCharacter = v;
                          // 매핑이 있으면 캐릭터명 → 빌드명 resolve, 없으면
                          // 드롭다운 값 자체가 이미 raw 빌드명이다.
                          _currentMap = _characterToBuild[v] ?? v;
                        });
                      },
                      onStart: _handleStart,
                      onPause: _handlePause,
                      cycle: CycleControl(
                        value: _cycle,
                        controller: _cycleCtrl,
                        onChanged: (v) {
                          setState(() => _cycle = v);
                          _api.setCycle(v);
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
                    )
                  else
                    MouseMode(
                      ip: widget.ip,
                      initialScale: _streamScale,
                      initialOffset: _streamOffset,
                      streamViewSize: _streamViewSize,
                      onScaleChanged: (s) => setState(() => _streamScale = s),
                      onOffsetChanged: (o) => setState(() => _streamOffset = o),
                      commandController: _commandController,
                      onSend: _handleSend,
                      onConvertMode: _handleConvert,
                      needsAttention: widget.captchaNeedsAttention,
                    ),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _trackpadMode = !_trackpadMode;
                          _streamScale = 1.0;
                          _streamOffset = Offset.zero;
                        });
                        widget.onTrackpadModeChanged?.call(_trackpadMode);

                        if (!_trackpadMode) {
                          _initialStatusFetched = false;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (_cycleCtrl.hasClients) {
                              _cycleCtrl.jumpToItem(_cycle);
                            }
                            if (_hourCtrl.hasClients) {
                              _hourCtrl.jumpToItem(_startHour);
                            }
                            if (_minCtrl.hasClients) {
                              _minCtrl.jumpToItem(_startMinute);
                            }
                          });
                        }
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
}
