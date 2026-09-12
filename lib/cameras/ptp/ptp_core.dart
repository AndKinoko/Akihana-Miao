import 'dart:typed_data';

/// PTP（PIMA 15740）常量与字节编解码工具
class Ptp {
  // ---------- USB 容器类型 ----------
  static const containerCommand = 1;
  static const containerData = 2;
  static const containerResponse = 3;
  static const containerEvent = 4;

  // ---------- 标准操作码 ----------
  static const opGetDeviceInfo = 0x1001;
  static const opOpenSession = 0x1002;
  static const opCloseSession = 0x1003;
  static const opGetStorageIDs = 0x1004;
  static const opGetObjectHandles = 0x1007;
  static const opGetObjectInfo = 0x1008;
  static const opGetObject = 0x1009;
  static const opGetThumb = 0x100A;
  static const opGetPartialObject = 0x101B;
  static const opGetStorageInfo = 0x1014;
  static const opGetDevicePropValue = 0x1015;

  /// 标准设备属性：电池等级（0~100，u8）
  static const dpBatteryLevel = 0x5001;

  // ---------- 尼康厂商操作码 ----------
  /// 尼康大缩略图（更清晰，AeroShutter 同策略：先大图后标准图）
  static const opNikonGetLargeThumb = 0x90C4;

  // ---------- 常用响应码 ----------
  static const rcOK = 0x2001;

  // ---------- 对象格式 ----------
  static const ofcAssociation = 0x3001;

  // ---------- 编码 ----------

  static void putU32(ByteData b, int off, int v) =>
      b.setUint32(off, v, Endian.little);
  static void putU16(ByteData b, int off, int v) =>
      b.setUint16(off, v, Endian.little);

  /// 请求容器：len(4) type=1(2) code(2) tid(4) params(4*n)
  static Uint8List buildCommand(int code, int tid, List<int> params) {
    assert(params.length <= 5);
    final len = 12 + params.length * 4;
    final b = ByteData(len);
    putU32(b, 0, len);
    putU16(b, 4, containerCommand);
    putU16(b, 6, code);
    putU32(b, 8, tid);
    for (var i = 0; i < params.length; i++) {
      putU32(b, 12 + i * 4, params[i]);
    }
    return b.buffer.asUint8List();
  }

  /// 数据容器：len(4) type=2(2) code(2) tid(4) payload
  static Uint8List buildData(int code, int tid, List<int> payload) {
    final len = 12 + payload.length;
    final b = ByteData(len);
    putU32(b, 0, len);
    putU16(b, 4, containerData);
    putU16(b, 6, code);
    putU32(b, 8, tid);
    b.buffer.asUint8List().setRange(12, len, payload);
    return b.buffer.asUint8List();
  }

  /// 解析响应/事件容器：{code, tid, params}
  static PtpContainer parseContainer(Uint8List raw) {
    final b = ByteData.sublistView(raw);
    final type = b.getUint16(4, Endian.little);
    final code = b.getUint16(6, Endian.little);
    final tid = b.getUint32(8, Endian.little);
    final len = b.getUint32(0, Endian.little);
    final params = <int>[];
    if (type == containerResponse || type == containerEvent) {
      for (var off = 12; off + 4 <= len && off + 4 <= raw.length; off += 4) {
        params.add(b.getUint32(off, Endian.little));
      }
    }
    return PtpContainer(type: type, code: code, tid: tid, params: params);
  }

  /// PTP 字符串解码：u8 字符数（含结尾 \u0000，按 u16 计），其后为 UTF-16LE。
  /// 返回 (字符串, 消费后的新偏移)。
  static (String, int) readString(Uint8List data, int offset) {
    final b = ByteData.sublistView(data);
    final count = b.getUint8(offset);
    if (count == 0) return ('', offset + 1);
    final sb = StringBuffer();
    for (var i = 0; i < count - 1; i++) {
      sb.writeCharCode(b.getUint16(offset + 1 + i * 2, Endian.little));
    }
    return (sb.toString(), offset + 1 + count * 2);
  }

  /// PTP 字符串解码（不需要偏移推进时使用）
  static String parseString(Uint8List data, int offset) =>
      readString(data, offset).$1;

  /// u32 数组解码：u32 个数 + n 个 u32
  static List<int> parseU32Array(Uint8List data, int offset) {
    final b = ByteData.sublistView(data);
    final n = b.getUint32(offset, Endian.little);
    return [
      for (var i = 0; i < n; i++)
        b.getUint32(offset + 4 + i * 4, Endian.little),
    ];
  }

