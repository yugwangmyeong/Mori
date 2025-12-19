import 'package:flutter/material.dart';

// 파형 링 애니메이션 위젯
class WaveformRing extends StatefulWidget {
  final bool isActive;
  final double size;
  final Color color;

  const WaveformRing({
    super.key,
    required this.isActive,
    this.size = 320,
    this.color = Colors.blue,
  });

  @override
  State<WaveformRing> createState() => _WaveformRingState();
}

class _WaveformRingState extends State<WaveformRing>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    _opacityAnimation = Tween<double>(begin: 0.6, end: 0.3).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    if (widget.isActive) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(WaveformRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.reset();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Opacity(
            opacity: _opacityAnimation.value,
            child: CustomPaint(
              size: Size(widget.size, widget.size),
              painter: _RingPainter(color: widget.color),
            ),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  final Color color;

  _RingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) => false;
}

