import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// 门店名称同步服务
///
/// 把本机保存的门店名称同步到 lejianwen/rustdesk-api 的：
///   1) 设备管理（peer）别名  ->  POST /api/admin/peer/update
///   2) 共享通讯簿（address_book）别名 -> POST /api/admin/address_book/{create|update}
///
/// 鉴权使用「永久令牌」方案：在 exe 同目录放一份 store_sync.json，
/// 内含 adminToken（用 SQL 把 user_tokens.expired_at 改成远未来得到）、
/// apiServer、addressBookUserId、addressBookCollectionId。
/// 令牌不写死进源码，便于轮换。
class StoreSyncService {
  static const String _configFileName = 'store_sync.json';

  /// 从 exe 同目录读取同步配置。
  static Future<Map<String, dynamic>> _loadConfig() async {
    try {
      final dir = File(Platform.resolvedExecutable).parent.path;
      final file = File('$dir/$_configFileName');
      if (await file.exists()) {
        // 显式按 UTF-8 读，避免 Windows 上按 GBK 解析导致中文配置乱码
        final bytes = await file.readAsBytes();
        final text = utf8.decode(bytes, allowMalformed: false);
        final decoded = jsonDecode(text);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
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
  static Future<Map<String, dynamic>> syncStoreName(String storeName) async {
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
      final adminToken = (cfg['adminToken'] ?? '').toString().trim();
      final abUserId = _toInt(cfg['addressBookUserId']);
      final abCollectionId = _toInt(cfg['addressBookCollectionId']);
      if (adminToken.isEmpty) {
        result['error'] = '未配置 adminToken（请在 exe 同目录的 store_sync.json 中填写）';
        return result;
      }

      // API 基址优先级：store_sync.json > 客户端 "api-server" 选项
      var base = _normalizeBase((cfg['apiServer'] ?? '').toString());
      if (base.isEmpty) {
        base = _normalizeBase(await bind.mainGetApiServer());
      }
      if (base.isEmpty) {
        result['error'] = '未配置 API 服务器地址（请在 store_sync.json 或客户端设置中填写）';
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
      try {
        // ---------- 1) 设备管理别名 ----------
        final listReq = await client.getUrl(Uri.parse('$base/api/admin/peer/list?id=$rid'));
        listReq.headers.set('api-token', adminToken);
        listReq.headers.set('Accept', 'application/json');
        final listResp = await listReq.close();
        final listBody = await listResp.transform(utf8.decoder).join();
        int? peerRowId;
        if (listResp.statusCode == 200) {
          final j = jsonDecode(listBody);
          for (final e in _extractList(j['data'])) {
            if (e is Map && '${e['id']}' == rid) {
              peerRowId = _toInt(e['row_id']);
              break;
            }
          }
        }
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
          final updResp = await updReq.close();
          await updResp.drain<void>();
          result['peer'] = updResp.statusCode == 200;
        } else {
          result['error'] = '设备管理里找不到本机 ID（确认客户端已连上 API 服务器）';
        }

        // ---------- 2) 共享通讯簿别名 ----------
        final abListReq = await client.getUrl(Uri.parse(
            '$base/api/admin/address_book/list?user_id=$abUserId&collection_id=$abCollectionId&id=$rid'));
        abListReq.headers.set('api-token', adminToken);
        final abListResp = await abListReq.close();
        final abListBody = await abListResp.transform(utf8.decoder).join();
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
        final abResp = await abReq.close();
        await abResp.drain<void>();
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
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
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
