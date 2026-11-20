import Testing
@testable import Fir

/// The answer's lines come from a model that read untrusted pages, and arrive cut off mid-line while streaming.
@Suite struct IntelligenceAnswerTests {
    @Test func readsTheFormat() {
        let answer = IntelligenceAnswer(parsing: """
            # Spring and autumn are best
            Go in **March to May** or October [1].
            ## 🌸 Spring
            - Cherry blossoms peak in early April [2].
            * Crowds are large [1].
            ## ☕️ Autumn
            1. Leaves turn in November [3].
            """)
        #expect(answer.headline == "Spring and autumn are best")
        #expect(answer.summary == "Go in March to May or October [1].")
        #expect(answer.sections.count == 2)
        #expect(answer.sections[0].emoji == "🌸")
        #expect(answer.sections[0].title == "Spring")
        #expect(answer.sections[0].points == ["Cherry blossoms peak in early April [2].", "Crowds are large [1]."])
        #expect(answer.sections[1].emoji == "☕️")
        #expect(answer.sections[1].points == ["Leaves turn in November [3]."])
    }

    @Test func readsAPartialLine() {
        let answer = IntelligenceAnswer(parsing: "# Spring\nGo in March.\n## ")
        #expect(answer.headline == "Spring")
        #expect(answer.sections.count == 1)
        #expect(answer.sections[0].title == nil)
        #expect(IntelligenceAnswer(parsing: "#").headline == nil)
        #expect(IntelligenceAnswer(parsing: "# A\n-").sections.first?.points == [])
    }

    @Test func readsHeadingsWrittenOtherwise() {
        let answer = IntelligenceAnswer(parsing: "# Strong coffee\n## Moka pot\n- Fill it [2].\n# 🛠 French press\n- Steep it [3].")
        #expect(answer.headline == "Strong coffee")
        #expect(answer.sections.map(\.title) == ["Moka pot", "French press"])
        #expect(answer.sections[1].emoji == "🛠")
        #expect(answer.sections[1].points == ["Steep it [3]."])
    }

    @Test func keepsTextThatOnlyLooksLikeMarkup() {
        let answer = IntelligenceAnswer(parsing: "# Moka pot\n#1 pick is the moka pot [2].\n## ☕ Why\n✅ It is cheap [1].")
        #expect(answer.summary == "#1 pick is the moka pot [2].")
        #expect(answer.sections.count == 1)
        #expect(answer.sections[0].points == ["✅ It is cheap [1]."])
    }

    @Test func keepsDigitsAndLooseText() {
        let answer = IntelligenceAnswer(parsing: "Just text first.\nMore of it.\n## 3 ways to brew\nA line without a marker")
        #expect(answer.headline == nil)
        #expect(answer.summary == "Just text first. More of it.")
        #expect(answer.sections[0].emoji == nil)
        #expect(answer.sections[0].title == "3 ways to brew")
        #expect(answer.sections[0].points == ["A line without a marker"])
    }
}
