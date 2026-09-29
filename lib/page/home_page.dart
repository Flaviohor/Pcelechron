import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' show Icons;
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:celechron/page/scholar/scholar_view.dart';
import 'package:celechron/page/flow/flow_view.dart';
import 'package:celechron/page/task/task_view.dart';
import 'package:celechron/page/calendar/calendar_view.dart';
import 'package:celechron/page/option/option_view.dart';

import 'package:celechron/worker/fuse.dart';
import 'package:celechron/design/glass.dart';
import 'package:celechron/utils/platform_features.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.title});

  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _indexNum = 0;
  final PageController _pageController = PageController();

  // 只构建一次，保持各页 widget 身份稳定，切页时不会重跑各页构造器里的 Get.put
  late final List<Widget> _pages = [
    _KeepAlivePage(child: FlowPage()),
    _KeepAlivePage(child: CalendarPage()),
    _KeepAlivePage(child: TaskPage()),
    _KeepAlivePage(child: ScholarPage()),
    _KeepAlivePage(child: OptionPage()),
  ];

  @override
  void initState() {
    super.initState();
    initFuse();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 桌面端切换到侧边导航的宽度阈值。
  static const double desktopBreakpoint = 700;

  @override
  Widget build(BuildContext context) {
    final useSidebar = PlatformFeatures.isDesktop &&
        MediaQuery.of(context).size.width >= desktopBreakpoint;
    return useSidebar ? _buildSidebarLayout(context) : _buildTabLayout(context);
  }

  /// 桌面宽屏布局：悬浮侧栏胶囊 + 内容区。
  ///
  /// 底部标签栏是按手机竖屏设计的，在 1000+ 宽度的窗口里横向拉伸后留白过多，
  /// 所以宽屏改成悬浮侧导航。侧栏本身用液态玻璃材质、距离窗口左边缘 12px、
  /// 距上下 24px；主内容区左侧让出 100px（76 侧栏 + 12 间距 + 12 缓冲），
  /// 保证悬浮胶囊不会盖在 page 顶部 large title 上。
  Widget _buildSidebarLayout(BuildContext context) {
    final ScrollBehavior scrollBehavior = ScrollConfiguration.of(context);
    const double sidebarWidth = 76;
    const double sidebarLeft = 12;
    const double contentLeftGap = sidebarWidth + sidebarLeft + 12; // 100
    final Widget content = Padding(
      padding: const EdgeInsets.only(left: contentLeftGap),
      child: HeroMode(
        enabled: false,
        child: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(),
          onPageChanged: (index) {
            if (index != _indexNum) {
              setState(() {
                _indexNum = index;
              });
            }
          },
          scrollBehavior: scrollBehavior.copyWith(scrollbars: false),
          children: _pages,
        ),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(child: content),
        Positioned(
          left: sidebarLeft,
          top: 24,
          bottom: 24,
          child: _SidebarNav(
            currentIndex: _indexNum,
            onSelected: (int index) => _pageController.jumpToPage(index),
          ),
        ),
      ],
    );
  }

  /// 手机竖屏布局：底部标签栏 + 可横向拖动切页。
  Widget _buildTabLayout(BuildContext context) {
    final tabBar = CupertinoTabBar(
      iconSize: 26,
      backgroundColor: CupertinoDynamicColor.resolve(
              CupertinoColors.secondarySystemBackground, context)
          .withValues(alpha: 0.5),
      items: const <BottomNavigationBarItem>[
        BottomNavigationBarItem(
          icon: Icon(CupertinoIcons.time),
          label: '接下来',
        ),
        BottomNavigationBarItem(
          icon: Icon(CupertinoIcons.calendar),
          label: '日程',
        ),
        BottomNavigationBarItem(
          icon: Icon(CupertinoIcons.check_mark),
          label: '任务',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.school_rounded),
          label: '学业',
        ),
        BottomNavigationBarItem(
          icon: Icon(CupertinoIcons.settings),
          label: '设置',
        ),
      ],
      currentIndex: _indexNum,
      // 点按瞬时切换（iOS 原生习惯）。jumpToPage 会同步触发 onPageChanged，
      // _indexNum 只在 onPageChanged 里更新，这里不再 setState
      onTap: (int index) => _pageController.jumpToPage(index),
    );

    final ScrollBehavior scrollBehavior = ScrollConfiguration.of(context);
    // HeroMode 关闭：原先嵌套 CupertinoTabView 导航器会屏蔽标签页内的 Hero
    // 飞行动画（如学业页成绩卡片），这里显式关闭以保持原有行为
    Widget content = HeroMode(
      enabled: false,
      child: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          if (index != _indexNum) {
            setState(() {
              _indexNum = index;
            });
          }
        },
        // 允许鼠标拖动切页（与原 GestureDetector 行为一致），只作用于本 PageView，
        // 不影响页面内部列表；scrollbars 必须关掉，否则桌面端会叠一条横向滚动条
        scrollBehavior: scrollBehavior.copyWith(
          scrollbars: false,
          dragDevices: {
            ...scrollBehavior.dragDevices,
            PointerDeviceKind.mouse,
          },
        ),
        children: _pages,
      ),
    );

    // 以下复刻 CupertinoTabScaffold（resizeToAvoidBottomInset: true）的布局逻辑：
    // 键盘高度转为内容 Padding 并从子 MediaQuery 移除；本应用标签栏为半透明
    // （alpha 0.5），栏高只注入 MediaQuery.padding，内容延伸到栏后方由各页
    // SafeArea 自行避让
    final MediaQueryData existingMediaQuery = MediaQuery.of(context);
    MediaQueryData newMediaQuery =
        existingMediaQuery.removeViewInsets(removeBottom: true);
    final EdgeInsets contentPadding =
        EdgeInsets.only(bottom: existingMediaQuery.viewInsets.bottom);

    // 键盘完全盖住标签栏时不再为栏高留白
    if (tabBar.preferredSize.height > existingMediaQuery.viewInsets.bottom) {
      final double bottomPadding =
          tabBar.preferredSize.height + existingMediaQuery.padding.bottom;
      newMediaQuery = newMediaQuery.copyWith(
        padding: newMediaQuery.padding.copyWith(bottom: bottomPadding),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        // 桌面端内容区透明，让 AppBackdrop 透到玻璃后面；移动端保持主题背景。
        color: PlatformFeatures.isDesktop
            ? const Color(0x00000000)
            : CupertinoTheme.of(context).scaffoldBackgroundColor,
      ),
      child: Stack(
        children: [
          // 内容在下层，半透明标签栏的 BackdropFilter 才有内容可模糊
          MediaQuery(
            data: newMediaQuery,
            child: Padding(padding: contentPadding, child: content),
          ),
          // 标签栏放在修改后的 MediaQuery 之外，读原始 viewPadding 计算安全区
          MediaQuery.withNoTextScaling(
            child: Align(alignment: Alignment.bottomCenter, child: tabBar),
          ),
        ],
      ),
    );
  }

  Future<void> initFuse() async {
    await Future.delayed(const Duration(seconds: 1));
    var fuse = Get.find<Rx<Fuse>>(tag: 'fuse');
    var response =
        await fuse.value.checkUpdate().whenComplete(() => fuse.refresh());
    if (response != null) {
      if (!mounted) return;
      showCupertinoDialog(
          context: context,
          builder: (context) {
            return CupertinoAlertDialog(
              title: const Text('更新可用'),
              content: Text(response),
              actions: [
                CupertinoDialogAction(
                  child: const Text('忽略'),
                  onPressed: () async {
                    Navigator.of(context).pop();
                  },
                ),
                CupertinoDialogAction(
                  child: const Text('访问网站'),
                  onPressed: () async {
                    await launchUrlString(
                      'https://celechron.top',
                      mode: LaunchMode.externalApplication,
                    );
                  },
                ),
              ],
            );
          });
    }
  }
}

