import Foundation
import Testing
@testable import AlasPlatform

struct LinuxCloudInitTests {
    private static func seed() -> [String: String] {
        let files = LinuxCloudInit.seedFiles(
            hostname: "alas-linux",
            account: .alas,
            instanceID: "golden-linux-1",
            salt: "saltsaltsaltsalt"
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.contents) })
    }

    @Test
    func seedContainsTheAccountAutologinMountAndHelper() throws {
        let files = Self.seed()
        #expect(files.keys.sorted() == ["meta-data", "network-config", "user-data"])

        let meta = try #require(files["meta-data"])
        #expect(meta.contains("instance-id: \"golden-linux-1\""))
        #expect(meta.contains("local-hostname: \"alas-linux\""))

        let user = try #require(files["user-data"])
        #expect(user.hasPrefix("#cloud-config\n"))
        #expect(user.contains("  - name: \"alas\""))
        #expect(user.contains("sudo: \"ALL=(ALL) NOPASSWD:ALL\""))
        #expect(user.contains("lock_passwd: false"))
        let hash = LinuxCloudInit.sha512Crypt(password: "alas", salt: "saltsaltsaltsalt")
        #expect(user.contains("passwd: \"\(hash)\""))
        #expect(!user.contains("plain_text_passwd"))
        for package in ["xubuntu-core", "lightdm", "spice-vdagent", "at-spi2-core", "git", "build-essential"] {
            #expect(user.contains("  - \(package)\n"))
        }
        #expect(user.contains("autologin-user=alas"))
        #expect(user.contains("autologin-session=xfce"))
        #expect(user.contains("alas /mnt/alas virtiofs"))
        #expect(user.contains("install -m 0755 /mnt/alas/helper/alas-vm-guest-linux /usr/local/bin/alas-vm-guest"))
        #expect(user.contains("ExecStart=/usr/local/bin/alas-vm-guest"))
        #expect(user.contains("Restart=always"))
        #expect(user.contains("WantedBy=default.target"))
        #expect(user.contains("/home/alas/.config/systemd/user/default.target.wants/alas-vm-guest.service"))
        #expect(user.contains("loginctl enable-linger alas"))
        #expect(user.contains("touch /etc/cloud/cloud-init.disabled"))
        #expect(user.contains("systemctl set-default graphical.target"))
        // The power button (the host's Stop) shuts down rather than being swallowed by Xfce.
        #expect(user.contains("path: /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml"))
        #expect(user.contains(#"<property name="power-button-action" type="uint" value="4"/>"#))
        // A clone regenerates the SSH host keys the golden's seal removed, before sshd's own check.
        #expect(user.contains("path: /etc/systemd/system/ssh.service.d/alas-host-keys.conf"))
        #expect(user.contains("ExecStartPre=\n      ExecStartPre=/usr/bin/ssh-keygen -A\n      ExecStartPre=/usr/sbin/sshd -t\n"))
        #expect(user.contains("power_state:\n  mode: poweroff"))
        // Power off only once setup really happened; otherwise the host's deadline fails the build.
        #expect(!user.contains("condition: true"))
        #expect(user.contains(
            #"condition: "test -x /usr/local/bin/alas-vm-guest && test -L /home/alas/.config/systemd/user/default.target.wants/alas-vm-guest.service && dpkg -s xubuntu-core lightdm >/dev/null 2>&1""#
        ))
        // The mount must be in place before the helper is copied from it.
        let mount = try #require(user.range(of: "mount /mnt/alas"))
        let install = try #require(user.range(of: "/mnt/alas/helper/alas-vm-guest-linux"))
        #expect(mount.lowerBound < install.lowerBound)

        let network = try #require(files["network-config"])
        #expect(network.contains("version: 2"))
        #expect(network.contains("dhcp-identifier: mac"))
    }

    @Test
    func seedQuotesUntrustedScalars() throws {
        let files = LinuxCloudInit.seedFiles(hostname: "a\"b\\c", account: .alas, instanceID: "x: y\n#z")
        let meta = try #require(files.first { $0.name == "meta-data" }?.contents)
        #expect(meta.contains(#"instance-id: "x: y\n#z""#))
        #expect(meta.contains(#"local-hostname: "a\"b\\c""#))
    }

    /// The first vector is the reference one from the SHA-crypt spec, also
    /// produced by `openssl passwd -6 -salt saltstring 'Hello world!'`.
    @Test(arguments: [
        ("Hello world!", "saltstring", "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"),
        ("alas", "saltsaltsaltsalt", "$6$saltsaltsaltsalt$byiHOb0dD5l8qa573IW7/jZb860TiJB1DfxCvjb5VFvV2G7L4gc1.oOEYGd7RCfC2vg7dcTpFlF70eLOc1d3A1"),
    ])
    func sha512CryptMatchesReferenceHashes(password: String, salt: String, expected: String) {
        #expect(LinuxCloudInit.sha512Crypt(password: password, salt: salt) == expected)
    }
}
