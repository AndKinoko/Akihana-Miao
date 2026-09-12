import 'dart:async';

import 'package:flutter/services.dart';

import '../ptp/ptp_link.dart';

/// Android USB Host 传输（经 MethodChannel 桥接 UsbHostChannel.kt）
class UsbTransport implements PtpTransport {
  UsbTransport._(this.deviceName);

  static const MethodChannel _channel = MethodChannel('dev.akihana/usb_host');

  final String deviceName;
  bool _closed = false;

  /// 枚举 USB 设备
  static Future<List<Map<String, dynamic>>> listDevices() async {
    final list = await _channel.invokeListMethod<Map>('listDevices');
    return (list ?? const []).map((e) => e.cast<String, dynamic>()).toList();
  }

  /// 请求授权并打开设备，返回可用传输
  static Future<UsbTransport> open(String deviceName) async {
    final ok = await _channel.invokeMethod<bool>('requestPermission', {
      'device': deviceName,
    });
    if (ok != true) {
      throw const PtpException('USB 权限被拒绝');
    }
    await _channel.invokeMethod('open', {'device': deviceName});
    return UsbTransport._(deviceName);
  }

  @override
  String get name => 'USB:$deviceName';

  @override
  Future<void> write(List<int> data) async {
    if (_closed) throw const PtpException('USB 已关闭');
    await _channel.invokeMethod('bulkWrite', {
      'data': Uint8List.fromList(data),
    });
  }

  @override
  Future<Uint8List> read(
    int length, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_closed) throw const PtpException('USB 已关闭');
    final data = await _channel.invokeMethod<List<int>>('bulkRead', {
      'length': length,
      'timeout': timeout.inMilliseconds,
    });
    return Uint8List.fromList(data ?? const []);
  }

  /// 读取 interrupt 事件（PTP 事件容器），无事件返回 null
  @override
  Future<Uint8List?> readEvent({
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (_closed) return null;
    final data = await _channel.invokeMethod<List<int>>('interruptRead', {
      'timeout': timeout.inMilliseconds,
    });
    return data == null ? null : Uint8List.fromList(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.invokeMethod('close');
    } catch (_) {}
  }
}
