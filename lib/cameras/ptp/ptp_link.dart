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

  /// 执行一个 PTP 事务，返回数据阶段负载（无数据返回空）。
  /// [onData] 数据阶段每收到一块回调已收字节数（进度用）。
  Future<List<int>> transact(
    int code,
    List<int> params, {
    List<int> sendData = const [],
    Duration timeout = const Duration(seconds: 30),
    void Function(int received)? onData,
  });

  /// 事件流（ObjectAdded 等）；USB 为 interrupt 轮询，WiFi 为事件通道推送
  Stream<PtpEvent> get events;

  Future<void> close();
}

/// USB 链路：PIMA 15740 USB 容器封装。
/// 所有事务经串行队列排队执行（与 WiFi 侧同规则）：bulk 端点共享
/// 一条数据流，keepalive/轮询等小事务绝不能插进下载的数据阶段，
/// 否则相机在传输中途收到新命令会复位掉线（Z6 实测）。
class UsbLink implements PtpLink {
  UsbLink(this._transport);

  final PtpTransport _transport;
  int _tid = 0;
  bool _closed = false;
  Future<void> _queue = Future.value();

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
    void Function(int received)? onData,
  }) {
    Future<List<int>> run() => _runTransact(
      code,
      params,
      sendData: sendData,
      timeout: timeout,
      onData: onData,
    );
    final result = _queue.then((_) => run(), onError: (_) => run());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<int>> _runTransact(
    int code,
    List<int> params, {
    required List<int> sendData,
    required Duration timeout,
    void Function(int received)? onData,
  }) async {
    if (_closed) throw const PtpException('USB 链路已关闭');
    final tid = ++_tid;
    await _transport.write(Ptp.buildCommand(code, tid, params));
    if (sendData.isNotEmpty) {
      await _transport.write(Ptp.buildData(code, tid, sendData));
    }
    // USB 是 512 字节分包的包传输：读取必须按包对齐的大块（16384）进行。
    // 若精确读 12 字节探头，首包剩余 500 字节会被主机丢弃，数据流整体
    // 错位 → 后续读取永远凑不齐 → 30s 超时（bulkRead 失败）。
    final first = await _readContainerStart(timeout);
    final c = Ptp.parseContainer(first);
    if (c.type == Ptp.containerData) {
      final total = ByteData.sublistView(first).getUint32(0, Endian.little);
      final bb = BytesBuilder(copy: false)..add(first);
      if (total > 12) onData?.call(bb.length - 12);
      while (bb.length < total) {
        final chunk = await _transport.read(16384, timeout: timeout);
        if (chunk.isEmpty) break; // 设备提前结束（真 ZLP/短包），停止
        bb.add(chunk);
        onData?.call(bb.length - 12);
      }
      final payload = bb.takeBytes();
      final resp = await _readResponse(timeout);
      _check(resp, code);
      return payload.sublist(
        12,
        total < payload.length ? total : payload.length,
      );
    }
    if (c.type == Ptp.containerResponse) {
      _check(Ptp.parseContainer(first), code);
      return c.params;
    }
    throw PtpException(
      'USB 意外容器类型 ${c.type} (op 0x${code.toRadixString(16)})',
      code: c.code,
    );
  }

  /// 读取一个容器的起始块，跳过上一事务残留的零长度包（真 ZLP）。
  /// 容器总长恰为 512 整数倍时相机会追加 ZLP，它会在下一次读取时以
  /// 0 长度返回——这里吸收掉，避免污染本事务的容器头解析。
  Future<Uint8List> _readContainerStart(Duration timeout) async {
    while (true) {
      final raw = await _transport.read(16384, timeout: timeout);
      if (raw.isNotEmpty) return raw;
      // 收到 ZLP（0 长度）→ 继续读真正的容器头
    }
  }

  /// 读取响应容器（12~32 字节短包；按大块读天然包对齐）
  Future<PtpContainer> _readResponse(Duration timeout) async {
    var raw = await _readContainerStart(timeout);
    final total = ByteData.sublistView(raw).getUint32(0, Endian.little);
    while (raw.length < total) {
      final chunk = await _transport.read(16384, timeout: timeout);
      if (chunk.isEmpty) break;
      final merged = Uint8List(raw.length + chunk.length)
        ..setAll(0, raw)
        ..setAll(raw.length, chunk);
      raw = merged;
    }
    return Ptp.parseContainer(raw);
  }

  void _check(PtpContainer resp, int op) {
    if (resp.code != Ptp.rcOK) {
      throw PtpException('操作 0x${op.toRadixString(16)} 失败', code: resp.code);
    }
  }

  /// USB 不使用 interrupt 事件端点（与 bulk 传输在 usbfs 层争抢管道，
  /// Z6 实测数据管道卡死）。新图发现改由 CameraHub 句柄差集轮询负责，
  /// 掉线感知靠轮询连续失败，不依赖事件流。
  /// 必须返回「永不关闭」的空流：Stream.empty() 会立即触发 onDone，
  /// 被 CameraHub 误判为链路死亡、连上即弹断开。
  @override
  Stream<PtpEvent> get events => _emptyEvents.stream;
  static final StreamController<PtpEvent> _emptyEvents =
      StreamController<PtpEvent>.broadcast();

  @override
  Future<void> close() async {
    _closed = true;
    await _transport.close();
  }
}
