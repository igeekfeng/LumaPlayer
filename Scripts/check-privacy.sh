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
ALLOWED_DOMAINS='^(example\.com|.*\.example\.com|.*\.emby\.media|.*\.apple\.com|com\.apple\..*|github\.com|.*\.aimes-soft\.com|.*\.test|.*\.foo|.*\.local|localhost|.*\.invalid|.*\.example)$'

# ── 个人身份信息模式,base64 存放 ──
# 之所以编码:明文写在这里等于把要防的东西又写进仓库一遍。
# 改成自己的模式:`printf '%s' '<你的模式>' | base64`
PERSONAL_B64='eGlhb2ZlbmdlZWt8QjRWUUxWOTlLUnxHWlE4Mzk3WFI0fFVUM0o5RjRHWFo='
PERSONAL_PATTERN=$(printf '%s' "$PERSONAL_B64" | base64 -D 2>/dev/null || printf '%s' "$PERSONAL_B64" | base64 -d)

# 滤掉 Swift 成员访问噪声(`类型名.属性名` 不是域名)
SWIFT_NOISE='^(FileManager|NetworkDiagnostics|PlayerError|PlaybackEngine|ErikaPlaybackEngine|EmbyAPIError|EmbyAPIClient|CredentialStore|CredentialFileStore|LegacyKeychainImport|PlaybackFailureProbe|ServerRegistry|ServerConnection|PlayerStatistics|ProcessInfo|MPNowPlayingInfoCenter|EmbyResponseCache|LibrarySort|Metrics|Self|self|result|probe|stored|sent|updated|items|raw|parts|fields|requests|duration|elapsed|session|item|detail|episode|profile|plan|response|context|endpoint|configuration|connection|player|track|viewModel|list|nodes|url|file|page|cache|store|state|error|container|reporter|recorder|mutex|credentials|tasks|sleeps|queue|payload|candidates|lines|images|entries|attempts|rows|targets|logs|outDir|cArgs|directory|wrapper|profiles|data|facts|public|storage|decoder|secondCredentials|embySameType|logger|probed|prepared|insertionOrder|accessOrder|playback|marks|hasher|latestViews|ApiClient|test)\.'

fail=0
report() { printf '\n❌ %s\n' "$1"; shift; printf '%s\n' "$@"; fail=1; }

total=$(git ls-files | wc -l | tr -d ' ')
[ "$total" -eq 0 ] && { echo "没有已跟踪文件,跳过。"; exit 0; }
echo "扫描 $total 个已跟踪文件…"

# ── 1. 真实域名 ──
dom=$(git grep -hoE '([a-zA-Z0-9][a-zA-Z0-9-]*\.)+(org|com|net|cn|io|tv|cc|xyz|top|info|biz|online|site|club|live|link|space|fun|shop)' -- . 2>/dev/null \
      | sort -u | grep -vE "$ALLOWED_DOMAINS" | grep -vE "$SWIFT_NOISE")
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
sec=$(git grep -nEi '(accesstoken|api_key|x-emby-token|password)"?[[:space:]]*[:=][[:space:]]*"[^"]{8,}"' -- . 2>/dev/null \
      | grep -viE 'FAKE_|<redacted>|\{|\$\{|synthetic|placeholder|example' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*case ')
if [ -n "$sec" ]; then report "发现疑似密钥明文:" "$sec"; fi

if [ "$fail" -eq 0 ]; then
  echo "✅ 通过:无真实服务器地址、无个人信息、无本机路径、无密钥明文。"
fi
exit "$fail"
