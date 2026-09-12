import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../ptp/ptp_link.dart';

/// PTP/IP 包类型（组包蓝本：docs/reference/aero_packets.ts，实测代码勿改格式）
class PtpIpPacketType {
  static const initCommandRequest = 1;
  static const initCommandAck = 2;
  static const initEventRequest = 3;
  static const initEventAck = 4;
  static const initFail = 5;
  static const operationRequest = 6;
  static const operationResponse = 7;
  static const event = 8;
  static const startData = 9;
  static const data = 10;
  static const cancel = 11;
  static const endData = 12;
  static const probeRequest = 13;
  static const probeResponse = 14;
}

/// OperationRequest 的数据阶段指示
class DataPhase {
  static const noData = 1;
  static const dataToInitiator = 2;
  static const dataToResponder = 3;
}

/// 尼康 WMU 固定发起方 GUID —— 相机视为「已配对老朋友」，跳过重新配对弹窗
final Uint8List wmuInitiatorGuid = Uint8List.fromList([
  0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, //
  0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
]);

const ptpIpPort = 15740;
const ptpIpVersion = 0x00010000;

class _InitAck {
  _InitAck(this.connectionNumber, this.responderName);
  final int connectionNumber;
  final String responderName;
}

/// PTP/IP 链路（WiFi 双 TCP 连接：命令/数据 + 事件）。
/// 协议要点（避坑 #2）：
/// - 事件连接必须完成 InitEventRequest/InitEventAck 握手后，OpenSession 才会响应
/// - 单命令连接同一时刻只允许一个在途事务（严格串行）
/// - 数据阶段：StartData(tid, total u64) → Data(tid, chunk)* → EndData(tid, last)
class WifiLink implements PtpLink {
  WifiLink._(this._cmd, this._event);

  Socket? _cmd;
  Socket? _event;
  List<int> _cmdBuf = [];
  List<int> _evBuf = [];
  int _tid = 0;
  bool _dead = false;

  Completer<_InitAck>? _initAck;
  Completer<void>? _eventAck;
  // 当前在途事务状态
  Completer<List<int>>? _pending;
  BytesBuilder? _pendingBody; // 数据阶段累积（零拷贝 append）
  int _pendingTotal = 0;
  Timer? _timeoutTimer;

  final StreamController<PtpEvent> _events = StreamController.broadcast();
  Future<void> _queue = Future.value();

  @override
  String get name => 'WiFi:$_host';

  String _host = '';

  @override
  String responderName = '';

