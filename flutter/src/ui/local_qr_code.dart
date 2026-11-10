import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Encodes login challenges on the device; no image service sees the token.
class LocalQrCode extends StatelessWidget {
  final String data;
  const LocalQrCode({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final matrix = QrImage(
      QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    return Semantics(
      label: '登录二维码，请使用对应网盘 App 扫码',
      image: true,
      child: CustomPaint(
        painter: _QrPainter(data, matrix),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  final String data;
  final QrImage matrix;
  _QrPainter(this.data, this.matrix);

  @override
  void paint(Canvas canvas, Size size) {
    const quietZone = 4;
    final count = matrix.moduleCount + quietZone * 2;
    final side = math.min(size.width, size.height);
    final cell = side / count;
    final x = (size.width - side) / 2;
    final y = (size.height - side) / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < matrix.moduleCount; row++) {
      for (var col = 0; col < matrix.moduleCount; col++) {
        if (matrix.isDark(row, col)) {
          final left = (x + (col + quietZone) * cell).floorToDouble();
          final top = (y + (row + quietZone) * cell).floorToDouble();
          final right = (x + (col + quietZone + 1) * cell).ceilToDouble();
          final bottom = (y + (row + quietZone + 1) * cell).ceilToDouble();
          canvas.drawRect(
            Rect.fromLTRB(left, top, right, bottom),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => data != oldDelegate.data;
}
