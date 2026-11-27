# Devices

The Devices tab in the right pane stacks the devices a worktree is using: the
Mac's booted iOS simulators and running Android devices, then the worktree's
own running macOS and Linux VMs. It appears when the Mac has Xcode's simulator
tools, the Android SDK, or can run worktree VMs. One running device fills the
tab; with more, they stack, two screens to a view, and the rest scroll. Each
device's header collapses it to one line, saves a screenshot, opens it in a
center tab, and holds the rest of its actions in its **⋯** menu. A device in a
center tab leaves a line in the stack with **Bring back**; the tab's own
button, or closing it, puts the device back. **+ Add** in the toolbar boots a
simulator or AVD, jumps to a running device, or opens a VM's tab, where it
starts or is set up.

## Send a device bug to an agent

On a running iOS simulator or Android device, open the device's **⋯** menu
and choose **Send to agent…**. Drag a rectangle on the frozen screenshot,
write what went wrong, and pick an open agent chat in this worktree. Dragging
here doesn't tap or swipe on the device.

Review the full screenshot and the crop before sending. The report includes
the device and the foreground app when Alas can identify it. If the selected
region matches one accessibility element, the report also includes its role,
label and ID when available. If the screen changed while Alas was reading it,
or more than one element could be the target, the images still go through
without an element guess.

## Simulators

Simulators need Xcode with at least one iOS simulator runtime. Boot a
simulator that is shut down, then use it: click to tap, drag to swipe, and
type while the screen has focus. Shift, Control and Option reach the
simulator; Command shortcuts stay with Alas. The buttons next to the screen
press Home, open the app switcher, lock the device, and start Siri. Its
header saves a screenshot to the Desktop; **⋯** shuts the simulator down.

To run an app you built for the simulator, drop its `.app` onto the screen:
Alas installs it, replacing an installed copy, and launches it. The screen
outlines itself while the drag is one it can take; an app built for a device
is refused.

**Settings…** in a device's **⋯** opens the simulator's settings while it is
booted and no agent is driving it: appearance, text size and Increase
Contrast, each showing the value the simulator reports back; privacy
permissions and a test push notification for one of your installed apps; a
simulated location, with a few preset places; and a URL or deep link to open.

The settings also hold accessibility: VoiceOver, Reduce Motion, Button
Shapes, Reduce Transparency, a color filter and the Liquid Glass look. Apps
pick changes up while they run. With VoiceOver on, a click selects an element
and a double click activates it.

The settings' Memory section slims the simulator with
[simslim](https://github.com/MobAI-App/simslim): it turns off about 150
background services the simulator doesn't need, which cuts its memory from
about 3.9 GB to under 1 GB, so more simulators fit on the Mac. Siri,
Spotlight, iCloud, widgets and the Photos and Contacts pickers stop working;
push notifications and universal links keep working. The switch applies
without a reboot, and on iOS 18.5 and newer the simulator stays slim across
reboots until you turn it off. Without simslim, Install simslim… installs it
with Homebrew (`brew install mobai-app/tap/simslim`).

**Show Accessibility Overlay** in **⋯** outlines the screen's accessibility
elements over it. Hover one to see its role, label, value and id. Buttons,
fields and other controls without a label are outlined in the warning color, since
VoiceOver can only read their type. The outlines update a second after you
click, type or rotate, and with Refresh.

⌘C and ⌘V work while the screen has focus. ⌘V pastes the Mac clipboard's
text into the focused field; ⌘C copies the simulator's selection to the Mac
clipboard. iOS only pastes from these keys when the app may paste without
asking, so Alas allows the app in front for the moment of the paste and then
puts its previous setting back. A copy waits up to 2 seconds for the app to
copy something.

The rotate buttons under the hardware buttons turn the device left or right.
The screen turns with the app, so an app that supports only portrait stays
upright. **Record Screen** in **⋯** records the screen until you click the
lit stop button in the header, then saves the video to the Desktop. The video keeps the device's
portrait frame, as Simulator.app's recordings do.

### Logs

**Logs** in **⋯** opens a booted simulator's logs in a center
tab. By default it shows the app in front: its own lines at Default level and
above, without Apple's `com.apple.*` subsystems, and it follows whichever app
comes forward. Pick one of your apps or all processes instead, choose a level
(Default, + Info, + Debug, or errors and faults only), show Apple's
subsystems, or search the lines already captured. Pause holds the view while
lines keep arriving; the tab keeps the newest 5,000 lines.

When the app crashes, a banner shows the exception and the crashing frames
from its crash report, with buttons to open the report or dismiss the banner.
macOS writes the report about 30 seconds after the crash.

### Running an app from a run script

A run script can name the app it builds with an `# alas-app:` line, relative
to the worktree root or absolute:

```sh
#!/bin/zsh
# alas-name: Run on Simulator
# alas-app: build/Build/Products/Debug-iphonesimulator/MyApp.app
xcodebuild -scheme MyApp -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build build
```

When the script succeeds, Alas installs and launches the app on the
simulator the worktree's Devices tab shows. When the tab shows a VM or
nothing, it uses the first booted simulator, else the first one, which it
boots. The Devices tab then comes forward, and the install's progress or
error shows on the screen. If an agent is driving that simulator, take over
first. This works for worktrees on this Mac only.

The screen keeps the device's real shape: its size and corner radius come
from Xcode's device type and DeviceKit chrome files.

Alas reads the simulator's screen directly through Xcode's private simulator
frameworks, in a helper process (`AlasSimService`). It does not need Node,
ffmpeg, or Simulator.app. A new Xcode release can break the stream until Alas
updates; the code comes from Expo's serve-sim (see
`ThirdParty/serve-sim-native/README.md`).

