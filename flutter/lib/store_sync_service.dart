import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/store_config_service.dart';

/// 门店名称同步服务
///
/// 把本机保存的门店名称同步到 lejianwen/rustdesk-api 的：
///   1) 设备管理（peer）别名  ->  POST /api/admin/peer/update
///   2) 共享通讯簿（address_book）别名 -> POST /api/admin/address_book/{create|update}
///
/// 鉴权使用「永久令牌」方案：令牌随安装包分发到安装目录的出厂配置
/// （store_config.json），读取与轮换都无需重新编译客户端。
/// 详见 StoreConfigService 的分层配置说明。
class StoreSyncService {
  /// 等待设备在服务端「设备管理」里出现（拿到 peer 的 row_id）的最长时长。
  ///
  /// 服务端是收到 sysinfo 上报才建 peer 记录的，而 sysinfo 由客户端心跳
  /// 驱动（15 秒一轮，内容有变化才上传，上传间隔上限 120 秒）。所以首次
  /// 装机时服务端要过一会儿才认得这台设备 —— 查一次就放弃会必然失败。
  static const Duration peerWaitTimeout = Duration(minutes: 5);

  /// 轮询 peer 上线的间隔
  static const Duration peerWaitInterval = Duration(seconds: 5);

  /// **首启弹窗**里等待 peer 上线的上限。
  ///
  /// 与后台自愈用的 [peerWaitTimeout]（5 分钟）刻意区分开：
  /// 弹窗是不可关闭的（barrierDismissible: false，且没有「稍后再说」按钮），
  /// 门店点完「保存并同步」就得干等。如果这里也等 5 分钟，
  /// 现场表现为「程序卡死，只能强制结束进程」—— 门店根本不会用。
  ///
  /// 所以弹窗只等 30 秒：够正常情况（设备通常已经上线），
  /// 不够就让后台调度器接着补。反正名字已经存到本机了。
  static const Duration firstRunWaitTimeout = Duration(seconds: 30);

  /// 单次 HTTP 请求的超时。
  ///
  /// HttpClient 默认**没有任何超时**（连接与读取都是无限等）。门店机在
  /// 拔网线、服务器重启、代理挂起等情况下，请求会一直挂着不返回，
  /// 于是：
  ///   - 首启弹窗的「保存并同步」会卡住，且弹窗不可关闭（无超时），
  ///     门店只能强制杀进程；
  ///   - 后台自愈的 _syncing 标志一直为 true，之后每轮自愈都被跳过，
  ///     等于同步功能彻底停摆。
  /// 加了超时后，最坏情况是「这次同步失败」，后台调度器下轮重试。
  static const Duration httpTimeout = Duration(seconds: 20);

  /// 从分层配置读取同步所需字段。
  ///
  /// 出厂配置（随包分发，含 adminToken）的定位由 StoreConfigService 负责，
  /// 这里只负责取值，不关心文件在哪、也不关心用户配置是否覆盖。
  static Future<Map<String, dynamic>> _loadConfig() async {
    try {
      return await StoreConfigService.loadEffectiveConfig();
    } catch (e) {
      debugPrint('[store_sync] 读取配置失败: $e');
    }
    return {};
  }

  /// 从 API 列表接口返回的 data 里抽取出本机 id 对应的记录。
  /// 不同版本返回结构略有差异，这里做多重兼容。
  static List _extractList(dynamic data) {
    if (data is List) return data;
    if (data is Map) {
      for (final key in ['data', 'list', 'items']) {
        final v = data[key];
        if (v is List) return v;
        if (v is Map) {
          for (final k2 in ['data', 'list', 'items']) {
            if (v[k2] is List) return v[k2];
          }
        }
      }
    }
    return [];
  }

