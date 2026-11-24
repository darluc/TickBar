---
name: tickbar-market-data
description: Query live stock quotes and the 20-ETF basket monitor from a local TickBar app via loopback MCP. Use when the user mentions TickBar MCP, on-screen ETF turnover bands, or ad-hoc quotes outside a watchlist.
---

# TickBar market data (local MCP)

## Prerequisites

- TickBar is running on the same Mac.
- **Settings → General → Local MCP** is enabled.
- Use endpoint `http://127.0.0.1:18766/mcp` and the Bearer token from settings (Keychain).

## Tools

### `get_stock_quotes`

- `market`: `a`, `hk`, `us`, or `kr` (not `crypto`).
- `codes`: up to 20 symbol strings; keep leading zeros for HK codes.
- Response includes `partial`, per-symbol `missing`/`stale`, `quoteTime` vs `retrievedAt`, and `session` for US extended hours.
- Do not treat missing symbols as price zero.

### `get_etf_snapshot`

- No arguments.
- **`turnoverStatistics`**: `totalTurnoverYuan` (sum of covered ETF day turnover), `cumulativeTurnoverYuan` (intraday basket cumulative at the latest minute edge), `liveMinuteSlot`, coverage counts — all in CNY yuan.
- **`historicalComparison`**: `referencePreviousYuan` and `referenceAverageYuan` at the same minute slot; `paceVsPrevious` / `paceVsAverage` are ratios (`0.05` = +5%). `averageBaselineDays` is the number of complete sessions used for the mean (up to 20, min 3).
- **`tradeSizeBands`**: `small` / `medium` / `large` with `turnoverYuan`, `shareOfClassified`, and `thresholdDescription` (public trade-record size, not net flow). Missing when detail classification is unavailable.
- **`rows`**: per-ETF turnover and share of basket.
- `sessionDay` / `status` for session date and refresh state; do not treat missing bands as zero.

## Rate behavior

TickBar shares the same upstream gates as the UI. Repeated calls within ~15s reuse cached quote rows; ETF refresh while the panel is hidden is throttled by the monitor’s own `pollDelay`.
