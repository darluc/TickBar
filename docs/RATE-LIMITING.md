# 限流与退避

本文汇总 TickBar 目前对所有公开行情接口采用的限流手段。改动数据源或刷新逻辑时，保持这里的约束，避免再次出现整批请求被网关拒绝、备用源又被同一冷却挡住的情况。

原则：

- **先批量、后备用。** 能一次取得的行情不逐只请求；备用源只处理主源失败或明显过旧的标的。
- **可见性驱动。** 没有界面在看就不轮询；关闭窗口会取消进行中的请求。
- **按主机隔离冷却。** 实时行情、历史 K 线、各家备用源各自维护门控，一个主机的 429 不阻塞另一个主机。
- **失败才退避。** 429、连接失败和 5xx 才进入冷却；客户端解析失败不重试，直接换源。
- **缓存优先于重复请求。** 当天已经成功的数据写入磁盘或内存，重启后复用。

## HTTP 层

所有请求经 `HTTPClient`（`TickBar/Data/HTTP/HTTPClient.swift`）：

- 默认携带浏览器 User-Agent；实时数据一律 `Cache-Control: no-cache`、`reloadIgnoringLocalCacheData`。
- 非 2xx 抛 `HTTPError.badStatus`。
- HTTP 429 抛 `HTTPError.rateLimited(Retry-After)`。`Retry-After` 同时支持秒数和 HTTP 日期；缺失时由调用方决定默认冷却时间。
- 网络错误统一包装为 `HTTPError.transport`，上层据此判断是否重试。
- 单请求超时：ETF 10 秒，其他默认 8 秒。

## 自选股行情

`QuoteRefresher`（`TickBar/Infrastructure/QuoteRefresher.swift`）和 `ProviderOrchestrator`（`TickBar/Data/Providers/ProviderOrchestrator.swift`）：

- **刷新节奏**：弹窗打开时 3 秒（`min(tickerInterval, 3)`）；仅菜单栏显示时使用用户配置的间隔，默认 5 秒；系统休眠、离线或（开启「休市暂停」时）全市场休市时停止轮询。
- **一次一批**：同一次刷新按市场分组，每个市场向当前首选源发一次批量请求；同一标的出现在多个自选分组时只取一次。
- **按源回退**：按设置中的顺序依次尝试，首个成功源返回即停止。
- **失败冷却**：某个 `provider|market` 请求抛错后冷却 30 秒，冷却期内直接跳过该组合、尝试下一个源。
- **美股扩展时段**：主源失败不阻止扩展时段源；扩展源按标的逐个覆盖，只接受当前时段的真实成交。

## ETF 面板

相关实现：`ETFMonitor`、`ETFWorker`、`ETFRequestGate`、`ETFService`、`TencentETFService`、`SinaETFHistoryService`、`ETFBaselineCache`。

### 请求节奏

- 仅在 ETF 页可见且未暂停时轮询；午休、收盘、周末不刷新。
- 正常间隔 60 秒；重新显示时若距上次成功超过 20 秒立即刷新。
- 隐藏页面会取消进行中的请求，包括历史基线加载。

### 每轮请求量

- 行情：1 次东方财富批量请求（20 只 ETF + 上证综指）。
- 分时：21 次单标的请求，最多 6 路并发。
- 备用请求只在需要时发出：缺失或过旧标的的腾讯行情、失败/停滞标的的腾讯分时、失败标的的新浪历史。
- 历史基线每个交易日最多加载一次，成功后写入磁盘，重启不再请求。

### 请求门控

`ETFRequestGate` 是 actor，每个主机一个实例：

| 事件 | 处理 |
| --- | --- |
| 正常请求 | 250 毫秒启动间隔，避免瞬时并发打满 |
| HTTP 429 | 冷却 `max(Retry-After, 1)` 秒；无 `Retry-After` 时 30 秒 |
| 连接失败 / 5xx | 仅重试一次，间隔 400–900 毫秒随机 |
| 连续 3 次连接失败 / 5xx | 进入冷却：5、10、20、40、60 秒（封顶 60 秒） |
| 429 或数据无效 | 不重试，直接换备用源 |
| 任一成功 | 清零连续失败计数 |

- 实时行情与分时共用 `push2` 门控；历史 K 线使用独立的 `push2his` 门控，避免分时的 429 冷却吞掉每天一次的历史加载。
- 新浪历史备用源使用自己的门控和 250 毫秒间隔，不继承东方财富的冷却。
- 腾讯备用源使用自己的门控。

### 自动轮询退避

- 一轮结束后若实时门控仍在冷却（429 或连续传输失败），自动轮询从 60 秒退避到 60 → 120 → 240 → 480 → 600 秒，封顶 10 分钟。
- 任一轮成功（包括用户手动刷新）立即恢复 60 秒。
- 手动刷新不受退避限制，暂停时也可用。

### 数据源回退

