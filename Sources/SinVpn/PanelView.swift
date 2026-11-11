import SwiftUI
import SinVpnCore

/// Выпадающая панель: блок переключателей VPN, блок статистики и нижняя строка.
struct PanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("VPN")
            vpnBlock
            Divider().padding(.vertical, 9)
            title("Статистика")
            statsBlock
            Divider().padding(.vertical, 9)
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { model.panelOpen = true }
        .onDisappear {
            model.panelOpen = false
            confirmReset = false
        }
    }

    private func title(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    // MARK: - Блок 1: переключатели

    @ViewBuilder private var vpnBlock: some View {
        if !model.loaded {
            ProgressView().controlSize(.small)
        } else if model.services.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("VPN не настроен").foregroundStyle(.secondary)
                Button("Открыть настройки VPN") { model.openVPNSettings() }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(model.services) { service in
                    VPNRow(service: service, state: model.rowState(service)) {
                        model.toggle(service)
                    }
                }
            }
        }
    }

    // MARK: - Блок 2: статистика

    private var statsBlock: some View {
        let session = model.session
        let today = model.today
        let month = model.month
        return VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    head("Сессия")
                    head("Сегодня")
                    head("30 дней")
                }
                GridRow {
                    label("Время")
                    value(session.map { DurationFormat.clock(Int($0.seconds.rounded())) })
                    value(DurationFormat.short(Int(today.seconds)))
                    value(DurationFormat.short(Int(month.seconds)))
                }
                GridRow {
                    label("Принято")
                    value(session.map { ByteFormat.string($0.rx) })
                    value(ByteFormat.string(today.rx))
                    value(ByteFormat.string(month.rx))
                }
                GridRow {
                    label("Отправлено")
                    value(session.map { ByteFormat.string($0.tx) })
                    value(ByteFormat.string(today.tx))
                    value(ByteFormat.string(month.tx))
                }
            }
            .font(.callout)
            .monospacedDigit()

            if confirmReset {
                HStack(spacing: 8) {
                    Text("Обнулить все показатели?").font(.callout)
                    Spacer(minLength: 0)
                    Button("Сбросить", role: .destructive) {
                        model.resetStats()
                        confirmReset = false
                    }
                    Button("Отмена") { confirmReset = false }
                }
                .controlSize(.small)
            } else {
                Button("Сбросить статистику") { confirmReset = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    private func head(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func value(_ text: String?) -> some View {
        Text(text ?? "—")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Нижняя строка

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            switchRow("Запускать при входе в систему", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            switchRow("Проверять обновления автоматически", isOn: Binding(
                get: { updater.autoCheck },
                set: { updater.autoCheck = $0 }
            ))
            HStack(spacing: 8) {
                Text(updater.statusLine)
                    .monospacedDigit()
                    .foregroundStyle(updater.isFailed ? Color.red : Color.secondary)
                    .help(updater.failureDetails ?? "")
                Spacer(minLength: 0)
                if let action = updater.actionTitle {
                    Button(action) { updater.primaryAction() }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
            menuButton("Настройки VPN…") { model.openVPNSettings() }
            menuButton("Выйти") { model.quit() }
        }
    }

    private func switchRow(_ text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private func menuButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct VPNRow: View {
    let service: VPNService
    let state: RowState
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .fontWeight(.medium)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if state.isBusy {
                        ProgressView().controlSize(.mini)
                    }
                    Text(state.title)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            Spacer(minLength: 0)
            Toggle(service.name, isOn: Binding(get: { state.isOn }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(state == .disconnecting)
        }
    }

    private var statusColor: Color {
        switch state {
        case .on: return .accentColor
        case .failed: return .red
        default: return .secondary
        }
    }
}
