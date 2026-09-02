import Foundation

/// Assertions for `RuleCleaner`, run via `Murmur cleantest`.
///
/// The negative cases matter more than the positive ones: the risk in filler
/// stripping is not missing an "um", it is eating a real word that happens to
/// look like one.
enum CleanerTest {

    private static let cases: [(input: String, expected: String, note: String)] = [
        // Vocal noises, including stretched ones.
        ("um can you send that", "Can you send that.", "leading um"),
        ("so uh I think it works", "So I think it works.", "mid-sentence uh"),
        ("uhhhh let me check that", "Let me check that.", "elongated uh"),
        ("errrr no that is wrong", "No that is wrong.", "elongated er"),
        ("aaah I see the problem", "I see the problem.", "elongated ah"),
        ("ooh that is clever", "That is clever.", "ooh"),
        ("hmm maybe we should wait", "Maybe we should wait.", "hmm"),
        ("erm can we reschedule", "Can we reschedule.", "erm"),
        ("ugh this build is slow", "This build is slow.", "ugh"),
        ("mm that works for me", "That works for me.", "mm"),
        ("eh it is fine either way", "It is fine either way.", "eh"),
        ("um, so, uh, ship it", "So, ship it.", "several with commas"),
        ("deploy it uh now", "Deploy it now.", "trailing-ish uh"),

        // Nothing but noise — must yield nothing, not a stray full stop.
        ("um", "", "filler only"),
        ("uh um erm", "", "all filler"),

        // Real words that resemble filler. Removing any of these is a bug.
        ("oh no the tests failed", "Oh no the tests failed.", "oh is a real word"),
        ("so the answer is yes", "So the answer is yes.", "so survives"),
        ("well that explains it", "Well that explains it.", "well survives"),
        ("I like the new design", "I like the new design.", "like survives"),
        ("right lets ship it", "Right lets ship it.", "right survives"),
        ("a moment please", "A moment please.", "single a survives"),
        ("the mm hmm meeting", "The meeting.", "mm hmm stripped, the kept"),
        ("her name is Ah Lam", "Her name is Ah Lam.", "proper noun Ah is kept"),
        ("we met Er Wang today", "We met Er Wang today.", "proper noun Er is kept"),
        ("done. Um, next thing", "Done. Next thing.", "filler after a stop still goes"),
        ("Um can you check", "Can you check.", "filler at the very start still goes"),

        // Formatting.
        ("no full stop here", "No full stop here.", "adds terminal stop"),
        ("already done.", "Already done.", "keeps existing stop"),
        ("what about tuesday?", "What about tuesday?", "keeps question mark"),
    ]

    static func run() -> Int32 {
        var failures = 0
        for testCase in cases {
            let actual = RuleCleaner.clean(testCase.input)
            let ok = actual == testCase.expected
            if !ok { failures += 1 }
            let mark = ok ? "PASS" : "FAIL"
            print("\(mark)  \(testCase.note)")
            if !ok {
                print("      in:       \"\(testCase.input)\"")
                print("      expected: \"\(testCase.expected)\"")
                print("      actual:   \"\(actual)\"")
            }
        }
        print("\n\(cases.count - failures)/\(cases.count) passed")
        return failures == 0 ? 0 : 1
    }
}