If the helper stops, the screen says so and Retry starts it again. If
`xcode-select` points at the Command Line Tools instead of Xcode, the tab
says simulators need Xcode.

## Android

Android devices need the Android SDK: Android Studio, or the command-line
tools with `platform-tools` and `emulator`. Alas finds it through
`ANDROID_HOME`, `ANDROID_SDK_ROOT` or `~/Library/Android/sdk`, and installs
nothing itself.

**+ Add**'s Android section lists connected phones and running
emulators, then the AVDs you can boot. Alas boots an AVD without the
emulator's window; it keeps running after Alas quits, as simulators do. A
phone shows once it's connected with USB debugging allowed.

Click to tap, drag to swipe, scroll, and type while the screen has focus.
The buttons beside the screen are Back, Home, Recents, Power, volume and
rotation. ⌘V pastes the Mac clipboard's text into the focused field; ⌘C
copies the device's selection. Drop an `.apk` on the screen to install and
open it. Its header saves a screenshot, and **⋯** records up to 3 minutes of
the screen, both to the Desktop, and shuts an emulator down.

**Settings…** opens the same settings as on iOS: appearance, text size
(Android's font scale) and high-contrast text; Wi-Fi and mobile data; an
app's permissions, or clearing its data after a confirmation; a simulated
location; and a URL to open. **Logs** opens a center tab with the
logcat of the app in front, a chosen app or every process, followed across
the app's restarts, with a banner for each Java crash.

The screen streams with scrcpy's server, which Alas bundles and copies to
the device each time it shows the screen.

To opt in on Android 16 emulators, turn on **Fast Android screen reads**
in **Settings → Computer Use**. Physical phones and other Android versions
keep the standard reader.

The fast reader uses Android's single UI Automation slot while reading and
releases it after five idle seconds. Wait for it to release before starting
Espresso or UI Automator. If another tool already owns the slot, Alas
reports the conflict rather than stopping that tool. Video and touch still
use scrcpy.

### Watch or drive a USB Android device from another machine

On the Mac connected to Android, turn on **Settings › Remote › Enable remote
control**, **Serve over HTTPS**, and **Tailscale only**. Both clients need a
route to that Mac on the tailnet. Pair the native Alas app directly with the
owning Mac using its HTTPS address; a different paired host cannot relay a
device stream.

Under **Settings › Remote › Device sharing**, grant **View** or **View and
Control** to each paired Mac or iPhone that should see the selected Android
device. The grant is saved on the host. Pairing alone grants no device
access. On iPhone, open **Peers › Devices** for the host. On another Mac,
open the Devices tab while viewing that peer's worktree.

A viewer opens without control. Choose **Take over** to tap, swipe, type,
or use the Android buttons. Only one viewer can drive at once. **Hand back**
releases control so the agent on the host can continue; it does not retry an
agent call that already timed out. On the host, use **Reclaim** on the
Android screen in the Devices rail or its center tab.
On a Mac viewer, holding a key such as Backspace repeats it on Android.
Submitting text uses the Android clipboard to paste into the focused field.
Alas does not sync clipboard contents to the viewer.

Opening a view does not stop the agent. Losing the connection or sending the
phone app to the background releases control. When the view reconnects,
choose **Take over** again. **Stop Sharing** clears the device's grants and
closes its viewers without stopping local use.

Keep the host Mac logged in, awake, and running Alas. **Keep awake on power**
does not prevent explicit sleep or lid-close sleep. Android must stay
USB-connected and authorized for debugging. If the Mac is unreachable, Alas
cannot tell whether it is asleep or disconnected. If USB debugging needs
approval again, someone must approve it on Android. Do not rely on remote
access to recover after a power loss or reboot without first checking your
device's USB and lock-screen behavior.

Remote viewing and control currently cover physical USB Android devices,
not Android emulators, iOS simulators, VMs, or the browser client.

## Flows

A flow is a script of steps on a device, kept in the worktree as
`.maestro/<name>.yaml`, that runs again on any simulator or Android device.
Steps name elements by their text or id rather than by where they were, so a
flow survives layout changes.

**Record Flow** in **⋯** records one on a booted device. Each click
becomes a tap on the element under it, named by its label, else its id, else
the point; typing becomes text, Delete erases, Return the Enter key, the Home and Back
buttons their keys, and a drag a swipe, as is a scroll on Android (simulators
don't take the wheel). A paste is recorded as the
text it pasted; tabs and newlines in it replay as Tab and Return, as typed
ones do. A recording starts by launching the
app in front. Click the lit hand button in the header to name the flow and save it.

**Run Flow** in **⋯** lists the worktree's flows and runs one; while you hold the
device, hand it back first. Each step waits up
to 5 seconds for its element, and the run stops at the first step that
fails; a popover then says which step and line failed and why. While a flow
runs, the pill on the screen shows its step, and Take over stops it.

Flows are a subset of [Maestro](https://maestro.dev)'s YAML, which Alas reads
and runs itself, without Maestro:

| Command | What it does |
|---|---|
| `launchApp` | Launches the flow's `appId`, or `launchApp: {appId: …}`. |
| `tapOn: "Save"`, `tapOn: {id: …}`, `tapOn: {point: "50%,80%"}` | Taps the element with that text or id, or a point. |
| `inputText: "hello"` | Types into the focused field. |
| `eraseText: 3` | Deletes characters before the cursor (50 without a count). |
| `pressKey: Home`, `Back` or `Enter` | Presses a button or Return. |
| `scroll`, `swipe: {direction: UP}` | Scrolls down, or swipes up, down, left or right. |
| `assertVisible: "Done"`, `assertNotVisible: …` | Waits for the element to appear, or to be gone. |
| `openLink: "myapp://x"` | Opens a URL. |
| `waitForAnimationToEnd` | Waits for the screen to settle. |

Values may be bare, in double quotes (with YAML's escapes such as `\n`, `\"`
and `\u00e9`) or in single quotes (with `''` for an apostrophe). Options a
command doesn't take here, such as `launchApp`'s `clearState`, are refused. Text matches a label exactly, then as
part of one, ignoring case; Alas
doesn't take Maestro's regular expressions. Maestro's other commands, such as
`runFlow`, `repeat` and conditions, are refused with their line.

## Routes

The settings popover's Route menu moves the simulated location along a path:
City Walk (5 km/h), Bike Ride (18 km/h) or Freeway Drive (100 km/h) around
Apple Park, or a GPX file's track at the speed beside the menu. A route stays
at its last point when it ends; Stop, Clear or a new location ends it sooner.
On Android the popover shows how far along it is. On iOS, routes need iOS 17
or later.

## VMs

A running VM shows its live screen in the stack, with who drives it, Take over
and Hand back, as a simulator does. The stack leaves the guest's display size
alone and scales the screen down. Open it in a tab for a full-size screen and
the VM's setup, clean points and disk tools; a VM that isn't running opens
there from **+ Add**, to start or set up. A VM another Alas runs is listed in
**+ Add** but can't be shown here. While you drive a VM, an agent's call to it
waits up to 50 seconds for you to hand it back, and the status names the agent
waiting. Moving a VM back from its tab hands it back.

## Agents

Agents can drive the same simulators and Android devices. Turn on
**Settings › Computer Use › Let agents use simulators and Android devices**.
Agent sessions in a worktree then get these tools from the built-in `alas`
MCP server:

| Tool | What it does |
|---|---|
| `device_list` | Lists the iOS simulators and Android devices, with their platform and whether each is booted. |
| `device_open` | Boots a simulator or an Android AVD if needed and shows it in the Devices tab of the agent's worktree. |
| `device_snapshot` | Reads the screen's accessibility elements, with refs such as `s2e3` and frames in points. |
| `device_screenshot` | Returns a PNG of the screen, at most 1280 px on the long edge. |
| `device_tap` | Taps a ref from the latest snapshot, or x/y pixels in the latest screenshot. |
| `device_swipe` | Swipes in a direction, or between two screenshot points. |
| `device_type` | Types text: ASCII as key presses, `\n` as Return; words with accents, emoji or other characters are pasted. |
| `device_button` | Presses Home, Lock, the side button or the app switcher; Siri on iOS; Back and the volume buttons on Android. |
| `device_install` | Installs a built `.app` on a simulator, or an `.apk` on an Android device, and returns its bundle ID or package. |
| `device_launch` | Launches an installed app, ending a running copy first. |
| `device_set_appearance` | Sets light or dark appearance, the text size and Increase Contrast, and returns what the device reports. |
| `device_set_accessibility` | Turns VoiceOver, Reduce Motion, Button Shapes, Reduce Transparency, a color filter and the Liquid Glass look on or off, and returns what the simulator reports. iOS only. |
| `device_set_permission` | Grants, revokes or resets a privacy permission for an installed app. |
| `device_set_location` | Sets or clears the simulated location. |
| `device_push` | Sends a push notification to an installed app. iOS only. |
| `device_set_network` | Turns Wi-Fi and mobile data on or off, and returns both. Android only. |
| `device_clear_data` | Clears an installed app's data, as a fresh install has it. Android only. |
| `device_set_slim` | Slims a simulator with simslim, or brings it back to stock, and returns its memory. iOS only; needs simslim. |
| `device_open_url` | Opens a web page or a deep link. |
| `device_logs` | Reads an app's recent logs and crash reports, by default the app in front. |
| `device_clipboard` | Reads the device's clipboard, or sets it. |
| `device_rotate` | Turns the device, and returns the device and interface orientations. |
| `device_record` | Starts or stops a screen recording; stop returns the video's path. |
| `device_flow_record` | Records the agent's own calls on a device as a flow in `.maestro/`. |
| `device_run_flow` | Runs a flow and returns whether it passed, or the step, line and reason it failed. |
| `device_set_route` | Moves the simulated location along waypoints or a GPX file at a speed. |

Taps, swipes, typing, buttons, launching, opening URLs and rotating wait for
the screen to settle and return what changed since the agent's last look:
elements added and removed, and changed values, or the whole screen when it
changed completely, as after navigating. Refs of elements still on screen
keep working. On iOS's keyboard, typing relabels keys, so typing usually
returns the whole screen.

On Android, devices are named by their serial (`emulator-5554`), and an AVD
that isn't running by `avd:<name>`: `device_open` boots it and answers with
the serial to use from then on. Snapshot frames are in dp. Text sizes map to
Android's font scale and Increase Contrast to its high-contrast text;
permissions map to Android's runtime permissions, and those Android lacks
answer `device_unsupported`, as do `device_push` and
`device_set_accessibility`. The location is set through Android's test
location provider, so it works on phones too. Reading an Android screen takes
about 2 seconds, so actions that return what changed take that long too;
pass `diff: false` to skip it.

While an agent works on a device, a pill on its screen says who is driving
and the screen ignores your clicks and keys. Take over to use it yourself. An
agent's call made while you drive waits for you to hand the simulator back,
for up to 50 seconds, and the pill says the agent is waiting; after that the
call fails with `device_user_active` and the agent tries again later. Typing
or a swipe already under way when you take over stops. Sessions started
while the setting is off don't get the `device_*` tools; sessions already
running keep them, and their calls fail with `device_disabled`. An agent's
calls keep the simulator's stream running for a minute after its last call,
so screenshots work with the Devices tab closed.

A flow run is one call, held while you drive like any other. A step waiting
for its element can take 5 seconds, and some agents end a call after 60
seconds (Codex by default), so keep the flows agents run short.

Not yet: physical iOS devices. The follow-up list is in
`docs/plans/2026-11-04-device-panel-design.md`.
