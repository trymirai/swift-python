//
//  Created by Anton Spivak
//

extension String {
    // This subset is shared by generated C literals and Python's sysconfig dictionary.
    var quotedSourceLiteral: String {
        var result = "\""
        for scalar in unicodeScalars {
            switch scalar.value {
            case 92:
                result += "\\\\"
            case 34:
                result += "\\\""
            case 10:
                result += "\\n"
            case 13:
                result += "\\r"
            case 9:
                result += "\\t"
            case 0:
                result += "\\000"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
