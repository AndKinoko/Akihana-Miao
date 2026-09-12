import 'package:flutter/material.dart';

/// RAW 角标（相机页/传输页共用）
class RawBadge extends StatelessWidget {
  const RawBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text('RAW',
          style: TextStyle(
              color: Colors.amberAccent,
              fontSize: 9,
              fontWeight: FontWeight.bold)),
    );
  }
}

/// 缩略图未加载/LOD 未请求时的占位
class ThumbPlaceholder extends StatelessWidget {
  const ThumbPlaceholder({this.pending = false, super.key});

  /// true = 排队等待（LOD 未到批次）；false = 加载中
  final bool pending;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: pending
          ? Icon(Icons.image_outlined,
              size: 24, color: Theme.of(context).hintColor)
          : const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }
}
