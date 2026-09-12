import 'package:flutter/material.dart';

import '../cameras/camera_driver.dart';
import '../cameras/camera_hub.dart';
import '../core/config.dart';
import 'camera_album_page.dart';
import 'home_page.dart';
import 'transfer_page.dart';
import 'widgets.dart';

/// 相机页（信息中枢）：连接管理 + 相机状态卡 + 功能入口。
/// 缩略图网格在「进入相机相册」二级页。
class CameraPage extends StatelessWidget {
  const CameraPage({super.key});

  void _toast(BuildContext context, String msg) => AppToast.show(context, msg);

  Future<void> _pullAll(BuildContext context, CameraHub hub) async {
    final targets = hub.pullAllCandidates();
    if (targets.isEmpty) {
      _toast(context, '没有可拉取的文件（全部已拉取过）');
      return;
    }
    final totalMb =
        targets.fold<int>(0, (s, r) => s + r.info.size) / 1024 / 1024;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('立即拉取全部'),
        content: Text(
          '将拉取 ${targets.length} 个文件，'
          '约 ${totalMb.toStringAsFixed(1)} MB。\n'
          '已拉取过的文件会自动跳过，任务在「传输-正在拉取」中显示。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始拉取'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = await hub.batchPull(targets.map((r) => r.handle).toSet());
    if (context.mounted) _toast(context, '批量拉取完成 $n 个');
  }

  @override
  Widget build(BuildContext context) {
    final hub = CameraHub.instance;
    return AnimatedBuilder(
      animation: hub,
      builder: (context, _) {
        // 一次性断开提示（弹一次即清，绝不重复弹）
        final note = hub.disconnectNote;
        if (note != null) {
          hub.disconnectNote = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) AppToast.show(context, note);
          });
        }
        return Stack(
          children: [
            // 列表：连接/断开切换时淡入+轻微上滑，平滑过渡
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, 0.03),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: hub.connected
                  ? ListView(
                      key: ValueKey(true),
                      padding: const EdgeInsets.only(bottom: 20, top: 4),
                      children: _connected(context, hub),
                    )
                  : _disconnectedBody(context, hub),
            ),
            // 连接浮层：转圈提示；成功态不显示（浮层直接消失），失败内嵌原因+重试
            if (hub.phase != ConnectPhase.idle &&
                hub.phase != ConnectPhase.success)
              ConnectOverlay(
                phase: hub.phase,
                failReason: hub.failReason,
                onRetry: hub.retryConnect,
                onCancel: hub.cancelConnect,
              ),
          ],
        );
      },
    );
  }

  /// 断开态布局：提示在剩余空间垂直居中，连接方式固定在底部。
  /// 之前 EmptyState 放 ListView 里（纵向无界）导致提示顶在上部不居中。
  Widget _disconnectedBody(BuildContext context, CameraHub hub) {
    return Column(
      key: ValueKey(false),
      children: [
        Expanded(
          child: Center(
            child: EmptyState(
              icon: Icons.photo_camera_outlined,
              title: '未检测到相机',
              subtitle: '请通过 USB 或 WiFi 连接相机',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader('相机品牌'),
              const _BrandSelector(),
              const SizedBox(height: 10),
              const SectionHeader('连接方式'),
              GroupList(
                rows: [
                  ListRow(
                    icon: Icons.usb,
                    title: 'USB 连接',
                    subtitle: '数据线直连，速度最快',
                    trailing: const Icon(Icons.arrow_forward, size: 16),
                    onTap: hub.busy ? null : () => hub.connectUsb(),
                  ),
                  ListRow(
                    icon: Icons.wifi,
                    title: 'WiFi 连接',
                    subtitle: '无线连接，无需数据线',
                    trailing: const Icon(Icons.arrow_forward, size: 16),
                    onTap: hub.busy ? null : () => hub.connectWifi(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _connected(BuildContext context, CameraHub hub) {
    final s = hub.session!;
    final cs = Theme.of(context).colorScheme;
    final connText = hub.connKind == 'wifi'
        ? 'WiFi 直连 · ${hub.connHost ?? ''}'
        : 'USB 连接';
    final rows = <Widget>[];
    // 相机信息卡
    rows.add(
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.photo_camera, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hub.deviceModel ?? '相机',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        connText,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (hub.deviceBattery != null) ...[
                  Icon(
                    hub.deviceBattery! >= 20
                        ? Icons.battery_4_bar
                        : Icons.battery_alert,
                    size: 17,
                    color: cs.onSurfaceVariant,
                  ),
                  Text(
                    '${hub.deviceBattery}%',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                    ),
                  ),
                ],
                if (hub.storageFree != null)
                  Text(
                    '存储卡可用 ${_gb(hub.storageFree!)} GB',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                Text(
                  '${hub.fileCount} 个对象',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: hub.busy ? null : () => _pullAll(context, hub),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('立即拉取全部'),
                  ),
                ),
                TextButton(
                  onPressed: hub.busy ? null : () => hub.disconnect(),
                  child: const Text('断开'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    // 本次自动拉取汇总卡（点击跳传输-已拉取）
    rows.add(
      AppCard(
        flat: true,
        onTap: () {
          transferTabIndex.value = 1;
          homeTabIndex.value = 1;
        },
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '本次自动拉取 · 已入相册「AkihanaMiao」',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${hub.autoCount}',
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const TextSpan(text: ' 张 · '),
                        TextSpan(
                          text: _mb(hub.autoBytes),
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward, size: 16, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
    // 功能入口
    rows.add(
      GroupList(
        rows: [
          ListRow(
            icon: Icons.photo_library_outlined,
            title: '进入相机相册',
            subtitle: _strategySummary(),
            trailing: const Icon(Icons.arrow_forward, size: 16),
            onTap: () => openCameraAlbum(context),
          ),
          ListRow(
            icon: Icons.import_export,
            title: '传输',
            trailing: const Icon(Icons.arrow_forward, size: 16),
            onTap: () => homeTabIndex.value = 1,
          ),
          ListRow(
            icon: Icons.settings_outlined,
            title: '设置',
            trailing: const Icon(Icons.arrow_forward, size: 16),
            onTap: () => homeTabIndex.value = 2,
          ),
        ],
      ),
    );
    rows.add(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(
          '连接：${s.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ),
    );
    return rows;
  }

  String _strategySummary() {
    final cfg = AppConfig.instance;
    final mode = switch (cfg.uploadMode) {
      AppConfig.modeLocalOnly => '仅保存本地',
      AppConfig.modeWifi => '上传 WiFi 环境',
      _ => '立即上传',
    };
    final auto = cfg.autoPull ? '自动开' : '自动关';
    return '拉取 ${cfg.pullTypes.join('/')} · $mode · $auto';
  }

  String _mb(int bytes) {
    final mb = bytes / 1024 / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  String _gb(int bytes) => (bytes / 1024 / 1024 / 1024).toStringAsFixed(1);
}

/// 相机品牌选择：单行 ListRow，点击弹出底部抽屉菜单。
/// 选项 = 自动 + CameraDrivers 注册表品牌（新增品牌零 UI 改动）。
class _BrandSelector extends StatefulWidget {
  const _BrandSelector();

  @override
  State<_BrandSelector> createState() => _BrandSelectorState();
}

class _BrandSelectorState extends State<_BrandSelector> {
  String get _value => AppConfig.instance.brandPreference;

  /// 品牌中文名（新品牌在此补一行即可）
  static String _brandLabel(String brand) => switch (brand) {
    AppConfig.brandNikon => '尼康',
    AppConfig.brandSony => '索尼',
    'canon' => '佳能',
    _ => brand,
  };

  static String _brandDesc(String brand) => switch (brand) {
    AppConfig.brandAuto => '所有品牌自动探测',
    AppConfig.brandNikon => 'WiFi 直连相机热点',
    AppConfig.brandSony => '发送到智能手机',
    _ => '',
  };

  Future<void> _pick() async {
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '选择相机品牌',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              GroupList(
                rows: [
                  for (final brand in [
                    AppConfig.brandAuto,
                    for (final d in CameraDrivers.all) d.brand,
                  ])
                    ListRow(
                      icon: brand == AppConfig.brandAuto
                          ? Icons.auto_awesome_outlined
                          : Icons.photo_camera_outlined,
                      title: brand == AppConfig.brandAuto
                          ? '自动'
                          : _brandLabel(brand),
                      subtitle: _brandDesc(brand),
                      trailing: _value == brand
                          ? Icon(
                              Icons.check_circle,
                              size: 19,
                              color: cs.primary,
                            )
                          : Icon(
                              Icons.radio_button_unchecked,
                              size: 19,
                              color: cs.onSurfaceVariant,
                            ),
                      onTap: () async {
                        Navigator.pop(ctx);
                        if (_value == brand) return;
                        setState(
                          () => AppConfig.instance.brandPreference = brand,
                        );
                        await AppConfig.instance.save();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = _value == AppConfig.brandAuto ? '自动' : _brandLabel(_value);
    return GroupList(
      rows: [
        ListRow(
          icon: Icons.photo_camera_outlined,
          title: '相机品牌',
          subtitle: '$label · ${_brandDesc(_value)}',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.expand_more,
                size: 17,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          onTap: _pick,
        ),
      ],
    );
  }
}
