import 'package:flutter/material.dart';

import '../core/app_build_info.dart';

/// Debug 构建的角落小角标（如「DEV」）。
///
/// release 构建里不会渲染此组件（调用处由 [AppBuildInfo.isDebug] 短路，
/// 编译期常量使整段 UI 被裁剪，不进入正式包）。
class DevBadge extends StatelessWidget {
  const DevBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'DEV',
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: cs.onErrorContainer,
        ),
      ),
    );
  }
}
