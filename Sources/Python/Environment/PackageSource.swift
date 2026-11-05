//
//  Created by Anton Spivak
//

/// An immutable source of application-wide Python packages.
public enum PackageSource: Sendable {
    /// An existing site-packages directory, including distribution metadata.
    case directory(String)

    /// A prepared site-packages ZIP, for example in application resources.
    case archive(String)

    /// A ZIP of an installed site-packages tree, including resources and metadata.
    /// SwiftPM's embedInCode resource rule can supply these bytes.
    case embedded([UInt8])
}
