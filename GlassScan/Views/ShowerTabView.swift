import SwiftUI

struct ShowerTabView: View {
    @Binding var selectedTab: AppTabSelection

    @Environment(ShowerController.self) private var shower
    @State private var searchText = ""
    @State private var onlyFavorites = false
    @State private var onlyIdle = false
    @State private var confirmStartDevice: QiekjDevice?
    @State private var showStopConfirm = false
    @State private var showForceDismissConfirm = false
    @State private var showManualAdd = false
    @State private var manualGoodsId = ""

    @Namespace private var glassNS

    /// Devices matching the current building + floor selection (before idle/fav/search filters)
    private var floorScopedDevices: [QiekjDevice] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // When user explicitly types a search query, search across ALL buildings/floors
        if !q.isEmpty {
            return shower.sortedDevices.filter { device in
                device.goodsName.lowercased().contains(q)
                    || device.floorLabel.lowercased().contains(q)
                    || device.parentPointName.lowercased().contains(q)
                    || device.goodsId.contains(q)
            }
        }
        return shower.sortedDevices.filter { device in
            if let b = shower.selectedBuilding, device.buildingKey != b {
                return false
            }
            if let f = shower.selectedFloor, device.floorNumber != f {
                return false
            }
            return true
        }
    }

    private var filteredDevices: [QiekjDevice] {
        floorScopedDevices.filter { device in
            if onlyFavorites && !shower.favoriteGoodsIDs.contains(device.goodsId) {
                return false
            }
            if onlyIdle && !device.isIdle {
                return false
            }
            return true
        }
    }

    private var idleCountOnFloor: Int {
        floorScopedDevices.filter(\.isIdle).count
    }

    private var busyCountOnFloor: Int {
        floorScopedDevices.filter(\.isBusy).count
    }

    private var isBusySession: Bool {
        if case .idle = shower.phase { return false }
        if case .finished = shower.phase { return false }
        if case .failed = shower.phase { return false }
        return true
    }

    var body: some View {
        @Bindable var bindableShower = shower

        NavigationStack {
            ZStack {
                LiquidBackdrop(style: .shower)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            Color.clear.frame(height: 1).id("shower-top-anchor")

                            if !shower.isLoggedIn {
                                loginPromptCard
                            } else {
                                if let highlighted = shower.highlightedDevice {
                                    highlightedScannedCard(device: highlighted)
                                        .id("highlighted-stall")
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                } else if let unmatchedSN = shower.unmatchedScanSN {
                                    unmatchedSNBanner(sn: unmatchedSN)
                                        .id("highlighted-stall")
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }

                                accountMetricsBar(usePoints: $bindableShower.usePoints)
                                activeSessionSection
                                if !shower.devices.isEmpty {
                                    floorSelectorCard
                                }
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
                    .onChange(of: shower.highlightedDevice?.goodsId) { _, newValue in
                        if newValue != nil {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                proxy.scrollTo("shower-top-anchor", anchor: .top)
                            }
                        }
                    }
                    .onChange(of: shower.unmatchedScanSN) { _, newValue in
                        if newValue != nil {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                proxy.scrollTo("shower-top-anchor", anchor: .top)
                            }
                        }
                    }
                }
            }
            .navigationTitle("胖乖洗澡")
            .searchable(text: $searchText, prompt: "全局搜索隔间号（如 90403）")
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
                let warn = device.isBusy ? "\n⚠️ 该隔间当前显示「使用中」，请核实后再操作！" : ""
                Text("将通过胖乖云端开启「\(device.floorLabel) · \(device.shortStallTitle)」（\(device.goodsName)）出水（先用后付按流量计费）。\(warn)")
            }
            .alert("确认结束本次洗澡？", isPresented: $showStopConfirm) {
                Button("继续洗", role: .cancel) {}
                Button("远程停阀并结算", role: .destructive) {
                    shower.requestStopShower()
                }
            } message: {
                Text("将立即向水控器下发远程停阀指令并生成本次结算账单。")
            }
            .alert("关闭本地洗澡状态面板？", isPresented: $showForceDismissConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认关闭", role: .destructive) {
                    shower.forceDismissActiveSession()
                }
            } message: {
                Text("仅关闭手机界面状态，请确认淋浴头已实际停水；账单稍后可在历史记录中查看。")
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

    // MARK: - Building & Floor Selector Card

    private var floorSelectorCard: some View {
        let buildings = shower.availableBuildings
        let floors = shower.availableFloors(for: shower.selectedBuilding)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Menu {
                    Button {
                        withAnimation { shower.selectBuilding(nil) }
                    } label: {
                        Label("全部楼栋", systemImage: shower.selectedBuilding == nil ? "checkmark" : "building.2")
                    }
                    Divider()
                    ForEach(buildings, id: \.self) { b in
                        Button {
                            withAnimation { shower.selectBuilding(b) }
                        } label: {
                            Label(b, systemImage: shower.selectedBuilding == b ? "checkmark" : "building")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "building.2.fill")
                            .font(.caption.weight(.semibold))
                        Text(shower.selectedBuilding ?? "全部楼栋")
                            .font(.subheadline.weight(.bold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)

                Spacer()

                // Live free/busy counter for current floor
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("空闲 \(idleCountOnFloor)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(.green)
                    }
                    if busyCountOnFloor > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                            Text("使用中 \(busyCountOnFloor)")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }

            if !floors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            floorPill(title: "全部楼层", selected: shower.selectedFloor == nil) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    shower.selectFloor(nil)
                                }
                            }
                            ForEach(floors, id: \.self) { floor in
                                floorPill(title: "\(floor)层", selected: shower.selectedFloor == floor) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        shower.selectFloor(floor)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func floorPill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .buttonStyle(.plain)
            .glassEffect(
                selected ? .regular.tint(.cyan).interactive() : .regular.interactive(),
                in: .capsule
            )
    }

    // MARK: - Highlighted Scanned Stall Spotlight

    private func highlightedScannedCard(device: QiekjDevice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("已定位当前扫码机器", systemImage: "scope")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular.tint(.cyan), in: .capsule)

                Spacer()

                Button {
                    withAnimation { shower.clearHighlight() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(device.floorLabel) · \(device.shortStallTitle)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                statusBadge(for: device)
            }

            Text("编号 \(device.goodsName) · goodsId: \(device.goodsId)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Button {
                confirmStartDevice = device
            } label: {
                Label("立即开启当前隔间出水", systemImage: "drop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.cyan)
            .disabled(isBusySession)
        }
        .padding(18)
        .glassEffect(.regular.tint(.cyan), in: .rect(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.65), lineWidth: 1.5)
        )
        .shadow(color: .cyan.opacity(0.25), radius: 16, y: 6)
    }

    private func unmatchedSNBanner(sn: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("已扫到胖乖设备码", systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    withAnimation { shower.clearHighlight() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
            }

            Text("SN = \(sn) 暂未匹配到具体隔间编号。请点击右上角刷新列表，或在「我的 → 运行日志」导出发我补齐该接口。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassEffect(.regular.tint(.orange), in: .rect(cornerRadius: 22))
    }

    private var loginPromptCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "drop.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.cyan)
            Text("登录胖乖生活以启用一键洗澡")
                .font(.headline)
            Text("登录后自动拉取本校所有淋浴隔间并按楼栋/楼层分组，实时查看空闲与使用中状态。")
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
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在启动 · \(device.floorLabel) \(device.shortStallTitle)")
                        .font(.headline)
                    Text(step)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .glassEffect(.regular.tint(.cyan), in: .rect(cornerRadius: 26))

        case let .running(device, _, startedAt, step, appEndSupported, stopping):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                VStack(spacing: 14) {
                    HStack {
                        Label("\(device.shortStallTitle) (\(device.goodsName)) · 出水中", systemImage: "drop.fill")
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

                    if let stopErr = shower.stopErrorMessage {
                        Text(stopErr)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }

                    Button {
                        showStopConfirm = true
                    } label: {
                        Label(
                            stopping ? "正在发送远程停阀…" : (shower.stopErrorMessage == nil ? "结束洗澡并结算" : "重试远程停阀"),
                            systemImage: "stop.circle.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .disabled(stopping)

                    HStack(spacing: 10) {
                        Button {
                            shower.forceSettleCurrentSession()
                        } label: {
                            Label("已在设备停水 · 立即结算", systemImage: "checkmark.circle")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .disabled(stopping)

                        Button {
                            showForceDismissConfirm = true
                        } label: {
                            Text("关闭")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(20)
                .glassEffect(.regular.tint(.cyan), in: .rect(cornerRadius: 28))
            }

        case let .settling(device, step):
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("结算中 · \(device.shortStallTitle) (\(device.goodsName))")
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
        let titlePrefix: String = {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "搜索结果"
            }
            var parts: [String] = []
            if let b = shower.selectedBuilding { parts.append(b) }
            if let f = shower.selectedFloor { parts.append("\(f)层") }
            return parts.isEmpty ? "全部隔间" : parts.joined(separator: " · ")
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(titlePrefix) (\(filteredDevices.count))")
                    .font(.headline)
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 6) {
                        Button {
                            withAnimation { onlyIdle.toggle() }
                        } label: {
                            Label("仅空闲", systemImage: onlyIdle ? "checkmark.circle.fill" : "circle")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            onlyIdle ? .regular.tint(.green).interactive() : .regular.interactive(),
                            in: .capsule
                        )

                        Button {
                            withAnimation { onlyFavorites.toggle() }
                        } label: {
                            Image(systemName: onlyFavorites ? "star.fill" : "star")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
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
                            Image(systemName: "qrcode.viewfinder")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
            }

            if filteredDevices.isEmpty {
                VStack(spacing: 10) {
                    Text(shower.isRefreshing ? "正在拉取隔间状态…" : "当前筛选下暂无隔间")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if onlyIdle || onlyFavorites {
                            Button("清除筛选") {
                                onlyIdle = false
                                onlyFavorites = false
                            }
                            .buttonStyle(.glass)
                        }
                        Button("刷新隔间") {
                            Task { await shower.refreshAll() }
                        }
                        .buttonStyle(.glass)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(22)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(filteredDevices) { device in
                        stallGridCard(device: device)
                            .id(device.goodsId)
                    }
                }
            }
        }
    }

    private func stallGridCard(device: QiekjDevice) -> some View {
        let isFav = shower.favoriteGoodsIDs.contains(device.goodsId)
        let isHighlighted = shower.highlightedDevice?.goodsId == device.goodsId

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.shortStallTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    Text(device.goodsName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    shower.toggleFavorite(goodsId: device.goodsId)
                } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(isFav ? .yellow : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                statusBadge(for: device)
                if isHighlighted {
                    Text("扫码")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cyan.opacity(0.25), in: Capsule())
                        .foregroundStyle(.cyan)
                }
            }

            if device.isIdle {
                Button {
                    confirmStartDevice = device
                } label: {
                    Label("开水", systemImage: "drop.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.cyan)
                .controlSize(.small)
                .disabled(isBusySession)
            } else {
                Button {
                    confirmStartDevice = device
                } label: {
                    Label(device.isBusy ? "使用中" : "尝试开水", systemImage: device.isBusy ? "person.fill" : "drop")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isBusySession)
            }
        }
        .padding(14)
        .glassEffect(
            isHighlighted ? .regular.tint(.cyan) : (device.isBusy ? .regular.tint(.orange) : .regular),
            in: .rect(cornerRadius: 22)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    isHighlighted ? Color.cyan.opacity(0.75) : (device.isIdle ? Color.green.opacity(0.25) : Color.clear),
                    lineWidth: isHighlighted ? 1.8 : 1
                )
        )
    }

    private func statusBadge(for device: QiekjDevice) -> some View {
        let color: Color = {
            switch device.availability {
            case .idle: return .green
            case .busy: return .orange
            case .fault: return .red
            case .unknown: return .secondary
            }
        }()

        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(device.statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.16), in: Capsule())
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
