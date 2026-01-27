import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// 마우스 트랙패드 모드 위젯
/// Google Chrome Remote Desktop 스타일:
/// - 핀치 줌: 핀치 중심점 기준 확대/축소
/// - 팬: 확대 상태에서 화면 이동 (경계 제한)
/// - 더블탭: 확대/축소 토글
class MouseMode extends StatefulWidget {
  final String basePath;
  final Function(double) onScaleChanged;
  final Function(Offset) onOffsetChanged;
  final double initialScale;
  final Offset initialOffset;
  final TextEditingController commandController;
  final VoidCallback onSend;
  final VoidCallback onConvertMode;
  
  /// 스트림 뷰 사이즈 (경계 계산용)
  final Size? streamViewSize;

  const MouseMode({
    super.key,
    required this.basePath,
    required this.onScaleChanged,
    required this.onOffsetChanged,
    this.initialScale = 1.0,
    this.initialOffset = Offset.zero,
    required this.commandController,
    required this.onSend,
    required this.onConvertMode,
    this.streamViewSize,
  });

  @override
  State<MouseMode> createState() => _MouseModeState();
}

class _MouseModeState extends State<MouseMode> {
  // 마우스 이동용 누적값
  double _accumDx = 0;
  double _accumDy = 0;
  static const double _pointerScale = 4.0;

  // 확대/이동 상태
  double _currentScale = 1.0;
  Offset _currentOffset = Offset.zero;

  // 제스처 시작 시 저장
  double _startScale = 1.0;
  Offset _startOffset = Offset.zero;
  Offset _startFocalPoint = Offset.zero;

  // 핀치 줌 중인지 여부
  bool _isPinching = false;

  String get _mouseMoveUrl => '${widget.basePath}mouse/MouseMove';
  String get _mouseClickUrl => '${widget.basePath}mouse/MouseClick';

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

  @override
  void initState() {
    super.initState();
    _currentScale = widget.initialScale;
    _currentOffset = widget.initialOffset;
  }

  @override
  void didUpdateWidget(MouseMode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 외부에서 scale/offset이 변경된 경우 동기화
    if (oldWidget.initialScale != widget.initialScale) {
      _currentScale = widget.initialScale;
    }
    if (oldWidget.initialOffset != widget.initialOffset) {
      _currentOffset = widget.initialOffset;
    }
  }

  /// 오프셋 경계 제한 (화면이 스트림 밖으로 나가지 않도록)
  Offset _clampOffset(Offset offset, double scale) {
    if (scale <= 1.0) return Offset.zero;
    
    // 스트림 뷰 사이즈 (없으면 기본값 사용)
    final viewSize = widget.streamViewSize ?? const Size(400, 225);
    
    // 확대된 상태에서 이동 가능한 최대 범위 계산
    final maxOffsetX = (viewSize.width * (scale - 1)) / 2;
    final maxOffsetY = (viewSize.height * (scale - 1)) / 2;
    
    return Offset(
      offset.dx.clamp(-maxOffsetX, maxOffsetX),
      offset.dy.clamp(-maxOffsetY, maxOffsetY),
    );
  }

  /// 핀치 줌 처리 (focal point 기준)
  void _handlePinchZoom(ScaleUpdateDetails details) {
    // 새 스케일 계산
    final newScale = (_startScale * details.scale).clamp(1.0, 5.0);
    
    if (newScale == _currentScale) {
      // 스케일 변화 없으면 팬만 처리
      final panDelta = details.focalPoint - _startFocalPoint;
      final newOffset = _clampOffset(_startOffset + panDelta, newScale);
      
      if (newOffset != _currentOffset) {
        _currentOffset = newOffset;
        widget.onOffsetChanged(_currentOffset);
      }
      return;
    }
    
    // focal point 기준 줌 계산
    // 줌 중심점을 기준으로 오프셋 조정
    final focalPointDelta = details.focalPoint - _startFocalPoint;
    final scaleChange = newScale / _startScale;
    
    // 현재 focal point의 스트림 좌표 계산
    final focalInStream = (details.focalPoint - _startOffset) / _startScale;
    
    // 새 오프셋: focal point가 같은 스트림 좌표를 가리키도록
    var newOffset = details.focalPoint - focalInStream * newScale;
    
    // 시작 오프셋과의 차이로 변환
    newOffset = Offset(
      newOffset.dx - (details.focalPoint.dx - details.focalPoint.dx / scaleChange),
      newOffset.dy - (details.focalPoint.dy - details.focalPoint.dy / scaleChange),
    );
    
    // 더 단순한 방식: 시작 오프셋 + 팬 델타 + 스케일 변화에 따른 조정
    final scaledOffset = _startOffset * scaleChange + focalPointDelta;
    newOffset = _clampOffset(scaledOffset, newScale);
    
    _currentScale = newScale;
    _currentOffset = newOffset;
    
    widget.onScaleChanged(_currentScale);
    widget.onOffsetChanged(_currentOffset);
  }

  /// 더블탭 줌 토글
  void _handleDoubleTapZoom() {
    if (_currentScale > 1.5) {
      // 축소 (원래 크기로)
      _currentScale = 1.0;
      _currentOffset = Offset.zero;
    } else {
      // 확대 (2배)
      _currentScale = 2.0;
      _currentOffset = Offset.zero;
    }
    
    widget.onScaleChanged(_currentScale);
    widget.onOffsetChanged(_currentOffset);
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
              onTap: () {
                if (!_isPinching) {
                  _sendMouseClick('left');
                }
              },
              onDoubleTap: () {
                // 더블탭: 줌 토글 또는 더블클릭
                // 현재 확대 상태면 줌 토글, 아니면 더블클릭
                if (_currentScale > 1.1) {
                  _handleDoubleTapZoom();
                } else {
                  _sendMouseClick('left');
                  _sendMouseClick('left');
                }
              },
              onLongPress: () => _sendMouseClick('right'),
              onScaleStart: (details) {
                _accumDx = 0;
                _accumDy = 0;
                _startScale = _currentScale;
                _startOffset = _currentOffset;
                _startFocalPoint = details.focalPoint;
                _isPinching = details.pointerCount >= 2;
              },
              onScaleUpdate: (details) {
                if (details.pointerCount == 1 && !_isPinching) {
                  // 한 손가락: 마우스 이동
                  _accumDx += details.focalPointDelta.dx * _pointerScale;
                  _accumDy += details.focalPointDelta.dy * _pointerScale;

                  int dxInt = _accumDx.round();
                  int dyInt = _accumDy.round();

                  if (dxInt == 0 && dyInt == 0) return;

                  _accumDx -= dxInt;
                  _accumDy -= dyInt;

                  _sendMouseMove(dxInt, dyInt);
                } else if (details.pointerCount >= 2) {
                  // 두 손가락: 핀치 줌 & 팬
                  _isPinching = true;
                  _handlePinchZoom(details);
                }
              },
              onScaleEnd: (details) {
                _isPinching = false;
              },
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Trackpad mode',
                      style: TextStyle(
                        color: Colors.black45,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '탭=좌클릭 | 길게=우클릭 | 더블탭=더블클릭\n'
                      '두 손가락=화면 확대/이동\n'
                      '확대 시 더블탭=원래 크기',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.black26,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 현재 줌 레벨 표시
                    if (_currentScale > 1.01)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${(_currentScale * 100).round()}%',
                          style: const TextStyle(
                            color: Colors.blue,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
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
