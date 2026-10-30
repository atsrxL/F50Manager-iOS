import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var dashboard: DashboardSnapshot?
    @Published var devices: [NearbyDevice] = []
    @Published var phase = "尚未连接"
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var isDemo = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var messages: [SMSMessage] = []
    @Published var smsBox = "inbox"
    @Published var smsNextCursor: String?
    @Published var preparedAction: PreparedAction?
    @Published var capabilities: JSONValue = .object([:])
    @Published var wifiState: JSONValue = .null
    @Published var lockState: JSONValue = .null

    private let session: any SessionServing
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = UUID()
    private var authorized = false
    private var foreground = true
    private var activeOperation: Task<Void, Never>?
    private var polling: Task<Void, Never>?

    var supportsSMS: Bool {
        isDemo || (isConnected && capabilities["sms"]["list"].bool == true && capabilities["sms"]["list_marks_read"].bool == false)
    }
    var supportsSend: Bool { isConnected && !isDemo && capabilities["sms"]["send"].bool == true }
    var supportsDelete: Bool { isConnected && !isDemo && capabilities["sms"]["delete"].bool == true }
    var supportsWiFi: Bool { isConnected && !isDemo && !(capabilities["wifi"]["modes"].strings ?? []).isEmpty }

    init(session: (any SessionServing)? = nil) {
        let session: any SessionServing = session ?? F50Session()
        self.session = session
        session.devicePublisher.sink { [weak self] in self?.devices = $0 }.store(in: &subscriptions)
        session.statusPublisher.sink { [weak self] status in
            guard let self, !self.isDemo else { return }
            self.phase = status
        }.store(in: &subscriptions)
        session.scanPublisher.sink { [weak self] in self?.isScanning = $0 }.store(in: &subscriptions)
        session.onDisconnect = { [weak self] reason in self?.sessionEnded(reason) }
        session.onEvent = { [weak self] method, params in self?.handleEvent(method, params: params) }
    }

    func startScan() {
        guard foreground, !isBusy, !isConnected else { return }
        if isDemo { leaveDemo() }
        errorMessage = nil
        session.startScan()
    }
    func stopScan() { session.stopScan() }

    func connect(_ device: NearbyDevice) {
        guard foreground, !isBusy else { return }
        disconnect()
        isDemo = false
        dashboard = nil
        run {
            try await self.session.connect(id: device.id)
            let hello: JSONValue
            do { hello = try await self.rpc("sys.hello") }
            catch { self.session.disconnect(); throw error }
            guard hello["proto"].string == "f50mgr/1",
                  let deviceID = self.session.connectedDeviceID,
                  hello["device_id"].string == deviceID else {
                self.session.disconnect()
                throw ClientError(message: "设备协议或身份不匹配，已断开连接。")
            }
            self.capabilities = hello["caps"]
            self.isConnected = true
            self.phase = "已连接 · TLS 1.3"
            self.authorized = hello["access"]["authorized"].bool == true && hello["access"]["scope"].string == "connection"
            self.notice = "已验证预置设备证书。首页数据通过加密管理连接读取，并非公开广播。"
            self.startPolling()
            if self.capabilities["dash"].bool == true { try await self.readDashboard() }
            if self.supportsWiFi { self.wifiState = try await self.rpc("wifi.get") }
            if !(self.capabilities["net"]["lock_kinds"].strings ?? []).isEmpty {
                self.lockState = try await self.rpc("net.get", timeout: 45)
            }
        }
    }

    func disconnect() {
        generation = UUID()
        activeOperation?.cancel()
        activeOperation = nil
        polling?.cancel()
        polling = nil
        session.stopScan()
        session.disconnect()
        clearPrivateState()
        isBusy = false
        isConnected = false
        capabilities = .object([:])
        wifiState = .null
        lockState = .null
        phase = "尚未连接"
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if !active {
            disconnect()
            if isDemo { messages = [] }
        }
    }

    func enterDemo() {
        disconnect()
        isDemo = true
        phase = "演示模式 · 合成数据"
        errorMessage = nil
        notice = "仅演示界面，不扫描、不连接，也不会对设备执行任何操作。"
        dashboard = DashboardSnapshot(DemoData.dashboard, deviceID: "DEMO")
        capabilities = .object([:])
        messages = []
    }
    func leaveDemo() {
        disconnect()
        isDemo = false
        dashboard = nil
        notice = nil
    }

    func refreshDashboard() {
        if isDemo {
            dashboard = DashboardSnapshot(DemoData.dashboard, deviceID: "DEMO")
        } else if isConnected {
            run { try await self.readDashboard() }
        }
    }

    func loadMessages(box: String, more: Bool = false) {
        guard ["inbox", "sent"].contains(box), supportsSMS else { return }
        if isDemo {
            smsBox = box
            messages = DemoData.messages.filter { $0.box == box }
            smsNextCursor = nil
            return
        }
        // Validate again inside run to prevent read side effects on older firmware.
        run {
            guard self.capabilities["sms"]["list_marks_read"].bool == false else {
                throw ClientError(message: "此固件可能在读取列表时标记已读；本客户端拒绝静默修改短信状态。")
            }
            try await self.ensureAuthorized()
            let cursor = more && self.smsBox == box ? self.smsNextCursor : nil
            if more && cursor == nil { return }
            let response = try await self.rpc("sms.list", params: ["box": .string(box), "limit": .number(20), "cursor": cursor.map(JSONValue.string) ?? .null], timeout: 45)
            guard let items = response["items"].array else { throw ClientError(message: "短信列表响应格式无效。") }
            let decoded = items.compactMap(SMSMessage.init)
            guard decoded.count == items.count else { throw ClientError(message: "短信记录格式无效，未展示不完整列表。") }
            if more && self.smsBox == box {
                let known = Set(self.messages.map(\.id))
                self.messages += decoded.filter { !known.contains($0.id) }
            } else {
                self.messages = decoded
            }
            self.smsBox = box
            self.smsNextCursor = response["next_cursor"].string
        }
    }

    func prepareSend(to: String, body: String) {
        guard supportsSend else { return }
        do {
            let phone = try SMSValidation.phone(to), text = try SMSValidation.body(body)
            prepare(kind: "sms.send", params: ["to": .string(phone), "body": .string(text)])
        } catch { errorMessage = error.localizedDescription }
    }
    func prepareDelete(_ message: SMSMessage) {
        guard supportsDelete, SMSValidation.validID(message.id) else { return }
        prepare(kind: "sms.delete", params: ["ids": .array([.string(message.id)])])
    }
    func prepareWiFi(target: String) {
        guard supportsWiFi, (capabilities["wifi"]["modes"].strings ?? []).contains(target) else { return }
        guard wifiState.object?["pending"] == .null,
              let current = wifiState["mode"].string, ["local", "eoip"].contains(current) else {
            errorMessage = "请先读取 Wi-Fi 状态，并处理已有事务后再切换。"
            return
        }
        guard current != target else { notice = "设备已经处于所选 Wi-Fi 模式。"; return }
        prepare(kind: "wifi.set_mode", params: ["target": .string(target)])
    }
    func prepareRAT(mode: String) {
        guard supportsLock("rat_pref"), (capabilities["net"]["rat_modes"].strings ?? []).contains(mode) else { return }
        prepare(kind: "net.set_lock", params: ["kind": .string("rat_pref"), "value": .object(["mode": .string(mode)])])
    }
    func prepareBands(kind: String, bands: [Int]) {
        guard supportsLock(kind) else { return }
        do {
            let key = kind == "lte_band" ? "lte_bands" : "nr_bands"
            let supported = capabilities["net"][key].array?.compactMap { item -> Int? in
                guard let n = item.bounded(1...1024), n.rounded() == n else { return nil }
                return Int(n)
            }
            try ActionPolicy.validateBands(kind: kind, bands: bands, supported: supported)
            prepare(kind: "net.set_lock", params: ["kind": .string(kind), "value": .object(["bands": .array(bands.map { .number(Double($0)) })])])
        } catch { errorMessage = error.localizedDescription }
    }
    func prepareClearLock(kind: String) {
        guard supportsLock(kind), ["rat_pref", "lte_band", "nr_band"].contains(kind) else { return }
        prepare(kind: "net.clear_lock", params: ["kind": .string(kind)])
    }
    func prepareReboot() {
        guard isConnected, !isDemo, capabilities["os"]["reboot"].bool == true else { return }
        prepare(kind: "os.reboot", params: [:])
    }

    func commitPrepared() {
        guard !isBusy, let action = preparedAction, isConnected, !isDemo else { return }
        guard !action.isExpired else {
            preparedAction = nil
            errorMessage = "确认已过期，请重新发起操作。"
            return
        }
        // Consume locally before awaiting. A failed/uncertain commit is never replayed.
        preparedAction = nil
        run {
            try await self.ensureAuthorized()
            guard !action.isExpired else { throw ClientError(message: "确认已过期，请重新发起操作。") }
            let response: JSONValue
            do {
                response = try await self.rpc("action.commit", params: ["action_id": .string(action.id)], timeout: action.kind == "os.reboot" ? 10 : 75)
            } catch {
                throw ClientError(message: "操作结果不确定；不会自动重试。请重新连接并读取实际状态。")
            }
            self.notice = ActionPolicy.outcome(kind: action.kind, result: response)
            if action.kind == "sms.send" || action.kind == "sms.delete" {
                self.messages = []
                self.smsNextCursor = nil
            }
            if action.kind == "wifi.set_mode", let txn = response["txn_id"].string,
               response["state"].string == "applied_pending_confirm" {
                self.wifiState = .object(["mode": .string("unknown"), "pending": .object(["txn_id": .string(txn), "expires_in_s": response["guard_ttl_s"]])])
            }
        }
    }
    func cancelPrepared() {
        guard let action = preparedAction else { return }
        preparedAction = nil
        if isConnected && !isBusy && !isDemo {
            run { _ = try await self.rpc("action.cancel", params: ["action_id": .string(action.id)]) }
        }
    }

    func confirmWiFi() { finishWiFi(confirm: true) }
    func rollbackWiFi() { finishWiFi(confirm: false) }
    func refreshManagement() {
        guard isConnected, !isDemo else { return }
        run {
            if self.supportsWiFi { self.wifiState = try await self.rpc("wifi.get") }
            if !(self.capabilities["net"]["lock_kinds"].strings ?? []).isEmpty {
                self.lockState = try await self.rpc("net.get", timeout: 45)
            }
        }
    }

    private func finishWiFi(confirm: Bool) {
        guard supportsWiFi, let txn = wifiState["pending"]["txn_id"].string else { return }
        run {
            try await self.ensureAuthorized()
            let result = try await self.rpc(confirm ? "wifi.confirm" : "wifi.rollback", params: ["txn_id": .string(txn)])
            let expected = confirm ? "confirmed" : "rolled_back"
            guard result["state"].string == expected else {
                throw ClientError(message: "Wi-Fi 事务结果未知，请重新读取设备状态。")
            }
            self.notice = confirm ? "已明确确认保留 Wi-Fi 设置。" : "设备报告 Wi-Fi 已回滚。"
            self.wifiState = try await self.rpc("wifi.get")
        }
    }
    private func supportsLock(_ kind: String) -> Bool {
        isConnected && !isDemo && (capabilities["net"]["lock_kinds"].strings ?? []).contains(kind)
    }
    private func prepare(kind: String, params: [String: JSONValue]) {
        guard isConnected, !isDemo, preparedAction == nil else { return }
        run {
            try await self.ensureAuthorized()
            let result = try await self.rpc("action.prepare", params: ["kind": .string(kind), "params": .object(params)])
            guard let id = result["action_id"].string, Data(base64Encoded: id)?.count == 16,
                  let summary = result["summary_zh"].string, !summary.isEmpty,
                  let risk = result["risk"].string,
                  let ttl = result["expires_in_s"].bounded(1...60) else {
                throw ClientError(message: "设备未返回有效的操作确认，已拒绝执行。")
            }
            self.preparedAction = PreparedAction(id: id, kind: kind, summary: summary, risk: risk, ttl: ttl)
        }
    }
    private func ensureAuthorized() async throws {
        if authorized { return }
        // Explicit V12 contract: configured code, only after verified pinned TLS.
        // Never persist it, log it, or retry authorization after failure.
        let result = try await rpc("access.authorize", params: ["code": .string("1121")])
        try ActionPolicy.requireAuthorization(result)
        authorized = true
    }
    private func readDashboard() async throws {
        guard capabilities["dash"].bool == true else { return }
        let value = try await rpc("dash.get")
        guard value.object != nil else { throw ClientError(message: "设备状态响应格式无效。") }
        dashboard = DashboardSnapshot(value, deviceID: session.connectedDeviceID ?? "未知")
    }
    private func rpc(_ method: String, params: [String: JSONValue] = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        let token = generation
        try Task.checkCancellation()
        let result = try await session.request(method: method, params: params, timeout: timeout)
        guard token == generation, foreground else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard foreground, !isBusy else { return }
        let token = generation
        isBusy = true
        errorMessage = nil
        activeOperation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.isBusy = false
                    self.activeOperation = nil
                }
            }
            do { try await operation() }
            catch is CancellationError { }
            catch {
                if self.generation == token { self.errorMessage = error.localizedDescription }
            }
        }
    }
    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            var cycles = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                guard let self, self.foreground, self.isConnected, !self.isDemo else { break }
                guard !self.isBusy, self.preparedAction == nil else { continue }
                cycles += 1
                if self.capabilities["dash"].bool == true { self.refreshDashboard() }
                else if cycles % 10 == 0 { self.run { _ = try await self.rpc("sys.ping") } }
            }
        }
    }
    private func clearPrivateState() {
        authorized = false
        messages = []
        smsNextCursor = nil
        preparedAction = nil
        // Notices can include action summaries/results; do not retain across sessions.
        notice = nil
        errorMessage = nil
    }
    private func sessionEnded(_ reason: String) {
        let hadConnection = isConnected || isBusy
        generation = UUID()
        activeOperation?.cancel()
        activeOperation = nil
        polling?.cancel()
        polling = nil
        clearPrivateState()
        isConnected = false
        isBusy = false
        capabilities = .object([:])
        wifiState = .null
        lockState = .null
        if !isDemo { phase = reason }
        if hadConnection && foreground { errorMessage = reason + "；如刚提交操作，结果可能不确定，请勿自动重试。" }
    }
    private func handleEvent(_ method: String, params: JSONValue) {
        guard isConnected, foreground, !isDemo else { return }
        if method == "event.wifi_txn" {
            switch params["state"].string {
            case "rollback_failed": errorMessage = "严重：设备 Wi-Fi 自动回滚失败，请通过 USB / 现有管理通道检查。"
            case "confirmed": notice = "Wi-Fi 事务已确认。"; wifiState = .null
            case "rolled_back": notice = "Wi-Fi 事务已回滚。"; wifiState = .null
            default: break
            }
        }
    }
}
