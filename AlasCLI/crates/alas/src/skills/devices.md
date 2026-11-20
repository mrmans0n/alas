# Alas simulators and devices

Device tools drive iOS simulators and Android devices that the user also sees
in Alas's Devices tab. They have no short commands: run each with
`alas tool call <name> '<json-arguments>'`, and print a tool's arguments with
`alas tool schema <name>`.

## Loop

1. `alas tool call device_list` lists simulators and devices;
   `alas tool call device_open '{"udid":"<udid>"}'` boots one if needed and
   shows it to the user. An Android AVD comes back under its serial, which
   later calls use.
2. To run an app, build it for the simulator with `xcodebuild`, or an .apk
   with Gradle, then call `device_install` and `device_launch`.
3. `device_snapshot` lists the screen's elements with refs; `device_screenshot`
   saves an image to the file named by `image_path`. Prefer refs; x/y are
   pixels in the latest screenshot.
4. Act with `device_tap`, `device_swipe`, `device_type` and `device_button`.
   Each action prints what changed on the screen, and refs you hold stay
   valid while their element is on screen, so snapshot again only when you
   need the whole screen.

## Settings and checks

- Dark mode, Dynamic Type and contrast: `device_set_appearance`.
- Accessibility settings (iOS): `device_set_accessibility`.
- Permissions: `device_set_permission`. Location: `device_set_location`, or a
  route with `device_set_route`. Push notifications (iOS): `device_push`.
  Deep links: `device_open_url`.
- Logs and crash reports: `device_logs`. Clipboard: `device_clipboard`.
- `device_rotate`, `device_record`, and flows with `device_flow_record` and
  `device_run_flow`.
- Several simulators at once: slim each with `device_set_slim` first.
- Android only: `device_set_network`, `device_clear_data`.

While the user drives a device, a call waits up to 50 seconds for them to
hand it back; `device_user_active` means it is still theirs, so try again
later. `device_disabled` means the user has not let agents use simulators and
devices: ask them instead of retrying.
