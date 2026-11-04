import SwiftUI
import SwiftData

@main
struct PhoneAppApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .modelContainer(for: MeetingRecord.self)
        }
    }
}
