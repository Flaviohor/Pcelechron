import 'package:flutter/cupertino.dart';

import 'package:celechron/design/glass.dart';

/// 二级界面的统一转场：淡入 + 轻微上移，路由自身铺一层环境光背景。
///
/// 为什么要换掉 Cupertino 横向滑动：二级页的脚手架是透明的（为了透出
/// 液态玻璃背景），滑动转场时新页面还没有滑到的区域会露出旧页面，
/// 看起来像「旧页面残留一半后突然消失」。改为不透明的本路由环境光 +
/// 交叉淡入，旧页面被整体盖住，观感干净且与全应用玻璃风格一致。
class GlassPageRoute<T> extends PageRouteBuilder<T> {
  /// [title] 仅为兼容 CupertinoPageRoute 的调用点（iOS 任务切换器标题，
  /// 桌面端不使用）；[fullscreenDialog] 让入场改为自下而上的轻浮动。
  GlassPageRoute({
    required WidgetBuilder builder,
    super.settings,
    String? title,
    bool fullscreenDialog = false,
  }) : super(
          transitionDuration: const Duration(milliseconds: 280),
          reverseTransitionDuration: const Duration(milliseconds: 240),
          pageBuilder: (context, animation, secondaryAnimation) =>
              AppBackdrop(child: builder(context)),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: fullscreenDialog
                      ? const Offset(0, 0.06)
                      : const Offset(0, 0.025),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        );
}