  /// 连接并完成三步握手；任一步失败抛 PtpException
  static Future<WifiLink> connect(
    String host, {
    String hostName = 'akihana-miao/0.1 (android)',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    Socket? cmd;
    Socket? event;
    // ignore: avoid_print
    print('PTP/IP: 正在连接 $host:$ptpIpPort …');
    try {
      cmd = await Socket.connect(host, ptpIpPort, timeout: timeout);
      // ignore: avoid_print
      print('PTP/IP: TCP 命令连接已建立，发送 InitCommandRequest …');
      final link = WifiLink._(cmd, null).._host = host;
      final ack = await link._initCommand(hostName, timeout);
      link.responderName = ack.responderName;
      // ignore: avoid_print
      print(
        'PTP/IP: 握手成功 connNumber=${ack.connectionNumber} 相机=${ack.responderName}',
      );

      // 事件连接（必须先于 OpenSession，避坑 #2）
      event = await Socket.connect(host, ptpIpPort, timeout: timeout);
      link._event = event;
      event.listen(
        link._onEventData,
        onError: (Object e) => link._markDead('事件连接错误: $e'),
        onDone: () => link._markDead('事件连接被相机关闭'),
      );
      // ignore: avoid_print
      print('PTP/IP: 事件连接 TCP 已建立，发送 InitEventRequest …');
      await link._initEvent(ack.connectionNumber, timeout);
      // ignore: avoid_print
      print('PTP/IP: 事件连接握手完成，链路就绪');

      // 命令连接数据流监听在 _initCommand 里已挂上
      return link;
    } on SocketException catch (e) {
      // ignore: avoid_print
      print(
        'PTP/IP: SocketException ${e.osError?.message ?? e.message} (errno=${e.osError?.errorCode})',
      );
      try {
        cmd?.destroy();
      } catch (_) {}
      try {
        event?.destroy();
      } catch (_) {}
      throw PtpException('连接相机失败: ${e.message}');
    } on PtpException {
      // 握手超时/InitFail 等 PtpException 同样必须清理，
      // 否则半开 socket 占住相机（单客户端限制），下次连接被拒
      try {
        cmd?.destroy();
      } catch (_) {}
      try {
        event?.destroy();
      } catch (_) {}
      rethrow;
    }
  }

  Future<_InitAck> _initCommand(String hostName, Duration timeout) async {
    final ack = Completer<_InitAck>();
    _initAck = ack;
    _cmd!.listen(
      _onCmdData,
      onError: (Object e) => _markDead('命令连接错误: $e'),
      onDone: () => _markDead('命令连接被相机关闭'),
    );
    _cmd!.add(_encodeInitCommandRequest(wmuInitiatorGuid, hostName));
    return ack.future.timeout(
      timeout,
      onTimeout: () {
        throw const PtpException('InitCommandRequest 握手超时');
      },
    );
  }

  Future<void> _initEvent(int connectionNumber, Duration timeout) async {
    final c = Completer<void>();
    _eventAck = c;
    _event!.add(_encodeInitEventRequest(connectionNumber));
    await c.future.timeout(
      timeout,
      onTimeout: () {
        throw const PtpException('InitEventRequest 握手超时（事件连接未确认）');
      },
    );
  }

  // ---------- 组包（格式与 aero_packets.ts 一致） ----------

  static Uint8List _packet(int type, List<int> payload) {
    final b = BytesBuilder();
    final len = payload.length + 8;
    b.add(_u32(len));
    b.add(_u32(type));
    b.add(payload);
    return b.toBytes();
  }

  static Uint8List _u32(int v) =>
      Uint8List(4)
        ..buffer.asByteData().setUint32(0, v & 0xFFFFFFFF, Endian.little);

  static Uint8List _u16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v & 0xFFFF, Endian.little);

  static Uint8List _encodeInitCommandRequest(Uint8List guid, String name) {
    final b = BytesBuilder();
    b.add(guid);
    // 友好名称 UTF-16LE + NUL 结尾
    for (final ch in name.codeUnits) {
      b.add(_u16(ch));
    }
    b.add(_u16(0));
    b.add(_u32(ptpIpVersion));
    return _packet(PtpIpPacketType.initCommandRequest, b.toBytes());
  }

  static Uint8List _encodeInitEventRequest(int connectionNumber) =>
      _packet(PtpIpPacketType.initEventRequest, _u32(connectionNumber));

  static Uint8List _encodeOperationRequest(
    int dataPhase,
    int code,
    int tid,
    List<int> params,
  ) {
    final b = BytesBuilder();
    b.add(_u32(dataPhase));
    b.add(_u16(code));
    b.add(_u32(tid));
    for (final p in params) {
      b.add(_u32(p));
    }
    return _packet(PtpIpPacketType.operationRequest, b.toBytes());
  }

  static Uint8List _encodeStartData(int tid, int totalLength) {
    final b = BytesBuilder();
    b.add(_u32(tid));
    b.add(_u32(totalLength & 0xFFFFFFFF));
    b.add(_u32(totalLength ~/ 0x100000000));
    return _packet(PtpIpPacketType.startData, b.toBytes());
  }

  static Uint8List _encodeEndData(int tid, List<int> data) {
    final b = BytesBuilder();
    b.add(_u32(tid));
    b.add(data);
    return _packet(PtpIpPacketType.endData, b.toBytes());
  }

  // ---------- 解包 ----------

  void _onCmdData(Uint8List chunk) {
    if (_dead) return;
    _cmdBuf.addAll(chunk);
    _drain(_cmdBuf, _handleCmdPacket, (rest) => _cmdBuf = rest);
  }

  void _onEventData(Uint8List chunk) {
    if (_dead) return;
    _evBuf.addAll(chunk);
    _drain(_evBuf, _handleEventPacket, (rest) => _evBuf = rest);
  }

