import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct ScanTabView: View {
    @Binding var selectedTab: AppTabSelection

    @Environment(ProbeCoordinator.self) private var coordinator
    @Environment(ShowerController.self) private var shower
    @Environment(LaundryController.self) private var laundry
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]

    @State private var isTorchOn = false
    @State private var isScanningEnabled = true
    @State private var businessMode = true
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var latestRecord: ScanRecord?
    @State private var presentingRecord: ScanRecord?
    @State private var showManualInput = false
    @State private var manualText = ""
    @State private var toastMessage: String?

    @Namespace private var glassNS

    var body: some View {
        @Bindable var bindableLaundry = laundry

        ZStack {
            CameraScannerView(
                isTorchOn: $isTorchOn,
                isScanningEnabled: $isScanningEnabled
            ) { rawText, symbology in
                triggerScan(rawText: rawText, symbology: symbology, source: .camera)
            }
            .ignoresSafeArea()

            ScanReticleOverlay(isProbing: coordinator.isProbing || laundry.isWorking)
                .allowsHitTesting(false)

            VStack(spacing: 14) {
                topStatusBar
                Spacer()
                if let toastMessage {
                    Text(toastMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
                if let latestRecord {
                    latestResultCard(record: latestRecord)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomLiquidDock
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
        .sheet(item: $bindableLaundry.preparedSession, onDismiss: {
            isScanningEnabled = true
        }) { session in
            UjingOrderSheet(session: session) {
                latestRecord = nil
                selectedTab = .laundry
            }
        }
        .sheet(item: $presentingRecord, onDismiss: {
            isScanningEnabled = true
        }) { record in
            NavigationStack {
                RecordDetailView(record: record)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") {
                                presentingRecord = nil
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
            }
            .presentationDetents([.large, .medium])
            .presentationDragIndicator(.visible)
        }
        .alert("输入或粘贴二维码原文", isPresented: $showManualInput) {
            TextField("粘贴链接或设备码", text: $manualText)
            Button("取消", role: .cancel) { manualText = "" }
            Button("立即识别") {
                let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
                manualText = ""
                if !text.isEmpty {
                    triggerScan(rawText: text, symbology: "MANUAL", source: .paste)
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let decoded = await PhotoQRDecoder.decode(from: data) {
                    triggerScan(rawText: decoded.0, symbology: decoded.1, source: .photo)
                } else {
                    showToast("图片中未识别到二维码")
                }
                selectedPhotoItem = nil
            }
        }
    }

    private var topStatusBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    if coordinator.isProbing || laundry.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isScanningEnabled ? "viewfinder" : "pause.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(
                        (coordinator.isProbing || laundry.isWorking)
                            ? "正在识别设备…"
                            : (businessMode ? "扫 U净洗衣 / 胖乖洗澡" : "采样探测模式")
                    )
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .glassEffectID("scan-status-pill", in: glassNS)

                Spacer(minLength: 4)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        businessMode.toggle()
                    }
                    showToast(businessMode ? "已切回：业务直达模式" : "已切到：纯采样调试模式")
                } label: {
                    Label(businessMode ? "业务" : "采样", systemImage: businessMode ? "bolt.fill" : "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    businessMode ? .regular.tint(.blue).interactive() : .regular.tint(.orange).interactive(),
                    in: .capsule
                )
                .glassEffectID("scan-mode-pill", in: glassNS)
            }
        }
    }

    private func latestResultCard(record: ScanRecord) -> some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: record.platform.systemImage)
                        .font(.title3.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.tint(platformTint(record.platform)), in: .circle)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(record.stabilityHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            latestRecord = nil
                            isScanningEnabled = true
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                }

                HStack(spacing: 10) {
                    if record.platform == .ujing {
                        Button {
                            Task {
                                let ok = await laundry.prepareFromQRCode(record.rawText)
                                if !ok, let err = laundry.lastError {
                                    showToast(err)
                                }
                            }
                        } label: {
                            Label("进入下单", systemImage: "washer.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.indigo)
                    } else if record.platform == .pangguai {
                        Button {
                            latestRecord = nil
                            isScanningEnabled = true
                            selectedTab = .shower
                        } label: {
                            Label("去洗澡页开阀", systemImage: "drop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.cyan)
                    }

                    Button {
                        presentingRecord = record
                    } label: {
                        Label("详情", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.glass)

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            latestRecord = nil
                            isScanningEnabled = true
                        }
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .glassEffectID("latest-result-card", in: glassNS)
        }
    }

    private var bottomLiquidDock: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        isTorchOn.toggle()
                    }
                } label: {
                    Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    isTorchOn ? .regular.tint(.yellow).interactive() : .regular.interactive(),
                    in: .circle
                )
                .glassEffectID("dock-torch", in: glassNS)
                .accessibilityLabel("手电筒")

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("dock-photo", in: glassNS)
                .accessibilityLabel("从相册识码")

                Button {
                    if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pasted.isEmpty {
                        manualText = pasted
                    }
                    showManualInput = true
                } label: {
                    Label("粘贴 / 输入", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 52)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("dock-paste", in: glassNS)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        isScanningEnabled.toggle()
                        if isScanningEnabled {
                            latestRecord = nil
                        }
                    }
                } label: {
                    Image(systemName: isScanningEnabled ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    isScanningEnabled ? .regular.interactive() : .regular.tint(.blue).interactive(),
                    in: .circle
                )
                .glassEffectID("dock-pause", in: glassNS)
                .accessibilityLabel(isScanningEnabled ? "暂停扫描" : "继续扫描")
            }
        }
    }

    private func triggerScan(rawText: String, symbology: String, source: ScanSource) {
        isScanningEnabled = false
        let analysis = QRAnalyzer.analyze(rawText: rawText, existingRecords: records)

        Task {
            // In business mode, route Ujing washer/dryer directly into the order & payment sheet
            if businessMode && analysis.platform == .ujing && laundry.isLoggedIn {
                let openedOrderSheet = await laundry.prepareFromQRCode(rawText)
                if openedOrderSheet {
                    // Record scan asynchronously without blocking the order sheet
                    _ = await coordinator.handleScannedCode(
                        rawText: rawText,
                        symbology: symbology,
                        source: source,
                        context: modelContext,
                        existingRecords: records
                    )
                    return
                } else if let err = laundry.lastError {
                    showToast(err)
                }
            }

            // In business mode, if Pangguai QR contains goodsId, auto-add to shower list
            if businessMode && analysis.platform == .pangguai && shower.isLoggedIn {
                if let gid = analysis.candidateGoodsId {
                    _ = await shower.addDeviceByGoodsId(gid)
                    showToast("已识别胖乖隔间并加入洗澡列表")
                }
            }

            let record = await coordinator.handleScannedCode(
                rawText: rawText,
                symbology: symbology,
                source: source,
                context: modelContext,
                existingRecords: records
            )
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                latestRecord = record
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(.easeInOut(duration: 0.25)) {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }

    private func platformTint(_ platform: ScanPlatform) -> Color {
        switch platform {
        case .pangguai: return .cyan
        case .ujing: return .indigo
        case .alipay: return .blue
        case .wechat: return .green
        case .web: return .orange
        case .text: return .gray
        }
    }
}

private struct ScanReticleOverlay: View {
    let isProbing: Bool
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isProbing ? 0.95 : 0.7),
                        Color.cyan.opacity(isProbing ? 0.9 : 0.35),
                        Color.white.opacity(isProbing ? 0.95 : 0.7)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isProbing ? 3 : 2
            )
            .frame(width: 248, height: 248)
            .scaleEffect(pulse ? 1.02 : 0.99)
            .shadow(color: .cyan.opacity(isProbing ? 0.45 : 0.15), radius: 16)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
