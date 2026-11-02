import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/store_config_service.dart';
import 'package:flutter_hbb/store_sync_service.dart';

/// 门店名自动同步调度器
///
/// 解决两个问题：
///
/// 1. **新部署的设备没有自动进通讯录**。
///    客户端登录 API 后会定时上报 sysinfo，服务端收到后自动在「设备管理」
///    （peer 表）建档；但「共享通讯录」（address_book 表）是另一张表，
///    服务端不会自动建。首次装机时用户填完门店名点保存，客户端往往还没
///    完成首次上报，写入必然失败且再无重试。
///
/// 2. **服务端把门店名改错后，门店端不会纠正回来**。
///    门店名是门店自己的属性，服务端被误改时门店端应当改回去。
///
/// 这里做两件事：
/// - **启动补偿**：客户端启动后延迟一段时间做一次同步（此时 sysinfo 大概率
///   已上报）；
/// - **周期自愈**：每隔一段时间检查通讯录里有没有本机条目、别名是否一致，
///   缺了就补写，不一致就用本地名称纠正回来。
///
/// 同步失败一律不影响客户端使用 —— 远程连接、地址簿本地缓存等功能与同步
/// 完全无关。
class StoreSyncScheduler {
  StoreSyncScheduler._();

  static StoreSyncScheduler instance = StoreSyncScheduler._();

  Timer? _timer;
  Timer? _startupTimer;
  bool _running = false;
  bool _syncing = false;

  /// 启动后的补偿检查延迟。
  ///
  /// 客户端的心跳是 15 秒一轮，而服务端要等 sysinfo 上报才建 peer 记录
  /// （上传间隔上限 120 秒）。60 秒能覆盖绝大多数情况，之后的缺口由周期
  /// 自愈兜住。
  static const Duration startupDelay = Duration(seconds: 60);

  /// 周期自愈的间隔
  static const Duration healInterval = Duration(minutes: 30);

  /// 自愈时的等待上限。
  ///
  /// 自愈是后台行为，不该长时间占着连接 —— 拿不到 peer 就下轮再说。
  static const Duration healWaitTimeout = Duration(seconds: 20);

  /// 启动调度器（幂等，可重复调用）
  void start() {
    if (_running) return;
    _running = true;

    _startupTimer = Timer(startupDelay, () async {
      await selfHeal();
    });

    _timer = Timer.periodic(healInterval, (_) async {
      await selfHeal();
    });

    debugPrint('[store_sync] 调度器已启动');
  }

  void stop() {
    _startupTimer?.cancel();
    _startupTimer = null;
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  /// 检查并补写通讯录条目，同时把服务端被改错的别名纠正回来。
  ///
  /// 只有「已经填过门店名」的机器才需要自愈 —— 没填名字的机器等首启弹窗
  /// 填完即可（弹窗保存时会立即同步一次）。
  Future<bool> selfHeal() async {
    if (_syncing) return false; // 上一轮还没跑完
    final name = await StoreConfigService.loadStoreName();
    if (name.isEmpty) return false;
    _syncing = true;
    try {
      final r = await StoreSyncService.syncStoreName(
        name,
        waitTimeout: healWaitTimeout,
      );
      var ok = r['success'] == true;
      if (!ok) {
        debugPrint('[store_sync] 自愈未完成: ${r['error']}');
      } else {
        // 别名已一致 —— 顺带确认服务端没有被改错
        final reconciled = await StoreSyncService.reconcileAlias(name);
        if (!reconciled) {
          debugPrint('[store_sync] 别名纠正未完成，稍后重试');
          ok = false;
        }
      }
      await StoreConfigService.saveSyncState(
        ok: ok,
        error: '${r['error'] ?? ''}',
      );
      return ok;
    } catch (e) {
      debugPrint('[store_sync] 自愈异常: $e');
      return false;
    } finally {
      _syncing = false;
    }
  }
}
