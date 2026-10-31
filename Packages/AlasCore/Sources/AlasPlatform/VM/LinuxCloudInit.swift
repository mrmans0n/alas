import CommonCrypto
import Foundation

/// The NoCloud seed (`meta-data`, `user-data`, `network-config`) for the first
/// boot of a Linux golden image. The guest installs Xfce, logs `account` in
/// automatically, mounts the `alas` virtiofs share, installs the guest helper
/// as a systemd user service, disables cloud-init for later boots and powers
/// off, which is how the host knows setup finished.
public enum LinuxCloudInit {
    /// The virtiofs tag of the host's helper/worktree/transfer share.
    public static let shareTag = "alas"
    public static let shareMountPoint = "/mnt/alas"
    public static let helperSource = "/mnt/alas/helper/alas-vm-guest-linux"
    public static let helperPath = "/usr/local/bin/alas-vm-guest"

    static let packages = ["xubuntu-core", "lightdm", "spice-vdagent", "at-spi2-core", "git", "build-essential"]

    public static func seedFiles(
        hostname: String,
        account: VMGuestAccount,
        instanceID: String
    ) -> [(name: String, contents: String)] {
        seedFiles(hostname: hostname, account: account, instanceID: instanceID, salt: randomSalt())
    }

    static func seedFiles(
        hostname: String,
        account: VMGuestAccount,
        instanceID: String,
        salt: String
    ) -> [(name: String, contents: String)] {
        [
            ("meta-data", metaData(hostname: hostname, instanceID: instanceID)),
            ("user-data", userData(hostname: hostname, account: account, salt: salt)),
            ("network-config", networkConfig),
        ]
    }

    private static func metaData(hostname: String, instanceID: String) -> String {
        """
        instance-id: \(quoted(instanceID))
        local-hostname: \(quoted(hostname))

        """
    }

    /// Netplan v2. The DHCP client id is the MAC, so clones with fresh MACs
    /// never share a lease with the golden image or each other.
    static let networkConfig = """
    version: 2
    ethernets:
      primary:
        match:
          name: "en*"
        dhcp4: true
        dhcp-identifier: mac

    """

    private static func userData(hostname: String, account: VMGuestAccount, salt: String) -> String {
        let name = account.shortName
        let home = "/home/\(name)"
        let userUnits = "\(home)/.config/systemd/user"
        let stagedUnit = "/usr/local/lib/alas/alas-vm-guest.service"
        // The share's fstab line is written directly rather than through
        // `mounts:`, so it doesn't depend on cc_mounts' device-name sanitizing
        // (which has changed across cloud-init releases) and is mounted before
        // the helper is copied from it. Lima also writes its fstab lines itself.
        let runcmd = [
            "mkdir -p \(shareMountPoint)",
            "grep -q ' \(shareMountPoint) ' /etc/fstab || echo '\(shareTag) \(shareMountPoint) virtiofs defaults,nofail 0 0' >> /etc/fstab",
            "mount \(shareMountPoint)",
            "install -m 0755 \(helperSource) \(helperPath)",
            // Each level is created owned by the user; a root-owned ~/.config breaks the desktop session.
            "install -d -o \(name) -g \(name) -m 0755 \(home)/.config \(home)/.config/systemd \(userUnits) \(userUnits)/default.target.wants",
            "install -o \(name) -g \(name) -m 0644 \(stagedUnit) \(userUnits)/alas-vm-guest.service",
            // What `systemctl --user enable` does, without needing the user's manager running yet.
            "ln -sfn ../alas-vm-guest.service \(userUnits)/default.target.wants/alas-vm-guest.service",
            "chown -h \(name):\(name) \(userUnits)/default.target.wants/alas-vm-guest.service",
            "loginctl enable-linger \(name)",
            "touch /etc/cloud/cloud-init.disabled",
        ]
        // write_files runs before users exist, so files land root-owned and
        // runcmd moves the unit into the user's home.
        return """
        #cloud-config
        hostname: \(quoted(hostname))
        preserve_hostname: false
        users:
          - name: \(quoted(name))
            gecos: \(quoted(account.fullName))
            uid: \(account.uid)
            shell: /bin/bash
            groups: [adm, sudo]
            sudo: "ALL=(ALL) NOPASSWD:ALL"
            lock_passwd: false
            passwd: \(quoted(sha512Crypt(password: account.password, salt: salt)))
        ssh_pwauth: false
        package_update: true
        packages:
        \(packages.map { "  - \($0)" }.joined(separator: "\n"))
        write_files:
          - path: /etc/lightdm/lightdm.conf.d/50-alas.conf
            content: |
              [Seat:*]
              autologin-user=\(name)
              autologin-session=xfce
              user-session=xfce
          - path: \(stagedUnit)
            content: |
              [Unit]
              Description=Alas VM guest helper

              [Service]
              ExecStart=\(helperPath)
              Restart=always
              RestartSec=1

              [Install]
              WantedBy=default.target
        runcmd:
        \(runcmd.map { "  - \(quoted($0))" }.joined(separator: "\n"))
        power_state:
          mode: poweroff
          message: "Alas golden image setup finished"
          timeout: 30
          condition: true

        """
    }

