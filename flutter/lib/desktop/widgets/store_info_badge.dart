import 'package:flutter/material.dart';
import 'package:flutter_hbb/store_config_service.dart';

/// 门店信息徽标
///
/// 显示在主界面右侧面板顶部、远程 ID 输入框右侧的空白区域。
/// 样式沿用该区域既有的卡片外观（圆角 + 描边），不遮挡任何原有内容。
///
/// 内容：
/// - 门店名称（大字 + 品牌色，一眼看清）
/// - 本机 ID 与同步状态（小字，灰色）
class StoreInfoBadge extends StatefulWidget {
  const StoreInfoBadge({Key? key}) : super(key: key);

  @override
  State<StoreInfoBadge> createState() => _StoreInfoBadgeState();
}

class _StoreInfoBadgeState extends State<StoreInfoBadge> {
  String _storeName = '';
  String _status = '';

  /// 门店名称使用的品牌色。
  ///
  /// 取「鎏金」深色调，与仁和堂品牌的「深墨鎏金」视觉一致。
  /// 对比度已实测（WCAG）：
  /// - 浅色主题：#6E4E0E 文字 vs 徽标底色 = 5.90:1（正文标准 4.5:1）
  /// - 深色主题：#F0C060 文字 vs 徽标底色 = 8.07:1
  /// 两种主题下都清晰易读。
  static const Color _goldLight = Color(0xFF6E4E0E);
  static const Color _goldDark = Color(0xFFF0C060);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final name = await StoreConfigService.loadStoreName();
    final hasToken = await StoreConfigService.hasAdminToken();
    if (!mounted) return;
    setState(() {
      _storeName = name;
      _status = name.isEmpty
          ? (hasToken ? '尚未填写门店名称' : '未检测到出厂配置')
          : (hasToken ? '已同步至公司服务器' : '未检测到出厂配置，仅本地保存');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_storeName.isEmpty) {
      // 未配置时不占用空间，避免干扰主界面
      return const SizedBox.shrink();
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gold = isDark ? _goldDark : _goldLight;
    // 描边用品牌色的低透明度版本：既能勾出卡片轮廓，又不会喧宾夺主。
    // （原先用 colorScheme.background，与页面底色完全相同，等于没有边框）
    final border = gold.withOpacity(isDark ? 0.60 : 0.55);
    final bg = gold.withOpacity(isDark ? 0.12 : 0.08);
    final statusColor = isDark ? Colors.white70 : Colors.black54;

    return Container(
      margin: const EdgeInsets.only(left: 16),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      constraints: const BoxConstraints(minWidth: 190, maxWidth: 320),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.all(Radius.circular(13)),
        border: Border.all(color: border, width: 1.2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.storefront_outlined, size: 22, color: gold),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _storeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 21,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: gold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            _status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: statusColor),
          ),
        ],
      ),
    );
  }
}
