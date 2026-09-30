import 'package:flutter/foundation.dart';

/// 协议层日志出口。
///
/// 之前这里是裸 print，每个事务打 3~4 行，且要逐行 // ignore: avoid_print
/// 压制 lint。抽成单例后：① 输出等级一处配置；② release 版自动降级
/// （kReleaseMode 下 debugPrint 本身不输出，print 却是无条件刷 logcat）；
/// ③ 协议调试信息不再散落成 lint 豁免。
///
/// 接日志系统时只改这里的 sink，不用动协议代码。
class PtpLog {
  PtpLog._();

  /// 静默：完全丢弃（生产环境可用）
  static const int levelSilent = 0;

  /// 常规：只记异常与生命周期事件
  static const int levelInfo = 1;

  /// 详细：逐事务收发（调试相机连接/传输问题）
  static const int levelDebug = 2;

  /// 当前等级。默认 info：保留连接失败这类关键信息，不刷逐包日志
  static int level = levelInfo;

  /// 实际输出；置空即静默（测试时可注入收集器）
  static void Function(String message)? sink = debugPrint;

  static bool get _enabled => level > levelSilent && sink != null;

  static void d(String message) {
    if (level < levelDebug || !_enabled) return;
    sink!('PTP/IP: $message');
  }

  static void i(String message) {
    if (level < levelInfo || !_enabled) return;
    sink!(message);
  }
}

/// 失败类型：链路故障判定必须靠它，**不能靠异常文案**。
///
/// 早前 CameraHub 用 `msg.contains('超时') || msg.contains('bulkRead')` 判断
/// 设备掉线——协议层或 Kotlin 侧改一个字，掉线检测就静默失效。抛异常时
/// 一律带上 kind，上层只认枚举。
enum PtpFailureKind {
  /// 协议/业务错误（响应码非 0x2001、参数非法）：链路还活着，重试有意义
  protocol,

  /// 超时：对端没在时限内回包。整链路必须作废（PTP 事务超时后响应流会残留，
  /// 复用会污染下一事务的组包边界），但对上层语义是「可能还能重连」
  timeout,

  /// 链路已断：设备拔出、socket 关闭、USB bulk 读写失败
  linkLost,
}

class PtpException implements Exception {
  const PtpException(
    this.message, {
    this.code,
    this.kind = PtpFailureKind.protocol,
  });

  final String message;
  final int? code;
  final PtpFailureKind kind;

  /// 是否属于「链路不可用」——上层据此判定掉线、提示重连
  bool get isLinkFailure =>
      kind == PtpFailureKind.timeout || kind == PtpFailureKind.linkLost;

  @override
  String toString() =>
      code == null ? message : '$message (0x${code!.toRadixString(16)})';
}

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

  /// 尼康事件检查（remoteyourcam/libgphoto2 同款）：
  /// 普通 PTP 事务返回事件数组，USB 上替代 interrupt 端点
  static const opNikonGetEvent = 0x90C1;

  // ---------- 常用响应码 ----------
  static const rcOK = 0x2001;

  /// 会话已打开：上次连接异常退出（ANR/被杀）没 CloseSession 时，
  /// 相机会保留会话，本次 OpenSession 返回此码——视为成功直接沿用
  static const rcSessionAlreadyOpen = 0x201E;

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

  /// 解析响应/事件容器：{code, tid, params}。
  ///
  /// 防御性解析：畸形/截断响应必须抛 [PtpException]，不能漏出 `RangeError`——
  /// 后者文案里没有「超时/断开」语义，掉线判定会误判成普通失败。
  static PtpContainer parseContainer(Uint8List raw) {
    if (raw.length < 12) {
      throw PtpException('PTP 容器过短（${raw.length} 字节 < 12）');
    }
    final b = ByteData.sublistView(raw);
    final type = b.getUint16(4, Endian.little);
    final code = b.getUint16(6, Endian.little);
    final tid = b.getUint32(8, Endian.little);
    final len = b.getUint32(0, Endian.little);
    final params = <int>[];
    if (type == containerResponse || type == containerEvent) {
      // 双上界：容器自报长度 ≤ 实际字节数，两者取小后仍要求至少剩 4 字节
      final end = len < raw.length ? len : raw.length;
      for (var off = 12; off + 4 <= end; off += 4) {
        params.add(b.getUint32(off, Endian.little));
      }
    }
    return PtpContainer(type: type, code: code, tid: tid, params: params);
  }

  /// PTP 字符串解码：u8 字符数（含结尾 \u0000，按 u16 计），其后为 UTF-16LE。
  /// 返回 (字符串, 消费后的新偏移)。
  static (String, int) readString(Uint8List data, int offset) {
    if (offset < 0 || offset >= data.length) {
      throw PtpException('PTP 字符串越界（offset=$offset / ${data.length}）');
    }
    final b = ByteData.sublistView(data);
    final count = b.getUint8(offset);
    if (count == 0) return ('', offset + 1);
    // 先验证整串在缓冲区内，再逐字符读——count 字段说谎时不至于读到一半才炸
    final end = offset + 1 + count * 2;
    if (end > data.length) {
      throw PtpException(
        'PTP 字符串长度越界（需 $end / 实际 ${data.length}，count=$count）',
      );
    }
    final sb = StringBuffer();
    for (var i = 0; i < count - 1; i++) {
      sb.writeCharCode(b.getUint16(offset + 1 + i * 2, Endian.little));
    }
    return (sb.toString(), end);
  }

  /// PTP 字符串解码（不需要偏移推进时使用）
  static String parseString(Uint8List data, int offset) =>
      readString(data, offset).$1;

  /// 校验「u32 个数 + n 个 u32」这段在缓冲区内，返回元素个数
  static int _checkArray(Uint8List data, int offset, String what) {
    if (offset < 0 || offset + 4 > data.length) {
      throw PtpException('$what 计数越界（offset=$offset / ${data.length}）');
    }
    final n = ByteData.sublistView(data).getUint32(offset, Endian.little);
    if (offset + 4 + n * 4 > data.length) {
      throw PtpException('$what 长度越界（声明 $n 项 / 实际 ${data.length} 字节）');
    }
    return n;
  }

  /// u32 数组解码：u32 个数 + n 个 u32
  static List<int> parseU32Array(Uint8List data, int offset) =>
      readU32Array(data, offset).$1;

  /// u32 数组解码并返回消费后的新偏移
  static (List<int>, int) readU32Array(Uint8List data, int offset) {
    final n = _checkArray(data, offset, 'PTP u32 数组');
    final b = ByteData.sublistView(data);
    return (
      [
        for (var i = 0; i < n; i++)
          b.getUint32(offset + 4 + i * 4, Endian.little),
      ],
      offset + 4 + n * 4,
    );
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
    if (d.length < 8) {
      throw PtpException('DeviceInfo 过短（${d.length} 字节）');
    }
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
    this.parentObject = 0,
    required this.filename,
    this.captureDate,
  });

  final int storageId;
  final int objectFormat;
  final int size;

  /// 父对象句柄。列表阶段恒为 0（flat 列表，parent=0），不建目录树，
  /// 故仅在解析时保留原始值供将来建树用，当前无读取方
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
    // 定长头 52 字节（parentObject 在 [44,48)）。截断响应在此拦下，
    // 而不是让 getUint32/getUint16 抛 RangeError（见容器解析处的同类说明）
    if (d.length < 52) {
      throw PtpException('ObjectInfo 过短（${d.length} 字节 < 52）');
    }
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
