import SwiftUI

@MainActor
struct DeviceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var ratMode = ""
    private var canManage: Bool { model.isConnected && !model.isDemo && !model.isBusy }
    private var wifiStateKnown: Bool { model.wifiState.object?["pending"] != nil && model.wifiState["mode"].string != nil }
    private var canChangeWiFi: Bool {
        canManage && model.supportsWiFi && wifiStateKnown && model.wifiState["pending"].isNull
        && ["local", "eoip"].contains(model.wifiState["mode"].string ?? "")
    }
    private var lockKinds: [String] { model.capabilities["net"]["lock_kinds"].strings ?? [] }
    private var ratModes: [String] { model.capabilities["net"]["rat_modes"].strings ?? [] }

    var body: some View {
        PageContent {
            connection
            if model.isConnected || model.isDemo {
                wifi
                networkLocks
                maintenance
            }
            security
        }
        .navigationTitle("设备")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.refreshManagement() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新管理状态").disabled(!canManage)
            }
        }
        .onChange(of: model.isConnected) { _, _ in ratMode = "" }
        .onChange(of: model.isDemo) { _, _ in ratMode = "" }
    }

    private var connection: some View {
        Surface(title: "管理连接", icon: "antenna.radiowaves.left.and.right") {
            Label(model.phase, systemImage: model.isConnected ? "lock.shield.fill" : "circle.dashed")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(model.isConnected ? F50Style.accent : .secondary)
            if model.isDemo {
                Text("你正在浏览本地演示，所有真实管理操作均已禁用。")
                    .foregroundStyle(.secondary)
                Button("退出演示，连接设备") { model.leaveDemo() }.buttonStyle(.borderedProminent)
            } else if model.isConnected {
                Hint(text: "这是经过证书校验的加密管理连接。App 离开前台后会断开，不会自动重连。", icon: "lock.shield")
                Button("断开连接", role: .destructive) { model.disconnect() }
                    .buttonStyle(.bordered)
            } else {
                Text("只发现 F50 管理服务，不解析现有公开广播。请选择设备并明确点击连接。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if model.isScanning {
                    HStack(spacing: 12) { ProgressView(); Text("正在查找附近的管理服务…").font(.subheadline) }
                    Button("停止查找") { model.stopScan() }.buttonStyle(.bordered)
                } else {
                    Button { model.startScan() } label: { Label("查找附近设备", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy)
                }
                if model.devices.isEmpty {
                    Hint(text: "未发现设备？请确认蓝牙权限已允许、设备已开启管理服务，并靠近设备。不会自动发起连接。")
                }
                ForEach(model.devices) { device in
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text(device.name).font(.headline)
                        Text("蓝牙信号 \(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        Text(device.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        Button { model.connect(device) } label: { Label("连接此设备", systemImage: "link") }
                            .buttonStyle(.bordered).disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private var wifi: some View {
        Surface(title: "Wi-Fi 工作模式", icon: "wifi") {
            InfoRow(title: "设备报告模式", value: DisplayValue.wifi(model.wifiState["mode"].string))
            Text("Host 连接本地 LAN；EoIP 将 Wi-Fi 接入远端网络。切换可能暂时影响联网。")
                .font(.subheadline).foregroundStyle(.secondary)
            if !wifiStateKnown {
                Hint(text: "尚未读取完整 Wi-Fi 状态。先读取模式及未完成事务，避免覆盖仍在等待确认的切换。")
                Button("读取 Wi-Fi 与管理状态") { model.refreshManagement() }
                    .buttonStyle(.bordered).disabled(!canManage)
            } else if !model.wifiState["pending"].isNull {
                wifiTransaction
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { wifiButtons }
                    VStack(alignment: .leading, spacing: 12) { wifiButtons }
                }
                Hint(text: "先准备并核对设备摘要。切换后必须在保护期限内确认，否则设备会尝试自动回滚。")
                if !["local", "eoip"].contains(model.wifiState["mode"].string ?? "") {
                    Hint(text: "当前模式未知，已禁用切换。请重新读取管理状态。")
                }
            }
            if !model.supportsWiFi { Hint(text: "当前设备未声明支持 Wi-Fi 模式管理。") }
        }
    }

    @ViewBuilder private var wifiButtons: some View {
        Button("切换为 Host") { model.prepareWiFi(target: "local") }
            .buttonStyle(.bordered)
            .disabled(!canChangeWiFi || model.wifiState["mode"].string == "local" || !wifiSupports("local"))
        Button("切换为 EoIP") { model.prepareWiFi(target: "eoip") }
            .buttonStyle(.bordered)
            .disabled(!canChangeWiFi || model.wifiState["mode"].string == "eoip" || !wifiSupports("eoip"))
    }

    private func wifiSupports(_ mode: String) -> Bool {
        model.capabilities["wifi"]["modes"].strings?.contains(mode) == true
    }

    private var wifiTransaction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("切换待确认", systemImage: "clock.badge.exclamationmark")
                .font(.headline).foregroundStyle(.orange)
            InfoRow(title: "目标模式", value: DisplayValue.wifi(model.wifiState["pending"]["target"].string))
            InfoRow(title: "设备报告剩余保护时间", value: DisplayValue.number(model.wifiState["pending"]["expires_in_s"].number, suffix: " 秒"))
            Hint(text: "剩余时间为最近一次读取值，不是实时倒计时。请先检查实际 Wi-Fi 联网，再确认保留；不确定时选择回滚。")
            Button("联网正常，确认保留") { model.confirmWiFi() }
                .buttonStyle(.borderedProminent).disabled(!canManage || !model.supportsWiFi)
            Button("回滚到原模式", role: .destructive) { model.rollbackWiFi() }
                .buttonStyle(.bordered).disabled(!canManage || !model.supportsWiFi)
            Button("重新读取事务状态") { model.refreshManagement() }.disabled(!canManage)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var networkLocks: some View {
        Surface(title: "网络制式与频段", icon: "slider.horizontal.3") {
            InfoRow(title: "回读来源", value: readbackSource)
            InfoRow(title: "当前制式偏好", value: model.lockState["rat_pref"].string.map { DisplayValue.rat($0) } ?? "未锁定或未知")
            InfoRow(title: "LTE 频段设置", value: bandState("lte_band", prefix: "B"))
            InfoRow(title: "NR 频段设置", value: bandState("nr_band", prefix: "n"))
            Hint(text: "空值不等于已解锁。只有设备权威回读匹配时才可确认生效；已下发但未验证不算成功。")
            Divider()
            if lockKinds.contains("rat_pref") && !ratModes.isEmpty {
                Picker("目标制式", selection: $ratMode) {
                    Text("请选择").tag("")
                    ForEach(ratModes, id: \.self) { mode in
                        Text(DisplayValue.rat(mode) + " · " + mode).tag(mode)
                    }
                }.disabled(!canManage)
                Button("准备应用制式") { model.prepareRAT(mode: ratMode) }
                    .buttonStyle(.bordered).disabled(!canManage || !ratModes.contains(ratMode))
                Button("准备清除制式锁定", role: .destructive) { model.prepareClearLock(kind: "rat_pref") }
                    .disabled(!canManage)
            }
            if lockKinds.contains("lte_band") {
                bandNavigation(kind: "lte_band", title: "LTE 频段", capKey: "lte_bands", prefix: "B")
            }
            if lockKinds.contains("nr_band") {
                bandNavigation(kind: "nr_band", title: "NR 频段", capKey: "nr_bands", prefix: "n")
            }
            if lockKinds.isEmpty {
                Hint(text: "设备未声明支持制式或频段锁定，相关操作不可用。")
            }
        }
    }

    private func bandNavigation(kind: String, title: String, capKey: String, prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                BandSelectionView(kind: kind, title: title, prefix: prefix, supported: model.capabilities["net"][capKey].array?.compactMap { value in
                    guard let n = value.number, n.rounded() == n, n >= 1, n <= (kind == "nr_band" ? 1024 : 255) else { return nil }
                    return Int(n)
                })
            } label: { Label("选择\(title)", systemImage: "list.bullet") }
                .disabled(!canManage)
            Button("准备清除\(title)锁定", role: .destructive) { model.prepareClearLock(kind: kind) }
                .disabled(!canManage)
        }.padding(.vertical, 4)
    }

    private var readbackSource: String {
        switch model.lockState["source"].string {
        case "readback": return "设备回读"
        case "cached": return "缓存（非实时验证）"
        default: return "未知"
        }
    }

    private func bandState(_ key: String, prefix: String) -> String {
        guard let values = model.lockState[key].array, !values.isEmpty else { return "未锁定或未知" }
        return values.compactMap(\.number).map { prefix + DisplayValue.number($0) }.joined(separator: "、")
    }

    private var maintenance: some View {
        Surface(title: "维护", icon: "wrench.and.screwdriver") {
            Button(role: .destructive) { model.prepareReboot() } label: {
                Label("准备重启设备", systemImage: "restart")
            }
            .buttonStyle(.bordered)
            .disabled(!canManage || model.capabilities["os"]["reboot"].bool != true)
            Hint(text: "重启会中断网络及管理连接，执行前仍需确认设备摘要；不会改变默认系统。")
            Divider()
            Label("系统切换 · 首版禁用", systemImage: "nosign")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("本客户端不提供 Android / OpenWrt 系统切换，也不提供后台常驻或短信推送承诺。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var security: some View {
        Surface(title: "连接与隐私", icon: "lock.shield") {
            Hint(text: "仅接受预置、固定的设备证书。证书未知、失配或 TLS 验证失败时拒绝连接，不提供忽略验证选项。", icon: "checkmark.shield")
            Hint(text: "蓝牙发现名称与信号强度不能证明设备身份；只有加密握手完成后才建立管理连接。")
            Hint(text: "保护操作可能使用设备的配置访问码授权当前连接。访问授权不替代证书校验，请只在可信范围内开放管理服务。")
            Hint(text: "超时或连接断开后不重放任何写操作。请重新读取状态，再决定是否重新发起。", icon: "arrow.counterclockwise")
            NavigationLink { LegalView() } label: { Label("开源许可", systemImage: "doc.text") }
        }
    }
}

@MainActor
private struct BandSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let kind: String
    let title: String
    let prefix: String
    let supported: [Int]?
    @State private var selected = Set<Int>()
    @State private var manual = ""

    private var choices: [Int] { Array(Set(supported ?? [])).sorted() }
    private var manualBands: [Int]? {
        let parts = manual.components(separatedBy: CharacterSet(charactersIn: ",，、 \n")).filter { !$0.isEmpty }
        let values = parts.compactMap(Int.init)
        let maximum = kind == "nr_band" ? 1024 : 255
        guard !values.isEmpty, values.count == parts.count, values.allSatisfy({ (1...maximum).contains($0) }), Set(values).count == values.count, values.count <= 32 else { return nil }
        return values.sorted()
    }
    private var selectedBands: [Int]? {
        if supported == nil { return manualBands }
        guard !selected.isEmpty, selected.count <= 32, selected.isSubset(of: Set(choices)) else { return nil }
        return selected.sorted()
    }
    private var canManage: Bool { model.isConnected && !model.isDemo && !model.isBusy }

    var body: some View {
        PageContent {
            Surface(title: "选择\(title)", icon: "antenna.radiowaves.left.and.right") {
                if supported == nil {
                    Hint(text: "设备未公布支持的频段列表。可输入数字，由设备在准备阶段校验，不会绕过验证。")
                    TextField("例如 1, 3, 41", text: $manual, axis: .vertical)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        .accessibilityLabel("频段编号，以逗号分隔")
                } else if choices.isEmpty {
                    Hint(text: "设备支持列表为空，无法选择此类频段。")
                } else {
                    ForEach(choices, id: \.self) { band in
                        Toggle("\(prefix)\(band)", isOn: Binding(get: { selected.contains(band) }, set: { checked in
                            if checked { selected.insert(band) } else { selected.remove(band) }
                        }))
                        .disabled(!canManage || (!selected.contains(band) && selected.count >= 32))
                    }
                }
                Hint(text: "请选择 1–32 个不重复频段。频段锁定可能中断服务；不会自动选择或执行。")
            }
            Button("准备应用所选频段") {
                guard let bands = selectedBands else { return }
                model.prepareBands(kind: kind, bands: bands)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!canManage || selectedBands == nil)
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.isConnected) { _, connected in if !connected { clear() } }
        .onChange(of: model.isDemo) { _, _ in clear() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear() } }
    }
    private func clear() { selected.removeAll(); manual = "" }
}
