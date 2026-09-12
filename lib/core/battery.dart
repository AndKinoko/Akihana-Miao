import 'package:flutter/services.dart';

/// 手机电池/充电状态（条件保护 gate 用：仅充电时上传 / 低电量暂停）
class Battery {
  static const MethodChannel _channel = MethodChannel('dev.akihana/usb_host');

  const Battery({required this.level, required this.charging});

  /// 0~100；读取失败返回 -1
  final int level;
  final bool charging;

  static Battery unknown = const Battery(level: -1, charging: false);

  static Future<Battery> get() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('getBattery');
      if (m == null) return unknown;
      return Battery(
        level: (m['level'] as num?)?.toInt() ?? -1,
        charging: m['charging'] as bool? ?? false,
      );
    } catch (_) {
      return unknown;
    }
  }
}
