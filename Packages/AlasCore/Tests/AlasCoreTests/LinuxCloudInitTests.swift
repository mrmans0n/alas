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
        let powerManager = try #require(LinuxGuestSetup.lockerOffFiles.first { $0.path.hasSuffix("/xfce4-power-manager.xml") })
        #expect(powerManager.content.contains(#"<property name="power-button-action" type="uint" value="4"/>"#))
        // A clone regenerates the SSH host keys the golden's seal removed, before sshd's own check.
        #expect(user.contains("path: /etc/systemd/system/ssh.service.d/alas-host-keys.conf"))
        #expect(user.contains("ExecStartPre=\n      ExecStartPre=/usr/bin/ssh-keygen -A\n      ExecStartPre=/usr/sbin/sshd -t\n"))
        #expect(user.contains("power_state:\n  mode: poweroff"))
        // Power off only once setup really happened; otherwise the host's deadline fails the build.
        #expect(!user.contains("condition: true"))
        #expect(user.contains(
            #"condition: "test -x /usr/local/bin/alas-vm-guest && test -x /usr/local/bin/cua-driver && test -L /home/alas/.config/systemd/user/default.target.wants/alas-vm-guest.service && dpkg -s xubuntu-core lightdm mousepad >/dev/null 2>&1""#
        ))
        // The shared guest setup runs in order, once the share it installs from is mounted.
        var cursor = try #require(user.range(of: "  - \"mount /mnt/alas\"\n")).upperBound
        for command in LinuxGuestSetup.commands(user: "alas") {
            let line = try #require(
                user.range(of: "  - \(LinuxCloudInit.quoted(command))\n", range: cursor ..< user.endIndex),
                "missing or out of order: \(command)"
            )
            cursor = line.upperBound
        }

        let network = try #require(files["network-config"])
        #expect(network.contains("version: 2"))
        #expect(network.contains("dhcp-identifier: mac"))
    }

    @Test
    func guestSetupInstallsBothBinariesAndTurnsTheLockerOff() throws {
        let commands = LinuxGuestSetup.commands(user: "alas")
        #expect(commands.contains("install -m 0755 /mnt/alas/helper/cua-driver /usr/local/bin/cua-driver"))
        // The dpkg lock is often held by apt-daily on first boot, so apt waits for it.
        let mousepad = try #require(commands.first { $0.contains("install -y mousepad") })
        #expect(mousepad.hasPrefix("dpkg -s mousepad >/dev/null 2>&1 || "))
        #expect(mousepad.contains("apt-get -o DPkg::Lock::Timeout=300 update"))
        #expect(mousepad.contains("apt-get -o DPkg::Lock::Timeout=300 install -y mousepad"))
        #expect(commands.last == "runuser -u alas -- env XDG_RUNTIME_DIR=/run/user/$(id -u alas) systemctl --user restart alas-vm-guest || true")

        // The lock screen swallows foreground input, so the screensaver, its locker and DPMS stay off.
        let screensaver = try #require(LinuxGuestSetup.lockerOffFiles.first { $0.path.hasSuffix("/xfce4-screensaver.xml") })
        for group in ["lock", "saver"] {
            #expect(screensaver.content.contains(
                #"<property name="\#(group)" type="empty">\#n    <property name="enabled" type="bool" value="false"/>"#
            ))
        }
        let powerManager = try #require(LinuxGuestSetup.lockerOffFiles.first { $0.path.hasSuffix("/xfce4-power-manager.xml") })
        #expect(powerManager.content.contains(#"<property name="dpms-enabled" type="bool" value="false"/>"#))

        // Update helper writes the same files by shell, so every file has a heredoc in the commands.
        for file in LinuxGuestSetup.lockerOffFiles {
            #expect(commands.contains { $0.hasPrefix("cat > \(file.path) ") })
        }

        // Update helper stops at once on a share without Cua Driver. On an older guest a per-user
        // screensaver channel overrides those defaults and a locker may run, so it also drops both.
        // The pkill is anchored: an unanchored -f would match the script's own command line. The
        // restart is queued, so the script ends before it stops the service it runs in.
        let update = LinuxGuestSetup.updateCommands(user: "alas")
        #expect(update == [
            #"test -x /mnt/alas/helper/cua-driver || { echo "no Cua Driver in the helper share" >&2; exit 3; }"#,
        ] + commands.dropLast() + [
            #"rm -f "$(getent passwd alas | cut -d: -f6)/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml""#,
            "pkill -f '^(/usr/bin/)?xfce4-screensaver' || true",
            "runuser -u alas -- env XDG_RUNTIME_DIR=/run/user/$(id -u alas) systemctl --user --no-block restart alas-vm-guest || true",
        ])
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
