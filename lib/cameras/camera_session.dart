import 'dart:async';
import 'dart:typed_data';

import 'ptp/ptp_session.dart' show PtpDeviceInfo, PtpEvent, PtpObjectInfo;

/// 相机会话抽象：品牌无关的对外能力面。
/// CameraHub 及全部上层（拉图/缩略图/上传管线）只面向本接口。
///
/// 现有实现：
/// - [PtpCameraSession]（nikon_driver.dart）：标准 PTP（尼康 USB/WiFi、索尼 USB 等）
/// - SonyWifiSession（sony/sony_wifi_session.dart）：索尼旧世代 WiFi（HTTP/UPnP）
abstract class CameraSession {
  CameraSession(this.label, this.brand);

  /// 连接描述（调试/信息卡底部显示）
  final String label;
  final String brand;

  /// 相机事件流（ObjectAdded 等）；不支持推送的品牌返回空流
  Stream<PtpEvent> get events;

  Future<List<int>> getStorageIds();

  /// 全部对象句柄（WiFi HTTP 后端返回合成句柄）
  Future<List<int>> listObjectHandles();

  Future<PtpObjectInfo> getObjectInfo(int handle);

  /// 落盘文件名：默认即原名。WiFi 后端若只能提供 RAW 的 JPEG 预览，
  /// 应在此改名为 .JPG，避免"假 RAW"文件。
  Future<String> outputName(int handle, PtpObjectInfo info) async =>
      info.filename;

  /// 流式下载对象；返回收到的总字节数。
  Future<int> download(
    int handle,
    int size,
    void Function(List<int> chunk) sink, {
    void Function(int received, int total)? onProgress,
  });

  Future<Uint8List> thumb(int handle);

  /// 相机型号：GetDeviceInfo 优先，握手友好名兜底；拿不到返回空串
  Future<String> model();

  /// 设备信息（厂商/型号）
  Future<PtpDeviceInfo> getDeviceInfo();

  /// 相机电池电量（0~100），不支持返回 null
  Future<int?> deviceBattery();

  /// 存储卡剩余空间（字节），不支持返回 null
  Future<int?> storageFreeBytes();

  /// 把已列出的句柄记为「已知」（自动拉图时跳过旧图）
  void markKnown(Iterable<int> handles);
  bool isKnown(int handle);
  void forgetHandles();

  Future<void> close();
}
