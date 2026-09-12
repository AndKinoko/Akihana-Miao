import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/gallery.dart';
import '../pan/pull_manager.dart';
import '../pan/upload_queue.dart';
import 'common.dart';
import 'widgets.dart';

/// 传输页当前子 tab（0=拉取中 1=已拉取 2=上传）。
final ValueNotifier<int> transferTabIndex = ValueNotifier<int>(0);

/// 传输页：分段控件（拉取中 N / 已拉取 N / 上传 N）+ 三个子视图
class TransferPage extends StatelessWidget {
  const TransferPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        PullManager.instance,
        UploadQueue.instance,
        transferTabIndex,
      ]),
      builder: (context, _) {
        final idx = transferTabIndex.value;
        return Column(
          children: [
            const SizedBox(height: 4),
            CountedSegmentedTabs(
              labels: const ['拉取中', '已拉取', '上传'],
              counts: [
                PullManager.instance.jobs.length,
                LocalFilesPanel.liveCount,
                UploadQueue.instance.items.length,
              ],
              index: idx,
              onChanged: (i) => transferTabIndex.value = i,
            ),
            // 子视图切换。注意：面板绝不能写 const——const 规范化会命中
            // 框架 child.widget == newWidget 短路，导致进度子树永不重建（冻结）。
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: switch (idx) {
                  0 => PullingPanel(key: const ValueKey(0)),
                  1 => LocalFilesPanel(key: const ValueKey(1)),
                  _ => UploadProgressPanel(key: const ValueKey(2)),
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 拉取中：卡片流（文件名 + 体积 + 方向 + 细进度条 + 百分比）
class PullingPanel extends StatelessWidget {
  const PullingPanel({super.key});

  String _sizeText(int n) {
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final jobs = PullManager.instance.jobs;
    if (jobs.isEmpty) {
      return const EmptyState(
        icon: Icons.inbox_outlined,
        title: '没有正在进行的拉取任务',
        subtitle: '连接相机后自动开始\n完成的任务直接进入系统相册「AkihanaMiao」',
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final job in jobs)
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            job.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_sizeText(job.totalSize)} · 相机 → 手机相册',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (job.isRaw) const RawBadge(),
                    const SizedBox(width: 6),
                    if (job.status == 'queued')
                      const StatusChip.info('排队中')
                    else
                      StatusChip.info(
                        '${(job.progress * 100).toStringAsFixed(0)}%',
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                ThinProgressBar(
                  value: job.status == 'queued' ? -1 : job.progress,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 已拉取面板的一条记录：只来自软件专属相册文件夹
/// （Pictures/AkihanaMiao、Movies/AkihanaMiao、Download/AkihanaMiao）。
/// size/mtime 扫描时预计算，避免构建/排序时对 UI 线程做同步 IO。
class _LocalEntry {
  const _LocalEntry({
    required this.file,
    required this.size,
    required this.mtime,
  });
  final File file;
  final int size;
  final DateTime mtime;
  String get name => file.uri.pathSegments.last;
}

/// 已拉取：只显示软件建立的相册文件夹内容（路径固定，与系统相册一一对应）。
/// 缓存目录文件不展示，避免用户困惑。先核准再显示：扫描完成前显示转圈。
class LocalFilesPanel extends StatefulWidget {
  const LocalFilesPanel({super.key});

  /// 供分段控件计数的实时条数（面板挂载过才有意义）
  static int liveCount = 0;

  @override
  State<LocalFilesPanel> createState() => _LocalFilesPanelState();
}

class _LocalFilesPanelState extends State<LocalFilesPanel> {
  final Set<String> _selected = {};
  List<_LocalEntry> _entries = [];
  bool _scanning = true; // 先核准再显示
  bool _scanError = false;
  Timer? _scanDebounce;

  @override
  void initState() {
    super.initState();
    _scan();
    // 拉取入库 / 上传后删除都会广播刷新。
    // 上传进度高频 notify（每 0.5%），这里 800ms 防抖避免全量 MediaStore 查询风暴。
    UploadQueue.instance.addListener(_scheduleScan);
    LocalLibrary.instance.addListener(_scheduleScan);
  }

  @override
  void dispose() {
    UploadQueue.instance.removeListener(_scheduleScan);
    LocalLibrary.instance.removeListener(_scheduleScan);
    _scanDebounce?.cancel();
    super.dispose();
  }

  void _scheduleScan() {
    _scanDebounce?.cancel();
    _scanDebounce = Timer(const Duration(milliseconds: 800), _scan);
  }

  Future<void> _scan() async {
    try {
      // 数据源：软件专属相册文件夹（MediaStore 查询本应用贡献的媒体，
      // 路径固定 Pictures|Movies|Download 下的 AkihanaMiao），按文件名去重
      final galleryFiles = await Gallery.query();
      final byName = <String, GalleryEntry>{};
      for (final g in galleryFiles) {
        if (g.path.isEmpty) continue;
        final old = byName[g.name];
        if (old == null || g.dateModified.isAfter(old.dateModified)) {
          byName[g.name] = g;
        }
      }
      final entries = <_LocalEntry>[
        for (final g in byName.values)
          if (File(g.path).existsSync())
            _LocalEntry(
              file: File(g.path),
              size: g.size,
              mtime: g.dateModified,
            ),
      ];

      entries.sort((a, b) => b.mtime.compareTo(a.mtime));
      if (mounted) {
        setState(() {
          _entries = entries;
          _selected.removeWhere((p) => entries.every((e) => e.file.path != p));
          _scanError = false;
          _scanning = false;
        });
        LocalFilesPanel.liveCount = entries.length;
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _scanError = true;
          _scanning = false;
        });
      }
    }
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == _entries.length) {
        _selected.clear();
      } else {
        _selected.addAll(_entries.map((e) => e.file.path));
      }
    });
  }

  void _uploadSelected() {
    final files = _entries
        .where((e) => _selected.contains(e.file.path))
        .map((e) => e.file)
        .toList();
    if (files.isEmpty) return;
    UploadQueue.instance.enqueue(files);
    setState(() => _selected.clear());
    // 切到上传视图（经 notifier 驱动）
    transferTabIndex.value = 2;
  }

  bool _isRaw(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return ['nef', 'nrw', 'cr2', 'cr3', 'arw', 'raf', 'dng'].contains(ext);
  }

  String _sizeText(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    if (_scanError) {
      return EmptyState(
        icon: Icons.error_outline,
        title: '本地目录读取失败',
        subtitle: null,
      );
    }
    // 先核准再显示：首轮扫描完成前显示转圈
    if (_scanning) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 80),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_entries.isEmpty) {
      return const EmptyState(
        icon: Icons.photo_library_outlined,
        title: '暂无已拉取的文件',
        subtitle: '连接相机后拉图，完成的文件会出现在这里',
      );
    }
    // Stack + 懒加载网格（GridView 自身滚动，仅构建视口内图块），
    // 选择栏以毛玻璃浮层出现，不打断滚动。
    return Stack(
      children: [
        GridView.builder(
          padding: EdgeInsets.fromLTRB(4, 0, 4, _selected.isEmpty ? 24 : 120),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 0.85,
          ),
          itemCount: _entries.length,
          itemBuilder: (context, i) => _buildTile(_entries[i]),
        ),
        if (_selected.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SelectionPanel(
              count: _selected.length,
              allSelected: _selected.length == _entries.length,
              primaryLabel: '上传',
              primaryIcon: Icons.upload,
              onSelectAll: _toggleAll,
              onCancel: () => setState(_selected.clear),
              onPrimary: _uploadSelected,
            ),
          ),
      ],
    );
  }

  Widget _buildTile(_LocalEntry entry) {
    final f = entry.file;
    final name = entry.name;
    final checked = _selected.contains(f.path);
    final mtime = entry.mtime;
    final timeText =
        '${mtime.month.toString().padLeft(2, '0')}-'
        '${mtime.day.toString().padLeft(2, '0')} '
        '${mtime.hour.toString().padLeft(2, '0')}:'
        '${mtime.minute.toString().padLeft(2, '0')}';
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => setState(() {
        checked ? _selected.remove(f.path) : _selected.add(f.path);
      }),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: checked
              ? Border.all(color: cs.primary, width: 2.5)
              : Border.all(color: Colors.transparent),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    f,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    // 缩略尺寸解码：按 3 列图块宽（约 400px）降采样，
                    // 避免 24MP 照片全尺寸解码导致的滚动卡顿与内存暴涨
                    cacheWidth: 400,
                    errorBuilder: (_, __, ___) => Container(
                      color: cs.surfaceContainerHigh,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.image_not_supported_outlined,
                        size: 28,
                      ),
                    ),
                  ),
                  if (_isRaw(name))
                    const Positioned(left: 4, top: 4, child: RawBadge()),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Icon(
                      checked
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: checked ? cs.primary : Colors.white70,
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
                  Text(
                    '${_sizeText(entry.size)} · $timeText',
                    style: TextStyle(
                      fontSize: 9,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 上传：卡片流（上传中/等待/已完成）+ 底部「全部暂停/继续」
class UploadProgressPanel extends StatelessWidget {
  const UploadProgressPanel({super.key});

  String _statusLine(UploadItem it) {
    final status = switch (it.status) {
      UploadStatus.waiting => '等待中',
      UploadStatus.uploading =>
        '上传中 ${(it.progress * 100).toStringAsFixed(0)}%',
      UploadStatus.done =>
        AppConfig.instance.deleteAfterUpload ? '已完成（本地已删除）' : '已完成',
      UploadStatus.failed => '失败',
    };
    final err = it.error == null ? '' : ' · ${it.error}';
    return '${it.sizeText} · $status$err'.trim();
  }

  @override
  Widget build(BuildContext context) {
    final items = UploadQueue.instance.items;
    final reason = UploadQueue.instance.waitReason;
    final paused =
        reason != null && items.any((i) => i.status == UploadStatus.waiting);
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.cloud_upload_outlined,
        title: '队列为空',
        subtitle: '已拉取的文件多选上传后，这里显示进度',
      );
    }
    return Column(
      children: [
        // 顶部固定：暂停提示 + 全部暂停/全部取消（列表再长也能操作），
        // 下方 Expanded(ListView) 承载卡片流，避免 Column 溢出且可滚动
        if (paused)
          AppCard(
            flat: true,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.pause_circle_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '上传已暂停：$reason',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => UploadQueue.instance.manualPaused
                      ? UploadQueue.instance.resumeAll()
                      : UploadQueue.instance.pauseAll(),
                  icon: Icon(
                    UploadQueue.instance.manualPaused
                        ? Icons.play_arrow
                        : Icons.pause,
                    size: 18,
                  ),
                  label: Text(
                    UploadQueue.instance.manualPaused ? '继续上传' : '全部暂停',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: UploadQueue.instance.hasCancellable
                      ? () => UploadQueue.instance.cancelAll()
                      : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('全部取消'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              for (final it in items)
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  it.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _statusLine(it),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            children: [
                              switch (it.status) {
                                UploadStatus.done => const StatusChip.ok('已完成'),
                                UploadStatus.failed => TextButton(
                                  onPressed: () =>
                                      UploadQueue.instance.retry(it),
                                  child: const Text('重试'),
                                ),
                                UploadStatus.uploading => StatusChip.info(
                                  '${(it.progress * 100).toStringAsFixed(0)}%',
                                ),
                                UploadStatus.waiting => const StatusChip.warn(
                                  '等待',
                                ),
                              },
                              // 取消：等待/失败直接移出；上传中中止在途传输
                              if (it.status != UploadStatus.done)
                                TextButton(
                                  onPressed: () =>
                                      UploadQueue.instance.cancel(it),
                                  child: const Text('取消'),
                                ),
                            ],
                          ),
                        ],
                      ),
                      if (it.status == UploadStatus.uploading) ...[
                        const SizedBox(height: 10),
                        ThinProgressBar(value: it.progress),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
