import 'package:flutter/services.dart';

/// 系统相册（MediaStore）访问：保存 + 查询本应用专属目录。
/// 图片 → Pictures/AkihanaMiao，视频 → Movies/AkihanaMiao，RAW 等 → Download/AkihanaMiao。
class Gallery {
  static const MethodChannel _channel = MethodChannel('dev.akihana/usb_host');

  /// 保存成功返回 true；失败/不支持返回 false（不抛异常，由调用方决定提示）。
  /// [subFolder] 可选子目录（如 yyyy-MM-dd），加在 AkihanaMiao 之后。
  static Future<bool> save(
    String filePath,
    String fileName, {
    String? subFolder,
  }) async {
    try {
      final uri = await _channel.invokeMethod<String>('saveToGallery', {
        'path': filePath,
        'fileName': fileName,
        'subFolder': subFolder,
      });
      return uri != null;
    } catch (_) {
      return false;
    }
  }

  /// 查询本应用存入相册/下载目录的媒体文件（缩略图和上传都从这里取）
  static Future<List<GalleryEntry>> query() async {
    try {
      final list =
          await _channel.invokeListMethod<Map>('queryGallery') ?? const [];
      return list.map((e) {
        final m = e.cast<String, dynamic>();
        return GalleryEntry(
          name: m['name'] as String? ?? '',
          path: m['path'] as String? ?? '',
          size: int.tryParse(m['size'] as String? ?? '') ?? 0,
          dateModified: DateTime.fromMillisecondsSinceEpoch(
            (int.tryParse(m['dateModified'] as String? ?? '') ?? 0) * 1000,
          ),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }
}

/// 相册里的一条媒体记录
class GalleryEntry {
  const GalleryEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.dateModified,
  });

  final String name;
  final String path; // 绝对路径（本应用贡献的媒体可直接读）
  final int size;
  final DateTime dateModified;
}
