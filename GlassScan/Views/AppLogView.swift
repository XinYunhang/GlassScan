import SwiftUI
import UIKit

struct AppLogView: View {
    @State private var appLog = AppLog.shared
    @State private var selectedModule: LogModule? = nil
    @State private var onlyErrors = false
    @State private var searchText = ""
    @State private var expandedIDs: Set<UUID> = []
    @State private var showClearConfirm = false
    @State private var toastText: String?

    private var filteredEntries: [AppLogEntry] {
        appLog.entries.filter { entry in
            if onlyErrors && entry.level != .error && entry.level != .warn {
                return false
            }
            if let selectedModule, entry.module != selectedModule {
                return false
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return entry.message.lowercased().contains(q)
                || entry.detail.lowercased().contains(q)
                || entry.module.rawValue.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if appLog.entries.isEmpty {
                    ContentUnavailableView(
                        "暂无运行日志",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("当你扫码、开水、停阀结算、查询洗衣房或拉起支付宝时，这里会自动记录脱敏后的完整过程。")
                    )
                } else {
                    List {
                        Section {
                            filterBar
                                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                                .listRowBackground(Color.clear)
                        }

                        Section("共 \(filteredEntries.count) 条（已自动脱敏，点击展开详情）") {
                            ForEach(filteredEntries) { entry in
                                logRow(entry)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }

            if let toastText {
                Text(toastText)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 16)
            }
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索接口、错误码或关键字")
        .toolbar {
            if !filteredEntries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = appLog.formattedExportText(filtered: filteredEntries)
                        showToast("已复制 \(filteredEntries.count) 条脱敏日志")
                    } label: {
                        Label("复制日志", systemImage: "doc.on.doc")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: appLog.makeExportDocument(filtered: filteredEntries),
                        preview: SharePreview("GlassScan 运行日志 (\(filteredEntries.count) 条)")
                    ) {
                        Label("导出日志", systemImage: "square.and.arrow.up")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog("清空全部运行日志？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) {
                appLog.clear()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip("全部", selected: selectedModule == nil && !onlyErrors) {
                        selectedModule = nil
                        onlyErrors = false
                    }
                    chip("警告/错误", selected: onlyErrors, tint: .orange) {
                        onlyErrors.toggle()
                    }
                    ForEach(LogModule.allCases) { module in
                        chip(module.rawValue, selected: selectedModule == module) {
                            selectedModule = (selectedModule == module) ? nil : module
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, tint: Color = .blue, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .buttonStyle(.plain)
            .glassEffect(
                selected ? .regular.tint(tint).interactive() : .regular.interactive(),
                in: .capsule
            )
    }

    @ViewBuilder
    private func logRow(_ entry: AppLogEntry) -> some View {
        if entry.detail.isEmpty {
            logHeader(entry)
                .padding(.vertical, 2)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedIDs.contains(entry.id) },
                    set: { open in
                        if open { expandedIDs.insert(entry.id) } else { expandedIDs.remove(entry.id) }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView(.horizontal) {
                        Text(entry.detail)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    Button("复制本条详情") {
                        UIPasteboard.general.string = "\(entry.message)\n\(entry.detail)"
                        showToast("已复制本条日志")
                    }
                    .font(.caption2)
                }
                .padding(.top, 4)
            } label: {
                logHeader(entry)
            }
        }
    }

    private func logHeader(_ entry: AppLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.level.rawValue)
                    .font(.caption2.monospaced().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelColor(entry.level).opacity(0.18), in: Capsule())
                    .foregroundStyle(levelColor(entry.level))

                Text(entry.module.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .net: return .cyan
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toastText = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                if toastText == text { toastText = nil }
            }
        }
    }
}
