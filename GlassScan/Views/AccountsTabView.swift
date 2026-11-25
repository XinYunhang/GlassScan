import SwiftData
import SwiftUI

struct AccountsTabView: View {
    @Binding var selectedTab: AppTabSelection

    @Environment(ProbeCoordinator.self) private var coordinator
    @Environment(ShowerController.self) private var shower
    @Environment(LaundryController.self) private var laundry
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]

    // Qiekj state
    @State private var qiekjPhone = KeychainStore.read(.qiekjPhone)
    @State private var qiekjCode = ""
    @State private var qiekjTokenPreview = Sanitizer.maskTokenPreview(KeychainStore.read(.qiekjToken))
    @State private var qiekjManualToken = ""
    @State private var qiekjCooldown = 0
    @State private var qiekjBusy = false

    // Ujing state
    @State private var ujingPhone = KeychainStore.read(.ujingPhone)
    @State private var ujingCaptcha = ""
    @State private var ujingTokenPreview = Sanitizer.maskTokenPreview(KeychainStore.read(.ujingToken))
    @State private var ujingManualToken = ""
    @State private var ujingCooldown = 0
    @State private var ujingBusy = false

    @State private var feedbackMessage: String?

    var body: some View {
        @Bindable var bindableCoordinator = coordinator

        NavigationStack {
            Form {
                if let feedbackMessage {
                    Section {
                        Text(feedbackMessage)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                }

                // MARK: - Qiekj (Pangguai Shower)
                Section {
                    LabeledContent("登录状态", value: qiekjTokenPreview)
                    if let bal = shower.balance {
                        LabeledContent("余额 / 积分", value: "¥\(bal.balance) · \(bal.integral) 积分")
                    }

                    TextField("手机号", text: $qiekjPhone)
                        .keyboardType(.numberPad)

                    HStack {
                        TextField("短信验证码", text: $qiekjCode)
                            .keyboardType(.numberPad)
                        Button(qiekjCooldown > 0 ? "\(qiekjCooldown)s" : "发验证码") {
                            sendQiekjCode()
                        }
                        .buttonStyle(.glass)
                        .disabled(qiekjBusy || qiekjCooldown > 0 || qiekjPhone.count < 11)
                    }

                    Button {
                        loginQiekj()
                    } label: {
                        Label("登录胖乖生活", systemImage: "drop.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.cyan)
                    .disabled(qiekjBusy || qiekjPhone.count < 11 || qiekjCode.isEmpty)

                    if shower.isLoggedIn {
                        Button {
                            dailySignInQiekj()
                        } label: {
                            Label("胖乖每日一键签到", systemImage: "sparkles")
                        }
                        .disabled(qiekjBusy)

                        Button {
                            syncQiekjSnapshot()
                        } label: {
                            Label("导出用：同步胖乖账单与设备样本", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(qiekjBusy)

                        Button("退出胖乖账号", role: .destructive) {
                            KeychainStore.delete(.qiekjToken)
                            shower.balance = nil
                            refreshPreviews()
                            feedbackMessage = "已清除胖乖登录态"
                        }
                    }

                    DisclosureGroup("手动粘贴胖乖 Token") {
                        TextField("粘贴胖乖 Token", text: $qiekjManualToken)
                            .font(.caption.monospaced())
                        Button("保存 Token") {
                            KeychainStore.save(qiekjManualToken, for: .qiekjToken)
                            qiekjManualToken = ""
                            refreshPreviews()
                            feedbackMessage = "已保存胖乖 Token"
                            Task { await shower.refreshAll() }
                        }
                        .disabled(qiekjManualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Label("胖乖生活（洗澡）", systemImage: "drop.fill")
                }

                // MARK: - Ujing (Laundry)
                Section {
                    LabeledContent("登录状态", value: ujingTokenPreview)

                    TextField("手机号", text: $ujingPhone)
                        .keyboardType(.numberPad)

                    HStack {
                        TextField("短信验证码", text: $ujingCaptcha)
                            .keyboardType(.numberPad)
                        Button(ujingCooldown > 0 ? "\(ujingCooldown)s" : "发验证码") {
                            sendUjingCaptcha()
                        }
                        .buttonStyle(.glass)
                        .disabled(ujingBusy || ujingCooldown > 0 || ujingPhone.count < 11)
                    }

                    Button {
                        loginUjing()
                    } label: {
                        Label("登录 U净洗衣房", systemImage: "washer.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.indigo)
                    .disabled(ujingBusy || ujingPhone.count < 11 || ujingCaptcha.isEmpty)

                    if laundry.isLoggedIn {
                        Button("退出 U净账号", role: .destructive) {
                            KeychainStore.delete(.ujingToken)
                            refreshPreviews()
                            feedbackMessage = "已清除 U净登录态"
                        }
                    }

                    DisclosureGroup("手动粘贴 U净 JWT") {
                        TextField("粘贴 JWT（不含 Bearer）", text: $ujingManualToken)
                            .font(.caption.monospaced())
                        Button("保存 JWT") {
                            KeychainStore.save(ujingManualToken, for: .ujingToken)
                            ujingManualToken = ""
                            refreshPreviews()
                            feedbackMessage = "已保存 U净 JWT"
                            Task { await laundry.refreshBoard() }
                        }
                        .disabled(ujingManualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Label("U净（洗衣机 / 烘干机）", systemImage: "washer.fill")
                }

                // MARK: - Logs, Debug Records & Settings
                Section("日志、采样与脱敏导出") {
                    NavigationLink {
                        AppLogView()
                    } label: {
                        LabeledContent {
                            HStack(spacing: 6) {
                                if AppLog.shared.errorCount > 0 {
                                    Text("\(AppLog.shared.errorCount) 异常")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                                Text("\(AppLog.shared.entries.count) 条")
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            Label("运行日志（可导出排错）", systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    NavigationLink {
                        RecordsTabView()
                    } label: {
                        LabeledContent {
                            Text("\(records.count) 条")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("采样记录与脱敏导出", systemImage: "tray.full.fill")
                        }
                    }

                    Toggle("扫码后自动 HTTP 只读探测", isOn: $bindableCoordinator.autoHTTPProbe)
                    Toggle("导出时自动脱敏手机号与凭据", isOn: $bindableCoordinator.sanitizeExport)
                }

                Section {
                    Text("所有凭据仅保存于本机 iOS Keychain（ThisDeviceOnly），不会上传第三方服务器；支付宝付款走本机官方支付宝收银台，本 App 不经手任何资金。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的账号")
            .onAppear {
                refreshPreviews()
            }
        }
    }

    private func refreshPreviews() {
        ujingTokenPreview = Sanitizer.maskTokenPreview(KeychainStore.read(.ujingToken))
        qiekjTokenPreview = Sanitizer.maskTokenPreview(KeychainStore.read(.qiekjToken))
    }

    private func sendUjingCaptcha() {
        ujingBusy = true
        feedbackMessage = nil
        Task {
            defer { ujingBusy = false }
            do {
                let msg = try await UjingClient.shared.requestCaptcha(mobile: ujingPhone)
                KeychainStore.save(ujingPhone, for: .ujingPhone)
                feedbackMessage = msg
                startCooldown(isUjing: true)
            } catch {
                feedbackMessage = "U净发码失败：\(error.localizedDescription)"
            }
        }
    }

    private func loginUjing() {
        ujingBusy = true
        feedbackMessage = nil
        Task {
            defer { ujingBusy = false }
            do {
                let token = try await UjingClient.shared.login(mobile: ujingPhone, captcha: ujingCaptcha)
                KeychainStore.save(ujingPhone, for: .ujingPhone)
                KeychainStore.save(token, for: .ujingToken)
                ujingCaptcha = ""
                refreshPreviews()
                feedbackMessage = "U净登录成功！去「洗衣」页可添加宿舍洗衣房看板并扫码付款。"
                await laundry.refreshBoard()
            } catch {
                feedbackMessage = "U净登录失败：\(error.localizedDescription)"
            }
        }
    }

    private func sendQiekjCode() {
        qiekjBusy = true
        feedbackMessage = nil
        Task {
            defer { qiekjBusy = false }
            do {
                let msg = try await QiekjClient.shared.sendCode(phone: qiekjPhone)
                KeychainStore.save(qiekjPhone, for: .qiekjPhone)
                feedbackMessage = msg
                startCooldown(isUjing: false)
            } catch {
                feedbackMessage = "胖乖发码失败：\(error.localizedDescription)"
            }
        }
    }

    private func loginQiekj() {
        qiekjBusy = true
        feedbackMessage = nil
        Task {
            defer { qiekjBusy = false }
            do {
                let token = try await QiekjClient.shared.login(phone: qiekjPhone, verifyCode: qiekjCode)
                KeychainStore.save(qiekjPhone, for: .qiekjPhone)
                KeychainStore.save(token, for: .qiekjToken)
                qiekjCode = ""
                refreshPreviews()
                feedbackMessage = "胖乖登录成功！已自动同步你的洗澡隔间列表。"
                await shower.refreshAll()
            } catch {
                feedbackMessage = "胖乖登录失败：\(error.localizedDescription)"
            }
        }
    }

    private func dailySignInQiekj() {
        let token = KeychainStore.read(.qiekjToken)
        guard !token.isEmpty else { return }
        qiekjBusy = true
        Task {
            defer { qiekjBusy = false }
            do {
                let text = try await QiekjClient.shared.runDailySignIn(token: token)
                feedbackMessage = text
                await shower.refreshAll()
            } catch {
                feedbackMessage = "签到失败：\(error.localizedDescription)"
            }
        }
    }

    private func syncQiekjSnapshot() {
        let token = KeychainStore.read(.qiekjToken)
        guard !token.isEmpty else { return }
        qiekjBusy = true
        Task {
            defer { qiekjBusy = false }
            let entries = await QiekjClient.shared.syncAccountSnapshot(token: token)
            _ = coordinator.saveManualSnapshot(
                platform: .pangguai,
                title: "胖乖历史订单 & 最近设备同步",
                probes: entries,
                context: modelContext
            )
            feedbackMessage = "已保存 \(entries.count) 项样本，点下方「采样记录与脱敏导出」即可分享"
        }
    }

    private func startCooldown(isUjing: Bool) {
        if isUjing {
            ujingCooldown = 60
        } else {
            qiekjCooldown = 60
        }
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if isUjing, ujingCooldown > 0 { ujingCooldown -= 1 }
                if !isUjing, qiekjCooldown > 0 { qiekjCooldown -= 1 }
            }
        }
    }
}
