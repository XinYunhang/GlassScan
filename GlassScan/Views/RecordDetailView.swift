import SwiftData
import SwiftUI
import UIKit

struct RecordDetailView: View {
    @Bindable var record: ScanRecord

    @Environment(ProbeCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @State private var expandedProbeIDs: Set<UUID> = []
    @State private var toastMessage: String?

    var body: some View {
        List {
            Section("设备备注（方便后续对照开发）") {
                TextField("例如：宿舍3号洗澡 / 1楼左2洗衣机 / 2楼吹风机", text: $record.note)
                    .onChange(of: record.note) { _, _ in
                        try? modelContext.save()
                    }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["胖乖洗澡", "U净洗衣机", "U净烘干机", "U净吹风机"], id: \.self) { tag in
                            Button(tag) {
                                record.note = tag
                                try? modelContext.save()
                            }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("基础解析") {
                LabeledContent("识别平台", value: record.platform.displayName)
                LabeledContent("采集方式", value: "\(record.source.displayName) (\(record.symbology))")
                LabeledContent("采集时间", value: record.createdAt.formatted(date: .numeric, time: .standard))
                LabeledContent("静/动态对比", value: record.stabilityHint)
                if !record.extractedDeviceHint.isEmpty {
                    LabeledContent("提取设备标识", value: record.extractedDeviceHint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("二维码原文")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("复制原文") {
                            UIPasteboard.general.string = record.rawText
                            showToast("已复制二维码原文")
                        }
                        .font(.caption)
                    }
                    Text(record.rawText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if !record.urlHost.isEmpty || !record.queryItems.isEmpty {
                Section("URL 结构拆解") {
                    if !record.urlScheme.isEmpty {
                        LabeledContent("Scheme", value: record.urlScheme)
                    }
                    if !record.urlHost.isEmpty {
                        LabeledContent("Host", value: record.urlHost)
                    }
                    if !record.urlPath.isEmpty {
                        LabeledContent("Path", value: record.urlPath)
                    }
                    ForEach(record.queryItems) { item in
                        LabeledContent(item.key, value: item.value)
                            .font(.caption.monospaced())
                    }
                }
            }

            Section("自动查询结果（\(record.probes.count) 项）") {
                if record.probes.isEmpty {
                    Text("暂无接口查询结果，可点击下方按钮重新探测。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(record.probes) { probe in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedProbeIDs.contains(probe.id) },
                                set: { isOpen in
                                    if isOpen {
                                        expandedProbeIDs.insert(probe.id)
                                    } else {
                                        expandedProbeIDs.remove(probe.id)
                                    }
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(probe.method) \(probe.endpoint)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                if !probe.redirectChain.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("重定向链：")
                                            .font(.caption2.weight(.semibold))
                                        ForEach(probe.redirectChain, id: \.self) { hop in
                                            Text("↳ \(hop)")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                if !probe.headers.isEmpty {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("关键响应头：")
                                            .font(.caption2.weight(.semibold))
                                        ForEach(probe.headers) { h in
                                            Text("\(h.key): \(h.value)")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                if !probe.rawBody.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("响应体预览（格式化）")
                                                .font(.caption2.weight(.semibold))
                                            Spacer()
                                            Button("复制响应") {
                                                let clean = Sanitizer.sanitizeText(
                                                    probe.rawBody,
                                                    enabled: coordinator.sanitizeExport
                                                )
                                                UIPasteboard.general.string = clean
                                                showToast("已复制脱敏响应体")
                                            }
                                            .font(.caption2)
                                        }
                                        ScrollView(.horizontal) {
                                            Text(probe.rawBody)
                                                .font(.caption2.monospaced())
                                                .textSelection(.enabled)
                                                .padding(10)
                                        }
                                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: probe.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(probe.success ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(probe.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(probe.summary) · \(probe.durationMs)ms")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("操作与导出") {
                Button {
                    Task {
                        await coordinator.reprobe(record: record, context: modelContext)
                        showToast("已重新探测并更新保存")
                    }
                } label: {
                    Label(coordinator.isProbing ? "探测中…" : "重新执行自动探测", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isProbing)

                Button {
                    Task {
                        await coordinator.probeUjingDirectly(record: record, context: modelContext)
                        showToast("已用 U净 scanWasherCode 探测完成")
                    }
                } label: {
                    Label("强制用 U净扫码接口探测", systemImage: "washer.fill")
                }
                .disabled(coordinator.isProbing)

                Button {
                    let json = ExportService.buildJSONString(records: [record], sanitize: coordinator.sanitizeExport)
                    UIPasteboard.general.string = json
                    showToast("已复制本条脱敏 JSON")
                } label: {
                    Label("复制本条脱敏 JSON（发给 AI）", systemImage: "doc.on.doc")
                }

                ShareLink(
                    item: ExportService.makeDocument(records: [record], sanitize: coordinator.sanitizeExport),
                    preview: SharePreview("GlassScan-\(record.displayTitle)")
                ) {
                    Label("分享 / 导出本条 JSON 文件", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(record.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 16)
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }
}
