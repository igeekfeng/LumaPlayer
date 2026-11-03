# danmu_api 本地弹幕服务

给 LumaPlayer 当弹幕后端的自建弹弹play 兼容服务。可行性分析与接口核对见
`docs/DANMU_API_FEASIBILITY.md`。

## 首次启动

```bash
cp env.example config/.env
docker compose up -d
```

`env.example` 故意不带前导点:根 `.gitignore` 的 `.*` 规则会把所有 dotfile 排除,
放 `config/.env.example` 就进不了仓库。

## 起停

```bash
docker compose up -d        # 启动 / 重建
docker compose logs -f      # 日志
docker compose down         # 停止
```

镜像更新(上游平台接口经常变,建议定期拉):

```bash
docker compose pull && docker compose up -d
```

## 配置

改 `config/.env` 就行,**不需要重启容器** —— danmu_api 会 watch 这个文件并热重载。
改了 `docker-compose.yml` 或镜像版本才需要 `docker compose up -d` 重建。

`config/.env` 不进仓库,换机器记得一起带走。

## 地址

LumaPlayer 侧要填的地址(等 `DANMU_API_FEASIBILITY.md` §3 的接入改造落地后):

- 保持 `TOKEN=87654321`(默认值):`http://127.0.0.1:9321`
- 改了令牌:`http://127.0.0.1:9321/<TOKEN>`

管理界面 `http://127.0.0.1:9321/`,需要 `ADMIN_TOKEN` 才进得去。

## 目录

```
docker-compose.yml   服务定义
env.example          配置模板(只列用到的变量)
config/.env          运行时配置,从 env.example 复制,不入库
.cache/              运行时缓存,不入库
```

`.cache/` 要留着 —— 重启容器后收藏、Bangumi Data、剧集 ID 索引都从这里面恢复。
删掉就重新下载(约 4 MB)。
