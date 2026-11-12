# TickBar

**A lightweight macOS menu bar app for live stock quotes and portfolio P&L.**
*macOS 菜单栏上的轻量盯盘工具 — 实时滚动自选股价格,一键查看持仓盈亏。*

[简体中文](README.md) · [English](README.en.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B-black?logo=apple)](https://www.apple.com/macos)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![CI](https://github.com/darluc/TickBar/actions/workflows/ci.yml/badge.svg)](https://github.com/darluc/TickBar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/darluc/TickBar?color=brightgreen&logo=github)](https://github.com/darluc/TickBar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/darluc/TickBar/total?color=blue&logo=github)](https://github.com/darluc/TickBar/releases)

---

## TL;DR

TickBar squeezes A-share / HK / US quotes into a tiny scrolling strip in the macOS menu bar. Click it for a compact 360pt panel showing your portfolio P&L, market indices, and price alerts — no window stealing, no cloud, no tracking.

## Screenshots

<p align="center">
  <img src="docs/screenshots/pane1.png" alt="Watchlist panel" width="32%">
  <img src="docs/screenshots/pane2.png" alt="ETF Capital monitor (screenshot 2)" width="32%">
  <img src="docs/screenshots/pane3.png" alt="ETF cumulative turnover and turnover ranking" width="32%">
</p>

## ✨ Acknowledgments

TickBar was originally named **PanBar**, and the open-source project [PanBar](https://github.com/TNT-Likely/PanBar) is its starting point. Since renaming to TickBar, we've kept the original lightweight-watchlist spirit and kept iterating.

🙏 Thanks to the original project: [PanBar](https://github.com/TNT-Likely/PanBar)

## Features

- **Scrolling menu bar ticker** — pick which tickers to scroll, plus three summary metrics (today's P&L / total assets / lifetime P&L)
- **Multi-market** — A-share / HK / US in one place, **auto-aggregated by base currency (¥ / $ / HK$)**
- **Multiple watchlists** — group management (create / rename / delete / reorder), cross-group move via **Option+drag**, drag within group to sort; quick switch via **Cmd+1 ~ Cmd+9**
- **Market indices** — 8 presets (SSE / SZSE / ChiNext / CSI300 / HSI / DJI / NDX / SPX), optionally shown in the ticker
- **Price alerts** — multi-condition (primary + secondary, AND/OR), daily trigger cap, trading-hours-only, weekdays-only
- **Configurable data sources** — Tencent / EastMoney / Yahoo / Finnhub / Naver / Binance, **per-market priority**
- **Stock search** — Chinese / pinyin / symbol, backed by Tencent smartbox
- **Mini trendline** — mini price curve driven by **real intraday data**
- **Privacy mode** — auto-masks the ticker during screen sharing or recording; ⌘⌃M to toggle manually
- **Color schemes** — Eastern (red-up / green-down), Western (green-up / red-down), or monochrome — switch live
- **Localization** — Simplified Chinese / English
- **Custom shortcuts** — global recorder, bind whatever you like
- **Full backup & restore** — one JSON contains all holdings / watchlist / alerts / settings
- **Fully local** — SQLite + cold-start FX cache · zero telemetry · zero cloud sync · zero ads

## Install

**Download the DMG** (Apple Developer ID notarized — Gatekeeper passes after a one-time "verified" prompt):

[**↓ Latest release**](https://github.com/darluc/TickBar/releases/latest) → double-click the `.dmg` → drag TickBar into Applications.

Or build from source:

```bash
brew install xcodegen create-dmg
git clone https://github.com/darluc/TickBar.git
cd TickBar
make run         # build & launch
```

## ☕ Support This Project

TickBar is fully free & open source — **no ads, no paid features**. If you find it useful, buy me a coffee ☕ to support ongoing development.

If this project helps you, consider buying me a coffee!

**PayPal:** [Buy Me a Coffee](https://paypal.me/imzvz/5USD)

**Crypto Donations**

| Token | Network | Address |
|-------|---------|---------|
| USDC | Base | `0x7341369a4073d728e59b64c20e50e804898ffc41` |

![USDC Base donation QR code](docs/qr/usdc-base.png)

> Please send only USDC on Base.
> Double-check the network before sending.

Thank you for supporting open source! ❤️

## License

MIT — see [LICENSE](LICENSE).
