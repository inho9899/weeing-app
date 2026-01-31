import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'widgets/lobby_header.dart';
import 'widgets/lobby_webrtc_view.dart';
import 'widgets/lobby_controls.dart';
import 'widgets/cycle_control.dart';
import 'widgets/start_time_control.dart';
import 'widgets/mouse_mode.dart';
import 'services/lobby_api_service.dart';

class LobbyScreen extends StatefulWidget {
  final String basePath;
  const LobbyScreen({super.key, required this.basePath});

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

  final TextEditingController _commandController = TextEditingController();
  Timer? _pollTimer;      // cycle 폴링 (1초)
  Timer? _timeSyncTimer;  // 시간 동기화 (1분)
  bool _initialStatusFetched = false;

  double _streamScale = 1.0;
  Offset _streamOffset = Offset.zero;
  Size _streamViewSize = const Size(400, 225); // 16:9 기본값

  // ===== Wheel controllers =====
  late FixedExtentScrollController _cycleCtrl;
  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minCtrl;

  // ===== Trackpad mode =====
  bool _trackpadMode = false;

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
    _api = LobbyApiService(basePath: widget.basePath);

    _cycleCtrl = FixedExtentScrollController();
    _hourCtrl = FixedExtentScrollController(initialItem: _startHour);
    _minCtrl = FixedExtentScrollController(initialItem: _startMinute);

    _renderer.initialize().then((_) {
      _connectWebRTC();
    });

    WidgetsBinding.instance.addObserver(this);

    _fetchBuildList();
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

  String get _webrtcSignalingUrl =>
      'ws://${Uri.parse(widget.basePath).host}:8765/ws';

  void _connectWebRTC() async {
    _signalingSubscription?.cancel();
    _signalingChannel?.sink.close();

    try {
      _signalingChannel =
          WebSocketChannel.connect(Uri.parse(_webrtcSignalingUrl));
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
  }

  /// cycle과 running_build만 폴링 (1초마다)
  Future<void> _fetchCycleAndBuild() async {
    final parsed = await _api.fetchStatus();
    if (parsed == null) return;

    int? expCycle;
    String? runningBuild;

    if (parsed.containsKey('exp_cycle')) {
      final raw = (parsed['exp_cycle'] ?? '').trim();
      final n = int.tryParse(raw) ?? double.tryParse(raw)?.round();
      if (n != null) expCycle = n.clamp(0, 99).toInt();
    }
    if (parsed.containsKey('running_build')) {
      final rb = (parsed['running_build'] ?? '').trim();
      if (rb.isNotEmpty && rb != 'None') {
        runningBuild = rb;
      }
    }

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
            _api.sendMouseMoveTo(
                transformed.dx, transformed.dy, viewWidth, viewHeight);
          },
          onDoubleTap: () {},
          onLongPressStart: (details) {
            final transformed = _transformTouchToStreamCoord(
              details.localPosition.dx,
              details.localPosition.dy,
              viewWidth,
              viewHeight,
            );
            _api.sendMouseClickAt(
                transformed.dx, transformed.dy, viewWidth, viewHeight, 'right');
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
                    leading: const Icon(Icons.bolt_outlined),
                    title: const Text('부스터 적용'),
                    subtitle: const Text('부스터 아이템 사용'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _api.callSimplePost('weeing/booster');
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('로그아웃'),
                    subtitle: const Text('현재 계정에서 로그아웃'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _api.callSimplePost('weeing/logout');
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
                  ListTile(
                    leading: const Icon(Icons.exit_to_app),
                    title: const Text('종료'),
                    subtitle: const Text('Weeing 프로세스 종료'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _api.callSimplePost('weeing/exit');
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('마빌가기'),
                    subtitle: const Text('마빌로 이동'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _api.callSimplePost('weeing/gomyster');
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.login),
                    title: const Text('맵으로 돌아오기'),
                    subtitle: const Text('마빌에서 나가기'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _api.callSimplePost('weeing/exitmyster');
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
                      basePath: widget.basePath,
                      initialScale: _streamScale,
                      initialOffset: _streamOffset,
                      streamViewSize: _streamViewSize,
                      onScaleChanged: (s) => setState(() => _streamScale = s),
                      onOffsetChanged: (o) => setState(() => _streamOffset = o),
                      commandController: _commandController,
                      onSend: _handleSend,
                      onConvertMode: _handleConvert,
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
