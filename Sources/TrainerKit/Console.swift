import Foundation

public enum Console {
    public static let bold = "\u{001B}[1m"
    public static let reset = "\u{001B}[0m"
    public static let red = "\u{001B}[31m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let dim = "\u{001B}[2m"

    public static func heading(_ text: String) {
        print("\n\(bold)\(text)\(reset)")
        print(String(repeating: "─", count: max(text.count, 40)))
    }

    public static func ms(_ value: Double, _ digits: Int = 2) -> String {
        value.isNaN ? "n/a" : String(format: "%.\(digits)f ms", value)
    }

    public static func verdict(_ pass: Bool) -> String {
        pass ? "\(green)PASS\(reset)" : "\(red)FAIL\(reset)"
    }

    public static func warn(_ text: String) { print("\(yellow)Warning:\(reset) \(text)") }
    public static func error(_ text: String) { print("\(red)\(text)\(reset)") }

    public static func prompt(_ text: String) {
        print("\n\(text)")
        print("Press return when ready... ", terminator: "")
        _ = readLine()
    }

    public static func readDouble(_ question: String, default fallback: Double) -> Double {
        print("\(question) [\(String(format: "%g", fallback))]: ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty,
              let value = Double(line) else { return fallback }
        return value
    }

    /// A 1–5 rating, or nil if skipped.
    public static func readRating(_ question: String) -> Int? {
        print("\(question) [1-5, enter to skip]: ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty,
              let value = Int(line), (1...5).contains(value) else { return nil }
        return value
    }

    public static func confirm(_ question: String) -> Bool {
        print("\(question) [y/N]: ", terminator: "")
        let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return line == "y" || line == "yes"
    }
}
