import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                statusArea
                TabView(selection: $tab) {
                    NavigationStack { DashboardView(openDevices: { tab = 2 }) }
                        .tabItem { Label("概览", systemImage: "square.grid.2x2") }.tag(0)
                    NavigationStack { MessagesView() }
                        .tabItem { Label("短信", systemImage: "bubble.left.and.bubble.right") }.tag(1)
                    NavigationStack { DeviceView() }
                        .tabItem { Label("设备", systemImage: "wifi.router") }.tag(2)
                }
            }
            // Cover private messages in the app switcher as well as clearing them in AppModel.
            if scenePhase != .active {
                F50Style.canvas.ignoresSafeArea()
                Label("F50 · 隐私保护", systemImage: "lock.shield")
                    .font(.title2.weight(.semibold)).foregroundStyle(F50Style.accent)
            }
        }
        .tint(F50Style.accent)
        .sheet(item: Binding(get: { model.preparedAction }, set: { value in
            if value == nil { model.cancelPrepared() }
        })) { action in
            PreparedActionView(action: action).environmentObject(model)
        }
    }

    private var statusArea: some View {
        VStack(spacing: 0) {
            if model.isDemo {
                HStack(alignment: .center) {
                    Label("演示数据 · 不连接真实设备", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("退出") { model.leaveDemo() }.font(.caption.weight(.bold))
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color.orange.opacity(0.17))
            }
            if model.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在处理，请勿重复操作…").font(.caption)
                    Spacer()
                }.padding(.horizontal, 20).padding(.vertical, 8).background(.thinMaterial)
                .accessibilityElement(children: .combine)
            }
            if let error = model.errorMessage {
                feedback(error, icon: "exclamationmark.triangle.fill", isError: true)
            } else if let notice = model.notice {
                feedback(notice, icon: "info.circle.fill", isError: false)
            }
        }
    }

    private func feedback(_ message: String, icon: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(isError ? Color.orange : F50Style.accent)
            Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                if isError { model.errorMessage = nil } else { model.notice = nil }
            } label: { Image(systemName: "xmark.circle.fill").padding(5) }
                .accessibilityLabel("关闭提示")
        }
        .padding(12).background(F50Style.surface)
        .accessibilityElement(children: .contain)
    }
}

@MainActor
struct PreparedActionView: View {
    @EnvironmentObject private var model: AppModel
    let action: PreparedAction
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            PageContent {
                Surface(title: "请核对设备给出的操作摘要", icon: "checkmark.shield") {
                    Text("以下为服务端原文，请确认对象及影响后继续。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(action.summary).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    InfoRow(title: "操作", value: action.kind)
                    InfoRow(title: "风险等级（设备报告）", value: action.risk)
                    InfoRow(title: "确认截止", value: action.expiresAt.formatted(date: .omitted, time: .standard))
                }
                Hint(text: "确认只提交这一次操作。超时或结果未知不代表成功，也不会自动重试；请重新连接并读取设备状态。", icon: "exclamationmark.shield")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let expired = action.isExpired
                    VStack(spacing: 14) {
                        if expired { Text("确认已过期，请取消并重新准备。").foregroundStyle(.orange) }
                        Button(expired ? "操作已过期" : "确认执行一次") { model.commitPrepared() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(expired || model.isBusy || model.isDemo || !model.isConnected)
                        Button("取消，不执行", role: .cancel) { model.cancelPrepared() }
                            .disabled(model.isBusy)
                    }.frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("操作确认").navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isBusy)
        }
        .privacySensitive()
        .overlay {
            if scenePhase != .active { F50Style.canvas.ignoresSafeArea() }
        }
    }
}

#Preview {
    RootView().environmentObject(AppModel())
}
