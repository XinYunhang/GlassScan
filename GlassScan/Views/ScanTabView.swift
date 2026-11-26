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
    @State private var showSavedRecordsSheet = false
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
        .sheet(isPresented: $showSavedRecordsSheet, onDismiss: {
            isScanningEnabled = true
        }) {
            NavigationStack {
                RecordsTabView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") {
                                showSavedRecordsSheet = false
                            }
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
                    isScanningEnabled = false
                    showSavedRecordsSheet = true
                } label: {
                    Label("\(records.count)", systemImage: "tray.full.fill")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("scan-records-pill", in: glassNS)
                .accessibilityLabel("已保存的扫码记录")

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        businessMode.toggle()
                    }
                    showToast(businessMode ? "已切回：业务直达模式" : "已切到：连续采样 / 仅收录模式")
                } label: {
                    Label(businessMode ? "业务" : "收录", systemImage: businessMode ? "bolt.fill" : "square.and.arrow.down.fill")
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
                        HStack(spacing: 6) {
                            Text(record.displayTitle)
                                .font(.headline)
                                .lineLimit(1)
                            Text("已保存")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2), in: Capsule())
                                .foregroundStyle(.green)
                        }
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
                    } else if record.platform == .ujingHairdryer {
                        Button {
                            Task {
                                let target = await UjingClient.shared.resolveHairdryerAlipayURL(qrCode: record.rawText)
                                if let url = URL(string: target) {
                                    await MainActor.run {
                                        UIApplication.shared.open(url)
                                    }
                                }
                            }
                        } label: {
                            Label("支付宝启动吹风机", systemImage: "wind")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.purple)
                    } else if record.platform == .shehuitong {
                        Button {
                            if let url = URL(string: "alipays://platformapi/startapp?saId=10000007") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("支付宝扫一扫", systemImage: "cup.and.saucer.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.teal)
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
        AppLog.shared.record(
            .info,
            module: .scan,
            "扫到二维码 [\(analysis.platform.displayName)]（\(source.displayName)）",
            detail: rawText
        )

        Task {
            // In business mode, route Ujing hairdryer (/6d/) straight to official Alipay mini-program!
            if businessMode && analysis.platform == .ujingHairdryer {
                showToast("已识别 U净吹风机，正在拉起支付宝小程序…")
                _ = await coordinator.handleScannedCode(
                    rawText: rawText,
                    symbology: symbology,
                    source: source,
                    context: modelContext,
                    existingRecords: records,
                    skipAutoProbes: true
                )
                let launchURL = await UjingClient.shared.resolveHairdryerAlipayURL(qrCode: rawText)
                if let url = URL(string: launchURL) {
                    UIApplication.shared.open(url)
                }
                isScanningEnabled = true
                return
            }

            // In business mode, route Ujing washer/dryer directly into the order & payment sheet (and auto-save fixed QR!)
            if businessMode && analysis.platform == .ujing && laundry.isLoggedIn {
                showToast("正在识别并保存 U净洗衣机…")
                let openedOrderSheet = await laundry.prepareFromQRCode(rawText)
                if openedOrderSheet {
                    _ = await coordinator.handleScannedCode(
                        rawText: rawText,
                        symbology: symbology,
                        source: source,
                        context: modelContext,
                        existingRecords: records,
                        skipAutoProbes: true
                    )
                    return
                } else if let err = laundry.lastError {
                    showToast(err)
                }
            }

            // In collect/sampling mode, auto-save Ujing washer QR without popping order sheet so user can scan all washers quickly!
            if !businessMode && analysis.platform == .ujing && laundry.isLoggedIn {
                if let saved = await laundry.saveWasherFromQRCode(rawText) {
                    showToast("已收录洗衣机：\(saved.displayName)（可在洗衣页远程锁机）")
                }
            }

            // In business mode, route Pangguai QR (`SN=...` or `goodsId=...`) directly to highlighted stall in Shower tab!
            if businessMode && analysis.platform == .pangguai {
                let sn = analysis.queryItems.first { $0.key.lowercased() == "sn" || $0.key.lowercased() == "imei" }?.value
                showToast("正在定位当前洗澡隔间…")
                let matched = await shower.resolveScannedShower(
                    rawText: rawText,
                    sn: sn,
                    goodsId: analysis.candidateGoodsId
                )
                _ = await coordinator.handleScannedCode(
                    rawText: rawText,
                    symbology: symbology,
                    source: source,
                    context: modelContext,
                    existingRecords: records,
                    skipAutoProbes: true
                )
                latestRecord = nil
                isScanningEnabled = true
                if let matched {
                    showToast("已定位隔间 \(matched.goodsName)")
                }
                selectedTab = .shower
                return
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
        case .ujingHairdryer: return .purple
        case .shehuitong: return .teal
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
