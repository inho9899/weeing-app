import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:weeing_app/gateway/gateway.dart';
import 'widgets/lobby_header.dart';
import 'widgets/lobby_webrtc_view.dart';
import 'widgets/lobby_controls.dart';
import 'widgets/cycle_control.dart';
import 'widgets/start_time_control.dart';
import 'widgets/mouse_mode.dart';
import 'widgets/run_options_sheet.dart';
import 'services/lobby_api_service.dart';
import 'services/remote_input.dart';

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
  // 세션 = 시그널링 ws 하나 + 그 위에서 맺은 pc. 스트리머는 receiver 를 한 명만
  // 받고 새 receiver 가 join 하면 세션을 넘겨주므로, 이 화면도 세션을 동시에
  // 둘 이상 열면 안 된다. 세션을 열거나 버릴 때마다 _session 을 올리고, 비동기
  // 작업은 await 뒤에 자기 세대가 아직 현재인지 확인해 아니면 손을 뗀다.
  int _session = 0;
  RTCPeerConnection? _pc;
  RTCDataChannel? _inputChannel;
  MediaStream? _remoteStream; // onTrack 에 stream 이 없어 직접 만든 경우만
  late final RemoteInput _input = RemoteInput(ip: widget.ip);
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _webrtcConnected = false;
  bool _firstFrame = false;
  String _webrtcStatus = '연결 중';
  WebSocketChannel? _signalingChannel;
  StreamSubscription? _signalingSubscription;
  // 시그널링 메시지는 이 체인에 이어 붙여 하나씩 처리한다 — offer 를 처리하는
  // 도중에 peer_joined/candidate 처리가 끼어들지 않게.
  Future<void> _signalingQueue = Future.value();
  String? _senderPeerId;
  String? _remoteUfrag; // 지금 pc 에 적용한 offer 의 ice-ufrag
  bool _remoteDescriptionSet = false;
  bool _answerSent = false;
  // 지금 offer 에 대해 받은 스트리머 candidate 전부. offer 적용 전에 온 건
  // 적용 직후 한꺼번에 넣는다. pc 를 같은 offer 로 다시 만들 때도 다시 넣는다.
  final List<RTCIceCandidate> _remoteCandidates = [];
  // answer 보다 먼저 나간 candidate 는 스트리머(libdatachannel)가 버리므로
  // answer 를 보낼 때까지 모아둔다.
  final List<RTCIceCandidate> _pendingLocalCandidates = [];
  Timer? _reconnectTimer;
  Timer? _healthTimer;
  int _retryCount = 0;
  DateTime _lastSignalingAt = DateTime.now();
  DateTime? _connectingSince; // null = 스트리머 재접속 대기 중 (시한 없음)
  DateTime? _connectedAt;
  DateTime? _disconnectedAt;

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
  // _fetchCharacterMapping()이 최소 한 번 끝났는지. _fetchBuildList()가 먼저
  // 끝나버리면 매핑이 아직 비어있는 걸 "매핑 없음"으로 오판해 raw 빌드로
  // 기본값을 확정해버리는 문제가 있어서, 매핑 조회가 끝나기 전까진 raw 빌드
  // 폴백을 보류한다.
  bool _characterMappingLoaded = false;

  // 캐릭터명 : 끈 준비·정리 단계 키 목록. 이 폰에만 저장한다 (SharedPreferences 'run_skip').
  Map<String, List<String>> _skipByCharacter = {};

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
  /// 매핑이 모호해(같은 빌드를 공유하는 캐릭터가 둘 이상) _currentCharacter가
  /// raw 빌드명으로 폴백된 경우, 그 값도 목록에 없으면 DropdownButton이
  /// value-not-in-items로 assert 하므로 없으면 추가해준다.
  List<String> get _characterDropdownItems {
    final items = _characterToBuild.isNotEmpty
        ? _characterToBuild.keys.toList()
        : List<String>.from(_builds);
    if (_currentCharacter.isNotEmpty && !items.contains(_currentCharacter)) {
      items.add(_currentCharacter);
    }
    return items;
  }

  /// 실행 중도 아니고 선택도 안 됐을 때(currentMap 비어있음) 보여줄 안내 문구.
  /// 매핑 조회가 아직 안 끝났으면 성급히 "등록해주세요"를 띄우지 않고 비워둔다.
  String? get _lobbyHint {
    if (_currentMap.isNotEmpty) return null;
    if (!_characterMappingLoaded) return null;
    return _characterToBuild.isNotEmpty ? '빌드를 선택해주세요' : '빌드를 등록해주세요';
  }

  /// 실제 매핑과 맞는 캐릭터명. _currentCharacter 는 역매핑이 모호하면 빌드명이 들어가는
  /// 표시용 라벨이라, 그때는 '' — Start 에 캐릭터를 보내지 않고 단계 설정도 열지 않는다.
  String get _selectedCharacter =>
      _characterToBuild[_currentCharacter] == _currentMap ? _currentCharacter : '';

  List<String> get _currentSkip => _skipByCharacter[_selectedCharacter] ?? const [];

  Future<void> _loadRunSkips() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('run_skip');
    if (raw == null || !mounted) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      setState(() {
        _skipByCharacter = {
          for (final e in decoded.entries) e.key: List<String>.from(e.value as List),
        };
      });
    } catch (_) {
      // 깨진 값이면 모두 켠 상태로 시작한다
    }
  }

  Future<void> _openRunOptions() {
    final character = _selectedCharacter;
    return showRunOptionsSheet(
      context,
      character: character,
      skip: _currentSkip,
      onChanged: (skip) async {
        setState(() => _skipByCharacter[character] = skip);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('run_skip', jsonEncode(_skipByCharacter));
      },
    );
  }

  /// 드롭다운 표시 텍스트: "캐릭터명 - 빌드명". 캐릭터로 매핑 안 된 값(raw
  /// 빌드명 자체가 값인 경우)은 라벨을 따로 두지 않아 값 그대로 보여준다.
  Map<String, String> get _characterDropdownLabels => {
        for (final e in _characterToBuild.entries) e.key: '${e.key} - ${e.value}',
      };

  @override
  void initState() {
    super.initState();
    _api = LobbyApiService(ip: widget.ip);

    _cycleCtrl = FixedExtentScrollController();
    _hourCtrl = FixedExtentScrollController(initialItem: _startHour);
    _minCtrl = FixedExtentScrollController(initialItem: _startMinute);

    _renderer.onFirstFrameRendered = _onFirstFrame;
    // 첫 프레임 이벤트를 못 받는 경우 대비 — 영상 크기가 잡혔으면 프레임이 온 것.
    _renderer.onResize = () {
      if (_renderer.value.width > 0) _onFirstFrame();
    };
    _renderer.initialize().then((_) {
      if (mounted) _connectWebRTC();
    });

    WidgetsBinding.instance.addObserver(this);

    // 부모(PcTabsScreen)에 초기 트랙패드 모드 상태를 알려 탭바 표시 여부를 맞춘다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onTrackpadModeChanged?.call(_trackpadMode);
    });

    _fetchBuildList();
    _fetchCharacterMapping();
    _loadRunSkips();
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
    // 백그라운드(paused)로 갈 때는 아무것도 하지 않는다 — 그동안 끊겼으면
    // 점검기/ws onDone 이 잡거나 여기 resumed 에서 복구한다.
    if (state == AppLifecycleState.resumed) {
      _resumeWebRTC();
      _syncTime();  // 화면 켤 때 시간 동기화
    }
  }

  /// 앱 복귀 시 WebRTC 복구. 잘 나오고 있는 스트림은 건드리지 않는다.
  ///
  /// 예전엔 복귀할 때마다 무조건 끊고 100ms 뒤 다시 붙었는데, 그 접속이 다른
  /// 경로(백그라운드 동안 밀려 있다 복귀 직후 터지는 재시도 타이머, 렌더러
  /// 초기화 완료)의 접속과 겹쳐 receiver join 이 수백 ms 간격으로 두 번 나갔고,
  /// 스트리머는 그 연속 인계에서 멈췄다.
  void _resumeWebRTC() {
    if (_session == 0) return; // 첫 접속은 initState(렌더러 초기화 뒤)가 한다
    if (_webrtcConnected && _firstFrame) return;
    if (_reconnectTimer?.isActive ?? false) {
      // 백오프 대기 중이면 기다리지 말고 지금 붙는다 (세션은 이미 닫혀 있다).
      debugPrint('WebRTC: resumed while waiting to reconnect, connecting now');
      _connectWebRTC();
      return;
    }
    if (_signalingChannel == null) {
      _connectWebRTC();
      return;
    }
    // 진행 중인 세션은 점검기에 맡긴다. 백그라운드 동안 시한이 지났으면 바로 걸린다.
    _checkWebRTCHealth(_session);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session++;
    _reconnectTimer?.cancel();
    unawaited(_closeSession());
    _input.dispose();
    _renderer.dispose();

    _pollTimer?.cancel();
    _timeSyncTimer?.cancel();
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

  bool _isCurrentPc(int gen, RTCPeerConnection pc) =>
      gen == _session && identical(pc, _pc) && mounted;

  void _setWebRTCStatus(String status) {
    if (!mounted) return;
    setState(() => _webrtcStatus = status);
  }

  /// 시그널링 접속 + join. WebRTC 세션을 여는 곳은 여기 하나뿐이다 (initState,
  /// 재접속 타이머, 앱 복귀). 이전 세션(ws + pc + 데이터 채널)을 다 닫고 연다.
  Future<void> _connectWebRTC() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final gen = ++_session;
    await _closeSession();
    // 닫는 사이 다른 곳에서 또 불렸으면 나중 호출만 연다.
    if (gen != _session || !mounted) return;

    final now = DateTime.now();
    _lastSignalingAt = now;
    _connectingSince = now;
    _setWebRTCStatus(_retryCount == 0 ? '연결 중' : '재연결 중 ($_retryCount)');

    try {
      final channel = WebSocketChannel.connect(_webrtcSignalingUri);
      _signalingChannel = channel;
      _signalingSubscription = channel.stream.listen(
        (message) => _enqueueSignaling(gen, message),
        onDone: () => _scheduleReconnect(gen, '시그널링 연결 끊김'),
        onError: (e) {
          debugPrint('WebRTC: [$gen] signaling error: $e');
          _scheduleReconnect(gen, '시그널링 오류');
        },
      );

      final peerId = 'receiver_${DateTime.now().millisecondsSinceEpoch}';
      channel.sink.add(jsonEncode({
        'type': 'join',
        'role': 'receiver',
        'roomId': 'default',
        'peerId': peerId,
      }));
      debugPrint('WebRTC: [$gen] Join message sent ($peerId)');
    } catch (e) {
      debugPrint('WebRTC: [$gen] signaling connect failed: $e');
      _scheduleReconnect(gen, '시그널링 접속 실패');
      return;
    }

    _healthTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkWebRTCHealth(gen),
    );
  }

  /// 지금 세션(ws + pc)을 닫는다. 필드는 동기적으로 먼저 비우므로 겹쳐 불려도
  /// 같은 걸 두 번 닫지 않는다.
  Future<void> _closeSession() async {
    _healthTimer?.cancel();
    _healthTimer = null;
    final subscription = _signalingSubscription;
    final channel = _signalingChannel;
    _signalingSubscription = null;
    _signalingChannel = null;
    _signalingQueue = Future.value();
    _senderPeerId = null;
    _connectingSince = null;

    unawaited(subscription?.cancel());
    if (channel != null) {
      try {
        // 프록시를 거치면 close 가 서버에 늦게 닿을 수 있어 leave 를 먼저 보낸다.
        channel.sink.add(jsonEncode({'type': 'leave'}));
      } catch (e) {
        debugPrint('WebRTC: leave send failed: $e');
      }
      unawaited(channel.sink.close().catchError((e) {
        debugPrint('WebRTC: signaling close failed: $e');
      }));
    }
    await _closePeer();
  }

  /// pc 와 거기 딸린 것(데이터 채널, 영상, candidate 큐)만 닫는다. ws 는 그대로.
  Future<void> _closePeer() async {
    final pc = _pc;
    final inputChannel = _inputChannel;
    final stream = _remoteStream;
    _pc = null;
    _inputChannel = null;
    _remoteStream = null;
    _remoteUfrag = null;
    _remoteDescriptionSet = false;
    _answerSent = false;
    _remoteCandidates.clear();
    _pendingLocalCandidates.clear();
    _webrtcConnected = false;
    _firstFrame = false;
    _connectedAt = null;
    _disconnectedAt = null;

    _input.detachChannel();
    if (_renderer.srcObject != null) _renderer.srcObject = null;

    try {
      await inputChannel?.close();
    } catch (e) {
      debugPrint('WebRTC: data channel close failed: $e');
    }
    try {
      await stream?.dispose();
    } catch (e) {
      debugPrint('WebRTC: stream dispose failed: $e');
    }
    try {
      await pc?.close();
      await pc?.dispose();
    } catch (e) {
      debugPrint('WebRTC: pc close failed: $e');
    }
  }

  /// 세션을 버리고 백오프(1,2,4,8,10초…) 뒤에 다시 연다. 같은 세션에서 여러 번
  /// 불려도(onError+onDone, 점검기, pc failed) 첫 번째만 유효하다.
  void _scheduleReconnect(int gen, String reason) {
    if (gen != _session || !mounted) return;
    _session++; // 이 세션의 남은 콜백은 전부 무시된다
    unawaited(_closeSession());

    final delay = _retryCount < 4 ? 1 << _retryCount : 10;
    _retryCount++;
    debugPrint('WebRTC: [$gen] $reason -> reconnect #$_retryCount in ${delay}s');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (mounted) _connectWebRTC();
    });
    _setWebRTCStatus('재연결 중 ($_retryCount)\n$reason');
  }

  /// 세션 점검 (1초마다). 시한을 넘긴 단계가 있으면 끊고 다시 붙는다.
  void _checkWebRTCHealth(int gen) {
    if (gen != _session || !mounted) return;
    final now = DateTime.now();
    bool over(DateTime? since, int seconds) =>
        since != null && now.difference(since).inSeconds >= seconds;

    String? reason;
    if (over(_disconnectedAt, 5)) {
      reason = '연결 끊김';
    } else if (_webrtcConnected && !_firstFrame && over(_connectedAt, 8)) {
      reason = '영상 수신 없음';
    } else if (!_webrtcConnected &&
        _disconnectedAt == null &&
        over(_connectingSince, 15)) {
      reason = '연결 시간 초과';
    } else if (!(_webrtcConnected && _firstFrame) &&
        over(_lastSignalingAt, 65)) {
      // 서버가 20초마다 ping 을 보내므로 이만큼 조용하면 ws 가 죽은 것이다.
      // 영상이 잘 나오는 동안엔 보지 않는다 (ping 이 안 와도 스트림은 멀쩡할 수 있다).
      reason = '시그널링 응답 없음';
    }
    if (reason != null) _scheduleReconnect(gen, reason);
  }

  void _onFirstFrame() {
    if (!mounted || _pc == null || _firstFrame || _renderer.srcObject == null) {
      return;
    }
    debugPrint('WebRTC: first frame rendered');
    _retryCount = 0; // 영상까지 나왔으면 성공 — 백오프 초기화
    setState(() {
      _firstFrame = true;
      _webrtcStatus = '';
    });
  }

  /// 메시지를 도착 순서대로 하나씩 처리하도록 큐에 넣는다.
  void _enqueueSignaling(int gen, dynamic message) {
    if (gen != _session) return;
    _lastSignalingAt = DateTime.now();
    _signalingQueue =
        _signalingQueue.then((_) => _onSignalingMessage(gen, message));
  }

  /// 예외를 밖으로 내보내지 않는다 — 큐 체인이 끊기면 뒤 메시지가 다 묻힌다.
  Future<void> _onSignalingMessage(int gen, dynamic message) async {
    if (gen != _session) return;
    try {
      final data = jsonDecode(message as String);
      final type = data['type'];

      if (type == 'ping' || type == 'pong') {
        // 서버 keepalive — _lastSignalingAt 갱신만으로 충분하다.
      } else if (type == 'joined') {
        debugPrint('WebRTC: [$gen] joined as ${data['peerId']}');
      } else if (type == 'peer_joined') {
        // 다른 receiver(다른 폰) 입장은 관심 없다 — 스트리머만 본다.
        if (data['role'] != 'sender') return;
        final peerId = data['peerId'] as String?;
        debugPrint('WebRTC: [$gen] Sender joined: $peerId');
        // 스트리머가 offerer 라 여기선 pc 를 만들지 않고 offer 를 기다린다.
        // (offer 가 이 알림보다 먼저 올 수도 있다 — 같은 스트리머면 그대로 둔다.)
        if (_senderPeerId != null && _senderPeerId != peerId) {
          await _closePeer();
          if (gen != _session) return;
        }
        _senderPeerId = peerId;
        if (_pc == null) _connectingSince = DateTime.now();
      } else if (type == 'offer') {
        await _handleOffer(gen, data['fromPeerId'] as String, data['sdp'] as String);
      } else if (type == 'candidate') {
        final from = data['fromPeerId'];
        if (from != _senderPeerId) {
          debugPrint('WebRTC: [$gen] ignoring candidate from $from (sender: $_senderPeerId)');
          return;
        }
        final c = data['candidate'];
        final candidate = RTCIceCandidate(
          c['candidate'],
          c['sdpMid'],
          c['sdpMLineIndex'],
        );
        _remoteCandidates.add(candidate);
        final pc = _pc;
        // offer 적용 전이면 쌓아두고 적용 직후 넣는다 (_applyOffer).
        if (pc != null && _remoteDescriptionSet) {
          await _addRemoteCandidate(pc, candidate);
        }
      } else if (type == 'peer_left') {
        if (data['peerId'] != _senderPeerId) return;
        // 스트리머가 나갔다 — pc 만 버리고, 돌아와서 새 offer 를 줄 때까지
        // 재접속을 두드리지 않고 기다린다. 다만 스트리머가 죽은 채면 서버는
        // receiver 가 새로 join 할 때만 다시 띄우므로, 15초 안에 안 돌아오면
        // 점검기의 연결 시간 초과로 다시 join 한다.
        debugPrint('WebRTC: [$gen] Sender left, waiting for it to rejoin');
        _senderPeerId = null;
        await _closePeer();
        if (gen != _session) return;
        _connectingSince = DateTime.now();
        _setWebRTCStatus('스트리머 재접속 대기 중');
      }
    } catch (e) {
      if (gen != _session) return;
      debugPrint('WebRTC: [$gen] signaling message failed: $e');
      _scheduleReconnect(gen, '협상 실패');
    }
  }

  /// 스트리머 offer 처리.
  ///
  /// 스트리머는 5초 안에 answer 를 못 받으면 같은 offer 를 (ICE ufrag 그대로)
  /// 다시 보내고 candidate 는 다시 보내지 않는다. 그래서 같은 ufrag 의 offer 는
  /// 지금 pc 에 다시 적용(재협상)하고, ufrag 나 보낸 쪽이 다르면 스트리머가 pc 를
  /// 새로 만든 것이므로 우리도 새 pc 로 받는다.
  Future<void> _handleOffer(int gen, String from, String sdp) async {
    final ufrag = RegExp(r'a=ice-ufrag:(\S+)').firstMatch(sdp)?.group(1);
    if (_pc != null && (from != _senderPeerId || ufrag != _remoteUfrag)) {
      debugPrint('WebRTC: [$gen] new offer session, recreating pc');
      await _closePeer();
      if (gen != _session) return;
    }
    _senderPeerId = from;
    _remoteUfrag = ufrag;

    final existing = _pc;
    if (existing != null) {
      debugPrint('WebRTC: [$gen] Re-offer from $from, applying to existing pc');
      try {
        await _applyOffer(gen, existing, sdp);
        return;
      } catch (e) {
        if (gen != _session) return;
        // 지금 pc 상태에선 못 받는다 — 새 pc 로 처음부터 받되, 이 offer 로
        // 받아둔 candidate 는 스트리머가 다시 안 보내므로 옮겨 담는다.
        debugPrint('WebRTC: [$gen] re-offer failed ($e), recreating pc');
        final candidates = List.of(_remoteCandidates);
        await _closePeer();
        if (gen != _session) return;
        _senderPeerId = from;
        _remoteUfrag = ufrag;
        _remoteCandidates.addAll(candidates);
      }
    }

    debugPrint('WebRTC: [$gen] Received offer from $from');
    final pc = await _createPeerConnection(gen);
    if (pc == null) return;
    _connectingSince = DateTime.now();
    await _applyOffer(gen, pc, sdp);
  }

  /// offer 적용 → answer 전송. 처음 적용이면 쌓아둔 candidate 를 넣고,
  /// answer 를 보낸 뒤에야 모아둔 내 candidate 를 보낸다.
  Future<void> _applyOffer(int gen, RTCPeerConnection pc, String sdp) async {
    final firstApply = !_remoteDescriptionSet;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    if (!_isCurrentPc(gen, pc)) return;
    _remoteDescriptionSet = true;
    if (firstApply) {
      for (final candidate in List.of(_remoteCandidates)) {
        await _addRemoteCandidate(pc, candidate);
        if (!_isCurrentPc(gen, pc)) return;
      }
    }

    final answer = await pc.createAnswer();
    if (!_isCurrentPc(gen, pc)) return;
    await pc.setLocalDescription(answer);
    if (!_isCurrentPc(gen, pc)) return;

    _signalingChannel?.sink.add(jsonEncode({
      'type': 'answer',
      'toPeerId': _senderPeerId,
      'sdp': answer.sdp,
    }));
    debugPrint('WebRTC: [$gen] Answer sent');

    if (!_answerSent) {
      _answerSent = true;
      for (final candidate in _pendingLocalCandidates) {
        _sendLocalCandidate(candidate);
      }
      _pendingLocalCandidates.clear();
    }
  }

  Future<void> _addRemoteCandidate(
      RTCPeerConnection pc, RTCIceCandidate candidate) async {
    try {
      await pc.addCandidate(candidate);
    } catch (e) {
      debugPrint('WebRTC: addCandidate failed (${candidate.candidate}): $e');
    }
  }

  void _sendLocalCandidate(RTCIceCandidate candidate) {
    try {
      _signalingChannel?.sink.add(jsonEncode({
        'type': 'candidate',
        'toPeerId': _senderPeerId,
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      }));
    } catch (e) {
      debugPrint('WebRTC: candidate send failed: $e');
    }
  }

  /// pc 를 만든다. 만드는 사이 세션이 바뀌었으면 만든 걸 닫고 null.
  Future<RTCPeerConnection?> _createPeerConnection(int gen) async {
    final pc = await createPeerConnection({
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

    if (gen != _session || _pc != null || !mounted) {
      debugPrint('WebRTC: [$gen] session changed while creating pc, closing it');
      try {
        await pc.close();
        await pc.dispose();
      } catch (e) {
        debugPrint('WebRTC: stale pc close failed: $e');
      }
      return null;
    }
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      if (!identical(pc, _pc) || candidate.candidate == null) return;
      if (!_answerSent) {
        _pendingLocalCandidates.add(candidate);
        return;
      }
      _sendLocalCandidate(candidate);
    };

    pc.onConnectionState = (state) {
      if (!identical(pc, _pc) || !mounted) return;
      debugPrint('WebRTC: Connection state changed: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectedAt ??= DateTime.now();
        _disconnectedAt = null;
        setState(() {
          _webrtcConnected = true;
          if (!_firstFrame) _webrtcStatus = '영상 대기 중';
        });
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // 잠깐 끊겼다 스스로 돌아오기도 하므로 5초는 기다린다 (_checkWebRTCHealth).
        _disconnectedAt ??= DateTime.now();
        setState(() {
          _webrtcConnected = false;
          _webrtcStatus = '연결 불안정 - 복구 대기';
        });
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _scheduleReconnect(gen, '연결 실패');
      }
    };

    pc.onTrack = (event) => _onTrack(gen, pc, event);

    pc.onDataChannel = (channel) {
      if (!identical(pc, _pc)) return;
      // 스트리머가 여는 "input" 채널. 여기로 입력을 보내면 Cloudflare 터널을
      // 지나지 않고 이미 열린 P2P 연결로 곧장 간다.
      _inputChannel = channel;
      if (channel.label == 'input') {
        _input.attachChannel(channel);
      }
    };
    return pc;
  }

  Future<void> _onTrack(
      int gen, RTCPeerConnection pc, RTCTrackEvent event) async {
    debugPrint(
        'WebRTC: onTrack kind=${event.track.kind} streams=${event.streams.length}');
    if (event.track.kind != 'video' || !_isCurrentPc(gen, pc)) return;

    MediaStream? stream = event.streams.isNotEmpty ? event.streams[0] : null;
    if (stream == null) {
      // 스트리머 SDP 에 msid 가 없어 streams 가 비어 온다 — 트랙으로 스트림을 직접 만든다.
      // (트랙을 먼저 넣고 렌더러에 붙여야 한다. 붙인 뒤 넣으면 렌더러가 모른다.)
      try {
        final created = await createLocalMediaStream('local');
        await created.addTrack(event.track);
        if (!_isCurrentPc(gen, pc)) {
          await created.dispose();
          return;
        }
        _remoteStream = created;
        stream = created;
      } catch (e) {
        debugPrint('WebRTC: building stream from track failed: $e');
        if (!_isCurrentPc(gen, pc)) return;
        for (final s in pc.getRemoteStreams()) {
          if (s != null && s.getVideoTracks().isNotEmpty) stream = s;
        }
      }
    }
    if (stream == null) {
      debugPrint('WebRTC: no stream to render for video track');
      return;
    }
    setState(() => _renderer.srcObject = stream);
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

    // 빌드→캐릭터 역매핑. 같은 PC의 두 캐릭터가 같은 빌드를 공유하면 빌드명만으로는
    // 어느 쪽이 실행 중인지 알 수 없으므로, 그 빌드는 역매핑에서 아예 제외한다
    // (하나를 임의로 골라 잘못 표시하는 것보다 "모름"으로 두는 게 안전).
    final buildUseCount = <String, int>{};
    for (final build in mapping.values) {
      buildUseCount[build] = (buildUseCount[build] ?? 0) + 1;
    }
    final reverse = <String, String>{
      for (final e in mapping.entries)
        if (buildUseCount[e.value] == 1) e.value: e.key,
    };

    if (!mounted) return;
    setState(() {
      _characterToBuild = mapping;
      _buildToCharacter = reverse;
      _characterMappingLoaded = true;
      _resolveCurrentCharacter();
    });
  }

  /// _currentMap(실제 빌드명, start()에 그대로 쓰이는 값)에서 드롭다운에 표시할
  /// 라벨만 계산한다. 실제 값(_currentMap)은 여기서 절대 바꾸지 않는다 —
  /// 표시용 캐릭터명을 못 찾았다고 다른 빌드로 덮어써버리면 "실행 중" 표시와
  /// 실제 실행 중인 빌드가 어긋나 Start를 눌렀을 때 엉뚱한 빌드가 재시작될 수 있다.
  ///
  /// 자동으로 첫 캐릭터/첫 빌드를 기본 선택하지 않는다 — 실행 중인 빌드가
  /// 없으면 currentMap을 비워두고, _lobbyHint가 "선택해주세요"/"등록해주세요"
  /// 안내를 보여준다 (사용자가 직접 고르기 전엔 아무 것도 확정하지 않음).
  void _resolveCurrentCharacter() {
    if (_currentMap.isEmpty) {
      _currentCharacter = '';
      return;
    }

    // 매핑에 없거나(수동 실행) 같은 빌드를 공유하는 캐릭터가 둘 이상이라 모호하면
    // 캐릭터명 대신 실제 빌드명을 그대로 라벨로 보여준다.
    _currentCharacter = _buildToCharacter[_currentMap] ?? _currentMap;
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
    await _api.start(_currentMap, _startHour, _startMinute,
        character: _selectedCharacter, skip: _currentSkip);
    _fetchCycleAndBuild();
  }

  Future<void> _handlePause() async {
    await _api.pause();
    _fetchCycleAndBuild();
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
      unawaited(_input.click(clickButton, x: x, y: y));
    } else {
      unawaited(_input.moveTo(x, y));
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
            connected: _webrtcConnected && _firstFrame,
            status: _webrtcStatus,
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

  Widget _buildToggleButton() {
    return Align(
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
    );
  }

  /// 기본(대기) 화면 — 콘텐츠가 화면보다 길어질 수 있으니 스크롤 가능하게 둔다.
  Widget _buildNormalLayout() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LobbyHeader(hostText: _hostText, onInfoTap: _openInfoSheet),
          const SizedBox(height: 8),
          LobbyWebRTCView(
            renderer: _renderer,
            connected: _webrtcConnected && _firstFrame,
            status: _webrtcStatus,
            scale: _streamScale,
            offset: _streamOffset,
          ),
          const SizedBox(height: 16),
          LobbyControls(
            builds: _characterDropdownItems,
            currentMap: _currentCharacter,
            itemLabels: _characterDropdownLabels,
            hint: _lobbyHint,
            onMapChanged: (v) {
              if (v == null) return;
              setState(() {
                _currentCharacter = v;
                // 매핑이 있으면 캐릭터명 → 빌드명 resolve, 없으면
                // 드롭다운 값 자체가 이미 raw 빌드명이다.
                _currentMap = _characterToBuild[v] ?? v;
              });
            },
            onOptionsTap: _selectedCharacter.isEmpty ? null : _openRunOptions,
            optionsSummary: _currentSkip.isEmpty
                ? null
                : '꺼짐: ${runStepLabels(_currentSkip).join(', ')}',
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
          ),
          const SizedBox(height: 24),
          _buildToggleButton(),
        ],
      ),
    );
  }

  /// 트랙패드 모드 화면 — 화면 전체가 드래그로 마우스를 움직이는 영역이라
  /// 페이지 자체를 스크롤시키면 제스처가 충돌한다. 그래서 스크롤뷰를 쓰지
  /// 않고, 트랙패드 영역(Expanded)이 남은 세로 공간에 딱 맞게 채우도록 해
  /// 화면 크기와 무관하게 항상 한 화면 안에 들어오게 한다.
  Widget _buildTrackpadLayout() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LobbyHeader(hostText: _hostText, onInfoTap: _openInfoSheet),
          const SizedBox(height: 8),
          _buildTouchableStreamView(),
          const SizedBox(height: 16),
          Expanded(
            child: MouseMode(
              ip: widget.ip,
              input: _input,
              initialScale: _streamScale,
              initialOffset: _streamOffset,
              streamViewSize: _streamViewSize,
              onScaleChanged: (s) => setState(() => _streamScale = s),
              onOffsetChanged: (o) => setState(() => _streamOffset = o),
              needsAttention: widget.captchaNeedsAttention,
            ),
          ),
          const SizedBox(height: 24),
          _buildToggleButton(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const bgColor = Color(0xFFF3F3F5);

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _trackpadMode ? _buildTrackpadLayout() : _buildNormalLayout(),
          ),
        ),
      ),
    );
  }
}
