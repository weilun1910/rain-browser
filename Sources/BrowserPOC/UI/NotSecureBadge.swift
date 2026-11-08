import SwiftUI

/// "Not secure" at the start of the address field when the page came over plain HTTP, like
/// Safari and Chrome. The address field drops the scheme, so without it an HTTP page looks
/// the same as an HTTPS one.
struct NotSecureBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.slash").font(.system(size: 10, weight: .medium))
            Text("Not secure").font(Theme.Font.label)
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("This page came over a connection that isn't encrypted. Don't type passwords or card numbers here.")
        .accessibilityElement(children: .combine)
    }
}
