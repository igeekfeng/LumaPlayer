#!/bin/bash
#
# check-privacy.sh
#
# 开源前的隐私自检。扫描**将被提交的文件**(git ls-files)是否含:
#   1. 真实服务器地址 / 域名(只允许白名单里的示例域与官方域)
#   2. 个人身份信息(邮箱、Apple Team ID、证书 UID)
#   3. 本机绝对路径(会泄露用户名)
#   4. 疑似密钥 / token 明文
#
# 用法(仓库根执行):
#   ./Scripts/check-privacy.sh
# 退出码 0 = 干净;1 = 有命中,逐条列出。
#
# ⛔ 新增真实服务器时**不要**把它加进白名单 —— 应当把它从代码和文档里删掉,
#    换成示例域。白名单只放「本来就是公开的」域名。

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# ── 白名单:公开的示例域与官方域,允许出现在仓库里 ──
# （白名单里的 shields 徽章图床是公开服务,与服务器无关。）
# ⚠️ 这里只放「本来就是公开的」域名:示例域、Apple / Emby 官方、TMDB 与弹弹play 的
#    官方 API 与文档站、GitHub / GNU(许可证链接)。**用户自己的服务器一律不进白名单**。
ALLOWED_DOMAINS='^(example\.com|.*\.example\.com|.*\.emby\.media|.*\.apple\.com|com\.apple\..*|.*\.test|.*\.foo|.*\.local|localhost|.*\.invalid|.*\.example|.*\.shields\.io|themoviedb\.org|.*\.themoviedb\.org|.*\.tmdb\.org|.*\.baidu\.com|.*\.baidupcs\.com|.*\.dandanplay\.(com|net)|github\.com|.*\.github\.com|gnu\.org|.*\.gnu\.org|fsf\.org|.*\.fsf\.org)$'

# ── 个人身份信息模式,base64 存放 ──
# 之所以编码:明文写在这里等于把要防的东西又写进仓库一遍。
# 改成自己的模式:`printf '%s' '<你的模式>' | base64`
PERSONAL_B64='eGlhb2ZlbmdlZWt8QjRWUUxWOTlLUnxHWlE4Mzk3WFI0fFVUM0o5RjRHWFo='
PERSONAL_PATTERN=$(printf '%s' "$PERSONAL_B64" | base64 -D 2>/dev/null || printf '%s' "$PERSONAL_B64" | base64 -d)

# 滤掉 Swift 成员访问噪声(`类型名.属性名` 不是域名)
SWIFT_NOISE='^(FileManager|NetworkDiagnostics|MPVError|EmbyAPIError|EmbyAPIClient|CredentialStore|CredentialFileStore|LegacyKeychainImport|PlaybackFailureProbe|ServerRegistry|ServerConnection|PlayerStatistics|ProcessInfo|MPNowPlayingInfoCenter|EmbyResponseCache|MPVPlayer|LibrarySort|Metrics|Self|self|result|probe|stored|sent|updated|items|raw|parts|fields|requests|duration|elapsed|session|item|detail|episode|profile|plan|response|context|endpoint|configuration|connection|player|track|viewModel|list|nodes|url|file|page|cache|store|state|error|container|reporter|recorder|mutex|credentials|tasks|sleeps|queue|payload|candidates|lines|images|entries|attempts|rows|targets|logs|outDir|cArgs|directory|wrapper|profiles|data|facts|public|storage|decoder|secondCredentials|embySameType|logger|probed|prepared|insertionOrder|accessOrder|playback|marks|ApiClient|test|os)\.'

fail=0
report() { printf '\n❌ %s\n' "$1"; shift; printf '%s\n' "$@"; fail=1; }

total=$(git ls-files | wc -l | tr -d ' ')
[ "$total" -eq 0 ] && { echo "没有已跟踪文件,跳过。"; exit 0; }
echo "扫描 $total 个已跟踪文件…"

# ── 1. 真实域名 ──
#
# ⚠️ 两处过滤是**必需**的,否则这份检查会被噪声淹掉(2026-10-21 修):
#
# ① **右边界**:TLD 后面必须是非标识符字符。少了它,`…durations.compactMap` 里的
#    `com` 会被当成 TLD、`…APIClient.topLevelKeys` 里的 `top` 同理 ——
#    上一版就是这样积了 40 条误报,检查等于失效。
# ② **全小写**:域名标签里出现大写就当成 Swift 类型名 / 枚举 case
#    (`TMDBEndpoint.tv` / `HomeHero.info` / `geometry.contentInsets.top`)。
#    真实服务器域名一律小写;万一真有人写了大写域名,这条会漏 —— 由人工复核兜。
#    目录名 / 主机名里混大写的写法不常见,这个取舍值得。
#
# `sed` 去掉 ① 匹配到的那个尾随分隔符,还原成干净域名再比对白名单。
DOMAIN_RE='([a-zA-Z0-9][a-zA-Z0-9-]*\.)+(org|com|net|cn|io|tv|cc|xyz|top|info|biz|online|site|club|live|link|space|fun|shop)([^a-zA-Z0-9-]|$)'
dom=$(git grep -hoE "$DOMAIN_RE" -- . 2>/dev/null \
      | sed -E 's/[^a-zA-Z0-9-]$//' \
      | sort -u \
      | grep -vE "$ALLOWED_DOMAINS" \
      | grep -vE "$SWIFT_NOISE" \
      | grep -vE '[A-Z]')
if [ -n "$dom" ]; then
  report "发现白名单外的域名(确认是否为真实服务器):" "$dom"
fi

# ── 2. 个人身份信息 ──
if [ -n "$PERSONAL_PATTERN" ]; then
  per=$(git grep -nE "$PERSONAL_PATTERN" -- . 2>/dev/null)
  if [ -n "$per" ]; then report "发现个人身份信息:" "$per"; fi
fi

# ── 3. 本机绝对路径 ──
loc=$(git grep -nE '/Users/[a-z][a-zA-Z0-9._-]*/(Library|Projects|Downloads|Documents|Desktop|Applications|Movies|Music|\.workbuddy)|/home/[a-z][a-zA-Z0-9._-]*/' -- . 2>/dev/null)
if [ -n "$loc" ]; then report "发现本机绝对路径(会泄露用户名):" "$loc"; fi

# ── 4. 疑似密钥明文 ──
# 排除 Swift 的 CodingKey 映射行(枚举 case 的值就是键名本身,不是密钥)
# ⚠️ 排除表里那几个词是**测试夹具**用的占位值(`"SUPERSECRET"` / `"token-value"`):
#    它们本来就该长得像密钥,才验得出「请求里确实带上了 Authorization」。
sec=$(git grep -nEi '(accesstoken|api_key|x-emby-token|password)"?[[:space:]]*[:=][[:space:]]*"[^"]{8,}"' -- . 2>/dev/null \
      | grep -viE 'FAKE_|<redacted>|\{|\$\{|synthetic|placeholder|example|SUPERSECRET|token-value' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*case ')
if [ -n "$sec" ]; then report "发现疑似密钥明文:" "$sec"; fi

if [ "$fail" -eq 0 ]; then
  echo "✅ 通过:无真实服务器地址、无个人信息、无本机路径、无密钥明文。"
fi
exit "$fail"
