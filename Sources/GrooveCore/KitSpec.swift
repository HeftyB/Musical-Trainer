import Foundation

/// What a kit is made of, as numbers a style can carry.
///
/// **A Motown snare is tuned high and damped; a rock snare is fatter and rings** — §7.30 item 2, and
/// the difference is the same synthesis with different constants rather than different code. Until
/// now those constants were literals inside `DrumSynth`, which meant every style in the library
/// played the same drum kit and a genre name could only ever be a claim about the *steps*.
///
/// That is what §7.33 found by ear: four styles that came out sounding like *"beat #3 rather than
/// oh, a Motown beat"*, and three of the four renamed because the name promised what the kit could
/// not deliver. Steps alone do not make a genre.
///
/// ### Every field is a multiplier, and 1 is what already shipped
///
/// **`standard` reproduces the current kit sample for sample**, which is not a nicety: the fixed
/// backing that 104 takes were played over has to keep its exact sound, and `KitGroup` would
/// otherwise see a new kit and split the corpus (§7.62). Multipliers rather than absolute values are
/// what make that free — 1 everywhere is the identity, so the default costs nothing to prove.
///
/// It also keeps the numbers readable as *intent*. `snareDecay: 0.7` says "damped" to anyone, where
/// an absolute 42 ms says it only to whoever remembers what the default was.
///
/// ### Where it lives
///
/// Here rather than in `TrainerKit`, because `Style` carries one and `GrooveCore` may not depend on
/// the module that does the synthesis (R1.1.3). A parameter set is data; the synthesis that reads it
/// is not.
public struct KitSpec: Hashable, Codable {

    /// Named so a readout can say which kit played without printing seven numbers.
    public let name: String

    // MARK: The snare, which is the voice a genre is recognised by

    /// Multiplies both snare partials. Higher is a tighter, more cracking drum.
    public let snareTuning: Double
    /// Multiplies the snare's decay. Below 1 is damped — tape over the head.
    public let snareDecay: Double
    /// Multiplies the snare rattle against the head tone. Above 1 is wires-loose.
    public let snareRattle: Double

    // MARK: The kick

    /// Multiplies the kick's pitch sweep. Higher is a tighter, more clicking drum.
    public let kickTuning: Double
    /// Multiplies the kick's body decay. Below 1 is a dead, muffled front head.
    public let kickDecay: Double

    // MARK: The cymbals

    /// Multiplies hat and ride decay. Below 1 is tight and dry; above is loose and washy.
    public let cymbalDecay: Double

    /// Multiplies how much of the room reaches the mix.
    ///
    /// **A genre parameter as much as any drum's tuning.** A sixties soul record and a modern rock
    /// one differ in the room before they differ in the snare, and putting it here rather than in
    /// `Room` is what lets one style be drier than another instead of the whole app being.
    public let roomAmount: Double

    public init(name: String,
                snareTuning: Double = 1, snareDecay: Double = 1, snareRattle: Double = 1,
                kickTuning: Double = 1, kickDecay: Double = 1,
                cymbalDecay: Double = 1, roomAmount: Double = 1) {
        self.name = name
        self.snareTuning = snareTuning
        self.snareDecay = snareDecay
        self.snareRattle = snareRattle
        self.kickTuning = kickTuning
        self.kickDecay = kickDecay
        self.cymbalDecay = cymbalDecay
        self.roomAmount = roomAmount
    }

    /// The kit as it stands: every take on record, and every style until one is given its own.
    ///
    /// **Bit-identical without a branch, because multiplying by exactly 1 is exact.** IEEE says
    /// `x * 1.0 == x` for every finite `x`, so the synthesis applies these unconditionally and the
    /// standard kit comes out sample for sample as it did — no `isStandard` test to get wrong, and
    /// no path that only the default takes.
    ///
    /// That is a stronger guarantee than `DrumSynth.tilt`'s, which *does* need its early return:
    /// `soft + (1 - soft)` is not exact, but a bare multiply is (§7.63).
    public static let standard = KitSpec(name: "standard")
}
