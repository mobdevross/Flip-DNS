import Foundation

public enum CLIInvocation {
    case gui, diagnose, help
    case control(ControlRequest)

    public static let helpText = """
    Flip — temporary DNS switching for people and assistants

    Usage:
      flip status                  Show DNS mode and timer as JSON
      flip bypass [--minutes N]    Use public DNS for 5, 15, or 60 minutes (default: 15)
      flip restore                 End Flip's active bypass, preserving external DNS edits
      flip --help                  Show this help

    Keep Flip.app running. macOS may ask you to approve DNS changes.
    Commands return JSON and exit 0 on success, 1 on error.
    A timeout may leave a request awaiting approval; check status before retrying.
    """

    public static func parse(_ arguments: [String], executableName: String = "DNSSwitch") throws -> CLIInvocation {
        guard let first = arguments.first else {
            return executableName == "flip" ? .help : .gui
        }
        if first.hasPrefix("-psn_") { return .gui }
        if arguments == ["--help"] || arguments == ["-h"] { return .help }
        if arguments == ["--diagnose"] { return .diagnose }
        if arguments == ["status"] { return .control(ControlRequest(command: .status)) }
        if arguments == ["restore"] { return .control(ControlRequest(command: .restore)) }
        if first == "bypass" {
            let minutes: Int
            if arguments.count == 1 { minutes = 15 }
            else if arguments.count == 3, arguments[1] == "--minutes", let value = Int(arguments[2]) {
                minutes = value
            } else {
                throw ControlFailure("invalid_arguments", "Use flip bypass --minutes 5, 15, or 60.")
            }
            guard [5, 15, 60].contains(minutes) else {
                throw ControlFailure("invalid_duration", "Choose 5, 15, or 60 minutes.")
            }
            return .control(ControlRequest(command: .bypass, minutes: minutes))
        }
        throw ControlFailure("invalid_arguments", "Unknown command. Run flip --help for usage.")
    }
}
