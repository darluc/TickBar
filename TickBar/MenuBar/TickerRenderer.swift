import Foundation
import AppKit

/// 菜单栏单条内容。
enum TickerItem {
    case quote(Quote)
}

/// 状态栏渲染器:严格按照 Pulse 风格，简洁干净，无多余配色与图标。
struct TickerRenderer {
    var scheme: TickerColorScheme = .mono
    var font: NSFont = NSFont.menuBarFont(ofSize: 0)
    var showsQuoteCode: Bool = true
    var showsQuoteName: Bool = false

    /// 统一使用纯净单色 (macOS 状态栏白 #E6E8EB)
    private let textColor = NSColor(srgbRed: 0.902, green: 0.910, blue: 0.922, alpha: 1.0)

    func render(items: [TickerItem]) -> NSAttributedString {
        guard !items.isEmpty else { return NSAttributedString() }

        let out = NSMutableAttributedString()
        let separatorAttr = NSAttributedString(string: "  ·  ", attributes: [
            .font: font,
            .foregroundColor: textColor.withAlphaComponent(0.4)
        ])

        for (i, item) in items.enumerated() {
            if i > 0 { out.append(separatorAttr) }
            switch item {
            case .quote(let q):
                out.append(piece(for: q))
            }
        }
        return out
    }

    private func piece(for q: Quote) -> NSAttributedString {
        let codeAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
            .foregroundColor: textColor
        ]
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: textColor
        ]
        let pctAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: textColor
        ]

        let display = displayCode(for: q.symbol)
        let priceStr = formatPrice(q.effectivePrice, for: q.symbol.market)
        let sign = q.effectiveChange >= 0 ? "+" : ""
        let pctStr = String(format: "%@%.2f%%", sign, q.effectiveChangePct * 100)

        let s = NSMutableAttributedString()
        if showsQuoteCode {
            s.append(NSAttributedString(string: display + " ", attributes: codeAttr))
        }
        if showsQuoteName, !q.name.isEmpty {
            s.append(NSAttributedString(string: q.name + " ", attributes: codeAttr))
        }
        if !showsQuoteCode && !showsQuoteName {
            s.append(NSAttributedString(string: display + " ", attributes: codeAttr))
        }
        s.append(NSAttributedString(string: priceStr + " ", attributes: valueAttr))
        s.append(NSAttributedString(string: pctStr, attributes: pctAttr))
        if q.isExtended, let label = q.extendedSession?.label, !label.isEmpty {
            s.append(NSAttributedString(string: " " + label, attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize - 1, weight: .medium),
                .foregroundColor: textColor.withAlphaComponent(0.55)
            ]))
        }
        return s
    }

    private func displayCode(for symbol: SymbolID) -> String {
        switch symbol.market {
        case .us:  return symbol.code.uppercased()
        case .hk:  return symbol.code
        case .a:   return symbol.code
        case .kr:  return symbol.code
        case .crypto: return symbol.code.uppercased()
        }
    }

    private func formatPrice(_ price: Decimal, for market: Market? = nil) -> String {
        let fmt = NumberFormatter()
        let digits: Int
        if market == .kr {
            digits = 0
        } else if market == .crypto {
            let d = (price as NSDecimalNumber).doubleValue
            if d >= 1.0 {
                digits = 2
            } else if d >= 0.01 {
                digits = 4
            } else {
                digits = 6
            }
        } else {
            digits = 2
        }
        fmt.minimumFractionDigits = digits
        fmt.maximumFractionDigits = digits
        return fmt.string(from: NSDecimalNumber(decimal: price)) ?? "\(price)"
    }
}
