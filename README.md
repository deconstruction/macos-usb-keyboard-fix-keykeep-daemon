# keykeep

A small background daemon for macOS that pokes a flaky USB keyboard every few seconds so it
stops dropping off the bus — plus a log that tells you *why* it was dropping.

Written for a cheap low-speed HID keyboard (`VID 0xc0f4`) behind a USB-C → USB-A adapter on
Apple Silicon, where the device would periodically disappear and need a replug.

## The important part: typing a key does not help

The obvious idea — "just press NumLock every 5 seconds" — cannot work, and it is worth knowing why:

* `CGEvent` / `osascript` keystrokes are born **inside** macOS, above the HID driver. They reach the
  window server and the focused app, but they never travel down the USB bus. The keyboard never sees
  them, so an idle keyboard stays idle and an idle port stays idle.
* Software on the host also cannot prevent a **link-level** drop (re-enumeration). Nothing in user
  space runs during that window — only the hardware can help there.

What *does* create real traffic is an actual HID transfer to the device. `keykeep` sends an **output
report** with the LED bitmap, which is a genuine host → device transfer. It changes the NumLock LED
and nothing else: no key event reaches any application, nothing is typed anywhere.

If your drops are link-level (the device vanishes from the bus), this won't save you — but the log
will prove that is what is happening, and then the fix is hardware.

## Install

```sh
git clone https://github.com/deconstruction/macos-usb-keyboard-fix-keykeep-daemon.git
cd macos-usb-keyboard-fix-keykeep-daemon
./install.sh
```

`install.sh` builds a small `Keykeep.app` (an app bundle, because macOS only offers a stable privacy
identity to bundles), installs `~/Library/LaunchAgents/local.keykeep.agent.plist`, and starts it.

Then grant Input Monitoring — this is required, there is no dialog for background processes:

> System Settings → Privacy & Security → Input Monitoring → enable **Keykeep**

Restart the agent afterwards:

```sh
launchctl kickstart -k gui/$(id -u)/local.keykeep.agent
```

The row normally appears in the list by itself once the bundle has been launched once. If it does not:

```sh
open -a ./Keykeep.app
```

## Configuration

The keyboard is matched by two constants at the top of `keykeep.swift`:

```swift
let KB_VID = 0xc0f4
let KB_PID = 0x06f5
```

Find yours with:

```sh
./keykeep devices
```

…then rebuild. **Any rebuild changes the code hash, and macOS silently revokes the Input Monitoring
grant for ad-hoc signed binaries** — you will have to toggle the permission off and on again. Keep
that in mind before rebuilding a working install.

Interval (seconds) is a launch agent argument:

```sh
./install.sh            # default 5
INTERVAL=2 ./install.sh
```

## Commands

```
keykeep poke [--interval 5] [--backoff 60] [--led | --key 71] [--log PATH]   keep-alive loop
keykeep once                                                  one poke, prints what happened and how long it took
keykeep probe                                                 open every interface separately, with timings
keykeep watch                                                 log attach/detach of the keyboard
keykeep devices                                               list HID devices with usage page and LED elements
keykeep status                                                permissions, presence, chosen interface
keykeep perms                                                 ask for Input Monitoring
```

Two poke modes:

| mode | what it does | USB traffic | permission |
|---|---|---|---|
| `--led` (default) | HID output report, toggles the NumLock LED | **yes** | Input Monitoring |
| `--key 71` | injects the Clear/NumLock key event via `CGEvent` | no | Accessibility |

## Which interface

Cheap keyboards expose two HID interfaces: a keyboard one (usage page 1 / usage 6, three LED
elements here) and a consumer-control one (usage page 12 / usage 1, no LED elements). The LED report
only makes sense on the first. `keykeep` picks the interface by its LED output elements instead of
taking the first one the manager returns — the order of a `Set` is arbitrary, and picking the
consumer interface makes every poke fail for no visible reason. `keykeep probe` prints what was
chosen and why.

## Reading the log

`~/Library/Logs/keykeep.log`. State transitions are logged the moment they happen; a periodic
line follows once a minute so the log shows the agent is alive.

```
startup   keykeep starting: every 5.0s (backoff 60.0s) -> LED report over USB
state     OK — LED on via usagePage 1/usage 6 (9 ms)
state     keyboard DISAPPEARED from the bus
state     OPEN FAILED — open failed 0xe00002c7 kIOReturnUnsupported (30012 ms)
state     REPORT REJECTED — SetReport 0xe00002c7 kIOReturnUnsupported via usagePage 1/usage 6
state     NO ACCESS — open denied 0xe00002e2 kIOReturnNotPermitted
```

What they mean:

* `keyboard DISAPPEARED from the bus` / `state: OK` afterwards — the device re-enumerated. That is a
  link-level drop; software cannot prevent it. Fix the hardware: a USB 2.0 hub between the Mac and
  the keyboard is the most reliable option, then a better adapter/cable, then another port.
* `OPEN FAILED` **with a large millisecond figure** — the device is on the bus but the open stalls and
  fails. This is the device's own state, not permissions: the same binary opens it in 0 ms after a
  replug. The agent then backs off to `--backoff` seconds instead of hammering a 30-second stall
  every cycle.
* `NO ACCESS — kIOReturnNotPermitted` — Input Monitoring is not granted. Note the grant is tied to
  the **code hash**, so any rebuild silently revokes it: toggle the permission off and on again.
* `REPORT REJECTED` — the open worked but the LED report did not; usually the same device stall.

A quick check on whether the ping really reaches the device: the NumLock LED blinks once per
interval. If it does, the transfer is real. `keykeep probe` shows the same thing in numbers.

A quick check on whether the ping really reaches the device: the NumLock LED blinks once per
interval. If it does, the transfer is real.

## Why an app bundle

macOS ties privacy grants to a code identity. A bare executable built ad-hoc gets a hash-derived
identifier that changes on every rebuild, so the grant silently stops matching
(`kIOReturnNotPermitted` from `IOHIDManagerOpen`). A bundle gives a stable `CFBundleIdentifier`.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/local.keykeep.agent
rm ~/Library/LaunchAgents/local.keykeep.agent.plist
```

The permission entry can be removed from the Input Monitoring list with `−`.

## Tested

macOS 15.8.1, arm64 (Apple Silicon), Swift 6.2.3, cheap low-speed HID keyboard
`Usb KeyBoard` (VID `0xc0f4`, PID `0x06f5`) behind a USB-C → USB-A adapter.

## License

MIT
