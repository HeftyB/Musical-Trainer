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

    /// Pick one of a numbered list, defaulting to the first on an empty line.
    ///
    /// The default is the first option on purpose: the caller orders the list so that the
    /// unmarked case comes first, and pressing return records it rather than recording nothing.
    public static func readChoice(_ question: String,
                                  options: [(label: String, blurb: String)]) -> Int {
        print("\n\(question)")
        for (i, option) in options.enumerated() {
            let marker = i == 0 ? "(default)" : ""
            let label = option.label.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("  \(i + 1). \(label)\(dim)\(option.blurb) \(marker)\(reset)")
        }
        print("Choose [1-\(options.count), enter for 1]: ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty,
              let value = Int(line), (1...options.count).contains(value) else { return 0 }
        return value - 1
    }

    public static func confirm(_ question: String) -> Bool {
        print("\(question) [y/N]: ", terminator: "")
        let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return line == "y" || line == "yes"
    }
}
