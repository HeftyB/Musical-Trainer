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

    public init(isProbe: Bool = false) { self.isProbe = isProbe }

    /// Split `arguments` into flags and the positional arguments that remain.
    ///
    /// - Throws: `SpikeError` naming the offending flag, and what is accepted.
    public static func parse(_ arguments: [String]) throws -> (flags: CommandFlags,
                                                               positional: [String]) {
        var flags = CommandFlags()
        var positional: [String] = []

        for argument in arguments {
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                continue
            }
            switch argument {
            case "--probe":
                flags.isProbe = true
            default:
                throw SpikeError("Unknown flag \(argument). Accepted: --probe (record this take "
                               + "as a deliberate look at a setting you have not earned, which "
                               + "the planner then ignores).")
            }
        }
        return (flags, positional)
    }
}
