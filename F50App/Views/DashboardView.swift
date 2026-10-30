import SwiftUI

@MainActor
struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    var openDevices: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 18, alignment: .top)]

    var body: some View {
        PageContent {
            if (model.isConnected || model.isDemo), let snapshot = model.dashboard {
                hero(snapshot)
                signal(snapshot)
                traffic(snapshot)
                system(snapshot)
                addresses(snapshot)
            } else if model.isConnected {
                Surface(title: "管理连接已建立", icon: "lock.shield") {
                    Text("设备尚未提供可显示的概览数据。没有数据不代表状态正常。")
                        .foregroundStyle(.secondary)
                    Button("读取设备概览") { model.refreshDashboard() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.capabilities["dash"].bool != true)
                    Button("查看设备管理", action: openDevices).buttonStyle(.bordered)
                }
            } else {
                connectionEmpty
            }
            Hint(text: "iOS 无法完整读取设备现有的公开广播。本页仅显示用户主动连接后的加密管理连接数据，不代表 Android 公开广播状态。", icon: "lock.shield")
        }
        .navigationTitle("F50 概览")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.refreshDashboard() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新概览")
                    .disabled(model.isBusy || (!model.isConnected && !model.isDemo))
            }
        }
        .refreshable {
            if !model.isBusy && (model.isConnected || model.isDemo) { model.refreshDashboard() }
        }
    }

    private var connectionEmpty: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "wifi.router.fill")
                .font(.system(size: 46, weight: .light)).foregroundStyle(F50Style.accent)
                .padding(24).background(F50Style.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 28))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("你的 F50，\n尽在掌握。").font(.largeTitle.weight(.bold))
                Text("连接后查看网络与设备状态，安全管理短信和设置。")
                    .font(.body).foregroundStyle(.secondary)
            }
            Label(model.phase, systemImage: "circle.dashed").font(.subheadline)
            Button(action: openDevices) { Label("查找并连接设备", systemImage: "antenna.radiowaves.left.and.right") }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button { model.enterDemo() } label: { Label("先看看演示", systemImage: "play.rectangle") }
                .buttonStyle(.bordered).disabled(model.isBusy || model.isConnected)
            Hint(text: "不会自动扫描或连接。演示只使用本地示例数据，不会对真实设备执行操作。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(F50Style.surface, in: RoundedRectangle(cornerRadius: 28))
    }

    private func hero(_ s: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.model).font(.largeTitle.weight(.bold))
                    Text(s.operatorName ?? "运营商未知").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Image(systemName: "wifi.router.fill").font(.largeTitle).foregroundStyle(F50Style.accent).accessibilityHidden(true)
            }
            Text(DisplayValue.rat(s.rat)).font(.title.weight(.semibold)).foregroundStyle(F50Style.accent)
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                Text("注册 · " + s.ageText(s.registrationAgeMS) + "\n运营商 · " + s.ageText(s.operatorAgeMS))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Label(model.isDemo ? "演示数据" : "加密管理连接数据", systemImage: model.isDemo ? "sparkles" : "lock.shield.fill")
                .font(.caption.weight(.semibold))
            Text("接收于 \(s.receivedAt.formatted(date: .omitted, time: .standard)) · 未提供的数据以 — 显示")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(F50Style.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 26))
    }

    private func signal(_ s: DashboardSnapshot) -> some View {
        Surface(title: "蜂窝网络", icon: "antenna.radiowaves.left.and.right") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                Metric(title: "RSRP · 信号强度", value: DisplayValue.number(s.rsrp, suffix: " dBm"))
                Metric(title: "RSRQ · 信号质量", value: DisplayValue.number(s.rsrq, suffix: " dB", digits: 1))
                Metric(title: "SINR · 信噪比", value: DisplayValue.number(s.sinr, suffix: " dB", digits: 1))
            }
            Divider()
            InfoRow(title: "LTE 频段 / 带宽", value: band(s.lteBand, prefix: "B") + " / " + DisplayValue.number(s.lteBandwidth, suffix: " MHz"))
            InfoRow(title: "NR 频段 / 带宽", value: band(s.nrBand, prefix: "n") + " / " + DisplayValue.number(s.nrBandwidth, suffix: " MHz"))
            freshness(s, source: s.signalAgeMS)
            Hint(text: "SA / NSA 以设备注册信息为准，不根据频段或信号数值推测。")
        }
    }

    private func traffic(_ s: DashboardSnapshot) -> some View {
        Surface(title: "蜂窝流量", icon: "arrow.up.arrow.down") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                Metric(title: "↓ 当前下载", value: DisplayValue.bytes(s.rxRate, rate: true))
                Metric(title: "↑ 当前上传", value: DisplayValue.bytes(s.txRate, rate: true))
                Metric(title: "累计接收", value: DisplayValue.bytes(s.rxBytes))
                Metric(title: "累计发送", value: DisplayValue.bytes(s.txBytes))
            }
            freshness(s, source: s.trafficAgeMS)
            Hint(text: "当前蜂窝接口的累计计数，不是套餐用量；接口重建或计数重置会重新累计。速率不是测速结果。")
        }
    }

    private func system(_ s: DashboardSnapshot) -> some View {
        Surface(title: "设备健康", icon: "cpu") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                Metric(title: "内存使用", value: DisplayValue.number(s.memoryPercent, suffix: "%"))
                Metric(title: "温度", value: DisplayValue.number(s.temperature, suffix: " °C", digits: 1))
            }
            Divider()
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                Text("内存 · " + s.ageText(s.memoryAgeMS) + "\nCPU · " + s.ageText(s.cpuAgeMS))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("CPU · 8 核心").font(.subheadline.weight(.medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 16) {
                ForEach(0..<8, id: \.self) { index in
                    let usage: Double? = index < s.cpu.count ? s.cpu[index] : nil
                    VStack(alignment: .leading, spacing: 7) {
                        InfoRow(title: "核心 \(index + 1)", value: DisplayValue.number(usage, suffix: "%"))
                        ProgressView(value: min(max(usage ?? 0, 0), 100), total: 100)
                            .opacity(usage == nil ? 0.25 : 1).accessibilityHidden(true)
                    }.accessibilityElement(children: .combine)
                }
            }
            Divider()
            InfoRow(title: "运行时间", value: DisplayValue.uptime(s.uptime))
            InfoRow(title: "固件", value: s.firmware ?? "—")
            InfoRow(title: "设备 ID", value: s.deviceID)
            freshness(s, source: s.deviceAgeMS)
        }
    }

    private func addresses(_ s: DashboardSnapshot) -> some View {
        Surface(title: "网络与地址", icon: "network") {
            InfoRow(title: "Wi-Fi 模式", value: DisplayValue.wifi(s.wifiMode))
            InfoRow(title: "Wi-Fi 客户端", value: DisplayValue.number(s.wifiClients))
            freshness(s, source: s.networkAgeMS)
            Divider()
            addressGroup("Host · IPv4", s.hostIPv4)
            addressGroup("Host · IPv6", s.hostIPv6)
            addressGroup("蜂窝 WAN · IPv4", s.wanIPv4)
            addressGroup("蜂窝 WAN · IPv6", s.wanIPv6)
            addressGroup("WireGuard", s.wgAddresses)
            addressGroup("EoIP 管理 · IPv4", s.eoipIPv4)
            freshness(s, source: s.addressAgeMS)
            Hint(text: "这里是接口分配地址，不是网关或路由；EoIP 地址不代表 DHCP 租约有效性。")
        }
    }

    private func addressGroup(_ title: String, _ values: [String]?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(values.map { $0.isEmpty ? "无已分配地址" : $0.joined(separator: "\n") } ?? "—")
                .font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }

    private func freshness(_ s: DashboardSnapshot, source: Double?) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text("数据时效 · " + s.ageText(source, now: context.date))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func band(_ value: Double?, prefix: String) -> String {
        value == nil ? "—" : prefix + DisplayValue.number(value)
    }
}
