# dl-wake-fix

Fix for a DisplayLink bug on macOS where, after the screens sleep and wake, only one of two external displays comes back — the other stays black until you physically unplug and replug the cable.

Written for a **JSAUX FlipGo Pro 16** dual-screen portable monitor (DisplayLink "Hybrid Dock", USB `17e9:6000`) on a **MacBook Air M5 / macOS 26.5.2**, but the failure is in DisplayLink, not in the monitor, so it likely applies to any DisplayLink dock on macOS 26.

## The problem

Setup: one USB-C cable from the Mac to the FlipGo, driving two 2560×1600 displays through DisplayLink, plus the built-in display — three distinct screens.

Symptom: after the displays turn off (idle timeout, ⌃⌘Q lock, closing the lid) and then wake up, **only one of the two FlipGo panels comes back**. The other one never lights up. Unplugging and replugging the USB-C cable fixes it, every time. Nothing else does — not waiting, not opening System Settings, not toggling "Detect Displays".

## Root cause

DisplayLink tears down both virtual displays when the screens go to sleep, then immediately tries to recreate them — while macOS is already inside its sleep window, so the recreation is rejected. It retries three times within 1.5 seconds and then **permanently gives up**, never recreating the display when the system wakes.

From the system log (`log show --predicate 'process CONTAINS "DisplayLink"'`):

```
13:51:55.349  kCGSDisplayWillSleep                      # screens go to sleep
13:52:05.954  CDVirtualDisplayDestroy(0x754c9adf0)      # D2 destroyed
13:52:05.955  CDVirtualDisplayDestroy(0x754f18fa0)      # D1 destroyed
13:52:05.960  spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
13:52:06.466  spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
13:52:06.973  spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
```

On wake, DisplayLink only rebuilds the panel that *disappeared from its device list during sleep* (the second panel powers down and is re-detected as a new device, so it gets recreated). The first panel stayed in the list the whole time, so there is no new event to trigger its recreation:

```
13:53:34.378  FlipGo-D1  CGID = 0x0    isEnabled = true    # listed, but bound to no display
              FlipGo-D2  CGID = 0x17   isEnabled = true    # recreated
```

`system_profiler SPDisplaysDataType` confirms only `FlipGo-D2` exists. `CGGetActiveDisplayList` returns an empty array while asleep; `CGGetOnlineDisplayList` still returns all three, so "is a screen missing" has to be answered from the *active* list.

Why this is a DisplayLink bug and not a hardware fault:

- The failure happens in a pure software call (`spawnProxy`), not in the USB link. The dock is enumerated once in the kernel log and never disconnects across a sleep/wake cycle.
- The same recreation succeeds occasionally (`kr=0x0` at 14:01:28 in the same session), so it is a race with the sleep window, not a permanent hardware state.
- Restarting the DisplayLink process alone restores both screens in about 5 seconds, with no change to the cable or the monitor.
- It reproduces on **DisplayLink Manager 16.2.39 and 17.0.24** (macOS 26.5.2). Neither release note mentions a fix; there is no version newer than 17.0 as of October 2026.

The FlipGo's behaviour makes the bug easier to hit: its two panels enter low-power state differently (one drops off the DisplayLink device list, one doesn't), and its scaler is slow to wake and briefly reports a fallback EDID.

## The fix

A small launchd daemon that polls once per second and restarts the DisplayLink agent when the screens are awake, the dock is present, but fewer than two external displays exist:

1. **Screen path (fast).** When `CGDisplayIsAsleep` flips from true to false, wait 3 seconds for the first panel to appear. If the second one is still missing, run `killall DisplayLinkUserAgent` followed by `open -g -a "DisplayLink Manager"`, which forces a full rebuild. Measured: **6 seconds from wake to both screens up**, versus manual replug.
2. **Slow path.** Scenarios without a sleep transition (replugging the cable) use a 10-second window instead, so it doesn't fight with panels appearing one after another.
3. **Window layout restore.** Because DisplayLink destroys both virtual displays, macOS evicts every window that was on them. A separate helper records window positions while everything is healthy and puts them back once both displays are up and the session is unlocked. Measured worst case: the window that used to land on the wrong screen is back where it belongs.

Restarting the agent is required — merely activating the already-running DisplayLink Manager does not recreate the missing display (tested, 16 seconds, no recovery).

## Repository layout

| Path | Contents |
|---|---|
| `sources/main.swift` | the daemon |
| `sources/winlayout.swift` | window layout record/restore helper |
| `bin/` | prebuilt binaries + SHA256SUMS |
| `launchd/` | LaunchAgent definition |
| `install.sh` | deploy to `~/Library/Scripts/dl-wake-fix/` and load |
| `docs/evidence.md` | raw log excerpts and reproduction commands |
| `docs/parameters.md` | every timing value with its measured justification |
| `AGENTS.md` | constraints for AI agents working on this repo |

## Install

```sh
./install.sh
```

Then grant **Accessibility** to `~/Library/Scripts/dl-wake-fix/dl-winlayout` in System Settings → Privacy & Security → Accessibility. Without it, screen recovery still works; only window restoration is skipped.

Logs: `~/Library/Logs/dl-wake-fix.log` (one line per state change).
Pause: `touch ~/Library/Scripts/dl-wake-fix/disabled`.

## ⚠️ Note for contributors

Accessibility permission is bound to the binary's cdhash. **Recompiling `sources/winlayout.swift` invalidates the granted permission** and requires re-adding the binary in System Settings. Prefer changing `sources/main.swift`, which needs no permissions.

## Status

Workaround, not a fix. It compensates for a driver defect that should be corrected in DisplayLink Manager. If Synaptics ships a version where the display is recreated on wake, delete this daemon.
