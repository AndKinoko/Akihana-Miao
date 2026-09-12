import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../cameras/camera_hub.dart';
import 'common.dart';
import 'widgets.dart';

/// 供相机页入口跳转
Future<void> openCameraAlbum(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const CameraAlbumPage()));

/// 相机相册（二级页）：原相机页的缩略图网格整体迁移至此。
/// 功能不变：3 列网格、视口精确 LOD、本地回填秒开、下载让路、
/// 多选/全选/批量拉取、RAW 角标、拍摄时间倒序、随相机增删实时刷新。
class CameraAlbumPage extends StatefulWidget {
  const CameraAlbumPage({super.key});

  @override
  State<CameraAlbumPage> createState() => _CameraAlbumPageState();
}

class _CameraAlbumPageState extends State<CameraAlbumPage> {
  final ScrollController _scroll = ScrollController();
  Timer? _rangeDebounce;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _rangeDebounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _rangeDebounce?.cancel();
    _rangeDebounce = Timer(const Duration(milliseconds: 150), _updateRange);
  }

  /// 视口精确加载：按滚动偏移反算可见网格行，请求范围 = 可见 ± 2 行
  void _updateRange() {
    if (!_scroll.hasClients) return;
    final w = MediaQuery.of(context).size.width;
    final cross = (w - 32) / 3; // 3 列（含网格 padding 与间距）
    final extent = cross / 0.85 + 4; // tile 主轴高度 + 间距
    if (extent <= 0) return;
    final hub = CameraHub.instance;
    final firstRow = (_scroll.offset / extent).floor();
    final lastRow =
        ((_scroll.offset + _scroll.position.viewportDimension) / extent).ceil();
    final files = hub.fileCount;
    final start = ((firstRow - 2) * 3).clamp(0, files);
    final end = ((lastRow + 3) * 3).clamp(0, files);
    hub.updateRange(start, end);
  }

  Future<void> _batchPull(BuildContext context, CameraHub hub) async {
    final sel = Set<int>.from(hub.selectedHandles);
    final n = await hub.batchPull(sel);
    if (context.mounted) {
      AppToast.show(context, '已拉取 $n 张');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = CameraHub.instance;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.pop(context)),
        title: const Text('相机相册'),
        actions: const [ThemeToggleButton(), SizedBox(width: 8)],
      ),
      body: AnimatedBuilder(
        animation: hub,
        builder: (context, _) {
          final files = hub.fileRows;
          if (!hub.connected) {
            // Center 包裹保证在任何约束下都垂直居中
            return const Center(
              child: EmptyState(
                icon: Icons.link_off,
                title: '相机未连接',
                subtitle: '请先在相机页连接相机',
              ),
            );
          }
          if (files.isEmpty) {
            return const Center(
              child: EmptyState(icon: Icons.image_outlined, title: '尚未读取到对象'),
            );
          }
          return Stack(
            children: [
              GridView.builder(
                controller: _scroll,
                padding: EdgeInsets.only(
                  left: 4,
                  right: 4,
                  top: 4,
                  // 有悬浮面板时给面板+手势条留出滚动余量（沉浸式适配）
                  bottom: hub.selectedHandles.isEmpty
                      ? 24
                      : 100 + MediaQuery.paddingOf(context).bottom,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                  childAspectRatio: 0.85,
                ),
                itemCount: files.length,
                itemBuilder: (context, i) => _buildTile(hub, files[i], i),
              ),
              if (hub.selectedHandles.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SelectionPanel(
                    count: hub.selectedHandles.length,
                    allSelected: hub.selectedHandles.length == files.length,
                    primaryLabel: '拉取',
                    onSelectAll: () =>
                        hub.selectedHandles.length == files.length
                        ? hub.clearSelection()
                        : hub.selectAll(),
                    onCancel: hub.clearSelection,
                    onPrimary: hub.busy
                        ? () {}
                        : () => _batchPull(context, hub),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTile(CameraHub hub, ObjectRow row, int index) {
    final info = row.info;
    final timeText = info.captureDate == null
        ? ''
        : '${info.captureDate!.month.toString().padLeft(2, '0')}-'
              '${info.captureDate!.day.toString().padLeft(2, '0')} '
              '${info.captureDate!.hour.toString().padLeft(2, '0')}:'
              '${info.captureDate!.minute.toString().padLeft(2, '0')}';
    final selected = hub.selectedHandles.contains(row.handle);
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      // 点选恒为选择；拉取只通过底部选择栏的「拉取 N 个」触发
      onTap: hub.busy ? null : () => hub.toggleSelect(row.handle),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: selected
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
                  _buildThumb(hub, row, index),
                  if (info.isRaw)
                    const Positioned(left: 4, top: 4, child: RawBadge()),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: selected ? cs.primary : Colors.white70,
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
                    info.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
                  Text(
                    timeText.isEmpty ? '${info.size} B' : timeText,
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

  /// 缩略图三级策略：
  /// 1) 本地回填——已拉取过的图直接读本地文件，秒开且不占相机带宽；
  /// 2) 视口精确加载——仅请求 [视口 ±2 行] 范围内的缩略图；
  /// 3) 下载让路——拉图下载进行中暂缓发起，避免与 1MiB 分块抢串行队列。
  Widget _buildThumb(CameraHub hub, ObjectRow row, int index) {
    final cached = hub.thumbs[row.handle];
    if (cached != null) {
      return Image.memory(cached, fit: BoxFit.cover, gaplessPlayback: true);
    }
    final localPath = hub.localFilePaths[row.info.filename];
    if (localPath != null && File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const ThumbPlaceholder(pending: true),
      );
    }
    if (index < hub.reqStart || index >= hub.reqEnd) {
      return const ThumbPlaceholder(pending: true);
    }
    return FutureBuilder<Uint8List?>(
      future: hub.thumbFuture(row.handle),
      builder: (context, snap) {
        if (snap.hasData && snap.data != null) {
          return Image.memory(
            snap.data!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        }
        return ThumbPlaceholder(pending: !snap.hasError);
      },
    );
  }
}