  static void _drain(
    List<int> buf,
    void Function(int type, List<int> payload) onPacket,
    void Function(List<int>) setRest,
  ) {
    while (buf.length >= 8) {
      final bd = Uint8List.fromList(buf.sublist(0, 8));
      final len = bd.buffer.asByteData().getUint32(0, Endian.little);
      if (len < 8) {
        buf.removeRange(0, 8);
        continue;
      }
      if (buf.length < len) break; // 包不完整
      final type = bd.buffer.asByteData().getUint32(4, Endian.little);
      onPacket(type, buf.sublist(8, len));
      buf.removeRange(0, len);
    }
    setRest(buf);
  }

  void _handleCmdPacket(int type, List<int> payload) {
    switch (type) {
      case PtpIpPacketType.initCommandAck:
        final c = _initAck;
        if (c != null && !c.isCompleted) {
          final bd = Uint8List.fromList(payload).buffer.asByteData();
          c.complete(_readInitAck(bd, payload));
        }
      case PtpIpPacketType.initFail:
        final c = _initAck;
        if (c != null && !c.isCompleted) {
          c.completeError(const PtpException('相机拒绝了连接 (InitFail)'));
        }
      case PtpIpPacketType.probeRequest:
        // 相机保活探测（WMU 行为，审计报告确认必须回应）
        // ignore: avoid_print
        print('PTP/IP: 收到 ProbeRequest，回应 ProbeResponse');
        _cmd?.add(_packet(PtpIpPacketType.probeResponse, const []));
      case PtpIpPacketType.startData:
        // 数据阶段开始：tid u32 + 总长度 u64（数据包在 OperationResponse 之前到达）
        final p = _pending;
        if (p != null) {
          final bd = Uint8List.fromList(payload).buffer.asByteData();
          _pendingTotal =
              bd.getUint32(4, Endian.little) +
              bd.getUint32(8, Endian.little) * 0x100000000;
          _pendingBody = BytesBuilder();
          // ignore: avoid_print
          print('PTP/IP: 数据阶段开始 total=$_pendingTotal');
        }
      case PtpIpPacketType.data:
      case PtpIpPacketType.endData:
        // 数据块：tid u32 + 数据（endData 为最后一块）
        final p = _pending;
        if (p != null && payload.length > 4) {
          _pendingBody?.add(payload.sublist(4));
          if (type == PtpIpPacketType.endData) {
            // ignore: avoid_print
            print('PTP/IP: 数据阶段结束，共 ${_pendingBody?.length} 字节');
          }
        }
      case PtpIpPacketType.operationResponse:
        final p = _pending;
        if (p != null && !p.isCompleted) {
          _timeoutTimer?.cancel();
          final bd = Uint8List.fromList(payload).buffer.asByteData();
          final respCode = bd.getUint16(0, Endian.little);
          // tid 在 [2..6)，参数从 6 开始
          final params = <int>[];
          for (var off = 6; off + 4 <= payload.length; off += 4) {
            params.add(bd.getUint32(off, Endian.little));
          }
          // ignore: avoid_print
          print(
            'PTP/IP: 事务响应 code=0x${respCode.toRadixString(16)} '
            'params=$params',
          );
          if (respCode != 0x2001) {
            p.completeError(PtpException('操作失败', code: respCode));
          } else {
            p.complete(_pendingBody?.takeBytes() ?? Uint8List(0));
          }
          _pending = null;
          _pendingBody = null;
        }
      default:
        // ignore: avoid_print
        print('PTP/IP: 未处理的命令通道包 type=$type len=${payload.length}');
    }
  }

  static _InitAck _readInitAck(ByteData bd, List<int> payload) {
    final connectionNumber = bd.getUint32(0, Endian.little);
    // 跳过 guid(16)，读 UTF-16LE NUL 结尾的相机名
    var name = '';
    var off = 20;
    final u8 = Uint8List.fromList(payload);
    while (off + 2 <= payload.length) {
      final code = u8.buffer.asByteData().getUint16(off, Endian.little);
      off += 2;
      if (code == 0) break;
      name += String.fromCharCode(code);
    }
    return _InitAck(connectionNumber, name);
  }

