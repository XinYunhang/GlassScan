import SwiftData
import SwiftUI
import UIKit

struct RecordsTabView: View {
    @Environment(ProbeCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]

    @State private var searchText = ""
    @State private var selectedPlatform: ScanPlatform? = nil
    @State private var showDeleteAllConfirm = false
    @State private var toastMessage: String?

    private var filteredRecords: [ScanRecord] {
        records.filter { record in
            if let selectedPlatform, record.platform != selectedPlatform {
                return false
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return record.displayTitle.lowercased().contains(q)
                || record.rawText.lowercased().contains(q)
                || record.note.lowercased().contains(q)
                || record.urlHost.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if records.isEmpty {
                        ContentUnavailableView(
                            "还没有采样记录",
                            systemImage: "qrcode.viewfinder",
                            description: Text("前往「扫码」页对准胖乖洗澡、U净洗衣机或吹风机二维码，扫描后会自动查询并保存数据。")
                        )
                    } else {
                        List {
                            Section {
                                filterBar
                                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                                    .listRowBackground(Color.clear)
                            }

                            Section("共 \(filteredRecords.count) 条采样（点击查看详情 / 左滑删除）") {
                                ForEach(filteredRecords) { record in
                                    NavigationLink {
                                        RecordDetailView(record: record)
                                    } label: {
                                        RecordRowView(record: record)
                                    }
                                }
                                .onDelete(perform: deleteRecords)
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }

                if let toastMessage {
                    Text(toastMessage)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .navigationTitle("采样记录")
            .searchable(text: $searchText, prompt: "搜索备注、域名或原文")
            .toolbar {
                if !filteredRecords.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            let json = ExportService.buildJSONString(
                                records: filteredRecords,
                                sanitize: coordinator.sanitizeExport
                            )
                            UIPasteboard.general.string = json
                            showToast("已复制 \(filteredRecords.count) 条脱敏 JSON 到剪贴板")
                        } label: {
                            Label("复制 JSON", systemImage: "doc.on.doc")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(
                            item: ExportService.makeDocument(
                                records: filteredRecords,
                                sanitize: coordinator.sanitizeExport
                            ),
                            preview: SharePreview("GlassScan 采样数据 (\(filteredRecords.count) 条)")
                        ) {
                            Label("导出文件", systemImage: "square.and.arrow.up")
                        }
                    }

                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            showDeleteAllConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .confirmationDialog("清空全部采样记录？", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
                Button("清空全部 (\(records.count) 条)", role: .destructive) {
                    for item in records {
                        modelContext.delete(item)
                    }
                    try? modelContext.save()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    filterChip(title: "全部 (\(records.count))", isSelected: selectedPlatform == nil) {
                        selectedPlatform = nil
                    }
                    ForEach(ScanPlatform.allCases) { platform in
                        let count = records.filter { $0.platform == platform }.count
                        if count > 0 {
                            filterChip(
                                title: "\(platform.displayName) (\(count))",
                                isSelected: selectedPlatform == platform
                            ) {
                                selectedPlatform = platform
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .buttonStyle(.plain)
            .glassEffect(
                isSelected ? .regular.tint(.blue).interactive() : .regular.interactive(),
                in: .capsule
            )
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filteredRecords[index])
        }
        try? modelContext.save()
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeInOut(duration: 0.25)) {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }
}

private struct RecordRowView: View {
    let record: ScanRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: record.platform.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(record.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(record.rawText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Label(record.source.displayName, systemImage: "dot.radiowaves.left.and.right")
                Text("·")
                let okCount = record.probes.filter(\.success).count
                Text("探测 \(okCount)/\(record.probes.count)")
                Text("·")
                Text(record.stabilityHint)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
