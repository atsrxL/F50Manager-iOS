import Foundation

enum SMSValidation {
    static let gsm = Set("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà".unicodeScalars)
    static let extended = Set("\u{000C}^{}\\[~]|€".unicodeScalars)

    static func phone(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("+") ? String(value.dropFirst()) : value
        guard (3...20).contains(digits.utf8.count), !digits.isEmpty,
              digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ClientError(message: "号码须为 3–20 位数字，可带 + 前缀。")
        }
        return value
    }

    static func body(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError(message: "短信正文不能为空。")
        }
        guard text.unicodeScalars.allSatisfy({ $0.value <= 0xffff && ($0.value >= 32 || $0 == "\n" || $0 == "\t") }) else {
            throw ClientError(message: "单条短信不支持表情、非 BMP 字符或控制字符。")
        }
        guard !text.hasSuffix("\n") else { throw ClientError(message: "正文末尾不能是换行。") }
        let scalars = text.unicodeScalars
        if scalars.allSatisfy({ gsm.contains($0) || extended.contains($0) }) {
            let length = scalars.reduce(0) { $0 + (extended.contains($1) ? 2 : 1) }
            guard length <= 160 else { throw ClientError(message: "GSM-7 最多 160 个 septet，扩展字符计 2；不支持分段发送。") }
        } else if text.utf16.count > 70 {
            throw ClientError(message: "中文 / Unicode 短信最多 70 个 UTF-16 单位；不支持分段发送。")
        }
        return text
    }

    static func validID(_ value: String) -> Bool {
        (1...6).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) } && (Int(value) ?? 0) > 0
    }
}

enum ActionPolicy {
    static func requireAuthorization(_ response: JSONValue) throws {
        guard response["scope"].string == "connection",
              response.object?["expires_in_s"] == .null else {
            throw ClientError(message: "设备未确认连接级授权；为安全起见已拒绝继续。")
        }
    }

    static func validateBands(kind: String, bands: [Int], supported: [Int]?) throws {
        guard ["lte_band", "nr_band"].contains(kind), !bands.isEmpty, bands.count <= 32,
              Set(bands).count == bands.count,
              bands.allSatisfy({ (1...(kind == "lte_band" ? 255 : 1024)).contains($0) }),
              supported.map({ Set(bands).isSubset(of: Set($0)) }) ?? true else {
            throw ClientError(message: "请选择设备支持的频段，最多 32 个且不能重复；清除锁定请单独操作。")
        }
    }

    static func outcome(kind: String, result: JSONValue) -> String {
        switch kind {
        case "sms.send":
            switch result["status"].string {
            case "submitted": return "已提交短信，不代表送达。"
            case "failed": return "短信提交失败；不会自动重发。"
            default: return "短信发送结果不确定；不要直接重发，请先检查设备状态。"
            }
        case "sms.delete":
            guard let deleted = result["deleted"].strings, let failed = result["failed"].strings else {
                return "删除结果不确定，请重新读取短信列表。"
            }
            return "已删除 \(deleted.count) 条，失败 \(failed.count) 条；仅删除设备短信池记录。"
        case "net.set_lock", "net.clear_lock":
            switch result["status"].string {
            case "verified": return "设备已通过权威读回确认设置。"
            case "applied_unverified": return "已下发，未能确认生效。不要将缓存或未知读回视为成功。"
            case "failed": return "设备报告设置失败，请重新读取状态。"
            default: return "设置结果未知，不能确认生效。"
            }
        case "wifi.set_mode":
            if result["state"].string == "applied_pending_confirm", result["txn_id"].string != nil {
                return "Wi-Fi 设置待确认：请检查连通性后点“确认保留”，否则设备守护将自动回滚。"
            }
            return "Wi-Fi 结果不确定，请读取事务状态；不会自动确认。"
        case "os.reboot":
            return result["status"].string == "scheduled" ? "设备已安排重启，蓝牙即将断开。" : "重启结果不确定，请检查设备。"
        default: return "操作结果未知，请重新读取设备状态。"
        }
    }
}