| 数据 | 主源 | 备用 | 触发条件 |
| --- | --- | --- | --- |
| 行情 | 东方财富 `push2` `ulist.np/get` | 腾讯 `qt.gtimg.cn` | 主源缺失或时间戳过旧 |
| 分时 | 东方财富 `stock/trends2/get` | 腾讯 `app/minute/query` | 主源失败，或落后同日行情/中位进度 5 分钟以上 |
| 历史 5 分钟线 | 东方财富 `push2his` `stock/kline/get` | 新浪 `CN_MarketDataService.getKLineData` | 单只请求失败（含 429、连接失败、空响应） |

- 腾讯分时要求交易日有效、09:30 起分钟连续、累计成交额不下降，否则拒绝该响应。
- 新浪与东方财富都按收盘时刻标注 5 分钟成交额，单只标的可混用两个来源构建同一条基线。

### 对比曲线缓存与重试

- 成功构建的基线按交易日写入 `etf-baseline.json`（应用支持目录），重启或升级后当天直接复用。
- 缓存只接受 `liveDay` 与当前交易日相同的基线；跨日自动失效并重新加载。
- 加载失败后至少间隔 5 分钟再尝试；休市但面板可见时继续检查。
- 只有真正尝试失败后才提示「对比曲线暂不可用」；加载中不报错。

## 个股分析

相关实现：`StockVolumeMonitor`、`StockHoldingsMonitor`。

- **刷新节奏**：只在个股分析窗口可见时运行，60 秒一轮，仅 A 股开盘时段；重新显示时距上次成功超过 20 秒立即刷新；关闭窗口取消请求，暂停停止自动请求。
- **每轮请求**：单只标的的行情与分时，由 `StockVolumeWorker` 合并获取；不做全市场扫描。
- **公开持仓**：每个窗口打开时加载一次，按股票代码缓存 24 小时（`disclosed-stock-holdings.json`）。手动刷新会绕过缓存。接口列已裁到 `SECURITY_CODE,HOLDER_NAME,END_DATE,NOTICE_DATE,HOLD_NUM,FREE_HOLDNUM_RATIO`，单次响应从约 265 KB 降到约 46 KB。
- **ETF 份额观察**：先读 `disclosed-holdings.json`；当天数据缺失或缓存超过 24 小时才请求；成功后覆盖写入。

## 缓存一览

| 文件 / 状态 | 位置 | 生命周期 |
| --- | --- | --- |
| 对比曲线 | `etf-baseline.json` | 当前交易日 |
| 个股公开持仓 | `disclosed-stock-holdings.json` | 每只股票 24 小时 |
| ETF 份额快照 | `disclosed-holdings.json` | 当日有效，最长 24 小时 |
| 自选行情快照 | SQLite 行情缓存 | 启动时先展示，随后被实时请求覆盖 |
| ETF 分钟 / 行情 | 内存 | 当前交易日，关闭面板后释放 |
| 个股分析分钟 | 内存 | 窗口存活期间 |

## 参数汇总

| 参数 | 值 | 位置 |
| --- | --- | --- |
| ETF 请求启动间隔 | 250 ms | `ETFRequestGate.spacing` |
| ETF 429 默认冷却 | 30 s | `ETFRequestGate.rateLimited` |
| ETF 传输失败冷却 | 5–60 s，连续 3 次后触发 | `ETFRequestGate.failed` |
| ETF 临时失败重试 | 1 次，400–900 ms 抖动 | `etfAttempt` |
| ETF 分时并发 | 6 | `concurrently(limit: 6)` |
| ETF 轮询间隔 | 60 s | `ETFMonitor` |
| ETF 限流退避 | 60 → 600 s | `ETFMonitor.refresh` |
| 基线失败重试间隔 | 300 s | `ETFWorker.prepareBaseline` |
| 自选弹窗刷新 | 3 s | `QuoteRefresher.Pace.popoverOpen` |
| 菜单栏刷新 | 默认 5 s，可配置 | `QuoteRefresher.tickerInterval` |
| 行情源失败冷却 | 30 s / provider+market | `ProviderOrchestrator.cooldownDuration` |
| 个股分析轮询 | 60 s | `StockVolumeMonitor` |
| 重新显示立即刷新阈值 | 20 s | `ETFMonitor` / `StockVolumeMonitor` |

## 维护规则

- 新接口必须经过自己的 `ETFRequestGate`（或其等价门控）；不要把不同主机的请求塞进同一个门控。
- 429 不重试，直接换源或等冷却；只有连接失败和 5xx 值得重试。
- 退避放在轮询层（monitor），不要藏在解析或视图层。
- 新增备用源时，先确认它与主源的字段口径一致（时间标签、金额单位、累计/单笔），再混用数据。
- 修改参数或新增数据源时，同步更新本文与 `docs/ETF-PANEL.md`。

## 测试

- `TickBarTests/TencentETFTests.swift`：门控冷却、连续失败冷却、实时/历史门控隔离、备用源回退。
- `TickBarTests/ETFMonitorTests.swift`：可见性调度、暂停、休市、限流退避。
- `TickBarTests/ETFBaselineCacheTests.swift`：基线缓存按交易日复用、离线时命中缓存。
- `TickBarTests/SinaETFHistoryTests.swift`：新浪 5 分钟线解析、东方财富限流时构建基线。