// 离屏页面保活：保留滚动位置等临时状态，等价于原先 CupertinoTabScaffold
// 对已构建标签页的常驻行为
/// 桌面端左侧导航栏。用 Cupertino 组件手写而不用 Material 的 NavigationRail，
/// 桌面端悬浮侧栏：液态玻璃胶囊 + 选中态主题色内嵌高亮。
///
/// 与原贴边侧栏（92px 宽）的差异：
///   - 距左 12 / 上下 24，距离窗口边缘都有呼吸感；
///   - 圆角 22，整体看起来像一颗浮岛；
///   - 选中态用主题色 GlassPill 内嵌，不再依赖文字/图标变色；
///   - 移动端不调用（仅 `_buildSidebarLayout` 使用）。
class _SidebarNav extends StatelessWidget {
  const _SidebarNav({required this.currentIndex, required this.onSelected});

  final int currentIndex;
  final ValueChanged<int> onSelected;

  static const List<(IconData, String)> items = <(IconData, String)>[
    (CupertinoIcons.time, '接下来'),
    (CupertinoIcons.calendar, '日程'),
    (CupertinoIcons.check_mark, '任务'),
    (Icons.school_rounded, '学业'),
    (CupertinoIcons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      child: Glass.island(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        child: SafeArea(
          child: Column(
            children: [
              for (var i = 0; i < items.length; i++)
                _SidebarItem(
                  icon: items[i].$1,
                  label: items[i].$2,
                  selected: i == currentIndex,
                  onTap: () => onSelected(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    final Color accent = theme.primaryColor;
    final Color normalColor =
        CupertinoDynamicColor.resolve(CupertinoColors.systemGrey, context);
    final Color tint = selected ? accent : normalColor;
    final Widget inner = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: tint, size: 22),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: tint,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: SizedBox(
          width: double.infinity,
          child: selected
              ? GlassPill(color: accent, child: inner)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Center(child: inner),
                ),
        ),
      ),
    );
  }
}

class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
