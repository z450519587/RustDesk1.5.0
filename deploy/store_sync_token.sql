-- ============================================================
--  lejianwen/rustdesk-api 造「永久令牌」SQL
--  原理：该服务校验 api-token 时，是把它当字符串去 MySQL 的
--        user_tokens 表查找，再判断那行的 expired_at 是否大于当前时间
--        （见源码 service/user.go InfoByAccessToken）。
--        它【不会】用 JWT 签名去验签、也不会读 JWT 里的 exp 字段。
--        所以"7天过期"只是那一行的 expired_at 到了 —— 改大即可永久。
-- ============================================================

-- 第 1 步：用管理员账号登录一次，拿到 token 字符串 T。
--   方式 A：网页控制台「设置 / 安全」里复制访问令牌（若版本支持）；
--   方式 B：命令行（管理员登录端点为 /admin/login）
--     curl -X POST https://<你的API服务器>/admin/login \
--       -H 'Content-Type: application/json' \
--       -d '{"username":"管理员名","password":"密码"}'
--   返回 JSON 里的 data.token（或 access_token）就是 T。

-- 第 2 步：把 T 对应那一行的 expired_at 改成远未来（等价于永久）。
--   253402300799 = 公元 9999-12-31 23:59:59 UTC，远大于现在，永不失效。
UPDATE user_tokens
   SET expired_at = 253402300799
 WHERE token = '<第1步拿到的T>';

-- 校验是否生效（应返回 1 行，expired_at 很大）：
SELECT token, expired_at FROM user_tokens WHERE token = '<第1步拿到的T>';

-- ============================================================
-- 安全与维护建议（重要）
-- ============================================================
-- 1) 该 token 等同管理员权限。请【专建一个只做同步的最小权限账号】，
--    不要复用你日常管理的超级管理员账号。
-- 2) token 会分发到每家门店机器（写在 store_sync.json 里）。
--    内部系统可接受；建议定期轮换：删除旧行、重新登录拿新 T 再改 expired_at。
--    删除旧令牌：DELETE FROM user_tokens WHERE token = '<旧T>';
-- 3) 风险点：若以后该开源项目升级、改成"真验 JWT 签名/exp"，此方法会失效，
--    届时请改用中继方案（见同步说明）。在此之前可放心使用。
-- 4) 【不要】把含真实 token 的 store_sync.json 提交进 Git 仓库；
--    仓库里只放 store_sync.example.json 模板。
