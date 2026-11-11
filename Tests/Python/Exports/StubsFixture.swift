//
//  Created by Anton Spivak
//

import Python

// MARK: - StubRoot

@PythonExportedModule("stub_fixture", documentation: "Fixture modules.")
enum StubRoot {}

// MARK: - StubRecords

@PythonExportedModule("stub_fixture.records", documentation: "Records and functions.", source: #"""
"""Source records and functions."""
raise RuntimeError("Generating stubs must never execute module source")

current = Record(1)
current_value = current.value
unknown = application_code()

def greeting(prefix: str = "hello") -> str:
    """Return a greeting.

    Keep the description, but never copy the implementation.
    """
    return application_code(prefix)

class Report:
    """A source-defined report."""
    title: str

    def read(self, *, fresh: bool = False) -> str:
        return application_code()

del _discarded
"""#)
enum StubRecords {
    @PythonFunction(documentation: "Return records with their exported type.")
    static func list(_ context: Python::Context, limit: Int = 10) -> [StubRecord?] {
        []
    }

    @PythonFunction
    static func property() -> Int {
        0
    }

    @PythonFunction(documentation: "A default may precede a required Swift argument.")
    static func unusual(optional: Int = 7, required: String) -> String {
        required
    }

    @PythonFunction("_discarded")
    static func discarded() {}
}

// MARK: - StubRecord

@PythonExportedClass("Record", module: StubRecords.self, documentation: "A fixture record.")
class StubRecord {
    @PythonProperty(documentation: "A mutable value.")
    var value: Int

    @PythonProperty("display_name", documentation: #"A name containing "quotes" and a \ path."#)
    let displayName: String = "Record"

    @PythonInit(documentation: "Create a record.")
    init(_ value: Int = 0) throws {
        try $value(value)
    }
}

// MARK: - StubChildModule

@PythonExportedModule("stub_child")
enum StubChildModule {}

// MARK: - StubChild

@PythonExportedClass("Child", module: StubChildModule.self)
final class StubChild: StubRecord {}

// MARK: - InvalidStubModule

@PythonExportedModule("../invalid")
enum InvalidStubModule {}
