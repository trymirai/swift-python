//
//  Created by Anton Spivak
//

import Python
import Testing

@Test
func boundMethodsCanBeCalledImmediatelyOrReused() async throws {
    let session = try await Python::Runtime().session(.source("""
    class Query:
        lookups = 0
        def __getattribute__(self, name):
            if name == "split":
                self.lookups += 1
                return "red blue".split
            return super().__getattribute__(name)

    query = Query()
    """))
    defer { await session.close() }

    try await session.enqueue { py in
        let query = try py.object("query")
        let words: [String] = try query(methodNamed: "split")().decode()
        #expect(words == ["red", "blue"])

        let split = try query(methodNamed: "split")
        let bySpace: [String] = try split(" ").decode()
        let byLetter: [String] = try split("e", 1).decode()
        #expect(bySpace == words)
        #expect(byLetter == ["r", "d blue"])
        #expect(try query.value(forAttribute: "lookups").decode(as: Int.self) == 2)

        try expectPythonFailure(.exception(.attributeError)) {
            _ = try query(methodNamed: "missing")
        }
        let count = try query(methodNamed: "lookups")
        try expectPythonFailure(.exception(.typeError)) { _ = try count() }
    }
}

@Test
func callableObjectsDistinguishAListFromPositionalAndKeywordArguments() async throws {
    let session = try await Python::Runtime().session(.source("""
    def collect(*args, end=0):
        return list(args) + [end]
    """))
    defer { await session.close() }

    try await session.enqueue { py in
        let collect = try py.object("collect")
        let noArguments: [Int] = try collect().decode()
        let positional: [Int] = try collect(1, 2, keywords: [("end", 3)]).decode()
        let prepared: [Int] = try collect(arguments: [1, 2], keywords: [("end", 3)]).decode()
        let named: [Int] = try collect(keywords: [("end", 3)]).decode()
        #expect(noArguments == [0])
        #expect(positional == [1, 2, 3])
        #expect(prepared == positional)
        #expect(named == [3])

        let list = try collect([1, 2])
        #expect(try list.value(at: 0).decode(as: [Int].self) == [1, 2])
        let first = try py.encode(1)
        let second = try py.encode(2)
        #expect(try collect(first, second).decode(as: [Int].self) == [1, 2, 0])
    }
}