  /// u32 数组解码并返回消费后的新偏移
  static (List<int>, int) readU32Array(Uint8List data, int offset) {
    final b = ByteData.sublistView(data);
    final n = b.getUint32(offset, Endian.little);
    final list = [
      for (var i = 0; i < n; i++)
        b.getUint32(offset + 4 + i * 4, Endian.little),
    ];
    return (list, offset + 4 + n * 4);
  }
}

/// 已解析的 PTP 容器
class PtpContainer {
  const PtpContainer({
    required this.type,
    required this.code,
    required this.tid,
    this.params = const [],
  });

  final int type;
  final int code;
  final int tid;
  final List<int> params;

  @override
  String toString() =>
      'PtpContainer(type:$type code:0x${code.toRadixString(16)} '
      'tid:$tid params:$params)';
}

/// GetDeviceInfo 解析结果（只需厂商/型号，其余字段略过）
class PtpDeviceInfo {
  const PtpDeviceInfo({
    required this.manufacturer,
    required this.model,
    required this.deviceVersion,
  });

  final String manufacturer;
  final String model;
  final String deviceVersion;

  static PtpDeviceInfo parse(Uint8List d) {
    // DeviceInfo 数据集（PIMA 15740）：
    // StandardVersion u16 + VendorExtensionID u32 = 6 字节，
    // 之后紧跟 VendorExtensionDesc 字符串（不是定长 u16！之前错跳 8 字节导致全盘错位）
    var off = 6;
    final desc = Ptp.readString(d, off); // VendorExtensionDesc
    off = desc.$2;
    off += 2; // FunctionalMode u16
    // Operations / Events / DeviceProps / CaptureFormats / ImageFormats
    for (var i = 0; i < 5; i++) {
      off = Ptp.readU32Array(d, off).$2;
    }
    final manufacturer = Ptp.readString(d, off);
    final model = Ptp.readString(d, manufacturer.$2);
    final dv = Ptp.readString(d, model.$2);
    return PtpDeviceInfo(
      manufacturer: manufacturer.$1,
      model: model.$1,
      deviceVersion: dv.$1,
    );
  }
}

/// GetObjectInfo 解析结果
class PtpObjectInfo {
  const PtpObjectInfo({
    required this.storageId,
    required this.objectFormat,
    required this.size,
    required this.parentObject,
    required this.filename,
    this.captureDate,
  });

  final int storageId;
  final int objectFormat;
  final int size;
  final int parentObject;
  final String filename;
  final DateTime? captureDate;

  bool get isFolder => objectFormat == Ptp.ofcAssociation;

  /// RAW 文件（缩略图需要角标提示）
  bool get isRaw {
    final ext = filename.contains('.')
        ? filename.split('.').last.toLowerCase()
        : '';
    return ['nef', 'nrw', 'cr2', 'cr3', 'arw', 'raf', 'dng'].contains(ext);
  }

  static PtpObjectInfo parse(Uint8List d) {
    final b = ByteData.sublistView(d);
    final storageId = b.getUint32(0, Endian.little);
    final objectFormat = b.getUint16(4, Endian.little);
    final size = b.getUint32(8, Endian.little);
    final parentObject = b.getUint32(44, Endian.little);
    // 52 字节定长头之后：Filename / CaptureDate / ModificationDate / Keywords
    var off = 52;
    final filename = Ptp.readString(d, off);
    off = filename.$2;
    final captureStr = Ptp.readString(d, off);
    off = captureStr.$2;
    return PtpObjectInfo(
      storageId: storageId,
      objectFormat: objectFormat,
      size: size,
      parentObject: parentObject,
      filename: filename.$1,
      captureDate: _parsePtpDate(captureStr.$1),
    );
  }

  /// PTP 日期格式 "20260911T121314"
  static DateTime? _parsePtpDate(String s) {
    if (s.length < 15) return null;
    try {
      return DateTime(
        int.parse(s.substring(0, 4)),
        int.parse(s.substring(4, 6)),
        int.parse(s.substring(6, 8)),
        int.parse(s.substring(9, 11)),
        int.parse(s.substring(11, 13)),
        int.parse(s.substring(13, 15)),
      );
    } catch (_) {
      return null;
    }
  }
}
