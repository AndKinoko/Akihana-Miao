import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../cameras/camera_hub.dart';
import 'theme.dart';

/// iOS 风格组件库（对照 demo index.html 的 .card/.lrow/.chip/.pill/.seg/.selbar 等）

/// 大标题页头
class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.trailing});
  final String title;
  final List<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
            ),
          ),
          ...?trailing,
        ],
      ),
    );
  }
}

/// 分组标题
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.4,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// iOS 卡片（.card / .card.flat）
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.flat = false,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final bool flat;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final card = Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: padding,
      decoration: BoxDecoration(
        color: flat ? cs.surfaceContainerHigh : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: flat ? null : Border.all(color: cs.outline),
      ),
      child: child,
    );
    if (onTap == null) return card;
    return GestureDetector(onTap: onTap, child: card);
  }
}

/// 分组列表（.list > .lrow）：圆角边框容器 + 行分割线
class GroupList extends StatelessWidget {
  const GroupList({super.key, required this.rows});
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: cs.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            rows[i],
            if (i < rows.length - 1)
              Divider(height: 1, indent: 16, color: cs.outline),
          ],
        ],
      ),
    );
  }
}

/// 分组列表行（.lrow）：leading 图标 + 标题/副标题 + trailing
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    this.icon,
    this.iconColor,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });
  final IconData? icon;
  final Color? iconColor;
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 防抖：同一行 300ms 内的重复点击只算一次
  static DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _handleTap() async {
    final now = DateTime.now();
    if (now.difference(_lastTap) < const Duration(milliseconds: 300)) return;
    _lastTap = now;
    // 先让点击高亮（水波纹）播完再执行动作，
    // 否则页面立即跳转、动画却留在原地播放（脱节）
    await Future<void>.delayed(const Duration(milliseconds: 150));
    onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap == null ? null : _handleTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            if (icon != null) ...[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: (iconColor ?? cs.primary).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 17, color: iconColor ?? cs.primary),
              ),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(
                      title!,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );
  }
}

/// iOS 开关（绿色圆角，.sw）；onChanged 为 null 时只读
class IosSwitch extends StatelessWidget {
  const IosSwitch({super.key, required this.value, this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 0.85,
      child: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// 状态 chip（.chip.ok/.warn/.err）
class StatusChip extends StatelessWidget {
  const StatusChip.ok(this.text, {super.key})
    : _color = const Color(0xFF30D158);
  const StatusChip.warn(this.text, {super.key})
    : _color = const Color(0xFFFF9F0A);
  const StatusChip.err(this.text, {super.key})
    : _color = const Color(0xFFFF453A);
  const StatusChip.info(this.text, {super.key}) : _color = null;
  final String text;
  final Color? _color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _color ?? cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}

/// 呼吸灯状态 pill（.pill.ok：绿点脉冲 + 文案）
/// 连接状态点：状态色实心圆 + 外围一圈半透明光环。
/// 放在页标题文字右边。
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.on, this.pulse = true});
  final bool on;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final color = on ? const Color(0xFF30D158) : const Color(0xFF636366);
    return Container(
      // 光环：状态色半透明描边一圈
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.35), width: 2),
      ),
      child: on && pulse
          ? _PulsingDot(color: color)
          : Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
    );
  }
}

class PulsePill extends StatelessWidget {
  const PulsePill({super.key, required this.text, this.off = false});
  final String text;
  final bool off;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = off ? cs.onSurfaceVariant : const Color(0xFF30D158);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!off) ...[_PulsingDot(color: color), const SizedBox(width: 5)],
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 带计数的分段控件（.seg：圆角容器 + 浮起选中块）
class CountedSegmentedTabs extends StatelessWidget {
  const CountedSegmentedTabs({
    super.key,
    required this.labels,
    required this.counts,
    required this.index,
    required this.onChanged,
  });
  final List<String> labels;
  final List<int> counts;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: i == index
                        ? cs.surfaceContainerLow
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: i == index
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          labels[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: i == index
                                ? cs.onSurface
                                : cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${counts[i]}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: counts[i] > 0
                              ? cs.primary
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 细进度条（.pbar）
class ThinProgressBar extends StatelessWidget {
  const ThinProgressBar({
    super.key,
    required this.value,
    this.height = 4,
    this.color,
  });
  final double value; // 0~1；负值 = 不定态
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: value < 0 ? null : value.clamp(0.0, 1.0),
        minHeight: height,
        color: color ?? cs.primary,
        backgroundColor: cs.surfaceContainerHigh,
      ),
    );
  }
}

/// 悬浮选择面板：所有多选场景统一使用（相机相册批量拉取、已拉取批量上传）。
/// 浮于内容之上的单行圆角卡片：全选 / 取消 / 主操作（拉取/上传）。
/// 底部留出系统手势条/三大金刚键的安全距离（沉浸式适配）。
class SelectionPanel extends StatelessWidget {
  const SelectionPanel({
    super.key,
    required this.count,
    required this.allSelected,
    required this.primaryLabel,
    this.primaryIcon = Icons.download,
    required void Function() onSelectAll,
    required void Function() onCancel,
    required this.onPrimary,
  }) : _onSelectAll = onSelectAll,
       _onCancel = onCancel;