    /// A YAML double-quoted scalar, safe for any input.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\x%02X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - SHA-512 crypt

    static let cryptAlphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func randomSalt() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< 16).map { _ in cryptAlphabet.randomElement(using: &generator)! })
    }

    /// `$6$<salt>$<hash>` with the default 5000 rounds, per Ulrich Drepper's
    /// "Unix crypt using SHA-256 and SHA-512" specification, so the guest's
    /// shadow file never sees the plaintext password.
    static func sha512Crypt(password: String, salt: String) -> String {
        precondition(!salt.isEmpty && salt.count <= 16 && salt.allSatisfy(cryptAlphabet.contains), "invalid crypt salt")
        let p = Array(password.utf8)
        let s = Array(salt.utf8)
        let rounds = 5000

        let b = sha512(p, s, p)
        var aParts = [p, s]
        var count = p.count
        while count > 64 {
            aParts.append(b)
            count -= 64
        }
        aParts.append(Array(b.prefix(count)))
        count = p.count
        while count > 0 {
            aParts.append(count & 1 != 0 ? b : p)
            count >>= 1
        }
        let a = sha512(aParts)

        let pBytes = stretch(sha512(Array(repeating: p, count: p.count)), to: p.count)
        let sBytes = stretch(sha512(Array(repeating: s, count: 16 + Int(a[0]))), to: s.count)

        var c = a
        for i in 0 ..< rounds {
            var parts: [[UInt8]] = [i & 1 != 0 ? pBytes : c]
            if i % 3 != 0 { parts.append(sBytes) }
            if i % 7 != 0 { parts.append(pBytes) }
            parts.append(i & 1 != 0 ? c : pBytes)
            c = sha512(parts)
        }

        let order: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
            (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
            (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]
        var encoded = ""
        func append(_ b2: UInt8, _ b1: UInt8, _ b0: UInt8, _ n: Int) {
            var w = UInt32(b2) << 16 | UInt32(b1) << 8 | UInt32(b0)
            for _ in 0 ..< n {
                encoded.append(cryptAlphabet[Int(w & 0x3F)])
                w >>= 6
            }
        }
        for (x, y, z) in order {
            append(c[x], c[y], c[z], 4)
        }
        append(0, 0, c[63], 2)
        return "$6$\(salt)$\(encoded)"
    }

    private static func stretch(_ digest: [UInt8], to length: Int) -> [UInt8] {
        (0 ..< length).map { digest[$0 % digest.count] }
    }

    private static func sha512(_ parts: [UInt8]...) -> [UInt8] {
        sha512(parts)
    }

    private static func sha512(_ parts: [[UInt8]]) -> [UInt8] {
        var context = CC_SHA512_CTX()
        CC_SHA512_Init(&context)
        for part in parts {
            part.withUnsafeBytes { _ = CC_SHA512_Update(&context, $0.baseAddress, CC_LONG($0.count)) }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CC_SHA512_Final(&digest, &context)
        return digest
    }
}
