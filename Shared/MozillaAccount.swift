import Foundation

/// How the app and its share extension sign in to the Mozilla account, so both find the same sign-in.
enum MozillaAccount {
    // Firefox for iOS's public OAuth client: Mozilla does not hand out Sync access to third parties.
    // Fine for a personal build, not for distribution.
    static let clientID = "1b1a3e44c54fbb58"
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob:oauth-redirect-webchannel"

    /// "Zen on Alex's MacBook Pro" as "MacBook Pro": the device, without the browser and the owner.
    static func shortDeviceName(_ clientName: String) -> String {
        guard let range = clientName.range(of: " on ", options: .backwards) else { return clientName }
        var device = String(clientName[range.upperBound...])
        if let mac = device.range(of: "MacBook") { device = String(device[mac.lowerBound...]) }
        return device.replacingOccurrences(of: "-", with: " ")
    }
}
