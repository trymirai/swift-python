//
//  Created by Anton Spivak
//

extension Module {
    struct Class: Sendable {
        let type: any _PClass.Type
        let module: any ModuleHost.Type

        let name: String
        let documentation: String?

        var superclass: (any _PClass.Type)?

        var initializer: Module.Function?
        var methods: [Module.Function] = []
        var properties: [Property] = []

        var key: String {
            String(reflecting: type)
        }

        mutating func validateMembers() throws {
            methods.sort { $0.name < $1.name }
            properties.sort { $0.name < $1.name }

            var members = Set<String>()
            func record(_ name: String) throws {
                guard members.insert(name).inserted else {
                    throw Module.Catalog.failure("Duplicate class member '\(name)'.")
                }
            }

            for method in methods {
                try record(method.name)
            }
            for property in properties {
                try record(property.name)
            }
        }
    }
}
