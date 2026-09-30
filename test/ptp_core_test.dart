import 'dart:typed_data';

import 'package:akihana_miao/cameras/ptp/ptp_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// PTP 字节编解码测试。
///
/// 这一层是全项目最容易写错、又最难靠真机复现的部分（字节序、长度、
/// 变长字符串），且全部是纯函数——零 IO 零依赖，是性价比最高的测试位置。
/// 每条用例都对应代码里记录过的真实踩坑。

/// 构造 PTP 字符串：u8 长度（含结尾 NUL，按 u16 计）+ UTF-16LE 内容
Uint8List ptpString(String s) {
  final codeUnits = s.codeUnits;
  final out = Uint8List(1 + (codeUnits.length + 1) * 2);
  out[0] = codeUnits.length + 1; // 含 NUL 终止符
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < codeUnits.length; i++) {
    bd.setUint16(1 + i * 2, codeUnits[i], Endian.little);
  }
  return out;
}

void main() {
  group('buildCommand', () {
    test('头部布局：len(4) type(1) code(2) tid(4)，小端', () {
      final raw = Ptp.buildCommand(Ptp.opGetObjectInfo, 7, [0x1234]);
      expect(raw.length, 16); // 12 头 + 1 参数

      final b = ByteData.sublistView(raw);
      expect(b.getUint32(0, Endian.little), 16, reason: '容器总长');
      expect(b.getUint16(4, Endian.little), Ptp.containerCommand);
      expect(b.getUint16(6, Endian.little), 0x1008, reason: 'GetObjectInfo');
      expect(b.getUint32(8, Endian.little), 7, reason: '事务 id');
      expect(b.getUint32(12, Endian.little), 0x1234, reason: '参数值');
    });

    test('无参数时长度为 12', () {
      expect(Ptp.buildCommand(Ptp.opOpenSession, 1, [1]).length, 16);
      expect(Ptp.buildCommand(Ptp.opCloseSession, 2, const []).length, 12);
    });

    test('buildData：数据容器头 + 原样负载', () {
      final payload = [1, 2, 3, 4, 5];
      final raw = Ptp.buildData(Ptp.opGetObject, 9, payload);
      expect(raw.length, 17);

      final b = ByteData.sublistView(raw);
      expect(b.getUint32(0, Endian.little), 17);
      expect(b.getUint16(4, Endian.little), Ptp.containerData);
      expect(b.getUint16(6, Endian.little), 0x1009);
      expect(b.getUint32(8, Endian.little), 9);
      expect(raw.sublist(12), payload);
    });
  });

  group('parseContainer', () {
    test('响应容器解析 code/tid/params', () {
      // 两个参数 → 容器总长 12 + 2*4 = 20。参数个数由**声明的总长**决定，
      // 不是由 buffer 有多长决定（下面另有截断用例盯这一点）
      final b = ByteData(20);
      b.setUint32(0, 20, Endian.little);
      b.setUint16(4, Ptp.containerResponse, Endian.little);
      b.setUint16(6, Ptp.rcOK, Endian.little);
      b.setUint32(8, 3, Endian.little);
      b.setUint32(12, 0x10001, Endian.little);
      b.setUint32(16, 0x20001, Endian.little);

      final c = Ptp.parseContainer(b.buffer.asUint8List());
      expect(c.type, Ptp.containerResponse);
      expect(c.code, Ptp.rcOK);
      expect(c.tid, 3);
      expect(c.params, [0x10001, 0x20001]);
    });

    test('声明长度大于实际内容时，多出的参数槽按 0 读且不越界', () {
      // 声明 24（3 槽）但只写了 2 个参数：第 3 槽读到补零的 0，
      // 不应抛异常。参数个数由声明长度决定——真实相机的响应容器
      // 长度总是自洽，这里固化的是「长度说话」这条解析规则
      final b = ByteData(24);
      b.setUint32(0, 24, Endian.little);
      b.setUint16(4, Ptp.containerResponse, Endian.little);
      b.setUint16(6, Ptp.rcOK, Endian.little);
      b.setUint32(8, 3, Endian.little);
      b.setUint32(12, 0x10001, Endian.little);
      b.setUint32(16, 0x20001, Endian.little);

      final c = Ptp.parseContainer(b.buffer.asUint8List());
      expect(c.params, [0x10001, 0x20001, 0]);
    });

    test('数据容器不解析参数（负载不是 u32 数组）', () {
      final raw = Ptp.buildData(Ptp.opGetObject, 1, [9, 9, 9, 9, 9, 9]);
      final c = Ptp.parseContainer(raw);
      expect(c.type, Ptp.containerData);
      expect(c.params, isEmpty, reason: '数据容器的载荷不能当参数读');
    });

    test('参数区被容器长度截断，不越界读', () {
      // 声明总长 16（12 头 + 1 参数），但只给 12 字节头
      final b = ByteData(12);
      b.setUint32(0, 16, Endian.little);
      b.setUint16(4, Ptp.containerResponse, Endian.little);
      b.setUint16(6, Ptp.rcOK, Endian.little);
      b.setUint32(8, 1, Endian.little);

      final c = Ptp.parseContainer(b.buffer.asUint8List());
      expect(c.params, isEmpty, reason: '缺参数时不应抛异常或读越界');
    });
  });

  group('readString', () {
    test('ASCII 字符串 + 偏移推进', () {
      final s = ptpString('DSC_0001.JPG');
      final (text, next) = Ptp.readString(s, 0);
      expect(text, 'DSC_0001.JPG');
      expect(next, s.length, reason: '消费后的偏移应正好是串尾');
    });

    test('空串（计数 0）只消耗 1 字节', () {
      final s = Uint8List.fromList([0, 9, 9]);
      final (text, next) = Ptp.readString(s, 0);
      expect(text, isEmpty);
      expect(next, 1);
    });

    test('中文 UTF-16LE（尼康机型名含中文时）', () {
      final s = ptpString('尼康');
      final (text, _) = Ptp.readString(s, 0);
      expect(text, '尼康');
    });

    test('从非零偏移读取', () {
      final head = Uint8List(6); // 前置字段
      final s = Uint8List.fromList([...head, ...ptpString('NIKON DSC Z6')]);
      final (text, next) = Ptp.readString(s, 6);
      expect(text, 'NIKON DSC Z6');
      expect(next, s.length);
    });
  });

  group('parseU32Array', () {
    test('u32 个数 + n 个 u32', () {
      final b = ByteData(4 + 3 * 4);
      b.setUint32(0, 3, Endian.little);
      b.setUint32(4, 0x10001, Endian.little);
      b.setUint32(8, 0x10002, Endian.little);
      b.setUint32(12, 0x10003, Endian.little);
      expect(
        Ptp.parseU32Array(b.buffer.asUint8List(), 0),
        [0x10001, 0x10002, 0x10003],
      );
    });

    test('计数 0 返回空列表', () {
      final b = ByteData(4)..setUint32(0, 0, Endian.little);
      expect(Ptp.parseU32Array(b.buffer.asUint8List(), 0), isEmpty);
    });

    test('readU32Array 同时返回新偏移', () {
      final b = ByteData(4 + 8 + 4);
      b.setUint32(0, 2, Endian.little);
      b.setUint32(4, 7, Endian.little);
      b.setUint32(8, 8, Endian.little);
      b.setUint32(12, 0xABCD, Endian.little); // 紧随其后的下一个字段
      final (list, next) = Ptp.readU32Array(b.buffer.asUint8List(), 0);
      expect(list, [7, 8]);
      expect(next, 12, reason: '偏移应推进到下一个字段起点');
    });
  });

  group('PtpDeviceInfo.parse', () {
    /// 组一个最小合法 DeviceInfo 数据集。
    /// 注意 VendorExtensionDesc 是**变长字符串**——早前实现按定长 8 字节
    /// 跳过后整段错位，这里专门盯住这一点。
    Uint8List deviceInfo({
      String vendorExt = 'microsoft.com: 1.0;',
      String manufacturer = 'NIKON CORPORATION',
      String model = 'NIKON Z 6_2',
      String deviceVersion = '1.00',
    }) {
      final parts = <Uint8List>[];
      final fixed = ByteData(6)..setUint16(0, 100, Endian.little);
      fixed.setUint32(2, 6, Endian.little); // VendorExtensionID
      parts.add(fixed.buffer.asUint8List());
      parts.add(ptpString(vendorExt));
      final functional = ByteData(2); // FunctionalMode u16
      parts.add(functional.buffer.asUint8List());
      // 5 个 u32 数组：Operations / Events / DeviceProps /
      // CaptureFormats / ImageFormats（各用空数组占位）
      for (var i = 0; i < 5; i++) {
        parts.add((ByteData(4)..setUint32(0, 0, Endian.little)).buffer
            .asUint8List());
      }
      parts.add(ptpString(manufacturer));
      parts.add(ptpString(model));
      parts.add(ptpString(deviceVersion));
      return Uint8List.fromList(parts.expand((e) => e).toList());
    }

    test('厂商/型号/固件解析正确（变长 VendorExtensionDesc 之后不错位）', () {
      final info = PtpDeviceInfo.parse(deviceInfo());
      expect(info.manufacturer, 'NIKON CORPORATION');
      expect(info.model, 'NIKON Z 6_2');
      expect(info.deviceVersion, '1.00');
    });

    test('VendorExtensionDesc 长度变化不影响后续字段', () {
      // 这正是「按定长 8 字节跳过」会崩掉的场景：描述串 12 字符与
      // 30 字符两种长度，型号都必须读对
      final short = PtpDeviceInfo.parse(deviceInfo(vendorExt: 'ab'));
      final long = PtpDeviceInfo.parse(
        deviceInfo(vendorExt: 'microsoft.com: 1.0; 1234567890'),
      );
      expect(short.model, 'NIKON Z 6_2');
      expect(long.model, 'NIKON Z 6_2');
      expect(long.manufacturer, 'NIKON CORPORATION');
    });
  });

  group('PtpObjectInfo.parse', () {
    /// 52 字节定长头 + 变长尾部（Filename / CaptureDate / …）
    Uint8List objectInfo({
      int objectFormat = 0x3801,
      int size = 12345,
      String filename = 'DSC_0001.NEF',
      String capture = '20260911T121314',
    }) {
      final head = ByteData(52);
      head.setUint32(0, 0x00010001, Endian.little); // storageId
      head.setUint16(4, objectFormat, Endian.little);
      head.setUint32(8, size, Endian.little);
      head.setUint32(44, 0, Endian.little); // parentObject
      return Uint8List.fromList([
        ...head.buffer.asUint8List(),
        ...ptpString(filename),
        ...ptpString(capture),
        ...ptpString(''), // ModificationDate
        ...ptpString(''), // Keywords
      ]);
    }

    test('定长头字段与文件名', () {
      final o = PtpObjectInfo.parse(objectInfo());
      expect(o.storageId, 0x00010001);
      expect(o.size, 12345);
      expect(o.filename, 'DSC_0001.NEF');
      expect(o.isFolder, isFalse);
      expect(o.isRaw, isTrue, reason: 'NEF 应识别为 RAW');
    });

    test('拍摄日期解析为本地 DateTime', () {
      final o = PtpObjectInfo.parse(objectInfo());
      expect(o.captureDate, isNotNull);
      expect(o.captureDate!.year, 2026);
      expect(o.captureDate!.month, 9);
      expect(o.captureDate!.day, 11);
      expect(o.captureDate!.hour, 12);
      expect(o.captureDate!.minute, 13);
      expect(o.captureDate!.second, 14);
    });

    test('日期缺失/畸形返回 null，不抛异常', () {
      expect(PtpObjectInfo.parse(objectInfo(capture: '')).captureDate, isNull);
      expect(
        PtpObjectInfo.parse(objectInfo(capture: 'x')).captureDate,
        isNull,
      );
    });

    test('Association(0x3001) 判定为文件夹且不算 RAW', () {
      final o = PtpObjectInfo.parse(
        objectInfo(objectFormat: 0x3001, filename: '100MEDIA', size: 0),
      );
      expect(o.isFolder, isTrue);
      expect(o.isRaw, isFalse);
    });

    test('isRaw 覆盖各品牌 RAW 扩展名，JPEG 不算', () {
      for (final ext in ['nef', 'NRW', 'cr3', 'arw', 'raf', 'dng']) {
        expect(
          PtpObjectInfo.parse(objectInfo(filename: 'A.$ext')).isRaw,
          isTrue,
          reason: ext,
        );
      }
      expect(
        PtpObjectInfo.parse(objectInfo(filename: 'A.jpeg')).isRaw,
        isFalse,
      );
      expect(
        PtpObjectInfo.parse(objectInfo(filename: 'A.mov')).isRaw,
        isFalse,
      );
    });
  });
}
