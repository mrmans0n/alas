import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

extension AppConfig.Remote {
    /// The hosts a request may name: loopback, this Mac's interfaces and
    /// names, the configured extras, and the tailnet name when known.
    public func accessPolicy(interfaces: [RemoteNetworkInterface], tailnetDNSName: String?) -> RemoteAccessPolicy {
        RemoteAccessPolicy(allowedHosts: RemoteNetwork.allowedHostCandidates(
            interfaces: interfaces,
            allowedHosts: allowedHosts,
            tailnetDNSName: tailnetDNSName
        ))
    }

    /// The origins a browser request may come from: those of the allowed
    /// hosts, plus the configured extras.
    public func originPolicy(interfaces: [RemoteNetworkInterface], tailnetDNSName: String?) -> RemoteOriginPolicy {
        RemoteOriginPolicy(
            hostPolicy: accessPolicy(interfaces: interfaces, tailnetDNSName: tailnetDNSName),
            allowedOrigins: allowedOrigins
        )
    }

    /// The addresses shown for pairing, best first; none until a port is bound.
    /// `tailnetHTTPSHost` is the tailnet name while `tailscale serve` fronts
    /// `port`. `loopbackOnly` overrides `listensOnLoopbackOnly` for a server
    /// whose bind mode comes from elsewhere, as `alas-host`'s does.
    public func advertisedAddresses(
        port: UInt16?,
        interfaces: [RemoteNetworkInterface],
        tailnetHTTPSHost: String?,
        loopbackOnly: Bool? = nil
    ) -> [RemoteAdvertisedAddress] {
        guard let port else { return [] }
        return RemoteNetwork.advertisedAddresses(
            port: port,
            interfaces: interfaces,
            allowedHosts: allowedHosts,
            preferredHost: preferredAdvertisedHost,
            tailnetHTTPSHost: tailnetHTTPSHost,
            tailnetHTTPSOnly: loopbackOnly ?? listensOnLoopbackOnly
        )
    }

    /// Name advertised to remote clients: the configured display name, else
    /// the computer name.
    public var resolvedDisplayName: String {
        let configured = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        return Host.current().localizedName ?? RemoteNetwork.machineHostName() ?? "Alas"
    }
}
