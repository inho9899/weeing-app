import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebRTC 연결 상태
enum WebRTCState {
  disconnected,
  connecting,
  connected,
}

/// WebRTC 시그널링 및 연결 관리 서비스
class WebRTCService {
  final String basePath;
  final RTCVideoRenderer renderer;
  final Function(WebRTCState) onStateChanged;

  RTCPeerConnection? _pc;
  RTCDataChannel? _inputChannel;
  WebSocketChannel? _signalingChannel;
  StreamSubscription? _signalingSubscription;
  Timer? _retryTimer;
  String? _senderPeerId;
  bool _disposed = false;

  WebRTCService({
    required this.basePath,
    required this.renderer,
    required this.onStateChanged,
  });

  String get _signalingUrl {
    final host = Uri.parse(basePath).host;
    return 'ws://$host:8765/ws';
  }

  Future<void> initialize() async {
    await renderer.initialize();
    connect();
  }

  void connect() {
    if (_disposed) return;

    _signalingSubscription?.cancel();
    _signalingChannel?.sink.close();

    try {
      _signalingChannel = WebSocketChannel.connect(Uri.parse(_signalingUrl));
      _signalingSubscription = _signalingChannel!.stream.listen(
        _onSignalingMessage,
        onDone: _scheduleRetry,
        onError: (_) => _scheduleRetry(),
      );

      _signalingChannel!.sink.add(jsonEncode({
        'type': 'join',
        'role': 'receiver',
        'roomId': 'default',
        'peerId': 'receiver_${DateTime.now().millisecondsSinceEpoch}',
      }));
      debugPrint('WebRTC: Join message sent');
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_disposed) return;
    onStateChanged(WebRTCState.disconnected);
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), connect);
  }

  Future<void> _onSignalingMessage(dynamic message) async {
    if (_disposed) return;

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
        await _pc!.setRemoteDescription(
            RTCSessionDescription(data['sdp'], 'offer'));
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
          onStateChanged(WebRTCState.disconnected);
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
        onStateChanged(WebRTCState.connected);
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onStateChanged(WebRTCState.disconnected);
      }
    };

    _pc!.onTrack = (event) {
      debugPrint(
          'WebRTC: onTrack kind=${event.track.kind} streams=${event.streams.length}');
      if (event.track.kind == 'video') {
        renderer.srcObject =
            event.streams.isNotEmpty ? event.streams[0] : null;
      }
    };

    _pc!.onDataChannel = (channel) {
      _inputChannel = channel;
    };
  }

  Future<void> reconnect() async {
    debugPrint('WebRTC: Reconnecting...');

    _retryTimer?.cancel();
    _retryTimer = null;

    _signalingSubscription?.cancel();
    _signalingSubscription = null;

    _signalingChannel?.sink.close();
    _signalingChannel = null;

    _inputChannel?.close();
    _inputChannel = null;

    await _pc?.close();
    _pc = null;

    _senderPeerId = null;

    onStateChanged(WebRTCState.disconnected);
    renderer.srcObject = null;

    Future.delayed(const Duration(milliseconds: 100), () {
      if (!_disposed) connect();
    });
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _signalingSubscription?.cancel();
    _signalingChannel?.sink.close();
    _inputChannel?.close();
    _pc?.close();
    renderer.dispose();
  }
}
