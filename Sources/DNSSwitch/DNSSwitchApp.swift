import AppKit
import DNSCore

@main
enum DNSSwitchApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            do {
                let services = try SystemDNSBackend().diagnose()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(services)
                print(String(decoding: data, as: UTF8.self))
            } catch {
                FileHandle.standardError.write(Data("Flip: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
