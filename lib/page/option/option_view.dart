import 'package:celechron/utils/platform_features.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher_string.dart';

import 'package:celechron/utils/utils.dart';
import 'package:celechron/model/option.dart';
import 'package:celechron/design/cupertino_async_switch.dart';
import 'package:celechron/design/glass.dart';

import 'allow_time_edit_page.dart';
import 'course_id_mapping_edit_page.dart';
import 'credits_page.dart';
import 'diagnostic_log_page.dart';
import 'package:get/get.dart';
import 'custom_license_page.dart';
import 'login_page.dart';
import 'option_controller.dart';
import 'update_sheet.dart';
import 'package:celechron/services/app_update_service.dart';

const Color _kHeaderFooterColor = CupertinoDynamicColor(
  color: Color.fromRGBO(108, 108, 108, 1.0),
  darkColor: Color.fromRGBO(142, 142, 146, 1.0),
  highContrastColor: Color.fromRGBO(74, 74, 77, 1.0),
  darkHighContrastColor: Color.fromRGBO(176, 176, 183, 1.0),
  elevatedColor: Color.fromRGBO(108, 108, 108, 1.0),
  darkElevatedColor: Color.fromRGBO(142, 142, 146, 1.0),
  highContrastElevatedColor: Color.fromRGBO(108, 108, 108, 1.0),
  darkHighContrastElevatedColor: Color.fromRGBO(142, 142, 146, 1.0),
);

class OptionPage extends StatelessWidget {
  final _optionController =
      Get.put(OptionController(), tag: 'optionController');
  final _updateController = Get.put(AppUpdateController(), tag: 'appUpdate');

  OptionPage({super.key});

