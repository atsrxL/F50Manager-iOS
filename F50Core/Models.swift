import Foundation

struct DashboardSnapshot {
    let receivedAt: Date
    private let receivedUptime: TimeInterval
    let deviceID: String
    let model: String
    let firmware: String?
    let rat: String?
    let operatorName: String?
    let rsrp: Double?
    let rsrq: Double?
    let sinr: Double?
    let lteBand: Double?
    let nrBand: Double?
    let lteBandwidth: Double?
    let nrBandwidth: Double?
    let rxRate: Double?
    let txRate: Double?
    let rxBytes: Double?
    let txBytes: Double?
    let cpu: [Double?]
    let memoryPercent: Double?
    let temperature: Double?
    let uptime: Double?
    let wifiMode: String?
    let wifiClients: Double?
    let hostIPv4: [String]?
    let hostIPv6: [String]?
    let wanIPv4: [String]?
    let wanIPv6: [String]?
    let wgAddresses: [String]?
    let eoipIPv4: [String]?
    let signalAgeMS: Double?
    let deviceAgeMS: Double?
    let networkAgeMS: Double?
    let operatorAgeMS: Double?
    let registrationAgeMS: Double?
    let cpuAgeMS: Double?
    let memoryAgeMS: Double?
    let trafficAgeMS: Double?
    let addressAgeMS: Double?

    init(_ value: JSONValue, deviceID: String, now: Date = Date()) {
        receivedAt = now
        receivedUptime = ProcessInfo.processInfo.systemUptime
        self.deviceID = deviceID
        let device = value["device"], cellular = value["cellular"], network = value["network"]
        let ages = value["freshness_ms"]
        model = device["model"].string ?? "ZTE F50"
        firmware = device["fw"].string
        rat = cellular["rat"].string
        operatorName = cellular["operator"].string ?? cellular["operator_plmn"].string
        let nr = rat == "nr_sa" || rat == "nr_nsa"
        let signal = nr ? cellular["nr"] : (rat == "lte" ? cellular["lte"] : .null)
        rsrp = signal[nr ? "ss_rsrp_dbm" : "rsrp_dbm"].bounded(-1000...1000)
        rsrq = signal[nr ? "ss_rsrq_db" : "rsrq_db"].bounded(-1000...1000)
        sinr = signal[nr ? "ss_sinr_db" : "sinr_db"].bounded(-1000...1000)
        lteBand = cellular["lte"]["band"].bounded(1...1024)
        nrBand = cellular["nr"]["band"].bounded(1...1024)
        lteBandwidth = cellular["lte"]["bandwidth_mhz"].bounded(0...1e15)
        nrBandwidth = cellular["nr"]["bandwidth_mhz"].bounded(0...1e15)
        rxRate = cellular["rx_bytes_per_s"].bounded(0...1e15)
        txRate = cellular["tx_bytes_per_s"].bounded(0...1e15)
        rxBytes = cellular["rx_bytes"].bounded(0...Double(Int64.max))
        txBytes = cellular["tx_bytes"].bounded(0...Double(Int64.max))
        let cores = device["cpu_usage_pct"].array
        cpu = (0..<8).map { index in
            guard let cores, cores.count == 8 else { return nil }
            return cores[index].bounded(0...100)
        }
        memoryPercent = device["memory_used_ratio"].bounded(0...1).map { $0 * 100 }
        temperature = device["cpu_temp_c"].bounded(-40...150) ?? device["temperatures_c"]["cpu"].bounded(-40...150)
        uptime = device["uptime_s"].bounded(0...Double(Int64.max))
        wifiMode = network["wifi_mode"].string
        wifiClients = network["wifi_clients"].bounded(0...Double(Int32.max))
        hostIPv4 = network["host_ipv4"].strings
        hostIPv6 = network["host_ipv6"].strings
        wanIPv4 = network["wan_ipv4"].strings
        wanIPv6 = network["wan_ipv6"].strings
        let v4 = network["wg_ipv4"].strings, v6 = network["wg_ipv6"].strings
        wgAddresses = v4 != nil && v6 != nil ? v4! + v6! : nil
        eoipIPv4 = network["eoip_ipv4"].strings
        // An explicitly unknown source age must not inherit another source's fresh age.
        signalAgeMS = (ages.object?["cellular_signal"] ?? ages["cellular"]).bounded(0...86_400_000)
        deviceAgeMS = ages["device"].bounded(0...86_400_000)
        networkAgeMS = ages["network"].bounded(0...86_400_000)
        operatorAgeMS = ages["cellular_operator"].bounded(0...86_400_000)
        registrationAgeMS = ages["cellular_registration"].bounded(0...86_400_000)
        cpuAgeMS = ages["cpu"].bounded(0...86_400_000)
        memoryAgeMS = ages["memory"].bounded(0...86_400_000)
        trafficAgeMS = ages["traffic"].bounded(0...86_400_000)
        addressAgeMS = ages["addresses"].bounded(0...86_400_000)
    }

    func ageText(_ sourceAgeMS: Double?, now: Date = Date()) -> String {
        guard let sourceAgeMS else { return "数据年龄未知" }
        // A user's wall-clock adjustment must never freshen retained telemetry.
        let seconds = sourceAgeMS / 1000 + max(0, ProcessInfo.processInfo.systemUptime - receivedUptime)
        if seconds < 15 { return "约 \(Int(seconds)) 秒前" }
        return "缓存 · 约 \(Int(seconds)) 秒前"
    }
}

extension JSONValue {
    func bounded(_ range: ClosedRange<Double>) -> Double? {
        guard let value = number, range.contains(value) else { return nil }
        return value
    }
}

struct SMSMessage: Identifiable, Equatable {
    let id: String
    let peer: String
    let body: String
    let date: Date?
    let status: String
    let box: String

    init?(_ value: JSONValue) {
        guard let id = value["id"].string, SMSValidation.validID(id),
              let peer = value["peer"].string, let body = value["body"].string,
              let box = value["box"].string, ["inbox", "sent"].contains(box) else { return nil }
        self.id = id
        self.peer = peer
        self.body = body
        self.box = box
        date = value["ts"].bounded(0...253_402_300_799).map(Date.init(timeIntervalSince1970:))
        status = value["status"].string ?? "unknown"
    }
}

struct PreparedAction: Identifiable {
    let id: String
    let kind: String
    let summary: String
    let risk: String
    let expiresAt: Date
    let deadlineUptime: TimeInterval

    init(id: String, kind: String, summary: String, risk: String, ttl: TimeInterval) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.risk = risk
        expiresAt = Date().addingTimeInterval(ttl)
        deadlineUptime = ProcessInfo.processInfo.systemUptime + ttl
    }
    var isExpired: Bool { ProcessInfo.processInfo.systemUptime >= deadlineUptime }
}
