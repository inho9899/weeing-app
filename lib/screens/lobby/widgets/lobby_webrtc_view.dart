import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class LobbyWebRTCView extends StatelessWidget {
  final RTCVideoRenderer renderer;
  final bool connected;

  /// 영상이 안 나올 때 오버레이에 보여줄 상태 ("연결 중", "재연결 중 (n)" 등).
  final String status;
  final double scale;
  final Offset offset;

  const LobbyWebRTCView({
    super.key,
    required this.renderer,
    required this.connected,
    this.status = '',
    required this.scale,
    required this.offset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
      ),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..translate(offset.dx, offset.dy)
                  ..scale(scale),
                child: RTCVideoView(
                  renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
              if (!connected)
                Container(
                  color: Colors.black.withOpacity(0.35),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        status.isEmpty ? 'WebRTC 연결 중...' : status,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
