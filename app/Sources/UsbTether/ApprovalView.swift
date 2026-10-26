import SwiftUI
import UsbTetherCore

/// Asks about exactly one pending phone; both buttons act on that same value.
struct ApprovalView: View {
    let phone: PendingPhone
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approve \(phone.name) (\(Presentation.vidPid(vid: phone.vid, pid: phone.pid)))?")
                .font(.headline)
            if let serial = Presentation.displaySerial(phone.serial) {
                Text("Serial: \(serial)")
                    .font(.callout)
            }
            if let note = Presentation.weakIdNote(for: phone) {
                Text(note)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Approve") { Task { await model.approve(phone) } }
                    .accessibilityIdentifier("approveButton")
                Button("Not now") { Task { await model.decline(phone) } }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("declineButton")
            }
            .disabled(model.busy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }
}
