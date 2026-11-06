//
//  Created by Anton Spivak
//

extension Module {
    struct Class: Sendable {
        let type: any _PythonClass.Type
        let module: any ModuleHost.Type

        let name: String
        let documentation: String?

        var superclass: (any _PythonClass.Type)?

        var initializer: Module.Function?

        var methods: [Module.Function] = []
        var properties: [Property] = []

        var key: String {
            String(reflecting: type)
        }

        var functions: [Module.Function] {
            (initializer.map { [$0] } ?? [])
                + methods
                + properties.flatMap { [$0.getter] + ($0.setter.map { [$0] } ?? []) }
        }

        mutating func validateMembers() throws {
            methods.sort { $0.name < $1.name }
            properties.sort { $0.name < $1.name }

            var members = Set<String>()
            for member in methods.map(\.name) + properties.map(\.name) {
                guard members.insert(member).inserted else {
                    throw ExportCatalog.failure("Duplicate class member '\(member)'.")
                }
            }
        }
    }
}
