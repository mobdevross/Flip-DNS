import AppKit
import DNSCore
import FlipAutomation

@main
enum DNSSwitchApp {
    @MainActor
    static func main() {
        let invocation: CLIInvocation
        do {
            invocation = try CLIInvocation.parse(Array(CommandLine.arguments.dropFirst()),
                                                 executableName: URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent)
        } catch {
            finish(ControlResponse(error: error as? ControlFailure ?? ControlFailure("invalid_arguments", error.localizedDescription)))
        }
        switch invocation {
        case .help:
            print(CLIInvocation.helpText)
            return
        case let .control(request):
            do { finish(try ControlClient.send(request)) }
            catch {
                finish(ControlResponse(requestID: request.requestID,
                                       error: error as? ControlFailure ?? ControlFailure("connection_failed", error.localizedDescription)))
            }
        case .diagnose:
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
        case .gui:
            break
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func finish(_ response: ControlResponse) -> Never {
        do {
            FileHandle.standardOutput.write(try response.encoded(pretty: true) + Data([10]))
        } catch {
            print("{\"version\":1,\"ok\":false,\"error\":{\"code\":\"encoding_failed\",\"message\":\"Could not encode the result.\"}}")
            exit(1)
        }
        exit(response.ok ? 0 : 1)
    }
}
