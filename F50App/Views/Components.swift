import SwiftUI

// Shared native surfaces keep large type, dark mode and iPad layouts consistent.
enum F50Style {
    static let accent = Color("AccentColor")
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

struct PageContent<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
        }
        .background(F50Style.canvas)
    }
}

struct Surface<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(F50Style.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).foregroundStyle(.secondary)
                Text(value)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct Hint: View {
    var text: String
    var icon = "info.circle"
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: icon)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct Metric: View {
    let title: String
    let value: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum DisplayValue {
    static func number(_ value: Double?, suffix: String = "", digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits))) + suffix
    }
    static func bytes(_ value: Double?, rate: Bool = false) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        let result = ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .decimal)
        return result + (rate ? "/s" : "")
    }
    static func uptime(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
        let minutes = Int(value / 60)
        return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时 \(minutes % 60) 分钟"
    }
    static func rat(_ value: String?) -> String {
        switch value {
        case "nr_sa": return "5G SA"
        case "nr_nsa": return "5G NSA"
        case "lte": return "4G LTE"
        case "lte_nr": return "LTE + NR"
        case "auto": return "自动"
        case "wcdma": return "3G WCDMA"
        case "gsm": return "2G GSM"
        case "none": return "未注册"
        default: return "未知"
        }
    }
    static func wifi(_ value: String?) -> String {
        switch value { case "local": return "Host"; case "eoip": return "EoIP"; default: return "未知" }
    }
}