  @override
  Widget build(BuildContext context) {
    var trailingTextStyle = TextStyle(
        color: CupertinoDynamicColor.resolve(
            CupertinoColors.secondaryLabel, context),
        fontSize: 16);

    var headerFooterTextStyle = CupertinoTheme.of(context)
        .textTheme
        .textStyle
        .merge(TextStyle(
            fontSize: 13.0,
            color:
                CupertinoDynamicColor.resolve(_kHeaderFooterColor, context)));

    return CupertinoPageScaffold(
        backgroundColor: const Color(0x00000000),
        child: SafeArea(
            child: CustomScrollView(
          slivers: [
            const CupertinoSliverNavigationBar(
              largeTitle: Text('设置'),
              backgroundColor: Color(0x00000000),
              border: null,
            ),
            // 教务
            Obx(() => SliverToBoxAdapter(
                    child: GlassCard(
                  margin: _defaultMargin,
                  child: CupertinoListSection.insetGrouped(
                    backgroundColor: Color(0x00000000),
                    decoration: const BoxDecoration(color: Color(0x00000000)),
                    additionalDividerMargin: 2,
                    header: Container(
                        padding: const EdgeInsets.only(left: 16),
                        child: Text('教务', style: headerFooterTextStyle)),
                    footer: (_optionController.pushOnGradeChange ||
                                _optionController.pushOnDdlReminder) &&
                            _optionController.scholar.value.isLogan
                        ? Padding(
                            padding: const EdgeInsets.only(left: 16),
                            child: Text(
                                'PCelechron 将不定期自动运行以刷新数据。请开启通知权限，且不要将 PCelechron 从后台中移除。',
                                style: headerFooterTextStyle))
                        : null,
                    children: <CupertinoListTile>[
                      if (_optionController.scholar.value.isLogan) ...{
                        CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: Text(
                                '已登录: ${_optionController.scholar.value.username}'),
                            trailing: BackChervonRow(
                                child: Text('退出',
                                    style: TextStyle(
                                        color: CupertinoDynamicColor.resolve(
                                            CupertinoColors.secondaryLabel,
                                            context),
                                        fontSize: 16))),
                            onTap: () async {
                              await showCupertinoDialog(
                                  context: context,
                                  builder: (BuildContext dialogContext) {
                                    return CupertinoAlertDialog(
                                      title: const Text('退出登录'),
                                      content: const Text('确定要退出当前账号吗？'),
                                      actions: [
                                        CupertinoDialogAction(
                                          child: const Text('取消'),
                                          onPressed: () {
                                            Navigator.of(dialogContext).pop();
                                          },
                                        ),
                                        CupertinoDialogAction(
                                          isDestructiveAction: true,
                                          child: const Text('退出'),
                                          onPressed: () async {
                                            Navigator.of(dialogContext).pop();
                                            await _optionController.logout();
                                          },
                                        ),
                                      ],
                                    );
                                  });
                            }),
                        CupertinoListTile(
                          backgroundColor: const Color(0x00000000),
                          title: const Text('重修绩点计算'),
                          trailing: CupertinoSlidingSegmentedControl(
                            children: {
                              GpaStrategy.first: Text('取首次',
                                  style: CupertinoTheme.of(context)
                                      .textTheme
                                      .textStyle
                                      .copyWith(fontSize: 16)),
                              GpaStrategy.best: Text('取最高',
                                  style: CupertinoTheme.of(context)
                                      .textTheme
                                      .textStyle
                                      .copyWith(fontSize: 16)),
                            },
                            groupValue: _optionController.gpaStrategy,
                            onValueChanged: (value) {
                              _optionController.gpaStrategy = value!;
                            },
                          ),
                        ),
                        CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('隐藏绩点'),
                            trailing: Obx(() => CupertinoSwitch(
                                  value: _optionController.hideHomeGpa,
                                  onChanged: (value) async {
                                    _optionController.hideHomeGpa = value;
                                  },
                                ))),
                        CupertinoListTile(
                          backgroundColor: const Color(0x00000000),
                          title: const Text('自定义课程代码映射'),
                          trailing: const BackChervonRow(),
                          onTap: () async {
                            Navigator.of(context, rootNavigator: true).push(
                                CupertinoPageRoute(
                                    builder: (context) =>
                                        CourseIdMappingEditPage()));
                          },
                        ),
                        CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('异步刷新'),
                            trailing: Obx(() => CupertinoSwitch(
                                  value: _optionController.asyncRefresh,
                                  onChanged: (value) async {
                                    _optionController.asyncRefresh = value;
                                  },
                                ))),
                        CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('推送成绩变动'),
                            trailing: CupertinoSwitch(
                              value: _optionController.pushOnGradeChange,
                              onChanged: PlatformFeatures.hasBackgroundRefresh
                                  ? (value) async {
                                      _optionController.pushOnGradeChange =
                                          value;
                                    }
                                  : null,
                            )),
                        CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('推送作业截止提醒'),
                            trailing: CupertinoSwitch(
                              value: _optionController.pushOnDdlReminder,
                              onChanged: PlatformFeatures.hasBackgroundRefresh
                                  ? (value) async {
                                      _optionController.pushOnDdlReminder =
                                          value;
                                    }
                                  : null,
                            )),
                        CupertinoListTile(
                          backgroundColor: const Color(0x00000000),
                          title: const Text('发送测试通知'),
                          subtitle: const Text('验证系统通知是否可正常弹出'),
                          trailing: const BackChervonRow(),
                          onTap: () async {
                            try {
                              await _optionController.sendTestNotification();
                            } on Object catch (error) {
                              if (!context.mounted) return;
                              await showCupertinoDialog(
                                  context: context,
                                  builder: (dialogContext) {
                                    return CupertinoAlertDialog(
                                      title: const Text('通知发送失败'),
                                      content: Text('$error'),
                                      actions: [
                                        CupertinoDialogAction(
                                          child: const Text('好'),
                                          onPressed: () =>
                                              Navigator.of(dialogContext).pop(),
                                        ),
                                      ],
                                    );
                                  });
                            }
                          },
                        ),
                      } else ...{
                        CupertinoListTile(
                          backgroundColor: const Color(0x00000000),
                          title: const Text('点击登录',
                              style:
                                  TextStyle(color: CupertinoColors.activeBlue)),
                          trailing: const BackChervonRow(
                            child: Text(''),
                          ),
                          onTap: () async {
                            // Pop up a login widget from the bottom of the screen
                            showCupertinoModalPopup(
                                context: context,
                                builder: (BuildContext context) {
                                  return LoginForm();
                                });
                          },
                        ),
                      },
                    ],
                  ),
                ))),
            // 时间规划
            SliverToBoxAdapter(
                child: GlassCard(
                    margin: _defaultMargin,
                    child: CupertinoListSection.insetGrouped(
                        backgroundColor: Color(0x00000000),
                        decoration:
                            const BoxDecoration(color: Color(0x00000000)),
                        additionalDividerMargin: 2,
                        header: Container(
                            padding: const EdgeInsets.only(left: 16),
                            child: Text('时间规划', style: headerFooterTextStyle)),
                        children: <CupertinoListTile>[
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('工作段时间长度'),
                            trailing: BackChervonRow(
                                child: Obx(() => Text(
                                    durationToString(
                                        _optionController.workTime),
                                    style: TextStyle(
                                        color: CupertinoDynamicColor.resolve(
                                            CupertinoColors.secondaryLabel,
                                            context),
                                        fontSize: 16)))),
                            onTap: () async {
                              Duration newWorkTime = _optionController.workTime;
                              await showCupertinoDialog(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return CupertinoAlertDialog(
                                      title: const Text(
                                        '工作段时间长度',
                                      ),
                                      content: SizedBox(
                                        width: double.maxFinite,
                                        height: 200,
                                        child: Column(
                                          children: [
                                            Expanded(
                                              child: CupertinoTimerPicker(
                                                mode:
                                                    CupertinoTimerPickerMode.hm,
                                                minuteInterval: 5,
                                                initialTimerDuration:
                                                    newWorkTime,
                                                onTimerDurationChanged:
                                                    (value) {
                                                  if (value >=
                                                      const Duration(
                                                          minutes: 5)) {
                                                    newWorkTime = value;
                                                  } else {
                                                    newWorkTime =
                                                        const Duration(
                                                            minutes: 5);
                                                  }
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      actions: [
                                        CupertinoDialogAction(
                                          child: const Text('确定'),
                                          onPressed: () async {
                                            Navigator.of(context).pop();
                                          },
                                        )
                                      ],
                                    );
                                  });
                              _optionController.workTime = newWorkTime;
                            },
                          ),
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('休息段时间长度'),
                            trailing: BackChervonRow(
                                child: Obx(() => Text(
                                    durationToString(
                                        _optionController.restTime),
                                    style: trailingTextStyle))),
                            onTap: () async {
                              Duration newRestTime = _optionController.restTime;
                              await showCupertinoDialog(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return CupertinoAlertDialog(
                                      title: const Text(
                                        '休息段时间长度',
                                      ),
                                      content: SizedBox(
                                        width: double.maxFinite,
                                        height: 200,
                                        child: Column(
                                          children: [
                                            Expanded(
                                              child: CupertinoTimerPicker(
                                                mode:
                                                    CupertinoTimerPickerMode.hm,
                                                initialTimerDuration:
                                                    newRestTime,
                                                onTimerDurationChanged:
                                                    (value) {
                                                  newRestTime = value;
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      actions: [
                                        CupertinoDialogAction(
                                          child: const Text('确定'),
                                          onPressed: () async {
                                            Navigator.of(context).pop();
                                          },
                                        )
                                      ],
                                    );
                                  });
                              _optionController.restTime = newRestTime;
                            },
                          ),
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('可用的工作时段'),
                            trailing: BackChervonRow(
                                child: Obx(() => Text(
                                    '${_optionController.allowTimeLength} 个时段',
                                    style: trailingTextStyle))),
                            onTap: () async {
                              await Navigator.of(context, rootNavigator: true)
                                  .push(CupertinoPageRoute(
                                builder: (context) => const AllowTimeEditPage(),
                              ));
                            },
                          ),
                        ]))),
            // 日程
            SliverToBoxAdapter(
                child: GlassCard(
                    margin: _defaultMargin,
                    child: CupertinoListSection.insetGrouped(
                        backgroundColor: Color(0x00000000),
                        decoration:
                            const BoxDecoration(color: Color(0x00000000)),
                        additionalDividerMargin: 2,
                        header: Container(
                            padding: const EdgeInsets.only(left: 16),
                            child: Text('日程', style: headerFooterTextStyle)),
                        children: [
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('导出为iCal文件'),
                            trailing: const BackChervonRow(),
                            onTap: () =>
                                _optionController.showExportDialog(context),
                          ),
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('导入iCal为日程'),
                            subtitle: const Text('选择 .ics 文件，按 UID 去重'),
                            trailing: const BackChervonRow(),
                            onTap: () => _showImportResult(
                                context, _optionController.importIcal()),
                          ),
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('导出待办JSON'),
                            subtitle: const Text('备份全部任务到 JSON 文件'),
                            trailing: const BackChervonRow(),
                            onTap: () async {
                              final count =
                                  await _optionController.exportTasksJson();
                              if (count == null || !context.mounted) return;
                              await showCupertinoDialog(
                                  context: context,
                                  builder: (dialogContext) {
                                    return CupertinoAlertDialog(
                                      title: const Text('导出完成'),
                                      content: Text('已导出 $count 条任务。'),
                                      actions: [
                                        CupertinoDialogAction(
                                          child: const Text('好'),
                                          onPressed: () =>
                                              Navigator.of(dialogContext).pop(),
                                        ),
                                      ],
                                    );
                                  });
                            },
                          ),
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('导入待办JSON'),
                            subtitle: const Text('按 UID 合并，已删除的不复活'),
                            trailing: const BackChervonRow(),
                            onTap: () => _showImportResult(
                                context, _optionController.importTasksJson()),
                          ),
                        ]))),
            // 工具
            SliverToBoxAdapter(
                child: GlassCard(
                    margin: _defaultMargin,
                    child: CupertinoListSection.insetGrouped(
                        backgroundColor: Color(0x00000000),
                        decoration:
                            const BoxDecoration(color: Color(0x00000000)),
                        additionalDividerMargin: 2,
                        header: Container(
                            padding: const EdgeInsets.only(left: 16),
                            child: Text('工具', style: headerFooterTextStyle)),
                        children: <Widget>[
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('暗色模式'),
                            trailing: BackChervonRow(
                                child: Obx(() => Text(
                                      _optionController.brightnessMode ==
                                              BrightnessMode.system
                                          ? "跟随系统设置"
                                          : _optionController.brightnessMode ==
                                                  BrightnessMode.light
                                              ? "亮色模式"
                                              : "暗色模式",
                                      style: trailingTextStyle,
                                    ))),
                            onTap: () => _showBrightnessPicker(context),
                          ),
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('付款码'),
                            trailing: const BackChervonRow(),
                            onTap: () async {
                              Navigator.of(context, rootNavigator: true)
                                  .pushNamed('/ecardpaypage');
                            },
                          ),
                          CupertinoListTile(
                            backgroundColor: const Color(0x00000000),
                            title: const Text('关闭时驻留托盘'),
                            subtitle: const Text('关窗不退出，后台刷新与通知继续工作'),
                            trailing: Obx(() => CupertinoSwitch(
                                  value: _optionController.closeToTray,
                                  onChanged: (value) async {
                                    _optionController.closeToTray = value;
                                  },
                                )),
                          ),
                        ]))),
            // 关于
            SliverToBoxAdapter(
                child: GlassCard(
              margin: _defaultMargin,
              child: CupertinoListSection.insetGrouped(
                backgroundColor: Color(0x00000000),
                decoration: const BoxDecoration(color: Color(0x00000000)),
                additionalDividerMargin: 2,
                header: Container(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text('诊断与测试', style: headerFooterTextStyle),
                ),
                children: [
                  CupertinoListTile(
                    backgroundColor: const Color(0x00000000),
                    title: const Text('测试日志'),
                    subtitle: const Text('查看、复制或导出脱敏 TXT'),
                    trailing: const BackChervonRow(),
                    onTap: () {
                      Navigator.of(context, rootNavigator: true).push(
                        CupertinoPageRoute(
                          builder: (context) => DiagnosticLogPage(
                            version: _optionController.celechronVersion,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            )),
            // 关于
            SliverToBoxAdapter(
                child: GlassCard(
              margin: _defaultMargin,
              child: CupertinoListSection.insetGrouped(
                  backgroundColor: Color(0x00000000),
                  decoration: const BoxDecoration(color: Color(0x00000000)),
                  additionalDividerMargin: 2,
                  header: Container(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text('关于', style: headerFooterTextStyle)),
                  children: <CupertinoListTile>[
                    CupertinoListTile(
                      backgroundColor: const Color(0x00000000),
                      title: const Text('检查更新'),
                      subtitle: Obx(() => Text(_updateController.subtitleText)),
                      trailing: const BackChervonRow(),
                      onTap: () => _showUpdateSheet(context),
                    ),
                    CupertinoListTile(
                      backgroundColor: const Color(0x00000000),
                      title: const Text('关于 PCelechron'),
                      trailing: BackChervonRow(
                        child: Text(_optionController.celechronVersion,
                            style: trailingTextStyle),
                      ),
                      onTap: () async {
                        Navigator.of(context, rootNavigator: true).push(
                            CupertinoPageRoute(
                                builder: (context) => CreditsPage(
                                    version:
                                        _optionController.celechronVersion)));
                      },
                    ),
                    CupertinoListTile(
                      backgroundColor: const Color(0x00000000),
                      title: const Text('服务条款'),
                      trailing: const BackChervonRow(),
                      onTap: () async {
                        Navigator.of(context, rootNavigator: true).push(
                            CupertinoPageRoute(
                                builder: (context) =>
                                    const CustomLicensePage()));
                      },
                    ),
                    CupertinoListTile(
                      backgroundColor: const Color(0x00000000),
                      title: const Text('PCelechron 项目网站'),
                      trailing: const BackChervonRow(),
                      onTap: () async {
                        await launchUrlString(
                          'https://github.com/Flaviohor/Celechron',
                          mode: LaunchMode.externalApplication,
                        );
                      },
                    ),
                    CupertinoListTile(
                      backgroundColor: const Color(0x00000000),
                      title: const Text('上游 Celechron 项目网站'),
                      trailing: BackChervonRow(
                        child: Obx(() {
                          if (_optionController.hasNewVersion) {
                            return Row(children: [
                              Container(
                                margin: const EdgeInsets.only(right: 4),
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                    color: CupertinoColors.systemRed,
                                    borderRadius: BorderRadius.circular(4)),
                              ),
                              Text('有新版本可用', style: trailingTextStyle)
                            ]);
                          } else {
                            return const Text('');
                          }
                        }),
                      ),
                      onTap: () async {
                        await launchUrlString(
                          'https://celechron.top',
                          mode: LaunchMode.externalApplication,
                        );
                      },
                    ),
                  ]),
            ))
          ],
        )));
  }

  /// 导入类操作的统一结果反馈：取消或解析失败静默，成功弹结果摘要。
  Future<void> _showImportResult(
      BuildContext context, Future<String?> operation) async {
    final summary = await operation;
    if (summary == null || !context.mounted) return;
    await showCupertinoDialog(
        context: context,
        builder: (dialogContext) {
          return CupertinoAlertDialog(
            title: const Text('导入完成'),
            content: Text(summary),
            actions: [
              CupertinoDialogAction(
                child: const Text('好'),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ],
          );
        });
  }

  void _showUpdateSheet(BuildContext context) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => const UpdateSheet(),
    );
  }

  void _showBrightnessPicker(BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) {
        return CupertinoActionSheet(
          actions: <Widget>[
            CupertinoActionSheetAction(
              onPressed: () {
                _optionController.brightnessMode = BrightnessMode.system;
                Navigator.pop(context);
              },
              child: const Text('跟随系统设置'),
            ),
            CupertinoActionSheetAction(
              onPressed: () {
                _optionController.brightnessMode = BrightnessMode.light;
                Navigator.pop(context);
              },
              child: const Text('亮色模式'),
            ),
            CupertinoActionSheetAction(
              onPressed: () {
                _optionController.brightnessMode = BrightnessMode.dark;
                Navigator.pop(context);
              },
              child: const Text('暗色模式'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        );
      },
    );
  }

  static const _defaultMargin =
      EdgeInsetsDirectional.fromSTEB(16.0, 0.0, 16.0, 10.0);
}

class BackChervonRow extends StatelessWidget {
  final Widget? child;

  const BackChervonRow({super.key, this.child});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      if (child != null) child!,
      const SizedBox(width: 4),
      Icon(Icons.arrow_forward_ios,
          color: CupertinoDynamicColor.resolve(
              CupertinoColors.tertiaryLabel, context),
          size: 16)
    ]);
  }
}
