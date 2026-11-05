//
//  Created by Anton Spivak
//

import ArgumentParser
import Logging

// MARK: - Logger.Level + @retroactive ExpressibleByArgument

extension Logger.Level: @retroactive ExpressibleByArgument {}
