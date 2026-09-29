#!/usr/bin/env bash
#
# 把 Tools/emby-dev/config/ 从零配置成一个可用的开发实例(幂等,可重复跑)。
#
# 为什么需要它:config/ 不入库(含媒体库定义与用户),删掉重来时如果靠手点 Emby
# 网页向导,下面这些「只有踩过才知道」的细节每次都要重新摸一遍:
#
#   · 判断向导是否已完成,只能看「匿名 GET /Startup/Configuration 返回 401」——
#     4.9 的 /System/Info/Public 里**没有** StartupWizardCompleted 字段,
#     照名字猜会永远判成「未完成」,然后朝已配置好的实例重复 POST Startup/User
#   · Startup/Complete 之后既有 token 会失效,必须重新登录(这里靠 401 自动重登兜底)
#   · 操作媒体库路径的 API 必须用 **Id(整数)**,用 Name 会报 "Unrecognized Guid format";
#     而 POST /Library/VirtualFolders/Paths 还会「报 500 但实际生效」——
#     所以每一步都要 GET 回读验证,不能只看状态码
#   · LibraryOptions 的 body 是 {"Id":..,"LibraryOptions":{..}} 包装形式,
#     直接提交裸的 LibraryOptions 会报 "Object reference not set to an instance of an object"
#   · POST /Users/New 建出来的用户默认就是非管理员(IsAdministrator=false),
#     不用再补一次 Policy 更新
#   · 给**别的**用户改密码时 CurrentPw 传空串即可(只有改自己才必须填旧密码);
#     Emby 不回显明文,所以幂等判断只能看 HasPassword 这个布尔
#
# 用法:
#   export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
#   docker compose up -d && ./setup-instance.sh
#
# 环境变量:BASE_URL / ADMIN_USER / ADMIN_PASS / VIEWER_USER / VIEWER_PASS / PYTHON 可覆盖。

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8096/emby}"
ADMIN_USER="${ADMIN_USER:-luma}"
ADMIN_PASS="${ADMIN_PASS:-lumadev}"
VIEWER_USER="${VIEWER_USER:-viewer}"
VIEWER_PASS="${VIEWER_PASS:-viewerdev}"
PYTHON="${PYTHON:-python3}"

if [ ! -x "$PYTHON" ]; then
  echo "找不到 python3: $PYTHON(可用 PYTHON=... 覆盖)" >&2
  exit 1
fi

BASE_URL="$BASE_URL" ADMIN_USER="$ADMIN_USER" ADMIN_PASS="$ADMIN_PASS" \
  VIEWER_USER="$VIEWER_USER" VIEWER_PASS="$VIEWER_PASS" "$PYTHON" - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ["BASE_URL"]
USER = os.environ["ADMIN_USER"]
PASS = os.environ["ADMIN_PASS"]
VIEWER_USER = os.environ["VIEWER_USER"]
VIEWER_PASS = os.environ["VIEWER_PASS"]

AUTH_HEADER = 'Emby Client="LumaPlayer", Device="Mac", DeviceId="luma-dev-setup", Version="0.1"'

# 期望的媒体库。路径是**容器内**路径,与 docker-compose.yml 的挂载一一对应。
WANTED = [
    ("本地测试库", "movies", "/mnt/media/Movies"),
    ("本地剧集库", "tvshows", "/mnt/media/TV"),
]

# 期望的非管理员用户。建它的用途是测「多账号」:同一台服务器换个账号登录,
# 续播位置是否按 UserId 隔离;以及一个**真服务器上不敢试**的场景——
# 把某个用户临时禁用,看客户端怎么处理。
#
# ⚠️ 实测(4.9.5.0):禁用用户后 POST /Users/AuthenticateByName 返回的是
# **403 +「您的账户已被禁用」**,不是 401。所以它走的是客户端
# `ServerLoginError.api(.forbidden)` 那条分支,文案是
# 「没有访问权限,请检查该服务器上的用户权限。」——**与真实原因不符**。
# 实测见 README.md「非管理员用户」一节。
WANTED_USERS = [
    (VIEWER_USER, VIEWER_PASS),
]

STATE = {"token": None}


def call(method, path, payload=None, query=None, token=None):
    """发请求。返回 (状态码, 响应文本)。不抛异常——调用方按需判断。"""
    url = BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    headers = {"Authorization": AUTH_HEADER}
    if token:
        headers["X-Emby-Token"] = token
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    req = urllib.request.Request(url, method=method, headers=headers, data=data)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()
    except urllib.error.URLError as exc:
        return 0, str(exc)


def login():
    status, body = call("POST", "/Users/AuthenticateByName", {"Username": USER, "Pw": PASS})
    if status != 200:
        raise SystemExit(f"登录失败: {status} {body[:200]}")
    auth = json.loads(body)
    STATE["token"] = auth["AccessToken"]
    print(f"   登录为 {auth['User']['Name']} / UserId={auth['User']['Id'][:8]}…")


def authed(method, path, payload=None, query=None):
    """带认证的请求。收到 401 就重新登录一次再重试——
    Startup/Complete 会让既有 token 失效,这一步不能省。"""
    for attempt in (1, 2):
        status, body = call(method, path, payload=payload, query=query, token=STATE["token"])
        if status != 401 or attempt == 2:
            return status, body
        print("   token 失效,重新登录后重试")
        login()
    return status, body


def get_json(path, query=None):
    status, body = authed("GET", path, query=query)
    if status != 200:
        raise SystemExit(f"GET {path} 失败: {status} {body[:200]}")
    return json.loads(body)


def folders():
    return get_json("/Library/VirtualFolders")


def step(text):
    print(f"—— {text}")


