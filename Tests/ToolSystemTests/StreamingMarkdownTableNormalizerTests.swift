import Testing
@testable import MLXCoder

struct StreamingMarkdownTableNormalizerTests {
    private mutating func normalize(chunks: [String]) -> String {
        var normalizer = StreamingMarkdownTableNormalizer()
        var output = ""
        for chunk in chunks {
            output += normalizer.consume(chunk)
        }
        output += normalizer.finish()
        return output
    }

    private func lines(in output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test
    mutating func convertsMarkdownTableWithAlignmentSeparators() {
        let output = normalize(chunks: [
            "Before\n",
            "| left | right | center |\n",
            "| :--- | ---: | :---: |\n",
            "| L1 | R1 | C1 |\n",
            "After\n",
        ])

        #expect(output.contains("Before"))
        #expect(output.contains("After"))
        #expect(output.contains("+") && output.contains("| left |"))
        #expect(output.contains("left"))
        #expect(output.contains("right"))
        #expect(output.contains("center"))
        #expect(output.contains("L1"))
        #expect(output.contains("R1"))
        #expect(output.contains("C1"))
        #expect(!output.contains("| :--- | ---: | :---: |"))
    }

    @Test
    mutating func handlesChunkBoundarySplitsAcrossTableLines() {
        let output = normalize(chunks: [
            "Start\n| c",
            "ol1 | col2 |\n| ---",
            " | --- |\n| a",
            "bc | def |\nEn",
            "d\n",
        ])

        #expect(output.contains("Start"))
        #expect(output.contains("End"))
        #expect(output.contains("col1"))
        #expect(output.contains("col2"))
        #expect(output.contains("abc"))
        #expect(output.contains("def"))
        #expect(output.contains("| col1 | col2 |"))
    }

    @Test
    mutating func transitionsIntoAndOutOfMultipleTableBlocksWithoutLineLoss() {
        let output = normalize(chunks: [
            "Intro\n",
            "| h1 | h2 |\n| --- | --- |\n| 1 | 2 |\n",
            "Between\n",
            "| x | y |\n| --- | --- |\n| 3 | 4 |\n",
            "Outro\n",
        ])

        let lineSet = lines(in: output)
        #expect(lineSet.filter { $0 == "Intro" }.count == 1)
        #expect(lineSet.filter { $0 == "Between" }.count == 1)
        #expect(lineSet.filter { $0 == "Outro" }.count == 1)
        #expect(output.filter { $0 == "+" }.count >= 4)
        #expect(output.contains("h1") && output.contains("h2"))
        #expect(output.contains("x") && output.contains("y"))
    }

    @Test
    mutating func keepsPlainMarkdownTextUnchanged() {
        let input = """
        ## Title
        Regular paragraph with **bold** text.
        - item one
        - item two
        """
        let output = normalize(chunks: [input])

        #expect(output == input + "\n")
        #expect(!output.contains("| Title |"))
    }

    @Test
    mutating func supportsTablesWithoutOuterPipes() {
        let output = normalize(chunks: [
            "A | B\n",
            "--- | ---\n",
            "1 | 2\n",
        ])

        #expect(output.contains("| A | B |"))
        #expect(output.contains("| 1 | 2 |"))
    }

    @Test
    mutating func doesNotConvertTableLikeTextInsideFences() {
        let output = normalize(chunks: [
            "```md\n",
            "| a | b |\n",
            "| --- | --- |\n",
            "| 1 | 2 |\n",
            "```\n",
        ])

        #expect(output.contains("| a | b |"))
        #expect(output.contains("| --- | --- |"))
        #expect(!output.contains("+---"))
    }
}
