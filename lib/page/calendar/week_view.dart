import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:table_calendar/table_calendar.dart' show isSameDay;

import 'package:celechron/design/custom_colors.dart';
import 'package:celechron/model/period.dart';
import 'package:celechron/utils/utils.dart';

import 'calendar_controller.dart';

/// 宽屏周视图：周一到周日 × 时间轴的课程 / 考试 / 日程块（甘特式）。
///
/// 数据完全复用 [CalendarController.getEventsForDay]，与日视图同一份合并结果；
/// 点击事件块的跳转行为由 [onPeriodTap] 提供（日视图同款），点击空白处通过
/// [onEmptyTap] 在对应时刻新建日程。
class WeekView extends StatefulWidget {
  const WeekView({
    super.key,
    required this.controller,
    required this.onPeriodTap,
    required this.onEmptyTap,
  });

  final CalendarController controller;
  final void Function(BuildContext context, Period period) onPeriodTap;
  final ValueChanged<DateTime> onEmptyTap;

  @override
  State<WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends State<WeekView> {
  static const int _startHour = 7;
  static const int _endHour = 23;
  static const double _hourHeight = 58;
  static const double _headerHeight = 30;
  static const double _timeGutterWidth = 46;
  static const double _gridHeight = (_endHour - _startHour) * _hourHeight;

  final ScrollController _scrollController = ScrollController();
  late DateTime _weekAnchor;

  @override
  void initState() {
    super.initState();
    _weekAnchor = widget.controller.focusedDay.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final now = DateTime.now();
      final offset = (now.hour + now.minute / 60.0 - _startHour) * _hourHeight;
      _scrollController.jumpTo(offset.clamp(0.0, _gridHeight));
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  DateTime get _monday {
    final anchor = dateOnly(_weekAnchor);
    return anchor.subtract(Duration(days: anchor.weekday - DateTime.monday));
  }

  void _shiftWeek(int days) {
    setState(() {
      _weekAnchor = _weekAnchor.add(Duration(days: days));
    });
  }

  double _y(DateTime time) {
    final hours = time.hour + time.minute / 60.0 - _startHour;
    return (hours * _hourHeight).clamp(0.0, _gridHeight);
  }

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(DateTime.now());
    final monday = _monday;
    final days = List.generate(7, (i) => monday.add(Duration(days: i)));
    final weekDescription =
        widget.controller.dayDescription(monday.add(const Duration(days: 3)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CupertinoButton(
              padding: const EdgeInsets.only(left: 12),
              minimumSize: Size.zero,
              child: const Icon(CupertinoIcons.chevron_left, size: 20),
              onPressed: () => _shiftWeek(-7),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    '${monday.month} 月 ${monday.day} 日 - '
                    '${days.last.month} 月 ${days.last.day} 日',
                    style: CupertinoTheme.of(context)
                        .textTheme
                        .textStyle
                        .copyWith(fontSize: 14),
                  ),
                  Text(
                    weekDescription,
                    style: CupertinoTheme.of(context)
                        .textTheme
                        .textStyle
                        .copyWith(
                            fontSize: 12,
                            color: CupertinoDynamicColor.resolve(
                                CupertinoColors.secondaryLabel, context)),
                  ),
                ],
              ),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              child: Text('今天',
                  style: TextStyle(
                      fontSize: 15,
                      color: CupertinoDynamicColor.resolve(
                          CupertinoColors.systemBlue, context))),
              onPressed: () {
                setState(() {
                  _weekAnchor = DateTime.now();
                });
              },
            ),
            CupertinoButton(
              padding: const EdgeInsets.only(right: 12),
              minimumSize: Size.zero,
              child: const Icon(CupertinoIcons.chevron_right, size: 20),
              onPressed: () => _shiftWeek(7),
            ),
          ],
        ),
        SizedBox(
          height: _headerHeight,
          child: Row(
            children: [
              const SizedBox(width: _timeGutterWidth),
              for (final day in days)
                Expanded(
                  child: Center(
                    child: Text(
                      '${'一二三四五六日'[day.weekday - 1]} ${day.month}/${day.day}',
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .textStyle
                          .copyWith(
                              fontSize: 13,
                              fontWeight: isSameDay(day, today)
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSameDay(day, today)
                                  ? CupertinoDynamicColor.resolve(
                                      CupertinoColors.activeBlue, context)
                                  : CupertinoDynamicColor.resolve(
                                      CupertinoColors.secondaryLabel, context)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            child: SizedBox(
              height: _gridHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: _timeGutterWidth,
                    child: Column(
                      children: [
                        for (var hour = _startHour; hour < _endHour; hour++)
                          SizedBox(
                            height: _hourHeight,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: Transform.translate(
                                offset: const Offset(0, -7),
                                child: Text(
                                  '$hour:00',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: CupertinoDynamicColor.resolve(
                                        CupertinoColors.tertiaryLabel, context),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final gridWidth = constraints.maxWidth;
                        final dayWidth = gridWidth / 7;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) {
                            final dx = details.localPosition.dx;
                            final dy = details.localPosition.dy;
                            if (dx < 0 || dx >= gridWidth) return;
                            final dayIndex = (dx ~/ dayWidth).clamp(0, 6);
                            final day = days[dayIndex];
                            final hourValue = _startHour + dy / _hourHeight;
                            final hour =
                                hourValue.floor().clamp(_startHour, 22).toInt();
                            final minute =
                                (((hourValue - hourValue.floor()) * 60)
                                        .round()
                                        .clamp(0, 59) ~/
                                    15 *
                                    15);
                            widget.onEmptyTap(DateTime(day.year, day.month,
                                day.day, hour, minute.toInt()));
                          },
                          child: Stack(
                            children: [
                              // 整点横线
                              for (var hour = _startHour + 1;
                                  hour < _endHour;
                                  hour++)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: _y(DateTime(0, 1, 1, hour)),
                                  child: Container(
                                    height: 0.5,
                                    color: CupertinoDynamicColor.resolve(
                                        CupertinoColors.separator, context),
                                  ),
                                ),
                              // 竖向分隔
                              for (var i = 1; i < 7; i++)
                                Positioned(
                                  left: dayWidth * i,
                                  top: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 0.5,
                                    color: CupertinoDynamicColor.resolve(
                                        CupertinoColors.separator, context),
                                  ),
                                ),
                              // 「现在」参考线
                              if (days.any((d) => isSameDay(d, today)))
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: _y(DateTime.now()),
                                  child: Container(
                                    height: 1.5,
                                    color: CupertinoDynamicColor.resolve(
                                        CupertinoColors.systemRed, context),
                                  ),
                                ),
                              // 事件块
                              for (var i = 0; i < 7; i++)
                                ..._buildDayBlocks(
                                    context, days[i], dayWidth, i),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 一天的事件块，按重叠分道排布，道内互不覆盖。
  List<Widget> _buildDayBlocks(
      BuildContext context, DateTime day, double dayWidth, int dayIndex) {
    final events = widget.controller.getEventsForDay(day);
    // 贪心分道：每个事件放进第一条与其不重叠的道。
    final lanes = <List<Period>>[];
    final laneIndexOf = <Period, int>{};
    for (final event in events) {
      var lane = 0;
      while (true) {
        if (lane >= lanes.length) {
          lanes.add([]);
        }
        final conflicts = lanes[lane].any((e) =>
            !e.endTime.isBefore(event.startTime) &&
            !event.endTime.isBefore(e.startTime));
        if (!conflicts) {
          lanes[lane].add(event);
          laneIndexOf[event] = lane;
          break;
        }
        lane++;
      }
    }

    final blocks = <Widget>[];
    for (final event in events) {
      final lane = laneIndexOf[event] ?? 0;
      final laneCount = lanes.length;
      final top = _y(event.startTime);
      var bottom = _y(event.endTime);
      if (bottom - top < 14) {
        bottom = top + 14; // 极短事件保底可见
      }
      final left = dayWidth * dayIndex + lane * (dayWidth / laneCount);
      blocks.add(
        Positioned(
          left: left + 1,
          top: top,
          width: dayWidth / laneCount - 2,
          height: bottom - top - 1,
          child: _EventBlock(
            period: event,
            onTap: () => widget.onPeriodTap(context, event),
          ),
        ),
      );
    }
    return blocks;
  }
}

class _EventBlock extends StatelessWidget {
  const _EventBlock({required this.period, required this.onTap});

  final Period period;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (period.type) {
      case PeriodType.classes:
        color = TimeColors.colorFromHour(period.startTime.hour);
        break;
      case PeriodType.test:
        color = CupertinoColors.systemPink;
        break;
      case PeriodType.user:
        color = UidColors.colorFromUid(period.fromFromUid ?? period.fromUid);
        break;
      default:
        color = CupertinoColors.inactiveGray;
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          border: Border.all(color: color.withValues(alpha: 0.8), width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              period.summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CupertinoTheme.of(context)
                  .textTheme
                  .textStyle
                  .copyWith(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            if (period.location.isNotEmpty)
              Text(
                period.location,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                      fontSize: 10,
                      color: CupertinoDynamicColor.resolve(
                          CupertinoColors.secondaryLabel, context),
                    ),
              ),
            const Spacer(),
            Icon(
              Icons.arrow_forward_ios,
              size: 8,
              color: CupertinoDynamicColor.resolve(
                  CupertinoColors.tertiaryLabel, context),
            ),
          ],
        ),
      ),
    );
  }
}
