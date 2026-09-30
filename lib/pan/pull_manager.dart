import 'package:flutter/foundation.dart';

/// 一条拉取任务（传输页「正在拉取」展示）
class PullJob {
  PullJob({
    required this.fileName,
    required this.totalSize,
    this.thumb,
    this.isRaw = false,
    this.status = 'pulling',
  });

  final String fileName;
  int totalSize;

  /// 相机侧缩略图缓存（可能为 null：还没拉到缩略图）
  final Uint8List? thumb;
  final bool isRaw;

  /// queued = 排队中 / pulling = 拉取中 / failed = 失败（保留在列表里可见）
  String status;
  double progress = 0; // 0.0 ~ 1.0
  String? error;

  bool get isActive => status == 'queued' || status == 'pulling';
}

/// 拉取任务中心：相机页发起拉取 → 这里登记 → 传输页「正在拉取」实时展示。
/// 拉取完成后任务移出本列表（文件自然出现在「已拉取」）。
class PullManager extends ChangeNotifier {
  PullManager._();
  static final PullManager instance = PullManager._();

  final List<PullJob> jobs = [];

  PullJob begin(
    String fileName,
    int totalSize,
    Uint8List? thumb, {
    bool isRaw = false,
    bool queued = false,
  }) {
    // 同名任务去重：正在拉取中不允许重复登记（防连点/事件重放）
    final existing = _findActive(fileName);
    if (existing != null) return existing;
    final job = PullJob(
      fileName: fileName,
      totalSize: totalSize,
      thumb: thumb,
      isRaw: isRaw,
      status: queued ? 'queued' : 'pulling',
    );
    jobs.add(job);
    notifyListeners();
    return job;
  }

  PullJob? _findActive(String fileName) {
    for (final j in jobs) {
      // 失败项留在列表里给用户看原因，但不能算「占着这个名字」，
      // 否则同名文件永远无法重新入队（自动拉取会被 hasActive 挡掉）
      if (j.isActive && j.fileName == fileName) return j;
    }
    return null;
  }

  bool hasActive(String fileName) => _findActive(fileName) != null;

  /// 排队任务开始拉取
  void start(PullJob job) {
    job
      ..status = 'pulling'
      ..progress = 0;
    notifyListeners();
  }

  void update(PullJob job, int received, {int? total}) {
    // WiFi 后端（索尼等）列表阶段可能拿不到真实大小，下载时由 content-length 回填
    if (total != null && total > 0 && job.totalSize != total) {
      job.totalSize = total;
    }
    if (job.totalSize <= 0) return;
    final p = (received / job.totalSize).clamp(0.0, 1.0);
    if ((p - job.progress).abs() > 0.005 || p >= 1.0) {
      job.progress = p;
      notifyListeners();
    }
  }

  /// 完成：移出「正在拉取」
  void finish(PullJob job) {
    jobs.remove(job);
    notifyListeners();
  }

  /// 失败：**保留在列表里并记下原因**。
  ///
  /// 原实现只 notifyListeners 就把任务移出列表，错误信息无处可去——
  /// 用户看到进度条凭空消失，不知道是成功了还是失败了。现在失败项留在
  /// 「拉取中」面板显示红色原因，由用户点「移除」清掉。
  void fail(PullJob job, String message) {
    job
      ..status = 'failed'
      ..error = message;
    notifyListeners();
  }

  /// 用户手动移除一条失败记录
  void dismiss(PullJob job) {
    if (job.isActive) return;
    jobs.remove(job);
    notifyListeners();
  }

  /// 清掉全部失败记录（相机页「清除失败项」入口用）
  void clearFailed() {
    if (!jobs.any((j) => j.status == 'failed')) return;
    jobs.removeWhere((j) => j.status == 'failed');
    notifyListeners();
  }

  /// 链路断开/死亡：清空全部任务（含排队中），避免面板残留死任务
  void clearAll() {
    if (jobs.isEmpty) return;
    jobs.clear();
    notifyListeners();
  }
}

/// 本地库变更广播：拉取入库 / 上传后删除时通知「已拉取」面板重扫
class LocalLibrary extends ChangeNotifier {
  LocalLibrary._();
  static final LocalLibrary instance = LocalLibrary._();

  void notifyChanged() => notifyListeners();
}
