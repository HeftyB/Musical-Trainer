import Foundation

/// Command-line flags, separated from the positional arguments before anything parses them.
///
/// **The point is that any drill can be launched at any setting from the shell**, so a level or
/// a rung the player has not earned can be tried for the reading without the planner being
/// taught to propose it. Putting a testing affordance into the planner is putting it into the
/// business logic, where it changes what the app recommends to a player who is not testing
/// anything (§7.26).
///
/// Unknown flags are an error rather than being ignored. A mistyped `--porbe` that silently ran
/// an ordinary take would produce a take recorded as earned — which is precisely the corruption
/// the flag exists to prevent, arriving through a typo.
public struct CommandFlags: Equatable {

    /// Run this take as a probe: a deliberate look at a setting the player has not earned.
    ///
    /// Stored on the take, and everything that decides what to practise next ignores it — the
    /// form level ladder and the interval rung ladder both promote from what is on record.
    public var isProbe = false

    /// Play over a generated backing instead of the fixed one: `--style driving`.
    ///
    /// The name is kept as the player typed it and resolved later, so an unknown style is one
    /// error message naming what the library has rather than a silent fallback to `jamBacking`.
    public var style: String?

    /// The seed that rebuilds a generated backing exactly: `--seed 5eed0001`, hexadecimal.
    ///
    /// Omitted means a fresh piece, and the one that was drawn is printed and stored — so "play
    /// me that again" is answerable after the fact, which is the whole reason the seed exists
    /// (R1.2.2). Reading it back off a take is `review <n>`.
    public var seed: UInt64?

    public init(isProbe: Bool = false, style: String? = nil, seed: UInt64? = nil) {
        self.isProbe = isProbe
        self.style = style
        self.seed = seed
    }

    /// Split `arguments` into flags and the positional arguments that remain.
    ///
    /// - Throws: `SpikeError` naming the offending flag, and what is accepted.
    public static func parse(_ arguments: [String]) throws -> (flags: CommandFlags,
                                                               positional: [String]) {
        var flags = CommandFlags()
        var positional: [String] = []

        // Indexed rather than a `for-in`, because `--style` takes a value. Both spellings are
        // accepted — `--style driving` and `--style=driving` — since a flag that works one way
        // and not the other is a flag people get wrong at four in the morning.
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                continue
            }

            let name: String
            var inlineValue: String?
            if let split = argument.firstIndex(of: "=") {
                name = String(argument[argument.startIndex..<split])
                inlineValue = String(argument[argument.index(after: split)...])
            } else {
                name = argument
            }

            /// The next argument, consumed. A flag whose value is missing must not silently eat
            /// the next *flag* — `--style --probe` is a typo, not a style called `--probe`.
            func value() throws -> String {
                if let inlineValue { return inlineValue }
                guard index < arguments.endIndex, !arguments[index].hasPrefix("--") else {
                    throw SpikeError("\(name) needs a value, as \(name) <value>.")
                }
                let next = arguments[index]
                index += 1
                return next
            }

            switch name {
            case "--probe":
                flags.isProbe = true
            case "--style":
                flags.style = try value().lowercased()
            case "--seed":
                let text = try value()
                // Hexadecimal, because that is how `BackingIdentity` writes it into a take and
                // the point of this flag is to type back what a readout printed. Accepting
                // decimal too would make `10` ambiguous between two different pieces of music.
                guard let parsed = UInt64(text.replacingOccurrences(of: "0x", with: ""),
                                          radix: 16) else {
                    throw SpikeError("--seed takes a hexadecimal seed, as it appears on a take: "
                                   + "--seed 000000005eed0001. Got \(text).")
                }
                flags.seed = parsed
            default:
                throw SpikeError("Unknown flag \(argument). Accepted: --probe (record this take "
                               + "as a deliberate look at a setting you have not earned, which "
                               + "the planner then ignores), --style <name> (play over a "
                               + "generated backing), --seed <hex> (rebuild one exactly).")
            }
        }
        return (flags, positional)
    }
}
