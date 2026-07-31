import Foundation

/// The dropout ladder from PLAN.md §6 — the training hidden inside the jam. As the level
/// rises, the band thins from a full kit down to a bare pulse and finally silence, so the
/// player is progressively left to hold time on their own.
public enum DropoutLevel: Int, CaseIterable, Comparable {
    case fullKit = 0        // the actual groove
    case hatsEveryBeat      // hi-hat on every beat
    case backbeat           // hi-hat on 2 and 4 only
    case beatFourOnly       // a single hit on beat 4
    case downbeatSparse     // downbeat of every other bar
    case silence            // nothing — you are alone

    public static func < (lhs: DropoutLevel, rhs: DropoutLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .fullKit:        return "full kit"
        case .hatsEveryBeat:  return "hats on every beat"
        case .backbeat:       return "hats on 2 & 4"
        case .beatFourOnly:   return "beat 4 only"
        case .downbeatSparse: return "downbeat, every other bar"
        case .silence:        return "silence"
        }
    }
}

public enum DropoutLadder {
    /// The pattern that actually plays for a bar at a given dropout level.
    ///
    /// At `fullKit` this is the musical groove untouched. Every thinner level replaces it
    /// with a sparse metronomic reference so the reduction feels like the band stepping
    /// back, not like a different exercise.
    public static func pattern(level: DropoutLevel, bar: Int, groove: Pattern,
                               accentVelocity: Int = 105) -> Pattern {
        let stepsPerBar = groove.stepsPerBar
        let stepsPerBeat = groove.stepsPerBeat
        let beats = stepsPerBar / stepsPerBeat

        func ref(_ steps: [Int], _ voice: DrumVoice = .closedHat) -> Pattern {
            Pattern(stepsPerBar: stepsPerBar, stepsPerBeat: stepsPerBeat,
                    hits: steps.map { Hit(voice: voice, step: $0, velocity: accentVelocity) })
        }

        // Beat b (1-based) begins at this step.
        func beatStep(_ b: Int) -> Int { (b - 1) * stepsPerBeat }

        switch level {
        case .fullKit:
            return groove
        case .hatsEveryBeat:
            return ref((1...beats).map(beatStep))
        case .backbeat:
            return ref([beatStep(2), beatStep(4)].filter { $0 < stepsPerBar })
        case .beatFourOnly:
            return ref([beatStep(4)].filter { $0 < stepsPerBar })
        case .downbeatSparse:
            return bar % 2 == 0 ? ref([beatStep(1)]) : .silence
        case .silence:
            return .silence
        }
    }
}
