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

    /// Substitution cases run against a fixed dictionary, never the user's own.
    private static let dictionaryCases: [(input: String, expected: String, note: String)] = [
        ("can you check pager duty", "Can you check PagerDuty.", "two words joined and cased"),
        ("Pager Duty is down", "PagerDuty is down.", "matches regardless of case"),
        ("ask justin about it", "Ask Justyn about it.", "homophone name"),
        ("um justin owns pager duty", "Justyn owns PagerDuty.", "filler and two terms together"),
        ("run npm install", "Run npm install.", "lowercase term stays lowercase"),
        ("npm is the tool", "npm is the tool.", "not capitalised at sentence start"),
        ("the pagerduty runbook", "The PagerDuty runbook.", "single-word variant"),
        ("justins laptop", "Justins laptop.", "no match inside a longer word"),
        ("injustice is unrelated", "Injustice is unrelated.", "no match mid-word"),
        ("pager duty pro is better", "PagerDuty Pro is better.", "longest term wins"),
        ("we use c++ here", "We use C++ here.", "term with punctuation"),
    ]

    private static let testDictionary = UserDictionary(entries: [
        "pager duty": "PagerDuty",
        "pagerduty": "PagerDuty",
        "pager duty pro": "PagerDuty Pro",
        "justin": "Justyn",
        "npm": "npm",
        "c++": "C++",
    ])

    static func run() -> Int32 {
        var failures = 0
        for testCase in cases {
            let actual = RuleCleaner.clean(testCase.input, dictionary: nil)
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
        for testCase in dictionaryCases {
            let actual = RuleCleaner.clean(testCase.input, dictionary: testDictionary)
            let ok = actual == testCase.expected
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  dict: \(testCase.note)")
            if !ok {
                print("      in:       \"\(testCase.input)\"")
                print("      expected: \"\(testCase.expected)\"")
                print("      actual:   \"\(actual)\"")
            }
        }

        let total = cases.count + dictionaryCases.count
        print("\n\(total - failures)/\(total) passed")
        return failures == 0 ? 0 : 1
    }
}
