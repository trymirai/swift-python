//
//  Created by Anton Spivak
//

import SystemPackage

extension StandardLibraryBuilder {
    struct Module {
        let name: String

        let path: String
        let source: FilePath

        let isPackage: Bool

        init?(resource: Resource) {
            guard resource.path.hasSuffix(".py") else {
                return nil
            }

            path = resource.path
            source = resource.source

            isPackage = path.hasSuffix("/__init__.py")

            let suffix = isPackage ? "/__init__.py" : ".py"
            name = String(path.dropLast(suffix.count)).replacing("/", with: ".")
        }

        var upstreamSymbol: String {
            "_Py_M__" + name.replacing(".", with: "_")
        }

        var symbol: String {
            upstreamSymbol.replacing("-", with: "_")
        }
    }
}
