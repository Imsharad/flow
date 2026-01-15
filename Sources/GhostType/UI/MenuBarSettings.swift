import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager

    var body: some View {
        SettingsView(manager: manager)
    }
}