# ---------------------------------------------------------------- 1. 首次向导
step("检查首次配置状态")
info = get_json("/System/Info/Public")
print(f"   {info.get('ServerName')} / Emby {info.get('Version')}")

# ⚠️ 判断依据:匿名 GET /Startup/Configuration 返回 401 = 向导已完成;
# 200 = 未完成(返回待填的配置 JSON)。见文件头注释。
wizard_status, _ = call("GET", "/Startup/Configuration")
if wizard_status == 401:
    print("   已完成,跳过向导")
elif wizard_status == 200:
    print("   未完成,走 Startup/* 端点(无需手点网页)")
    call("POST", "/Startup/Configuration",
         {"UICulture": "zh-cn", "MetadataCountryCode": "CN", "PreferredMetadataLanguage": "zh-cn"})
    call("POST", "/Startup/User", {"Name": USER, "Password": PASS})
    call("POST", "/Startup/RemoteAccess",
         {"EnableRemoteAccess": False, "EnableAutomaticPortMapping": False})
    status, body = call("POST", "/Startup/Complete")
    print(f"   Startup/Complete -> {status}")
else:
    raise SystemExit(f"   无法判断向导状态: {wizard_status}")

# ---------------------------------------------------------------- 2. 登录
step("登录")
login()

# ---------------------------------------------------------------- 3. 普通用户
step("非管理员用户")

for uname, upass in WANTED_USERS:
    found = next((u for u in get_json("/Users") if u.get("Name") == uname), None)

    if found is None:
        # 这个端点建出来的用户默认 IsAdministrator=false,不用再补 Policy。
        status, body = authed("POST", "/Users/New", {"Name": uname})
        if status != 200:
            raise SystemExit(f"   建用户「{uname}」失败: {status} {body[:200]}")
        found = json.loads(body)
        print(f"   建用户「{uname}」Id={found['Id'][:8]}…")
    else:
        print(f"   已存在「{uname}」")

    # Emby 不回显明文密码,只能靠 HasPassword 判断该不该补设。
    # 改**别人**的密码时 CurrentPw 传空串即可。
    if not found.get("HasPassword"):
        authed("POST", f"/Users/{found['Id']}/Password",
               {"Id": found["Id"], "CurrentPw": "", "NewPw": upass})
        print("      已设置密码")

    # 回读断言,不信任上一步——默认值也是别人给的约定,写出来才算核实过。
    final = next(u for u in get_json("/Users") if u["Name"] == uname)
    policy = final.get("Policy") or {}
    if policy.get("IsAdministrator"):
        raise SystemExit(f"   「{uname}」意外拿到了管理员权限")
    if not final.get("HasPassword"):
        raise SystemExit(f"   「{uname}」密码未生效")
    print(f"      IsAdministrator={policy.get('IsAdministrator')} "
          f"HasPassword={final.get('HasPassword')} "
          f"可见全部媒体库={policy.get('EnableAllFolders')}")

# ---------------------------------------------------------------- 4. 媒体库
step("媒体库")

for name, collection, path in WANTED:
    existing = next((f for f in folders() if f["Name"] == name), None)

    if existing is None:
        # POST /Library/VirtualFolders 是这一圈里唯一会用状态码正常汇报的端点。
        status, body = authed("POST", "/Library/VirtualFolders",
                              query={"name": name, "collectionType": collection,
                                     "paths": path, "refreshLibrary": "true"})
        if status not in (200, 204):
            raise SystemExit(f"   建库「{name}」失败: {status} {body[:200]}")
        print(f"   建库「{name}」({collection}) -> {path}")
    else:
        print(f"   已存在「{name}」")

    # 回读,不信任上一步的返回码(见文件头注释)。
    existing = next(f for f in folders() if f["Name"] == name)
    fid = existing["ItemId"]

    # 路径可能因为目录重组而过期:不在期望集合里的一律移除,缺的补上。
    current = list(existing.get("Locations") or [])
    for stale in [p for p in current if p != path]:
        # DELETE 需要 Id;用 Name 会得到 "Unrecognized Guid format"。
        authed("DELETE", "/Library/VirtualFolders/Paths", query={"Id": fid, "Path": stale})
        print(f"   移除旧路径 {stale}")
    if path not in current:
        # 这个 POST 已知会返回 500 但实际生效,所以只回读验证。
        authed("POST", "/Library/VirtualFolders/Paths", query={"Id": fid, "Path": path})

    # 续播门槛:默认 120 秒意味着 2 分钟以内的素材永远不会产生续播位置。
    # 测试素材里有 2 分钟的特辑,所以统一设 0。
    folder = next(f for f in folders() if f["Name"] == name)
    options = dict(folder["LibraryOptions"])
    options["MinResumeDurationSeconds"] = 0
    authed("POST", "/Library/VirtualFolders/LibraryOptions",
           {"Id": fid, "LibraryOptions": options}, query={"Id": fid})

    final = next(f for f in folders() if f["Name"] == name)
    opts = final["LibraryOptions"]
    print(f"      路径 {final.get('Locations')} | MinResumeDurationSeconds "
          f"{opts.get('MinResumeDurationSeconds')}")

# ---------------------------------------------------------------- 5. 收尾
step("触发扫描")
authed("POST", "/Library/Refresh")

step("结果")
for f in folders():
    print(f"   Id={f['ItemId']:>3}  {f['Name']}  ({f.get('CollectionType')})  {f.get('Locations')}")
for u in get_json("/Users"):
    policy = u.get("Policy") or {}
    role = "管理员" if policy.get("IsAdministrator") else "普通用户"
    print(f"   {role}  {u['Name']}  Id={u['Id'][:8]}…")
print("\n完成。媒体库内容由 gen-media.sh 生成,若为空请确认已跑过该脚本。")
PY
