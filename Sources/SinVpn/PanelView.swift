import SwiftUI
import SinVpnCore

/// Выпадающая панель: блок переключателей VPN, блок статистики и нижние строки.
struct PanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @State private var settingsOpen = false
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
        .frame(width: 340)
        .onAppear { model.panelOpen = true }
        .onDisappear {
            model.panelOpen = false
            settingsOpen = false
            confirmReset = false
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    // MARK: - Блок 1: переключатели

    @ViewBuilder private var vpnBlock: some View {
        if !model.loaded {
            ProgressView().controlSize(.small)
        } else if model.loadFailed {
            VStack(alignment: .leading, spacing: 8) {
                Text("Не удалось прочитать список VPN")
                Text("Система не вернула список подключений. Управлять VPN можно в «Системных настройках».")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Открыть настройки VPN") { model.openVPNSettings() }
            }
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
        return Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                head("Сессия")
                head("Сегодня")
                head("30 дней")
            }
            GridRow {
                label("Время")
                value(session.map { DurationFormat.clock(Int($0.seconds.rounded())) }, primary: true)
                value(DurationFormat.short(Int(today.seconds)))
                value(DurationFormat.short(Int(month.seconds)))
            }
            GridRow {
                label("Принято")
                value(session.map { ByteFormat.string($0.rx) }, primary: true)
                value(ByteFormat.string(today.rx))
                value(ByteFormat.string(month.rx))
            }
            GridRow {
                label("Отправлено")
                value(session.map { ByteFormat.string($0.tx) }, primary: true)
                value(ByteFormat.string(today.tx))
                value(ByteFormat.string(month.tx))
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func head(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Подпись строки никогда не обрезается: ширину уступают колонки значений.
    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// Колонка текущей сессии выделена, итоги за периоды — обычным начертанием.
    private func value(_ text: String?, primary: Bool = false) -> some View {
        Text(text ?? "—")
            .fontWeight(primary ? .semibold : .regular)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Нижние строки

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Новая версия или идущая установка видны всегда, без раскрытия настроек.
            if updater.needsAttention {
                updateRow.padding(.bottom, 4)
            }
            MenuRow(action: { settingsOpen.toggle() }) {
                Text("Настройки")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(settingsOpen ? 90 : 0))
            }
            if settingsOpen {
                settings
                    .padding(.leading, 10)
                    .padding(.vertical, 6)
            }
            MenuRow(action: { model.openVPNSettings() }) {
                Text("Настройки VPN…")
                Spacer(minLength: 0)
            }
            MenuRow(action: { model.quit() }) {
                Text("Выйти")
                Spacer(minLength: 0)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            switchRow("Запускать при входе в систему", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if model.launchNeedsApproval {
                HStack(spacing: 8) {
                    Text("Автозапуск ждёт разрешения в «Объектах входа»")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Открыть") { model.openLoginItemsSettings() }
                        .buttonStyle(.link)
                }
            }
            switchRow("Проверять обновления автоматически", isOn: Binding(
                get: { updater.autoCheck },
                set: { updater.autoCheck = $0 }
            ))
            if !updater.needsAttention {
                updateRow
            }
            if confirmReset {
                HStack(spacing: 8) {
                    Text("Обнулить всю статистику?")
                    Spacer(minLength: 0)
                    Button("Сбросить", role: .destructive) {
                        model.resetStats()
                        confirmReset = false
                    }
                    Button("Отмена") { confirmReset = false }
                }
                .controlSize(.small)
            } else {
                Button("Сбросить статистику…") { confirmReset = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var updateRow: some View {
        HStack(spacing: 8) {
            Text(updater.statusLine)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(updater.isFailed ? Color.red : Color.primary)
                .help(updater.failureDetails ?? "")
            Spacer(minLength: 0)
            if let action = updater.actionTitle {
                Button(action) { updater.primaryAction() }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    private func switchRow(_ text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

/// Строка-кнопка, как в системных меню: подсвечивается при наведении.
private struct MenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { content() }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
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
                    } else if let dot = dotColor {
                        Circle().fill(dot).frame(width: 7, height: 7)
                    }
                    Text(state.title)
                        .font(.subheadline)
                        .foregroundStyle(state == .off ? Color.secondary : Color.primary)
                }
            }
            Spacer(minLength: 0)
            Toggle(service.name, isOn: Binding(get: { state.isOn }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(state == .disconnecting)
        }
    }

    /// Состояние передаёт цветная точка, а текст остаётся контрастным на любом фоне панели.
    private var dotColor: Color? {
        switch state {
        case .on: return .green
        case .failed: return .red
        default: return nil
        }
    }
}