  void _handleEventPacket(int type, List<int> payload) {
    switch (type) {
      case PtpIpPacketType.initEventAck:
        final c = _eventAck;
        if (c != null && !c.isCompleted) c.complete();
      case PtpIpPacketType.event:
        // eventCode u16 + tid u32 + params u32*
        final u8 = Uint8List.fromList(payload);
        final bd = u8.buffer.asByteData();
        if (payload.length < 2) return;
        final eventCode = bd.getUint16(0, Endian.little);
        var tid = 0;
        if (payload.length >= 6) tid = bd.getUint32(2, Endian.little);
        final params = <int>[];
        for (var off = 6; off + 4 <= payload.length; off += 4) {
          params.add(bd.getUint32(off, Endian.little));
        }
        if (!_events.isClosed) {
          _events.add(PtpEvent(eventCode: eventCode, tid: tid, params: params));
        }
    }
  }

  void _markDead(String reason) {
    if (_dead) return;
    _dead = true;
    _timeoutTimer?.cancel();
    final p = _pending;
    if (p != null && !p.isCompleted) {
      p.completeError(PtpException('连接已断开: $reason'));
      _pending = null;
    }
    // 握手期的 completer 也要完成，否则 connect() 要等满超时才失败
    final ia = _initAck;
    if (ia != null && !ia.isCompleted) {
      ia.completeError(PtpException('连接已断开: $reason'));
    }
    final ea = _eventAck;
    if (ea != null && !ea.isCompleted) {
      ea.completeError(PtpException('连接已断开: $reason'));
    }
    if (!_events.isClosed) _events.close();
    _destroy();
  }

  void _destroy() {
    try {
      _cmd?.destroy();
    } catch (_) {}
    try {
      _event?.destroy();
    } catch (_) {}
    _cmd = null;
    _event = null;
  }

  // ---------- PtpLink 实现 ----------

  @override
  Future<List<int>> transact(
    int code,
    List<int> params, {
    List<int> sendData = const [],
    Duration timeout = const Duration(seconds: 30),
    void Function(int received)? onData,
  }) {
    // 串行化：同一命令连接严格单事务在途（与 AeroShutter 一致）
    Future<List<int>> run() => _runTransact(code, params, sendData, timeout);
    final result = _queue.then((_) => run(), onError: (_) => run());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<int>> _runTransact(
    int code,
    List<int> params,
    List<int> sendData,
    Duration timeout,
  ) async {
    if (_dead || _cmd == null) throw const PtpException('PTP/IP 连接已断开');
    final tid = ++_tid;
    final c = Completer<List<int>>();
    _pending = c;
    _pendingBody = BytesBuilder();
    _pendingTotal = 0;
    _timeoutTimer = Timer(timeout, () {
      if (_pending == c) {
        _pending = null;
        _pendingBody = null;
        if (!c.isCompleted) {
          c.completeError(
            PtpException('操作 0x${code.toRadixString(16)} 超时（$_host）'),
          );
        }
        // 关键：超时意味着响应流可能残留（数据阶段半途而废），
        // 继续复用会污染下一事务的组包边界 —— 必须整链路作废重连
        _markDead('操作 0x${code.toRadixString(16)} 超时，链路作废');
      }
    });
    try {
      // ignore: avoid_print
      print(
        'PTP/IP: 发送事务 0x${code.toRadixString(16)} tid=$tid '
        'params=$params dataPhase=${sendData.isEmpty ? 1 : 3}',
      );
      _cmd!.add(
        _encodeOperationRequest(
          sendData.isEmpty ? DataPhase.noData : DataPhase.dataToResponder,
          code,
          tid,
          params,
        ),
      );
      if (sendData.isNotEmpty) {
        _cmd!.add(_encodeStartData(tid, sendData.length));
        _cmd!.add(_encodeEndData(tid, sendData));
      }
      return await c.future;
    } finally {
      _timeoutTimer?.cancel();
    }
  }

  @override
  Stream<PtpEvent> get events => _events.stream;

  @override
  Future<void> close() async {
    _dead = true;
    _timeoutTimer?.cancel();
    if (!_events.isClosed) await _events.close();
    _destroy();
  }
}
