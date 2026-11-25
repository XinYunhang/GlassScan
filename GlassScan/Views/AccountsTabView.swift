import SwiftData
import SwiftUI

struct AccountsTabView: View {
    @Binding var selectedTab: AppTabSelection

    @Environment(ProbeCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext

    // Ujing state
    @State private var ujingPhone = KeychainStore.read(.ujingPhone)
    @State private var ujingCaptcha = ""
    @State private var ujingTokenPreview = Sanitizer.maskTokenPreview(KeychainStore.read(.ujingToken))
    @State private var ujingManualToken = ""
    @State private var ujingStoreKeyword = ""
    @State private var ujingCooldown = 0
    @State private var ujingBusy = false

    // Qiekj state
    @State private var qiekjPhone = KeychainStore.read(.qiekjPhone)
    @State private var qiekjCode = ""
    @State private var qiekjTokenPreview = Sanitizer.maskTokenPreview(KeychainStore.read(.qiekjToken))
    @State private var qiekjManualToken = ""
    @State private var qiekjCooldown = 0
    @State private var qiekjBusy = false

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

                // MARK: - Ujing Account
                Section {
                    LabeledContent("当前 JWT", value: ujingTokenPreview)

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
                        Label("登录 U净（保存 JWT 至 Keychain）", systemImage: "key.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(ujingBusy || ujingPhone.count < 11 || ujingCaptcha.isEmpty)

                    DisclosureGroup("或手动粘贴 U净 JWT") {
                        TextField("粘贴 JWT（不含 Bearer）", text: $ujingManualToken)
                            .font(.caption.monospaced())
                        Button("保存 JWT") {
                            KeychainStore.save(ujingManualToken, for: .ujingToken)
                            ujingManualToken = ""
                            refreshPreviews()
                            feedbackMessage = "已保存 U净 JWT 到 Keychain"
                        }
                        .disabled(ujingManualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack {
                        TextField("门店/楼栋关键字（如：13栋）", text: $ujingStoreKeyword)
                        Button("抓看板") {
                            probeUjingStores()
                        }
                        .buttonStyle(.glass)
                        .disabled(ujingBusy || KeychainStore.read(.ujingToken).isEmpty)
                    }

                    if !KeychainStore.read(.ujingToken).isEmpty {
                        Button("清除 U净登录态", role: .destructive) {
                            KeychainStore.delete(.ujingToken)
                            refreshPreviews()
                            feedbackMessage = "已清除 U净 JWT"
                        }
                    }
                } header: {
                    Label("U净洗衣房 / 吹风机账号", systemImage: "washer.fill")
                } footer: {
                    Text("登录后，扫码将自动调用 scanWasherCode 与 program/info 保存完整设备/档位 JSON。")
                }

                // MARK: - Qiekj (Pangguai) Account
                Section {
                    LabeledContent("当前 Token", value: qiekjTokenPreview)

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
                        Label("登录胖乖生活（保存 Token 至 Keychain）", systemImage: "drop.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(qiekjBusy || qiekjPhone.count < 11 || qiekjCode.isEmpty)

                    DisclosureGroup("或手动粘贴胖乖 Token") {
                        TextField("粘贴胖乖 Token", text: $qiekjManualToken)
                            .font(.caption.monospaced())
                        Button("保存 Token") {
                            KeychainStore.save(qiekjManualToken, for: .qiekjToken)
                            qiekjManualToken = ""
                            refreshPreviews()
                            feedbackMessage = "已保存胖乖 Token 到 Keychain"
                        }
                        .disabled(qiekjManualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button {
                        syncQiekjSnapshot()
                    } label: {
                        Label("一键同步胖乖历史订单 & 最近设备", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(qiekjBusy || KeychainStore.read(.qiekjToken).isEmpty)

                    if !KeychainStore.read(.qiekjToken).isEmpty {
                        Button("清除胖乖登录态", role: .destructive) {
                            KeychainStore.delete(.qiekjToken)
                            refreshPreviews()
                            feedbackMessage = "已清除胖乖 Token"
                        }
                    }
                } header: {
                    Label("胖乖生活账号", systemImage: "drop.fill")
                } footer: {
                    Text("一键同步可抓取你历史洗澡订单（order/list）和各类别最近使用设备（goods/latestUsed），直接保存为可导出样本。")
                }

                // MARK: - Probe & Export Settings
                Section("自动探测与脱敏设置") {
                    Toggle("扫码后自动 HTTP 只读探测", isOn: $bindableCoordinator.autoHTTPProbe)
                    Toggle("已登 U净时自动调扫码识别接口", isOn: $bindableCoordinator.autoUjingProbe)
                    Toggle("已登胖乖时自动查设备详情/SKU", isOn: $bindableCoordinator.autoQiekjProbe)
                    Toggle("导出/复制时自动脱敏手机号与凭据", isOn: $bindableCoordinator.sanitizeExport)
                }

                Section {
                    Text("所有凭据仅存储于本机 iOS Keychain（ThisDeviceOnly），不会进入任何日志；开启自动脱敏后，导出的 JSON 会自动将手机号、JWT、Token 等敏感字段替换为 ***。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("账号与探测")
        }
    }

    private func refreshPreviews() {
        ujingTokenPreview = Sanitizer.maskTokenPreview(KeychainStore.read(.ujingToken))
        qiekjTokenPreview = Sanitizer.maskTokenPreview(KeychainStore.read(.qiekjToken))
    }

    // MARK: - Ujing Actions

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
                feedbackMessage = "U净登录成功！现在去扫码会自动查设备与档位。"
            } catch {
                feedbackMessage = "U净登录失败：\(error.localizedDescription)"
            }
        }
    }

    private func probeUjingStores() {
        let token = KeychainStore.read(.ujingToken)
        guard !token.isEmpty else { return }
        ujingBusy = true
        Task {
            defer { ujingBusy = false }
            let entry = await UjingClient.shared.probeStoresNear(
                keyword: ujingStoreKeyword,
                lat: 30.0,
                lng: 114.0,
                token: token
            )
            let title = ujingStoreKeyword.isEmpty ? "U净门店看板采样" : "U净门店看板 · \(ujingStoreKeyword)"
            _ = coordinator.saveManualSnapshot(
                platform: .ujing,
                title: title,
                probes: [entry],
                context: modelContext
            )
            feedbackMessage = "已保存门店看板采样，前往「记录」页即可导出"
            selectedTab = .records
        }
    }

    // MARK: - Qiekj Actions

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
                feedbackMessage = "胖乖登录成功！建议顺手点一次「一键同步胖乖历史订单」。"
            } catch {
                feedbackMessage = "胖乖登录失败：\(error.localizedDescription)"
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
            feedbackMessage = "已保存 \(entries.count) 项胖乖接口样本，前往「记录」页即可导出"
            selectedTab = .records
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
