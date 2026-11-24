# 本机 MCP

TickBar 可在菜单栏进程内提供只读 MCP 服务，供本机 AI Agent 查询股票与 ETF 篮子监控数据。

## 启用

1. 打开 **设置 → 通用 → 本机 MCP**，打开开关。
2. 复制 **Endpoint** 与 **Bearer token**（token 存在钥匙串，不会进入应用备份）。
3. 保持 TickBar 运行；无需打开 ETF 面板即可查询 ETF 快照（必要时由 MCP 触发一轮按需刷新）。

默认地址：`http://127.0.0.1:18766/mcp`

## 工具

| 工具 | 说明 |
| --- | --- |
| `get_stock_quotes` | 参数 `market`（`a`/`hk`/`us`/`kr`）与 `codes`（最多 20 个）。复用 TickBar 数据源与限流，不写入自选。 |
| `get_etf_snapshot` | 20 只 ETF 篮子：**成交额统计**（总量/分时累计）、**历史对比**（前一交易日与近 N 日均值参考额及 pace）、**大/中/小三档**成交记录分类、分 ETF 排名。 |

传输为无会话 JSON-RPC（POST `application/json`），请求头需包含 `Authorization: Bearer <token>` 与 `Accept: application/json`。

## Agent Skill

仓库内可选安装：`skills/tickbar-market-data/SKILL.md`（说明工具选择与字段含义）。
