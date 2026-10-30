import SwiftUI

@MainActor
struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var composing = false
    @State private var pendingSend: (to: String, body: String)?
    @State private var selectedMessageID: String?

    private var canRead: Bool { !model.isBusy && (model.isDemo || (model.isConnected && model.supportsSMS)) }
    private var canSend: Bool { model.isConnected && !model.isDemo && !model.isBusy && model.supportsSend }

    var body: some View {
        PageContent {
            Surface(title: "设备短信", icon: "bubble.left.and.bubble.right") {
                Picker("短信箱", selection: Binding(get: { model.smsBox }, set: { model.loadMessages(box: $0) })) {
                    Text("收件箱").tag("inbox")
                    Text("已发送").tag("sent")
                }
                .pickerStyle(.segmented).disabled(!canRead)
                Hint(text: "短信属于私密内容，仅在前台连接中读取。离开前台或断开后会清空本机页面，不常驻监听通知。", icon: "hand.raised")
                if model.isDemo {
                    Hint(text: "当前短信为虚构示例，发送和删除均已禁用。", icon: "sparkles")
                }
            }
            if !model.isConnected && !model.isDemo {
                ContentUnavailableView("先连接你的 F50", systemImage: "lock.bubble", description: Text("前往「设备」主动连接后，再读取短信。"))
            } else if !model.supportsSMS && !model.isDemo {
                ContentUnavailableView("短信读取不可用", systemImage: "bubble.left.and.exclamationmark.bubble.right", description: Text("设备未声明支持安全的短信列表读取，或当前能力不可用。"))
            } else if model.messages.isEmpty {
                Surface(title: "还没有可显示的短信", icon: "tray") {
                    Text("点击读取，获取当前短信箱。空列表不代表设备一定没有短信。")
                        .foregroundStyle(.secondary)
                    Button("读取\(model.smsBox == "sent" ? "已发送" : "收件箱")") { model.loadMessages(box: model.smsBox) }
                        .buttonStyle(.borderedProminent).disabled(!canRead)
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(model.messages) { message in
                        Button { selectedMessageID = message.id } label: { MessageRow(message: message) }
                            .buttonStyle(.plain)
                    }
                }
                if model.smsNextCursor != nil {
                    Button { model.loadMessages(box: model.smsBox, more: true) } label: {
                        Label("加载更多", systemImage: "ellipsis.bubble")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large).disabled(!canRead)
                } else {
                    Text("已到本次列表末尾").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("短信")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.loadMessages(box: model.smsBox) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新短信").disabled(!canRead)
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("撰写短信").disabled(!canSend)
            }
        }
        .navigationDestination(item: $selectedMessageID) { id in
            if let message = model.messages.first(where: { $0.id == id }) {
                MessageDetailView(message: message)
            } else {
                ContentUnavailableView("内容已清除", systemImage: "lock.shield", description: Text("请重新读取短信列表。"))
            }
        }
        .sheet(isPresented: $composing, onDismiss: preparePendingSend) {
            ComposeMessageView { to, body in
                pendingSend = (to, body)
                composing = false
            }
        }
        .onChange(of: model.isConnected) { _, connected in if !connected { clearPrivateUI() } }
        .onChange(of: model.isDemo) { _, _ in clearPrivateUI() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clearPrivateUI() } }
    }

    private func clearPrivateUI() {
        pendingSend = nil
        composing = false
        selectedMessageID = nil
    }

    private func preparePendingSend() {
        guard let pending = pendingSend else { return }
        pendingSend = nil
        guard canSend, scenePhase == .active else { return }
        model.prepareSend(to: pending.to, body: pending.body)
    }
}

private struct MessageRow: View {
    let message: SMSMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.peer).font(.headline)
                Spacer(minLength: 10)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            Text(message.body).font(.subheadline).lineLimit(3).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            Text(message.date?.formatted(date: .abbreviated, time: .shortened) ?? "时间未知")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(F50Style.surface, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开完整短信")
    }
}

