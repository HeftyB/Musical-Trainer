import Foundation

enum Console {
    static let bold = "\u{001B}[1m"
    static let reset = "\u{001B}[0m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let dim = "\u{001B}[2m"

    static func heading(_ text: String) {
        print("\n\(bold)\(text)\(reset)")
        print(String(repeating: "─", count: max(text.count, 40)))
    }

    static func ms(_ value: Double, _ digits: Int = 2) -> String {
        value.isNaN ? "n/a" : String(format: "%.\(digits)f ms", value)
    }

    static func verdict(_ pass: Bool) -> String {
        pass ? "\(green)PASS\(reset)" : "\(red)FAIL\(reset)"
    }

    static func warn(_ text: String) { print("\(yellow)Warning:\(reset) \(text)") }
    static func error(_ text: String) { print("\(red)\(text)\(reset)") }

    static func prompt(_ text: String) {
        print("\n\(text)")
        print("Press return when ready... ", terminator: "")
        _ = readLine()
    }

    static func readDouble(_ question: String, default fallback: Double) -> Double {
        print("\(question) [\(String(format: "%g", fallback))]: ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty,
              let value = Double(line) else { return fallback }
        return value
    }

    static func confirm(_ question: String) -> Bool {
        print("\(question) [y/N]: ", terminator: "")
        let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return line == "y" || line == "yes"
    }
}