  final int count;
  final bool allSelected;
  final String primaryLabel;
  final IconData primaryIcon; // 拉取场景 download，上传场景 upload
  final VoidCallback _onSelectAll;
  final VoidCallback _onCancel;
  final VoidCallback onPrimary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      margin: EdgeInsets.fromLTRB(12, 0, 12, 12 + safeBottom),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: cs.outline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _onSelectAll,
              icon: Icon(
                allSelected ? Icons.deselect : Icons.select_all,
                size: 17,
              ),
              label: const Text('全选'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: _onCancel,
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: count == 0 ? null : onPrimary,
              icon: Icon(primaryIcon, size: 17),
              label: Text(primaryLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// 毛玻璃底部悬浮选择栏（.selbar）
class GlassBar extends StatelessWidget {
  const GlassBar({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow.withValues(alpha: 0.85),
            border: Border(top: BorderSide(color: cs.outline)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: child,
        ),
      ),
    );
  }
}

/// 空态（.empty-state：圆底图标 + 标题 + 说明）
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.padding = const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 34, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 全局 Toast：持久 OverlayEntry，消息原地淡入替换。
/// 旧实现每次 show 都销毁重建 entry，快速连弹时两个药丸叠影（双下横线）。
class AppToast {
  AppToast._();

  static OverlayEntry? _entry;
  static final ValueNotifier<String?> _message = ValueNotifier(null);
  static Timer? _hideTimer;

  static void show(BuildContext context, String message) {
    final overlay = Overlay.of(context, rootOverlay: true);
    if (_entry == null) {
      _entry = OverlayEntry(builder: (_) => const _ToastView());
      overlay.insert(_entry!);
    }
    _hideTimer?.cancel();
    _message.value = message;
    _hideTimer = Timer(const Duration(milliseconds: 1800), () {
      _message.value = null;
    });
  }
}

class _ToastView extends StatelessWidget {
  const _ToastView();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 12,
      left: 0,
      right: 0,
      // 必须包 Material：OverlayEntry 没有 Material 祖先时，
      // Text 会落到回退样式（黄色双下划线）
      child: Material(
        type: MaterialType.transparency,
        child: IgnorePointer(
          child: ValueListenableBuilder<String?>(
            valueListenable: AppToast._message,
            builder: (context, msg, _) {
              final visible = msg != null;
              return AnimatedSlide(
                offset: visible ? Offset.zero : const Offset(0, -0.5),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Align(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      child: msg == null
                          ? const SizedBox.shrink(key: ValueKey('empty'))
                          : Container(
                              key: ValueKey(msg),
                              margin: const EdgeInsets.symmetric(
                                horizontal: 60,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF323232,
                                ).withValues(alpha: 0.95),
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.18),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Text(
                                msg,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 连接过渡浮层：转圈 + 「正在连接相机…」；失败时展示原因 + 重试/取消。
class ConnectOverlay extends StatelessWidget {
  const ConnectOverlay({
    super.key,
    required this.phase,
    this.failReason = '',
    required this.onRetry,
    required this.onCancel,
  });

  final ConnectPhase phase;
  final String failReason;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final failed = phase == ConnectPhase.failed;
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 40),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            decoration: BoxDecoration(
              // 与主界面卡片一致：surfaceContainerLow + radiusMd 圆角 + outline 边框
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: cs.outline),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: failed
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 30, color: cs.error),
                      const SizedBox(height: 10),
                      Text(
                        failReason,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: cs.error,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: onCancel,
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: onRetry,
                              icon: const Icon(Icons.refresh, size: 17),
                              label: const Text('重试'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 34,
                        height: 34,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '正在连接相机…',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton(onPressed: onCancel, child: const Text('取消')),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 主题切换按钮（页头圆形按钮）
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) => IconButton(
        onPressed: () => ThemeController.instance.toggle(),
        icon: Icon(
          mode == ThemeMode.dark
              ? Icons.dark_mode_outlined
              : Icons.light_mode_outlined,
          size: 21,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        ),
      ),
    );
  }
}

/// iOS 单选行（.radio：圆点 + 标题/副标题）
class IosRadioRow extends StatelessWidget {
  const IosRadioRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(color: cs.outline),
        ),
        child: Row(
          children: [
            Container(
              width: 21,
              height: 21,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? cs.primary : cs.outline,
                  width: 2,
                ),
                color: selected ? cs.primary : Colors.transparent,
              ),
              child: selected
                  ? const Icon(Icons.check, size: 13, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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

/// iOS 多选行（.ckrow：方框勾选）
class IosCheckRow extends StatelessWidget {
  const IosCheckRow({
    super.key,
    required this.title,
    required this.checked,
    this.trailing,
    required this.onToggle,
  });
  final String title;
  final bool checked;
  final String? trailing;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 21,
              height: 21,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: checked ? cs.primary : cs.outline,
                  width: 2,
                ),
                color: checked ? cs.primary : Colors.transparent,
              ),
              child: checked
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 14))),
            if (trailing != null)
              Text(
                trailing!,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}
