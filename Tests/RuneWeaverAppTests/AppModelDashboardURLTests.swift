// Rune Weaver App Tests — Dashboard URL resolution and availability tests.

import Foundation
@testable import RuneWeaverApp
import RuneWeaverCore
import RuneWeaverServer
import Testing

@Suite("AppModel dashboardURL resolution")
@MainActor
struct AppModelDashboardURLTests {
    @Test
    func `dashboardURL resolves standard loopback binds`() {
        let model = AppModel()
        model.hostname = "127.0.0.1"
        model.port = 8080

        let url = model.dashboardURL()
        #expect(url != nil)
        #expect(url?.absoluteString == "http://127.0.0.1:8080/")
    }

    @Test
    func `dashboardURL resolves all-interfaces wildcards to loopback`() {
        let model = AppModel()
        model.port = 8082

        // 0.0.0.0
        model.hostname = "0.0.0.0"
        #expect(model.dashboardURL()?.absoluteString == "http://127.0.0.1:8082/")

        // :: (IPv6 unspecified)
        model.hostname = "::"
        #expect(model.dashboardURL()?.absoluteString == "http://127.0.0.1:8082/")

        // [::] (bracketed IPv6 unspecified)
        model.hostname = "[::]"
        #expect(model.dashboardURL()?.absoluteString == "http://127.0.0.1:8082/")

        // * (wildcard)
        model.hostname = "*"
        #expect(model.dashboardURL()?.absoluteString == "http://127.0.0.1:8082/")
    }

    @Test
    func `dashboardURL preserves LAN IPs and custom hostnames`() {
        let model = AppModel()
        model.port = 8082

        model.hostname = "10.100.40.90"
        #expect(model.dashboardURL()?.absoluteString == "http://10.100.40.90:8082/")

        model.hostname = "my-host.local"
        #expect(model.dashboardURL()?.absoluteString == "http://my-host.local:8082/")
    }

    @Test
    func `dashboardURL constructs fragments and query items correctly`() {
        let model = AppModel()
        model.hostname = "0.0.0.0"
        model.port = 8082

        let settingsURL = model.dashboardURL(
            fragment: "settings",
            queryItems: [URLQueryItem(name: "standalone", value: "true")]
        )
        #expect(settingsURL != nil)
        #expect(settingsURL?.absoluteString == "http://127.0.0.1:8082/?standalone=true#settings")

        let chatID = UUID()
        let chatURL = model.dashboardURL(
            fragment: "chat",
            queryItems: [URLQueryItem(name: "session", value: chatID.uuidString)]
        )
        #expect(chatURL != nil)
        #expect(chatURL?.absoluteString == "http://127.0.0.1:8082/?session=\(chatID.uuidString)#chat")
    }

    @Test
    func `isDashboardAvailable reflects server run state`() {
        let model = AppModel()
        // Starts not running and not bound
        #expect(model.isDashboardAvailable == false)

        model.isRunning = true
        // Still false if boundEndpoint is not yet populated
        #expect(model.isDashboardAvailable == false)
    }
}
