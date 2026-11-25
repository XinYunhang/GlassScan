import SwiftUI

struct ShowerTabView: View {
    @Binding var selectedTab: AppTabSelection

    @Environment(ShowerController.self) private var shower
    @State private var searchText = ""
    @State private var onlyFavorites = false
    @State private var confirmStartDevice: QiekjDevice?
    @State private var showStopConfirm = false
    @State private var showManualAdd = false
    @State private var manualGoodsId = ""

    @Namespace private var glassNS

    private var filteredDevices: [QiekjDevice] {
        shower.sortedDevices.filter { device in
            if onlyFavorites && !shower.favoriteGoodsIDs.contains(device.goodsId) {
                return false
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return device.goodsName.lowercased().contains(q)
                || device.parentPointName.lowercased().contains(q)
                || device.goodsId.contains(q)
        }
    }

    var body: some View {
        @Bindable var bindableShower = shower

        NavigationStack {
            ZStack {
                LiquidBackdrop(style: .shower)

                ScrollView {
                    VStack(spacing: 16) {
                        if !shower.isLoggedIn {
                            loginPromptCard
                        } else {
                            accountMetricsBar(usePoints: $bindableShower.usePoints)
                            activeSessionSection
                            stallsSection
                            if !shower.recentOrders.isEmpty {
                                recentBillsSection
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .refreshable {
                    await shower.refreshAll()
                }
            }
            .navigationTitle("胖乖洗澡")
            .searchable(text: $searchText, prompt: "搜索隔间号（如 90404）")
            .toolbar {
                if shower.isLoggedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showManualAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("按 goodsId 添加隔间")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await shower.refreshAll() }
                        } label: {
                            if shower.isRefreshing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
            .task {
                if shower.isLoggedIn && shower.devices.isEmpty {
                    await shower.refreshAll()
                }
            }
            .alert(
                "确认开启淋浴出水？",
                isPresented: Binding(
                    get: { confirmStartDevice != nil },
                    set: { if !$0 { confirmStartDevice = nil } }
                ),
                presenting: confirmStartDevice
            ) { device in
                Button("取消", role: .cancel) { confirmStartDevice = nil }
                Button("立即开阀") {
                    confirmStartDevice = nil
                    shower.startShower(device: device)
                }
            } message: { device in
                Text("将通过胖乖云端开启「\(device.goodsName)」出水（先用后付按流量计费），确认你已站在该隔间内。")
            }
            .alert("确认结束本次洗澡？", isPresented: $showStopConfirm) {
                Button("继续洗", role: .cancel) {}
                Button("停阀并结算", role: .destructive) {
                    shower.requestStopShower()
                }
            } message: {
                Text("将向水控器下发远程停阀指令并生成本次结算账单。")
            }
            .alert("添加淋浴隔间", isPresented: $showManualAdd) {
                TextField("输入 goodsId（例如 1101668384）", text: $manualGoodsId)
                    .keyboardType(.numberPad)
                Button("取消", role: .cancel) { manualGoodsId = "" }
                Button("添加") {
                    let id = manualGoodsId
                    manualGoodsId = ""
                    Task { _ = await shower.addDeviceByGoodsId(id) }
                }
            }
        }
    }

    private var loginPromptCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "drop.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.cyan)
            Text("登录胖乖生活以启用一键洗澡")
                .font(.headline)
            Text("登录后自动拉取本校所有淋浴隔间与常用隔间，支持一键云端开阀与远程停阀结算。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                selectedTab = .accounts
            } label: {
                Label("前往「我的」登录胖乖", systemImage: "person.badge.key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(22)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func accountMetricsBar(usePoints: Binding<Bool>) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("账户余额")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("¥\(shower.balance?.balance ?? "--")")
                        .font(.title3.monospacedDigit().weight(.bold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .glassEffectID("shower-balance", in: glassNS)

                VStack(alignment: .leading, spacing: 2) {
                    Text("积分（可抵 ¥\(shower.balance?.integralAmount ?? "0.00")）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Toggle(isOn: usePoints) {
                        Text("\(shower.balance?.integral ?? 0)")
                            .font(.title3.monospacedDigit().weight(.bold))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .glassEffectID("shower-points", in: glassNS)
            }
        }
    }

    @ViewBuilder
    private var activeSessionSection: some View {
        switch shower.phase {
        case .idle:
            EmptyView()

        case let .preparing(device, step):
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在启动 · 隔间 \(device.goodsName)")
                            .font(.headline)
                        Text(step)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(18)
            .glassEffect(.regular.tint(.cyan), in: .rect(cornerRadius: 26))

        case let .running(device, _, startedAt, step, appEndSupported, stopping):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                VStack(spacing: 16) {
                    HStack {
                        Label("隔间 \(device.goodsName) · 出水中", systemImage: "drop.fill")
                            .font(.headline)
                        Spacer()
                        Text(appEndSupported ? "支持远程停阀" : "设备端停水")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular.tint(.cyan), in: .capsule)
                    }

                    Text(formatElapsed(elapsed))
                        .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())

                    Text(step)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        showStopConfirm = true
                    } label: {
                        Label(stopping ? "正在停阀结算…" : "结束洗澡并结算", systemImage: "stop.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .disabled(stopping)
                }
                .padding(20)
                .glassEffect(.regular.tint(.cyan), in: .rect(cornerRadius: 28))
            }

        case let .settling(device, step):
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("结算中 · 隔间 \(device.goodsName)")
                        .font(.headline)
                    Text(step)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))

        case let .finished(receipt):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("洗澡已结算 · \(receipt.goodsName)", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Spacer()
                    Text("¥\(receipt.realPrice)")
                        .font(.title2.monospacedDigit().weight(.bold))
                }
                Text("本次用时 \(formatElapsed(receipt.elapsedSeconds)) · 支付方式：\(receipt.payTypeName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("知道了") {
                    shower.dismissResult()
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(18)
            .glassEffect(.regular.tint(.green), in: .rect(cornerRadius: 26))

        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Label("操作未完成", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                HStack {
                    Spacer()
                    Button("关闭") {
                        shower.dismissResult()
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(18)
            .glassEffect(.regular.tint(.orange), in: .rect(cornerRadius: 26))
        }
    }

    private var stallsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("淋浴隔间 (\(filteredDevices.count))")
                    .font(.headline)
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            withAnimation { onlyFavorites.toggle() }
                        } label: {
                            Label(onlyFavorites ? "全部" : "收藏", systemImage: onlyFavorites ? "star.fill" : "star")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            onlyFavorites ? .regular.tint(.yellow).interactive() : .regular.interactive(),
                            in: .capsule
                        )

                        Button {
                            selectedTab = .scan
                        } label: {
                            Label("扫码", systemImage: "qrcode.viewfinder")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
            }

            if filteredDevices.isEmpty {
                VStack(spacing: 10) {
                    Text(shower.isRefreshing ? "正在拉取隔间列表…" : "暂无匹配的淋浴隔间")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("刷新隔间列表") {
                        Task { await shower.refreshAll() }
                    }
                    .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity)
                .padding(22)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredDevices) { device in
                        stallRow(device: device)
                    }
                }
            }
        }
    }

    private func stallRow(device: QiekjDevice) -> some View {
        let isFav = shower.favoriteGoodsIDs.contains(device.goodsId)
        let isBusySession: Bool = {
            if case .idle = shower.phase { return false }
            if case .finished = shower.phase { return false }
            if case .failed = shower.phase { return false }
            return true
        }()

        return HStack(spacing: 12) {
            Button {
                shower.toggleFavorite(goodsId: device.goodsId)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .foregroundStyle(isFav ? .yellow : .secondary)
                    .font(.body)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(device.goodsName)
                        .font(.title3.monospacedDigit().weight(.bold))
                    Text(device.statusLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (device.isIdle ? Color.green : Color.orange).opacity(0.18),
                            in: Capsule()
                        )
                        .foregroundStyle(device.isIdle ? .green : .orange)
                }

                let subtitle = [device.parentPointName, device.orgName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                Text(subtitle.isEmpty ? "goodsId: \(device.goodsId)" : subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                confirmStartDevice = device
            } label: {
                Label("开水", systemImage: "drop.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            .tint(device.isIdle ? .cyan : .gray)
            .disabled(isBusySession)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var recentBillsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近洗澡账单")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(shower.recentOrders.prefix(6).enumerated()), id: \.element.id) { index, order in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("隔间 \(order.goodsName)")
                                .font(.subheadline.weight(.semibold))
                            Text(order.createTime)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("¥\(order.payPrice)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)

                    if index < min(shower.recentOrders.count, 6) - 1 {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
