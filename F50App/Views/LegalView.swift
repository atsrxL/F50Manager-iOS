import SwiftUI

struct LegalView: View {
    private let files = [
        "swift-nio-LICENSE", "swift-nio-NOTICE",
        "swift-nio-ssl-LICENSE", "swift-nio-ssl-NOTICE", "BoringSSL-LICENSE",
        "swift-atomics-LICENSE", "swift-system-LICENSE", "swift-collections-LICENSE"
    ]
    var body: some View {
        List(files, id: \.self) { name in
            NavigationLink(name) {
                ScrollView {
                    Text(contents(name)).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            }
        }.navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline)
    }
    private func contents(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "许可文件未找到，请参阅源代码中的 F50App/Legal。" }
        return text
    }
}