  /// 规整 API 基址：去掉末尾斜杠、补齐 http:// scheme。
  ///
  /// Rust 侧 get_api_server_() 在 "api-server" 选项非空时是原样返回的，
  /// 若门店机上填的是 "192.168.100.190:21114"（无 scheme），
  /// 直接拼路径会得到无法解析的 URL，这里统一兜底。
  static String _normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'/+$'), '');
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    return s;
  }

  /// 同步门店名称到服务器。
  /// 返回 {success, peer, addressBook, peerAlias, addressBookAlias, error}。
  ///
  /// ## 为什么要有等待
  ///
  /// 首次装机时用户填完门店名点保存，往往只过去几秒 —— 此时客户端还没完成
  /// 首次 sysinfo 上报，服务端的设备管理里查不到本机，**写入必然失败**，
  /// 而且失败后再没有人重试。这就是「填了名字却没进通讯录」的直接原因。
  ///
  /// 所以这里不是查一次就放弃，而是**轮询等待** peer 出现，最多等
  /// [waitTimeout]。等不到才把状态记为待补，由后台调度器接着做。
  static Future<Map<String, dynamic>> syncStoreName(
    String storeName, {
    Duration waitTimeout = peerWaitTimeout,
  }) async {
    final result = <String, dynamic>{
      'success': false,
      'peer': false,
      'addressBook': false,
      'peerAlias': '',
      'addressBookAlias': '',
      'error': '',
    };
    try {
      final cfg = await _loadConfig();
      final adminToken =
          (cfg[StoreConfigService.kKeyAdminToken] ?? '').toString().trim();
      final abUserId = _toInt(cfg[StoreConfigService.kKeyAddressBookUserId]);
      final abCollectionId =
          _toInt(cfg[StoreConfigService.kKeyAddressBookCollectionId]);
      if (adminToken.isEmpty) {
        result['error'] = '未配置 adminToken（出厂配置未随安装包分发，请联系管理员）';
        return result;
      }

      // API 基址优先级：出厂/用户配置 > 客户端 "api-server" 选项
      var base = _normalizeBase((cfg[StoreConfigService.kKeyApiServer] ?? '').toString());
      if (base.isEmpty) {
        base = _normalizeBase(await bind.mainGetApiServer());
      }
      if (base.isEmpty) {
        result['error'] = '未配置 API 服务器地址（请在配置窗口或客户端设置中填写）';
        return result;
      }

      final rid = (await bind.mainGetMyId()).trim();
      if (rid.isEmpty) {
        result['error'] = '无法获取本机 RustDesk ID';
        return result;
      }

      final client = HttpClient();
      // 内网自签证书放行（内部工具，仅用于同步门店名称）
      client.badCertificateCallback = (cert, host, port) => true;
      // 必须设超时：HttpClient 默认无限等待，网络异常时请求会永久挂起
      client.connectionTimeout = httpTimeout;
      client.idleTimeout = httpTimeout;
      try {
        // ---------- 1) 设备管理别名 ----------
        // 先查；查不到就等一会儿再查 —— 首次装机时服务端还没建本机记录，
        // 查一次就放弃会让这次同步必然失败。
        final peerRowId = await _waitForPeerRowId(
          client: client,
          base: base,
          adminToken: adminToken,
          rid: rid,
          timeout: waitTimeout,
        );
        if (peerRowId != null && peerRowId > 0) {
          final updReq = await client.postUrl(Uri.parse('$base/api/admin/peer/update'));
          // 显式 charset=utf-8，且 body 用 utf8 编码字节发送
          updReq.headers.set('Content-Type', 'application/json; charset=utf-8');
          updReq.headers.set('api-token', adminToken);
          updReq.add(utf8.encode(jsonEncode({
            'row_id': peerRowId,
            'id': rid,
            'alias': storeName,
          })));
          final updResp = await updReq.close().timeout(httpTimeout);
          await updResp.drain<void>().timeout(httpTimeout);
          result['peer'] = updResp.statusCode == 200;
        } else {
          result['error'] =
              '设备管理里还没有本机记录（客户端尚未完成上线登记），稍后会自动重试';
        }

        // ---------- 2) 共享通讯簿别名 ----------
        final abListReq = await client.getUrl(Uri.parse(
            '$base/api/admin/address_book/list?user_id=$abUserId&collection_id=$abCollectionId&id=$rid'));
        abListReq.headers.set('api-token', adminToken);
        final abListResp = await abListReq.close().timeout(httpTimeout);
        final abListBody =
            await abListResp.transform(utf8.decoder).join().timeout(httpTimeout);
        int? abRowId;
        if (abListResp.statusCode == 200) {
          final j = jsonDecode(abListBody);
          for (final e in _extractList(j['data'])) {
            if (e is Map && '${e['id']}' == rid) {
              abRowId = _toInt(e['row_id']);
              break;
            }
          }
        }
        final abPayload = <String, dynamic>{
          'id': rid,
          'alias': storeName,
          'user_id': abUserId,
          'collection_id': abCollectionId,
        };
        if (abRowId != null && abRowId > 0) abPayload['row_id'] = abRowId;
        final abUrl = abRowId != null && abRowId > 0
            ? '$base/api/admin/address_book/update'
            : '$base/api/admin/address_book/create';
        final abReq = await client.postUrl(Uri.parse(abUrl));
        abReq.headers.set('Content-Type', 'application/json; charset=utf-8');
        abReq.headers.set('api-token', adminToken);
        abReq.add(utf8.encode(jsonEncode(abPayload)));
        final abResp = await abReq.close().timeout(httpTimeout);
        await abResp.drain<void>().timeout(httpTimeout);
        result['addressBook'] = abResp.statusCode == 200;

        // ---------- 3) 读回校验：确认落库中文没乱码 ----------
        result['peerAlias'] = await _readAlias(client, base, adminToken, rid, true);
        result['addressBookAlias'] =
            await _readAlias(client, base, adminToken, rid, false, abUserId, abCollectionId);

        result['success'] = result['peer'] == true &&
            result['addressBook'] == true &&
            _aliasOk('${result['peerAlias']}', storeName) &&
            _aliasOk('${result['addressBookAlias']}', storeName);
        if (!result['success'] && '${result['error']}'.isEmpty) {
          final parts = <String>[];
          if (result['peer'] != true) parts.add('设备管理写入失败');
          if (result['addressBook'] != true) parts.add('通讯簿写入失败');
          if (!_aliasOk('${result['peerAlias']}', storeName)) {
            parts.add('设备管理别名校验不通过(实际值:${result['peerAlias']})');
          }
          if (!_aliasOk('${result['addressBookAlias']}', storeName)) {
            parts.add('通讯簿别名校验不通过(实际值:${result['addressBookAlias']})');
          }
          result['error'] = parts.join('；');
        }
      } finally {
        client.close();
      }
    } catch (e) {
      result['error'] = e.toString();
    }
    return result;
  }

  /// 轮询等待本机在服务端「设备管理」里出现，返回它的 row_id。
  ///
  /// 服务端是收到 sysinfo 上报才建 peer 记录的，而 sysinfo 由客户端心跳驱动
  /// （15 秒一轮，内容有变化才上传，上传间隔上限 120 秒）。首次装机时，
  /// 用户点保存往往只过去几秒，服务端还认不得这台设备 —— 查一次就放弃会让
  /// 这次同步必然失败，之后再无重试。
  ///
  /// 所以这里按 [peerWaitInterval] 轮询，直到 [timeout] 用尽。
  /// 等不到返回 null，由调用方把状态记为待补。
  ///
  /// 注意：单次请求的超时会被**剩余预算**裁剪 —— 否则一次卡住的请求
  /// （20 秒）会把 30 秒的预算拖成 45 秒，超出调用方（首启弹窗）
  /// 能接受的等待时长。
  static Future<int?> _waitForPeerRowId({
    required HttpClient client,
    required String base,
    required String adminToken,
    required String rid,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      // 单次请求最多用掉剩余预算与 httpTimeout 的较小值
      final slice = remaining < httpTimeout ? remaining : httpTimeout;
      final rowId =
          await _findPeerRowId(client, base, adminToken, rid, slice);
      if (rowId != null && rowId > 0) {
        return rowId;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      // 只等到剩余预算用完，但至少等一个轮询间隔（保证不忙等）
      await Future.delayed(
          left < peerWaitInterval ? left : peerWaitInterval);
    }
  }

  /// 在设备管理里查本机的 row_id；查不到返回 null。
  ///
  /// [timeout] 限定单次请求的上限（由调用方按剩余预算给出）。
  static Future<int?> _findPeerRowId(
      HttpClient client,
      String base,
      String adminToken,
      String rid,
      [Duration? timeout]) async {
    try {
      final req =
          await client.getUrl(Uri.parse('$base/api/admin/peer/list?id=$rid'));
      req.headers.set('api-token', adminToken);
      req.headers.set('Accept', 'application/json');
      final limit = timeout ?? httpTimeout;
      final resp = await req.close().timeout(limit);
      final body = await resp.transform(utf8.decoder).join().timeout(limit);
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body);
      for (final e in _extractList(j['data'])) {
        if (e is Map && '${e['id']}' == rid) {
          return _toInt(e['row_id']);
        }
      }
    } catch (e) {
      debugPrint('[store_sync] 查询设备管理失败: $e');
    }
    return null;
  }

  /// 查通讯录里本机条目的 row_id
  static Future<int?> _findAbRowId(HttpClient client, String base,
      String adminToken, String rid, int? userId, int? collectionId) async {
    try {
      final req = await client.getUrl(Uri.parse(
          '$base/api/admin/address_book/list?user_id=$userId&collection_id=$collectionId&id=$rid'));
      req.headers.set('api-token', adminToken);
      req.headers.set('Accept', 'application/json');
      final resp = await req.close().timeout(httpTimeout);
      final body = await resp.transform(utf8.decoder).join().timeout(httpTimeout);
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body);
      for (final e in _extractList(j['data'])) {
        if (e is Map && '${e['id']}' == rid) {
          return _toInt(e['row_id']);
        }
      }
    } catch (e) {
      debugPrint('[store_sync] 查询通讯录失败: $e');
    }
    return null;
  }

  /// POST JSON，返回 HTTP 状态码（0 表示请求失败）。
  ///
  /// body 一律转成 UTF-8 字节数组再发送 —— 传字符串时若编码不对，
  /// 中文会变成问号，服务端就存下 ???XX?。
  static Future<int> _postJson(HttpClient client, String url,
      String adminToken, Map<String, dynamic> payload) async {
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.headers.set('api-token', adminToken);
      req.add(utf8.encode(jsonEncode(payload)));
      // connectionTimeout 只管「建连」，响应体读取仍可能无限挂起，
      // 这里再包一层 Future.timeout 兜底。
      final resp = await req.close().timeout(httpTimeout);
      await resp.drain<void>().timeout(httpTimeout);
      return resp.statusCode;
    } catch (e) {
      debugPrint('[store_sync] POST 失败 $url: $e');
      return 0;
    }
  }

  /// 以门店端本地的名称为准，把服务端被改掉的别名纠正回来。
  ///
  /// 门店名是门店自己的属性 —— 服务端被误改（手误、技术员误操作、条目
  /// 被删后重建导致别名清空）时，门店端应当在下次同步时改回去，而不是
  /// 默认接受服务端的名字。
  ///
  /// 反过来，门店端自己改了名（沂蒙路店 → 沂蒙路二店），也走同一条路径
  /// 把新名字推上去 —— 「以本地为准」对两个方向是同一条规则。
  ///
  /// 返回 true 表示服务端别名已与本地一致（或已成功纠正）。
  static Future<bool> reconcileAlias(String localName) async {
    if (localName.trim().isEmpty) return false;
    try {
      final cfg = await _loadConfig();
      final adminToken =
          (cfg[StoreConfigService.kKeyAdminToken] ?? '').toString().trim();
      final abUserId = _toInt(cfg[StoreConfigService.kKeyAddressBookUserId]);
      final abCollectionId =
          _toInt(cfg[StoreConfigService.kKeyAddressBookCollectionId]);
      if (adminToken.isEmpty) return false;

      final rid = (await bind.mainGetMyId()).trim();
      if (rid.isEmpty) return false;

      var base = _normalizeBase((cfg[StoreConfigService.kKeyApiServer] ?? '').toString());
      if (base.isEmpty) {
        base = _normalizeBase(await bind.mainGetApiServer());
      }
      if (base.isEmpty) return false;

      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) => true;
      // 必须设超时：HttpClient 默认无限等待，网络异常时请求会永久挂起
      client.connectionTimeout = httpTimeout;
      client.idleTimeout = httpTimeout;
      try {
        final serverAlias = await _readAlias(
            client, base, adminToken, rid, false, abUserId, abCollectionId);
        if (serverAlias == localName) return true; // 已一致，无需动作

        final abRowId = await _findAbRowId(
            client, base, adminToken, rid, abUserId, abCollectionId);
        final payload = <String, dynamic>{
          'id': rid,
          'alias': localName,
          'user_id': abUserId,
          'collection_id': abCollectionId,
        };
        final url = (abRowId != null && abRowId > 0)
            ? '$base/api/admin/address_book/update'
            : '$base/api/admin/address_book/create';
        if (abRowId != null && abRowId > 0) {
          payload['row_id'] = abRowId;
        }
        final code = await _postJson(client, url, adminToken, payload);
        if (code != 200) {
          debugPrint('[store_sync] 别名纠正失败 HTTP $code');
          return false;
        }
        debugPrint('[store_sync] 已用本地名称纠正服务端别名: $localName');
        return true;
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[store_sync] 别名纠正异常: $e');
      return false;
    }
  }

  /// 读回服务端真正存下来的别名，用于校验中文编码。
  static Future<String> _readAlias(HttpClient client, String base,
      String adminToken, String rid, bool isPeer,
      [int? abUserId, int? abCollectionId]) async {
    try {
      final String url;
      if (isPeer) {
        url = '$base/api/admin/peer/list?id=$rid';
      } else {
        url = '$base/api/admin/address_book/list'
            '?user_id=$abUserId&collection_id=$abCollectionId&id=$rid';
      }
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('api-token', adminToken);
      req.headers.set('Accept', 'application/json');
      final resp = await req.close().timeout(httpTimeout);
      final body = await resp.transform(utf8.decoder).join().timeout(httpTimeout);
      if (resp.statusCode != 200) return '';
      final j = jsonDecode(body);
      for (final e in _extractList(j['data'])) {
        if (e is Map && '${e['id']}' == rid) {
          return '${e['alias'] ?? ''}';
        }
      }
    } catch (e) {
      debugPrint('[store_sync] 读回校验失败: $e');
    }
    return '';
  }

  /// 判断落库值是否与输入一致（不相等即视为乱码/未写入）。
  static bool _aliasOk(String saved, String expected) {
    if (saved.isEmpty) return false;
    return saved == expected;
  }

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }
}
