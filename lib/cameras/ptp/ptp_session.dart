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
  }) => _link.transact(code, params, sendData: sendData, timeout: timeout);

  /// OpenSession（session id 固定 1）
  Future<void> openSession() async {
    if (_open) return;
    await transact(Ptp.opOpenSession, [1]);
    _open = true;
  }

  Future<void> closeSession() async {
    if (!_open) return;
    try {
      await transact(Ptp.opCloseSession, []);
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
    return _chunkedStream(handle, totalSize, chunk, onProgress);
  }

  Stream<List<int>> _chunkedStream(
    int handle,
    int totalSize,
    int chunk,
    void Function(int)? onProgress,
  ) async* {
    var offset = 0;
    var received = 0;
    var first = true;
    while (offset < totalSize) {
      final want = (totalSize - offset) < chunk ? (totalSize - offset) : chunk;
      List<int> data;
      try {
        data = await transact(Ptp.opGetPartialObject, [
          handle,
          offset,
          want,
        ], timeout: const Duration(minutes: 10));
      } on PtpException catch (e) {
        // 首块即失败 → 机型不支持分块，回退 GetObject 整体传输
        if (first && e.code != null && e.code != Ptp.rcOK && offset == 0) {
          final full = await transact(Ptp.opGetObject, [
            handle,
          ], timeout: const Duration(minutes: 10));
          onProgress?.call(full.length);
          yield full;
          return;
        }
        rethrow;
      }
      first = false;
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
      final data = await transact(
        Ptp.opGetStorageInfo,
        [storageId],
        timeout: const Duration(seconds: 5),
      );
      if (data.length < 22) return null;
      final b = ByteData.sublistView(Uint8List.fromList(data));
      return b.getUint64(14, Endian.little);
    } catch (_) {
      return null;
    }
  }
}
