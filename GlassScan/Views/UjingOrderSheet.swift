import SwiftUI

struct UjingOrderSheet: View {
    let session: PreparedUjingSession
    var onOrderCreated: () -> Void

    @Environment(LaundryController.self) private var laundry
    @Environment(\.dismiss) private var dismiss

    @State private var selectedModelId: Int = 0
    @State private var selectedTemperatureId: Int = 1
    @State private var useDetergent: Bool = false
    @State private var useDisinfectant: Bool = false
    @State private var selectedDryMinutes: Int? = nil
    @State private var showConfirmOrder = false

    private let temperatureOptions: [(id: Int, label: String)] = [
        (1, "常温"),
        (2, "30℃"),
        (3, "40℃"),
        (4, "60℃")
    ]

    private var program: UjingProgramInfo { session.programInfo }

    private var selectedModel: UjingWashModel? {
        program.visibleModels.first { $0.workModelId == selectedModelId }
            ?? program.visibleModels.first
    }

    private var canSubmit: Bool {
        guard session.scanInfo.createOrderEnabled, let model = selectedModel else { return false }
        if program.isDryer && model.hasAdditionDryTime && selectedDryMinutes == nil {
            return false
        }
        return !laundry.isWorking
    }

    private var estimatedPriceText: String {
        guard let model = selectedModel else { return "--" }
        let fen = model.estimatedPriceFen(selectedDryMinutes: selectedDryMinutes)
        return PriceFormatter.fenToYuan(fen)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop(style: .laundry)

                ScrollView {
                    VStack(spacing: 16) {
                        deviceHeaderCard
                        if !session.scanInfo.createOrderEnabled {
                            unavailableBanner
                        }
                        modelsSection
                        if let model = selectedModel, program.isDryer && model.hasAdditionDryTime {
                            dryTimeSection(model: model)
                        }
                        if !program.isDryer && program.isWashTemperatureEnable {
                            temperatureSection
                        }
                        if !program.isDryer {
                            addonsSection
                        }
                        submitSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle(program.isDryer ? "选择烘干程序" : "选择洗涤程序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                let defaultModel = program.visibleModels.first(where: \.isDefault) ?? program.visibleModels.first
                selectedModelId = defaultModel?.workModelId ?? 0
                useDetergent = program.isForceDetergent
                useDisinfectant = program.isForceDisinfectant
                if let defaultModel, defaultModel.hasAdditionDryTime {
                    selectedDryMinutes = defaultModel.additionDryTimeOptions.first
                }
            }
            .alert("确认创建 U净订单？", isPresented: $showConfirmOrder) {
                Button("取消", role: .cancel) {}
                Button("下单并锁机") {
                    guard let model = selectedModel else { return }
                    Task {
                        let ok = await laundry.createOrder(
                            session: session,
                            model: model,
                            washTemperatureId: selectedTemperatureId,
                            useDetergent: useDetergent,
                            useDisinfectant: useDisinfectant,
                            selectedDryMinutes: selectedDryMinutes
                        )
                        if ok {
                            dismiss()
                            onOrderCreated()
                        }
                    }
                }
            } message: {
                Text("下单后将为你锁定该机器 2 分钟，实付金额以支付宝收银台为准（预估 \(estimatedPriceText)）。")
            }
        }
    }

    private var deviceHeaderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    [program.deviceTypeName, program.deviceNo].filter { !$0.isEmpty }.joined(separator: " "),
                    systemImage: program.isDryer ? "wind" : "washer.fill"
                )
                .font(.headline)
                Spacer()
                Text(session.scanInfo.badgeText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        (session.scanInfo.createOrderEnabled ? Color.green : Color.orange).opacity(0.18),
                        in: Capsule()
                    )
                    .foregroundStyle(session.scanInfo.createOrderEnabled ? .green : .orange)
            }

            HStack(spacing: 10) {
                if !program.storeName.isEmpty {
                    Label(program.storeName, systemImage: "building.2")
                }
                Label(session.scanInfo.moduleLabel, systemImage: "antenna.radiowaves.left.and.right")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var unavailableBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(session.scanInfo.reason.isEmpty ? "当前设备暂不可下单，请换一台空闲机器" : session.scanInfo.reason)
                .font(.subheadline)
            Spacer()
        }
        .padding(14)
        .glassEffect(.regular.tint(.orange), in: .rect(cornerRadius: 20))
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(program.isDryer ? "烘干模式" : "洗涤档位")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(program.visibleModels) { model in
                    let isSelected = (model.workModelId == selectedModel?.workModelId)
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            selectedModelId = model.workModelId
                            if model.hasAdditionDryTime {
                                if let cur = selectedDryMinutes, !model.additionDryTimeOptions.contains(cur) {
                                    selectedDryMinutes = model.additionDryTimeOptions.first
                                } else if selectedDryMinutes == nil {
                                    selectedDryMinutes = model.additionDryTimeOptions.first
                                }
                            } else {
                                selectedDryMinutes = nil
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.displayTitle(isDryer: program.isDryer))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 2)
                            HStack {
                                Text(PriceFormatter.fenToYuan(model.basePriceFen))
                                    .font(.headline.monospacedDigit())
                                Spacer()
                                if model.timeMinutes > 0 && !model.hasAdditionDryTime {
                                    Text("\(model.timeMinutes)分")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        isSelected ? .regular.tint(.indigo).interactive() : .regular.interactive(),
                        in: .rect(cornerRadius: 20)
                    )
                }
            }
        }
    }

    private func dryTimeSection(model: UjingWashModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.additionDryTimeTitle.isEmpty ? "选择烘干时长" : model.additionDryTimeTitle)
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(model.additionDryTimeOptions, id: \.self) { mins in
                            let selected = selectedDryMinutes == mins
                            Button("\(mins) 分钟") {
                                selectedDryMinutes = mins
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .buttonStyle(.plain)
                            .glassEffect(
                                selected ? .regular.tint(.indigo).interactive() : .regular.interactive(),
                                in: .capsule
                            )
                        }
                    }
                }
            }
        }
    }

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("洗涤水温")
                .font(.headline)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(temperatureOptions, id: \.id) { opt in
                        let selected = selectedTemperatureId == opt.id
                        Button(opt.label) {
                            selectedTemperatureId = opt.id
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .buttonStyle(.plain)
                        .glassEffect(
                            selected ? .regular.tint(.indigo).interactive() : .regular.interactive(),
                            in: .capsule
                        )
                    }
                }
            }
        }
    }

    private var addonsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("智能投放（可选）")
                .font(.headline)

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        useDetergent.toggle()
                    } label: {
                        Label("洗衣液", systemImage: useDetergent ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        useDetergent ? .regular.tint(.blue).interactive() : .regular.interactive(),
                        in: .capsule
                    )

                    Button {
                        useDisinfectant.toggle()
                    } label: {
                        Label("消毒液", systemImage: useDisinfectant ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        useDisinfectant ? .regular.tint(.teal).interactive() : .regular.interactive(),
                        in: .capsule
                    )
                }
            }
        }
    }

    private var submitSection: some View {
        VStack(spacing: 8) {
            Button {
                showConfirmOrder = true
            } label: {
                HStack {
                    if laundry.isWorking {
                        ProgressView()
                    } else {
                        Label("下单并锁机 · 预估 \(estimatedPriceText)", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.indigo)
            .controlSize(.large)
            .disabled(!canSubmit)

            Text("下单后会立即在「洗衣」页提供一键拉起支付宝付款与云端启动。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}
