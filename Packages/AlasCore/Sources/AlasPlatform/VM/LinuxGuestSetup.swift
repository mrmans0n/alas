import Foundation

/// The setup a Linux guest needs for the Alas helper and computer use, shared
/// by the golden image's first boot (cloud-init) and a live guest's Update
/// helper. Both run `commands(user:)` as root with the `alas` share mounted at
/// `LinuxCloudInit.shareMountPoint`; Update helper runs it as
/// `updateCommands(user:)`.
public enum LinuxGuestSetup {
    public static let helperSource = "/mnt/alas/helper/alas-vm-guest-linux"
    public static let helperPath = "/usr/local/bin/alas-vm-guest"
    public static let cuaDriverSource = "/mnt/alas/helper/cua-driver"
    public static let cuaDriverPath = "/usr/local/bin/cua-driver"

    static let xfconfDirectory = "/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"

    /// System-wide Xfce defaults that keep the desktop usable by an agent. The
    /// lock screen swallows foreground (XTest) input, so the screensaver, its
    /// locker, blanking and DPMS stay off. Xfce's power manager also takes the
    /// power key from logind and by default does nothing, so the host's Stop
    /// (an ACPI power button press) would end in a forced power-off; 4 is
    /// XFPM_DO_SHUTDOWN, which powers off through logind.
    public static let lockerOffFiles: [(path: String, content: String)] = [
        (
            "\(xfconfDirectory)/xfce4-power-manager.xml",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <channel name="xfce4-power-manager" version="1.0">
              <property name="xfce4-power-manager" type="empty">
                <property name="power-button-action" type="uint" value="4"/>
                <property name="dpms-enabled" type="bool" value="false"/>
                <property name="blank-on-ac" type="int" value="0"/>
              </property>
            </channel>

            """
        ),
        (
            "\(xfconfDirectory)/xfce4-screensaver.xml",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <channel name="xfce4-screensaver" version="1.0">
              <property name="lock" type="empty">
                <property name="enabled" type="bool" value="false"/>
              </property>
              <property name="saver" type="empty">
                <property name="enabled" type="bool" value="false"/>
              </property>
            </channel>

            """
        ),
    ]

    /// One `cat > path <<'EOF'` heredoc per `lockerOffFiles` entry. Each is a
    /// single multi-line shell command; the contents never contain a line
    /// that is exactly `EOF`.
    static func writeFilesCommands() -> [String] {
        lockerOffFiles.map { "cat > \($0.path) <<'EOF'\n\($0.content)EOF" }
    }

    /// The idempotent root shell lines that install both binaries from the
    /// share, install the packages computer use needs, write `lockerOffFiles`
    /// (it already includes `writeFilesCommands()`, so callers must not add
    /// them again) and finally restart `user`'s helper service.
    ///
    /// The restart never fails the script: on first boot the user's systemd
    /// manager may not be up yet, and linger starts the service later anyway.
    public static func commands(user: String) -> [String] {
        ["install -d -m 0755 \(xfconfDirectory)"]
            + writeFilesCommands()
            + [
                "install -m 0755 \(helperSource) \(helperPath)",
                "install -m 0755 \(cuaDriverSource) \(cuaDriverPath)",
                // apt-daily or unattended-upgrades often hold the dpkg lock on first boot.
                "dpkg -s mousepad >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=300 update && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y mousepad; }",
                restartCommand(user: user),
            ]
    }

    /// `commands(user:)` for a guest that has been running. It first stops
    /// with exit status 3 when the share has no Cua Driver. Before the
    /// restart it removes `user`'s own screensaver channel (older guests
    /// wrote one, and it overrides the `/etc/xdg` defaults), turns the locker
    /// and saver off in a running xfconfd too, which could otherwise write
    /// the old values back, and ends a running locker. The locker's name is
    /// longer than the 15 characters `pkill -x` sees, so it matches the
    /// command line, anchored so it can't match this script's. The restart is
    /// only queued: the script runs inside the helper's service, whose stop
    /// would otherwise wait for it.
    public static func updateCommands(user: String) -> [String] {
        let xfconfOff = ["/lock/enabled", "/saver/enabled"].map { property in
            "runuser -u \(user) -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u \(user))/bus "
                + "xfconf-query -c xfce4-screensaver -p \(property) -n -t bool -s false || true"
        }
        return [#"test -x \#(cuaDriverSource) || { echo "no Cua Driver in the helper share" >&2; exit 3; }"#]
            + commands(user: user).dropLast()
            + [#"rm -f "$(getent passwd \#(user) | cut -d: -f6)/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml""#]
            + xfconfOff
            + [
                "pkill -f '^(/usr/bin/)?xfce4-screensaver' || true",
                restartCommand(user: user, noBlock: true),
            ]
    }

    private static func restartCommand(user: String, noBlock: Bool = false) -> String {
        "runuser -u \(user) -- env XDG_RUNTIME_DIR=/run/user/$(id -u \(user)) systemctl --user\(noBlock ? " --no-block" : "") restart alas-vm-guest || true"
    }
}
