import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class MouseMode extends StatefulWidget {
  final String basePath;
  final Function(double) onScaleChanged;
  final Function(Offset) onOffsetChanged;
  final double initialScale;
  final Offset initialOffset;
  // 스트리밍 영역 터치 콜백 (외부에서 사용할 경우)
  final Function(double touchX, double touchY, double viewWidth, double viewHeight)? onStreamTap;
  final TextEditingController commandController;
  final VoidCallback onSend;
  final VoidCallback onConvertMode;

  const MouseMode({
    super.key,
    required this.basePath,
    required this.onScaleChanged,
    required this.onOffsetChanged,
    this.initialScale = 1.0,
    this.initialOffset = Offset.zero,
    this.onStreamTap,
    required this.commandController,
    required this.onSend,
    required this.onConvertMode,
  });

  @override
  State<MouseMode> createState() => _MouseModeState();
}

class _MouseModeState extends State<MouseMode> {
  double _accumDx = 0;
  double _accumDy = 0;
  static const double _pointerScale = 4.0;

  double _baseScale = 1.0;
  Offset _baseOffset = Offset.zero;

  String get _mouseMoveUrl => '${widget.basePath}mouse/MouseMove';
  String get _mouseClickUrl => '${widget.basePath}mouse/MouseClick';
  String get _mouseMoveToUrl => '${widget.basePath}mouse/MouseMoveTo';
  String get _mouseClickAtUrl => '${widget.basePath}mouse/MouseClickAt';

  Future<void> _sendMouseMove(int dx, int dy) async {
    try {
      final url = '$_mouseMoveUrl/$dx/$dy';
      await http.post(Uri.parse(url));
    } catch (e) {
      debugPrint('MouseMode move error: $e');
    }
  }

  Future<void> _sendMouseClick(String button) async {
    try {
      final url = '$_mouseClickUrl/$button';
      await http.post(Uri.parse(url));
    } catch (e) {
      debugPrint('MouseMode click error: $e');
    }
  }

  /// 스트리밍 영역 터치 시 절대 좌표로 마우스 이동
  Future<void> _sendMouseMoveTo(double touchX, double touchY, double viewWidth, double viewHeight) async {
    try {
      final uri = Uri.parse(_mouseMoveToUrl).replace(queryParameters: {
        'touch_x': touchX.toString(),
        'touch_y': touchY.toString(),
        'view_width': viewWidth.toString(),
        'view_height': viewHeight.toString(),
      });
      await http.post(uri);
    } catch (e) {
      debugPrint('MouseMode moveTo error: $e');
    }
  }

  /// 스트리밍 영역 터치 시 해당 좌표로 이동 후 클릭
  Future<void> _sendMouseClickAt(double touchX, double touchY, double viewWidth, double viewHeight, String button) async {
    try {
      final uri = Uri.parse(_mouseClickAtUrl).replace(queryParameters: {
        'touch_x': touchX.toString(),
        'touch_y': touchY.toString(),
        'view_width': viewWidth.toString(),
        'view_height': viewHeight.toString(),
        'button': button,
      });
      await http.post(uri);
    } catch (e) {
      debugPrint('MouseMode clickAt error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _baseScale = widget.initialScale;
    _baseOffset = widget.initialOffset;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _sendMouseClick('left'),
              onDoubleTap: () async {
                // 더블클릭: 좌클릭 두 번
                await _sendMouseClick('left');
                await _sendMouseClick('left');
              },
              onLongPress: () => _sendMouseClick('right'),
              onScaleStart: (details) {
                _accumDx = 0;
                _accumDy = 0;
                _baseScale = widget.initialScale;
                _baseOffset = widget.initialOffset;
              },
              onScaleUpdate: (details) {
                if (details.pointerCount == 1) {
                  // Mouse Move
                  _accumDx += details.focalPointDelta.dx * _pointerScale;
                  _accumDy += details.focalPointDelta.dy * _pointerScale;

                  int dxInt = _accumDx.round();
                  int dyInt = _accumDy.round();

                  if (dxInt == 0 && dyInt == 0) return;

                  _accumDx -= dxInt;
                  _accumDy -= dyInt;

                  _sendMouseMove(dxInt, dyInt);
                } else if (details.pointerCount >= 2) {
                  // Zoom & Pan for Stream
                  final newScale = (_baseScale * details.scale).clamp(1.0, 5.0);
                  widget.onScaleChanged(newScale);

                  // Pan: Use the current offset from the widget and add the per-update delta
                  final newOffset = widget.initialOffset + details.focalPointDelta;
                  widget.onOffsetChanged(newOffset);
                }
              },
              child: const Center(
                child: Text(
                  'Trackpad mode\n(탭=좌클릭, 길게=우클릭, 더블탭=더블클릭)\n(두 손가락=화면 확대/이동)',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.black26,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
          // 하단 입력 창 및 버튼
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                TextField(
                  controller: widget.commandController,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.grey[100],
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
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _greyButton(
                        label: 'Send',
                        onTap: widget.onSend,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _greyButton(
                        label: '한/영 전환',
                        onTap: widget.onConvertMode,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _greyButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 40,
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
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
