import 'dart:async';
import 'dart:typed_data';

import 'ptp_core.dart';
import 'ptp_link.dart';

export 'ptp_core.dart';
export 'ptp_link.dart';

/// PTP 会话核心：高层操作封装，事务与组包由 PtpLink（USB/WiFi）实现。
class PtpSession {
  PtpSession(this._link);

  final PtpLink _link;
  bool _open = false;

  bool get isOpen => _open;
  PtpLink get link => _link;

  Future<List<int>> transact(
    int code,
    List<int> params, {
    List<int> sendData = const [],
    Duration timeout = const Duration(seconds: 30),
    void Function(int received)? onData,
  }) => _link.transact(
    code,
    params,
    sendData: sendData,
    timeout: timeout,
    onData: onData,
  );

  /// OpenSession（session id 固定 1）。
  /// 上次连接异常退出（ANR/被杀）时相机会保留脏会话并返回
  /// SessionAlreadyOpen(0x201E)——此时不能直接沿用（旧状态会挂起后续
  /// 事务），必须 CloseSession 后重新 OpenSession 拿一个干净会话。
  Future<void> openSession() async {
    if (_open) return;
    try {
      await transact(Ptp.opOpenSession, [1]);
      _open = true;
    } on PtpException catch (e) {
      if (e.code == Ptp.rcSessionAlreadyOpen) {
        try {
          await transact(Ptp.opCloseSession, const []);
        } catch (_) {}
        await transact(Ptp.opOpenSession, [1]);
        _open = true;
        return;
      }
      rethrow;
    }
  }

  Future<void> closeSession() async {
    if (!_open) return;
    try {
      // 链路可能已死（设备拔出）：3s 收不了就算了，别拖住断开流程
      await transact(
        Ptp.opCloseSession,
        [],
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
    } finally {
      _open = false;
    }
  }

  Future<void> close() async {
    try {
      await closeSession();
    } catch (_) {}
    await _link.close();
  }

  // ---------- 高层操作 ----------

  Future<List<int>> getStorageIds() async {
    final data = await transact(Ptp.opGetStorageIDs, []);
    return Ptp.parseU32Array(Uint8List.fromList(data), 0);
  }

  /// 设备信息（厂商/型号，连接后读取真实型号用）
  Future<PtpDeviceInfo> getDeviceInfo() async {
    final data = await transact(Ptp.opGetDeviceInfo, []);
    return PtpDeviceInfo.parse(Uint8List.fromList(data));
  }

  Future<List<int>> getObjectHandles({
    int storageId = 0xFFFFFFFF,
    int format = 0,
    int parent = 0,
  }) async {
    final data = await transact(Ptp.opGetObjectHandles, [
      storageId,
      format,
      parent,
    ]);
    return Ptp.parseU32Array(Uint8List.fromList(data), 0);
  }

  /// 尼康厂商事件检查（0x90C1）：USB 上替代 interrupt 端点的事件来源。
  /// 数据格式：[count u16][eventCode u16][param u32] × count
  Future<List<PtpEvent>> getNikonEvents() async {
    final data = await transact(Ptp.opNikonGetEvent, []);
    final events = <PtpEvent>[];
    if (data.length < 2) return events;
    final bytes = Uint8List.fromList(data);
    final b = ByteData.sublistView(bytes);
    final count = b.getUint16(0, Endian.little);
    var off = 2;
    for (var i = 0; i < count && off + 6 <= bytes.length; i++) {
      final code = b.getUint16(off, Endian.little);
      final param = b.getUint32(off + 2, Endian.little);
      off += 6;
      events.add(PtpEvent(eventCode: code, params: [param]));
    }
    return events;
  }

  Future<PtpObjectInfo> getObjectInfo(int handle) async {
    final data = await transact(Ptp.opGetObjectInfo, [handle]);
    return PtpObjectInfo.parse(Uint8List.fromList(data));
  }

  /// 分块拉取完整对象（1MiB 块保证进度颗粒度）。
  /// 首块失败（不支持/参数无效）时自动回退 GetObject 一次性传输。
  Future<Stream<List<int>>> downloadObject(
    int handle,
    int totalSize, {
    int chunk = 1024 * 1024,
    void Function(int received)? onProgress,
  }) async {
    if (totalSize <= 0) {
      onProgress?.call(0);
      return Stream.value(const []);
    }
    return _chunkedStream(handle, totalSize, onProgress);
  }

  Stream<List<int>> _chunkedStream(
    int handle,
    int totalSize,
    void Function(int)? onProgress,
  ) async* {
    var offset = 0;
    var received = 0;
    // 分块上限 64KB：Z6 实测对 1MiB 的 GetPartialObject 会挂起并随后
    // 自我复位掉线（相机 USB 固件限制），64KB 稳定。64KB 粒度同时也
    // 是进度刷新颗粒度。
    const chunk = 65536;
    while (offset < totalSize) {
      final want = (totalSize - offset) < chunk ? (totalSize - offset) : chunk;
      List<int> data;
      try {
        data = await transact(
          Ptp.opGetPartialObject,
          [handle, offset, want],
          timeout: const Duration(minutes: 10),
          onData: (n) => onProgress?.call(received + n),
        );
      } on PtpException catch (e) {
        // 明确报错（非超时挂起）→ 机型不支持分块，回退 GetObject 整体传输
        if (offset == 0 && e.code != null && e.code != Ptp.rcOK) {
          final full = await transact(
            Ptp.opGetObject,
            [handle],
            timeout: const Duration(minutes: 10),
            onData: (n) => onProgress?.call(n),
          );
          onProgress?.call(full.length);
          yield full;
          return;
        }
        rethrow;
      }
      offset += data.length;
      received += data.length;
      onProgress?.call(received);
      yield data;
      if (data.length < want) break; // 设备提前给完
    }
  }

  /// 探测设备是否支持 GetPartialObject（0x101B）
  Future<bool> probePartialObject(int handle) async {
    try {
      await transact(Ptp.opGetPartialObject, [handle, 0, 4]);
      return true;
    } on PtpException {
      return false;
    }
  }

  Future<Uint8List> getThumb(int handle) async {
    // 尼康大缩略图优先（更清晰），失败回退标准缩略图（AeroShutter 同策略）
    try {
      final large = await transact(Ptp.opNikonGetLargeThumb, [handle]);
      if (large.isNotEmpty) return Uint8List.fromList(large);
    } on PtpException catch (_) {
      // 机型不支持厂商大图，走标准
    }
    final data = await transact(Ptp.opGetThumb, [handle]);
    return Uint8List.fromList(data);
  }

  /// 相机电池电量（0~100）；属性不支持或解析失败返回 null
  Future<int?> deviceBattery() async {
    try {
      final data = await transact(Ptp.opGetDevicePropValue, [
        Ptp.dpBatteryLevel,
      ], timeout: const Duration(seconds: 5));
      if (data.length < 5) return null;
      // [propCode u16][dataType u16][value u8]
      return Uint8List.fromList(data)[4];
    } catch (_) {
      return null;
    }
  }

  /// 存储卡剩余空间（字节）；解析失败返回 null。
  /// StorageInfo: [storageType u16][fs u16][access u16][max u64][free u64]...
  Future<int?> storageFreeBytes({int storageId = 0x00010001}) async {
    try {
      final data = await transact(Ptp.opGetStorageInfo, [
        storageId,
      ], timeout: const Duration(seconds: 5));
      if (data.length < 22) return null;
      final b = ByteData.sublistView(Uint8List.fromList(data));
      return b.getUint64(14, Endian.little);
    } catch (_) {
      return null;
    }
  }
}
