import Foundation

/// Entirely synthetic fixtures. Never used as fallback for live requests.
enum DemoData {
    static let dashboard: JSONValue = .object([
        "device": .object([
            "model": .string("ZTE F50"), "fw": .string("OpenWrt · 演示"),
            "uptime_s": .number(86400 + 7200), "cpu_temp_c": .number(46.2),
            "cpu_usage_pct": .array([12, 28, 8, 43, 16, 9, 24, 18].map { .number(Double($0)) }),
            "memory_used_ratio": .number(0.38)
        ]),
        "cellular": .object([
            "rat": .string("nr_sa"), "operator": .string("演示网络"),
            "lte": .object(["band": .number(3), "bandwidth_mhz": .number(20)]),
            "nr": .object(["band": .number(78), "bandwidth_mhz": .number(100),
                           "ss_rsrp_dbm": .number(-86), "ss_rsrq_db": .number(-9.5), "ss_sinr_db": .number(23)]),
            "rx_bytes_per_s": .number(12_800_000), "tx_bytes_per_s": .number(2_400_000),
            "rx_bytes": .number(7_500_000_000), "tx_bytes": .number(820_000_000)
        ]),
        "network": .object([
            "wifi_mode": .string("local"), "wifi_clients": .number(3),
            "host_ipv4": .array([.string("192.0.2.1")]), "host_ipv6": .array([]),
            "wan_ipv4": .array([.string("198.51.100.8")]), "wan_ipv6": .array([.string("2001:db8::8")]),
            "wg_ipv4": .array([.string("192.0.2.2")]), "wg_ipv6": .array([]),
            "eoip_ipv4": .array([.string("203.0.113.10")])
        ]),
        "freshness_ms": .object(["device": .number(3000), "cellular_signal": .number(1200), "network": .number(4000),
                                 "cellular_operator": .number(3000), "cellular_registration": .number(1200),
                                 "cpu": .number(200), "memory": .number(200), "traffic": .number(200), "addresses": .number(4000)])
    ])

    private static let rawMessages: [JSONValue] = [
        .object(["id": .string("000001"), "peer": .string("演示通知"), "body": .string("欢迎使用 F50 Manager。此消息仅用于界面演示，不是设备中的真实短信。"), "ts": .number(1_790_000_000), "status": .string("unread"), "box": .string("inbox")]),
        .object(["id": .string("000002"), "peer": .string("演示联系人"), "body": .string("连接通过 TLS 1.3 加密。发送操作需要您再次确认；“已提交”不代表已送达。"), "ts": .number(1_789_999_800), "status": .string("sent"), "box": .string("sent")])
    ]
    static let messages = rawMessages.compactMap(SMSMessage.init)
}
