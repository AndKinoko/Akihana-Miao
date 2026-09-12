import 'dart:async';
import 'dart:typed_data';

import 'ptp_core.dart';

/// PTP 字节传输抽象：USB bulk 实现精确读写字节流；
/// WiFi PTP/IP 有自己的包层（见 wifi_link.dart），不走这个接口。
abstract class PtpTransport {
  String get name;
  Future<void> write(List<int> data);

  /// 精确读取 [length] 字节；设备提前结束（短包）时返回已读部分
  Future<Uint8List> read(int length, {Duration timeout});

  /// 读取 interrupt 事件原始字节；无事件返回 null（WiFi 实现不使用）
  Future<Uint8List?> readEvent({
    Duration timeout = const Duration(seconds: 1),
  }) async => null;
  Future<void> close();
}

class PtpException implements Exception {
  const PtpException(this.message, {this.code});
  final String message;
  final int? code;

  @override
  String toString() =>
      code == null ? message : '$message (0x${code!.toRadixString(16)})';
}

/// PTP 事件（ObjectAdded 0x4002 / ObjectRemoved 0x4003 / CaptureComplete 0x400d 等）
class PtpEvent {
  const PtpEvent({
    required this.eventCode,
    this.tid = 0,
    this.params = const [],
  });

  static const objectAdded = 0x4002;
  static const objectRemoved = 0x4003;

  final int eventCode;
  final int tid;
  final List<int> params;

  @override
  String toString() =>
      'PtpEvent(0x${eventCode.toRadixString(16)}, params:$params)';
}

/// PTP 链路抽象：USB 与 WiFi 各自实现组包细节，会话层只面对「事务 + 事件」。
abstract class PtpLink {
  String get name;

  /// 握手时相机上报的友好名（WiFi InitCommandAck；USB 无，返回空）
  String get responderName => '';

  /// 执行一个 PTP 事务，返回数据阶段负载（无数据返回空）
  Future<List<int>> transact(
    int code,
    List<int> params, {
    List<int> sendData = const [],
    Duration timeout = const Duration(seconds: 30),
  });

  /// 事件流（ObjectAdded 等）；USB 为 interrupt 轮询，WiFi 为事件通道推送
  Stream<PtpEvent> get events;

  Future<void> close();
}

/// USB 链路：PIMA 15740 USB 容器封装
class UsbLink implements PtpLink {
  UsbLink(this._transport);

  final PtpTransport _transport;
  int _tid = 0;
  bool _closed = false;
  StreamController<PtpEvent>? _eventCtrl;

  @override
  String get name => _transport.name;

  @override
  String get responderName => '';

  @override
  Future<List<int>> transact(
    int code,
    List<int> params, {
    List<int> sendData = const [],
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_closed) throw const PtpException('USB 链路已关闭');
    final tid = ++_tid;
    await _transport.write(Ptp.buildCommand(code, tid, params));
    if (sendData.isNotEmpty) {
      await _transport.write(Ptp.buildData(code, tid, sendData));
    }
    // 探测响应头：数据容器 type=2 / 响应容器 type=3
    final first = await _transport.read(12, timeout: timeout);
    final c = Ptp.parseContainer(first);
    if (c.type == Ptp.containerData) {
      final total = ByteData.sublistView(first).getUint32(0, Endian.little);
      Uint8List payload = first.sublist(12);
      if (total > 12) {
        final rest = await _transport.read(total - 12, timeout: timeout);
        payload = Uint8List.fromList([...payload, ...rest]);
      }
      // 读响应（长度可变：先 12 字节头，再按需补读）
      final respHead = await _transport.read(12, timeout: timeout);
      final respTotal = ByteData.sublistView(
        respHead,
      ).getUint32(0, Endian.little);
      var respRaw = respHead;
      if (respTotal > 12) {
        respRaw = Uint8List.fromList([
          ...respHead,
          ...await _transport.read(respTotal - 12, timeout: timeout),
        ]);
      }
      _check(Ptp.parseContainer(respRaw), code);
      return payload;
    }
    if (c.type == Ptp.containerResponse) {
      final total = ByteData.sublistView(first).getUint32(0, Endian.little);
      if (total > 12) {
        final respRaw = Uint8List.fromList([
          ...first,
          ...await _transport.read(total - 12, timeout: timeout),
        ]);
        _check(Ptp.parseContainer(respRaw), code);
        return const [];
      }
      _check(c, code);
      return c.params;
    }
    throw PtpException(
      'USB 意外容器类型 ${c.type} (op 0x${code.toRadixString(16)})',
      code: c.code,
    );
  }

  void _check(PtpContainer resp, int op) {
    if (resp.code != Ptp.rcOK) {
      throw PtpException('操作 0x${op.toRadixString(16)} 失败', code: resp.code);
    }
  }

  @override
  Stream<PtpEvent> get events {
    return _eventCtrl?.stream ?? _startEvents();
  }

  Stream<PtpEvent> _startEvents() {
    final ctrl = StreamController<PtpEvent>.broadcast();
    _eventCtrl = ctrl;
    () async {
      while (!_closed && !ctrl.isClosed) {
        try {
          final raw = await _transport.readEvent(
            timeout: const Duration(seconds: 1),
          );
          if (raw == null || raw.isEmpty) continue;
          final c = Ptp.parseContainer(raw);
          if (c.type == Ptp.containerEvent) {
            ctrl.add(PtpEvent(eventCode: c.code, tid: c.tid, params: c.params));
          }
        } catch (_) {
          if (!_closed) await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }();
    return ctrl.stream;
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _eventCtrl?.close();
    await _transport.close();
  }
}
