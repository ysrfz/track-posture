# TrackPosture

A menu bar app that watches your posture through the built-in camera and fades a soft amber glow onto the screen edges when you've been slouching for a while. Nothing shows while you sit well; the glow disappears the moment you correct. Everything runs on-device with Apple's Vision body-pose model.

## How it works

On calibration it records three numbers from your nose and shoulder positions while you sit up straight:

| Signal | Measures | Bad when |
|---|---|---|
| height | nose height above the shoulder line ÷ shoulder width | below 90% of baseline (slouch / head drop) |
| width | apparent shoulder width | above 115% of baseline (leaning in) |
| tilt | shoulder line angle | more than 8° off baseline (sideways lean) |

Once flagged, you have to recover half of each tolerance to clear it, so hovering at the boundary doesn't restart the timer. After 10s of continuous bad posture the glow appears at 15% opacity and ramps to 40% over 30s. It works over fullscreen apps, shows on every display, and is excluded from screen sharing.

The camera stops while the screen is locked or the app is paused. Time away from the desk isn't counted.

## Build

Requires the Xcode Command Line Tools.

```bash
./build.sh
```

This compiles `main.swift`, assembles an ad-hoc signed `TrackPosture.app` into `~/Applications`, and launches it. It registers itself as a login item on first launch. Because the signature is ad-hoc, macOS may ask for camera access again after a rebuild.

## Tuning

Thresholds are constants at the top of `main.swift`. To see live values against your baseline:

```bash
pkill -x TrackPosture; open --stdout $(tty) --stderr $(tty) ~/Applications/TrackPosture.app --args --debug
```

## Stats

The menu shows today's upright percentage and alert count. One row per day is appended to `~/Library/Application Support/TrackPosture/history.csv` when the day rolls over.