@MainActor
private struct MessageDetailView: View {
    @EnvironmentObject private var model: AppModel
    let message: SMSMessage
    var body: some View {
        PageContent {
            Surface(title: message.box == "sent" ? "发送给" : "来自", icon: "person.crop.circle") {
                Text(message.peer).font(.title2.weight(.semibold)).textSelection(.enabled)
                InfoRow(title: "时间", value: message.date?.formatted(date: .abbreviated, time: .standard) ?? "未知")
                InfoRow(title: "设备记录状态", value: message.status)
            }
            Surface(title: "完整内容", icon: "text.bubble") {
                Text(message.body).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Hint(text: "显示设备短信池保存的完整内容。设备接收时已丢失的格式无法恢复；已发送记录不等同于对方已收到。")
            Button(role: .destructive) { model.prepareDelete(message) } label: {
                Label("准备删除这条短信", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(model.isBusy || model.isDemo || !model.isConnected || !model.supportsDelete)
            Hint(text: "删除前会展示设备摘要并再次确认，仅删除设备短信池中的这条记录。")
        }
        .navigationTitle("短信详情").navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
    }
}

@MainActor
private struct ComposeMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var recipient = ""
    @State private var message = ""
    @State private var previewing = false
    var prepare: (String, String) -> Void
    private var validation: SMSDraftValidation { SMSDraftValidation(to: recipient, body: message) }

    var body: some View {
        NavigationStack {
            PageContent {
                if previewing {
                    Surface(title: "核对发送内容", icon: "text.bubble") {
                        InfoRow(title: "收件人", value: recipient)
                        Divider()
                        Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text(validation.countDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Hint(text: "下一步仅向设备准备发送请求。你仍需核对服务端摘要并确认，才会真正提交。")
                    Button("下一步：准备发送") { prepare(recipient, message) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(validation.error != nil)
                    Button("返回编辑") { previewing = false }.buttonStyle(.bordered)
                } else {
                    Surface(title: "收件人", icon: "person.crop.circle") {
                        TextField("手机号码，可带 +", text: $recipient)
                            .keyboardType(.phonePad).textContentType(.telephoneNumber)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("收件人号码")
                        Hint(text: "可选 + 号，后接 3–20 位数字。")
                    }
                    Surface(title: "短信内容", icon: "square.and.pencil") {
                        TextEditor(text: $message).frame(minHeight: 190)
                            .scrollContentBackground(.hidden).accessibilityLabel("短信正文")
                        Text(validation.countDescription).font(.caption).foregroundStyle(.secondary)
                        if let error = validation.error, !recipient.isEmpty || !message.isEmpty {
                            Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    Hint(text: "仅支持单条短信：GSM 7-bit 最多 160 septets（扩展字符计 2）；其他 BMP 字符最多 70 个 UTF-16 单元。不支持 emoji、非 BMP 字符、非法控制字符或末尾换行。最终由设备校验。")
                    Button("预览短信") { previewing = true }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(validation.error != nil)
                }
                Hint(text: "提交不代表送达。超时或结果未知时，不会自动重发；请先检查设备短信记录。", icon: "exclamationmark.shield")
            }
            .navigationTitle("撰写短信").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { clear(); dismiss() } } }
        }
        .privacySensitive()
        .onDisappear(perform: clear)
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear(); dismiss() } }
    }
    private func clear() { recipient = ""; message = ""; previewing = false }
}

// This is UI validation only. The device remains authoritative.
private struct SMSDraftValidation {
    let error: String?
    let countDescription: String

    init(to: String, body: String) {
        let basic = SMSValidation.gsm
        let extended = SMSValidation.extended
        let scalars = Array(body.unicodeScalars)
        let isGSM = scalars.allSatisfy { basic.contains($0) || extended.contains($0) }
        let count = isGSM ? scalars.reduce(0) { $0 + (extended.contains($1) ? 2 : 1) } : body.utf16.count
        countDescription = isGSM ? "GSM 7-bit · \(count) / 160 septets · 单条" : "BMP UCS-2 · \(count) / 70 单元 · 单条"
        if to.range(of: "^\\+?[0-9]{3,20}$", options: .regularExpression) == nil {
            error = "请输入有效的收件人号码。"
        } else {
            do {
                _ = try SMSValidation.body(body)
                error = nil
            } catch let validationError {
                error = validationError.localizedDescription
            }
        }
    }
}
