import SwiftUI

/// Pulse 风格:在浮动窗内搜索并添加标的,不跳出设置页。
struct PopoverSearch: View {
    @EnvironmentObject var vm: PopoverViewModel
    @Environment(\.container) private var container

    var onClose: () -> Void

    @StateObject private var searchVM = SymbolSearchViewModel()
    @State private var localQuery: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                TextField(L("search.placeholder", comment: "搜索代码 / 名称"), text: $localQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($fieldFocused)
                    .onChange(of: localQuery) { value in
                        searchVM.updateQuery(value)
                    }
                    .onSubmit {
                        pickFirst()
                    }

                if searchVM.loading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else if !localQuery.isEmpty {
                    Button {
                        localQuery = ""
                        searchVM.updateQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onClose) {
                    Text(L("action.cancel", comment: "取消"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            if !searchVM.results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(searchVM.results) { result in
                            resultRow(result)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
            } else if !localQuery.isEmpty && !searchVM.loading {
                Text(L("search.noResults", comment: "没有匹配的标的"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .onAppear {
            searchVM.bind(container?.symbolSearch ?? DependencyContainer.shared?.symbolSearch)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                fieldFocused = true
            }
        }
    }

    private func resultRow(_ result: SymbolSearchResult) -> some View {
        let added = vm.isOnWatchlist(result.symbol)
        return Button {
            guard !added else { return }
            vm.addFromSearch(result)
            localQuery = ""
            searchVM.updateQuery("")
            fieldFocused = true
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(displayCode(result.symbol))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                MarketBadge(market: result.symbol.market)
                if added {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(added ? Color.primary.opacity(0.03) : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(added)
    }

    private func pickFirst() {
        guard let first = searchVM.results.first else { return }
        guard !vm.isOnWatchlist(first.symbol) else { return }
        vm.addFromSearch(first)
        localQuery = ""
        searchVM.updateQuery("")
    }

    private func displayCode(_ s: SymbolID) -> String {
        s.market == .us ? s.code.uppercased() : s.code
    }
}
