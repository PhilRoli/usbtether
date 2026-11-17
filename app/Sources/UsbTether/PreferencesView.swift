import SwiftUI
import UsbTetherCore

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    /// Reports the phone currently shown in the approval prompt (nil if none).
    var onPromptShown: (PendingPhone?) -> Void = { _ in }

    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Presentation.statusLine(model.status))
                .font(.headline)
            if let problem = model.problem {
                Text(problem)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let prompt = model.prompt {
                ApprovalView(phone: prompt, model: model)
            }
            Divider()
            Text("Approved phones")
                .font(.subheadline)
            approvedList
            Text(versionLine)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { onPromptShown(model.prompt) }
        .onChange(of: model.prompt) { onPromptShown($0) }
        .task {
            // Tied to the view's lifetime: cancelled when the window goes away.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var versionLine: String {
        guard let daemon = model.status?.version else { return "App \(Self.appVersion)" }
        return daemon == Self.appVersion
            ? "Version \(Self.appVersion)"
            : "App \(Self.appVersion), daemon \(daemon)"
    }

    @ViewBuilder private var approvedList: some View {
        switch model.status?.approved {
        case nil:
            // Daemon unreachable or the request refused: the list is unknown, not empty.
            Text("Unavailable until usbtetherd answers.")
                .foregroundColor(.secondary)
        case let approved? where approved.isEmpty:
            Text("No approved phones yet. Plug in a phone and turn on USB tethering.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case let approved?:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(approved) { phone in
                    row(phone)
                }
            }
        }
    }

    private func row(_ phone: ApprovedPhone) -> some View {
        let ids = Presentation.vidPid(vid: phone.vid, pid: phone.pid)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.name)
                Text("\(ids), \(Presentation.serialText(phone.serial))")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Approved \(Presentation.approvalDate(phone.approvedAt))")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Remove") { Task { await model.remove(phone) } }
                .disabled(model.busy)
                .accessibilityIdentifier("removeButton-" + ids.replacingOccurrences(of: ":", with: "-"))
        }
    }
}
