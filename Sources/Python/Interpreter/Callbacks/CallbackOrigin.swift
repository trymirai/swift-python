//
//  Created by Anton Spivak
//

enum CallbackOrigin {
    @TaskLocal
    static var current: [ObjectIdentifier] = []
}
