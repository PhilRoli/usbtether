import SwiftUI
import UsbTetherCore

struct PreferencesView: View {
    @ObservedObject var model: AppModel

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
        }
        .padding(16)
        .frame(width: 420)
        .task {
            // Tied to the view's lifetime: cancelled when the window goes away.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @ViewBuilder private var approvedList: some View {
        let approved = model.status?.approved ?? []
        if approved.isEmpty {
            Text("No approved phones yet. Plug in a phone and turn on USB tethering.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
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
                .accessibilityIdentifier("removeButton-" + ids.replacingOccurrences(of: ":", with: "-"))
        }
    }
}
