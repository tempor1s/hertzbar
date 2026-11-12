# HertzBar

A tiny macOS menu bar app that applies a custom **EDID override** to an external display on **Apple Silicon**. You can use it to unlock refresh rates (or other modes) that macOS won't offer from the monitor's factory EDID.

It ships with a worked example: a **Dell U4025QW** (5120×2160, 120 Hz panel) on an **M1 Max** MacBook Pro. macOS only offers 60 Hz there; with HertzBar it runs at **100 Hz with 48–100 Hz VRR**.

## Why this is needed

macOS picks display modes from the timings listed in the monitor's EDID. If the monitor's high-refresh timing needs more pixel clock than your Mac's display engine can produce, macOS drops it entirely, even when a slightly slower timing would work. The U4025QW's 120 Hz timing needs **1485 MHz**; the M1 Max tops out somewhere around **1330–1365 MHz**, so you get 60 Hz.

The fix is to give macOS an EDID that also lists a timing the Mac *can* drive, such as 100 Hz at about 1196 MHz.

## How it works

On Apple Silicon there are no display override plists any more. Instead, HertzBar uses an undocumented IOKit call on the external display's `DCPAVServiceProxy` service:

```c
IOAVServiceSetVirtualEDIDMode(avService, &(uint32_t){1}, edidData); // use this EDID
IOAVServiceSetVirtualEDIDMode(avService, NULL, NULL);               // back to factory
```

The override lasts until the display re-probes (sleep/wake, replug, KVM switch, input change). HertzBar watches for those events and re-applies it, and macOS then restores your saved resolution and refresh rate.

Details worth knowing:

- **Matching**: a profile is only applied to a display with the same EDID vendor and product ID, so a profile for one monitor will never be pushed to a different one.
- **Serial numbers**: profiles ship with the serial blanked. At apply time HertzBar copies the serial from the connected monitor's real EDID, so macOS still sees "the same display" and keeps its settings.
- **Idle Macs**: the display pipeline only finishes re-probing once there's user activity, so HertzBar briefly declares activity after applying (like `caffeinate -u`).

## Install

Apple Silicon, macOS 13+. Needs only the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/tempor1s/hertzbar.git && cd hertzbar
./build.sh
cp -R build/HertzBar.app /Applications/ && open /Applications/HertzBar.app
```

On first run it adds itself as a login item. Once the override is active, pick the refresh rate in **System Settings → Displays**. If you see both a "Variable" and a fixed rate, the fixed one gives smoother cursor movement.

## Menu

- Status (override active or not) and the current mode
- **EDID Profile**: the bundled examples, or **Custom** after importing your own
- Apply override / Restore factory EDID
- Auto-apply on connect/wake (on by default)
- Launch at login
- Import override EDID… (any raw `.bin` / `.edid`)

## Make a profile for your monitor

1. Dump the factory EDID and look at its timings:
   ```bash
   H=/Applications/HertzBar.app/Contents/MacOS/HertzBar
   $H --reset            # make sure you're looking at the factory EDID
   $H --dump > factory.edid
   python3 tools/edid_timing.py show factory.edid
   ```
   `show` lists the DisplayID timings and the pixel clock each needs. If it finds none, your monitor keeps its timings in a different part of the EDID, which this tool doesn't edit yet; a GUI EDID editor will work instead.
2. Add a timing your Mac can drive, starting conservatively:
   ```bash
   python3 tools/edid_timing.py add factory.edid mine.edid --width 5120 --height 2160 --hz 100
   ```
   It uses reduced blanking by default (`--hblank 80 --vblank 62`). If the monitor shows no picture, raise `--vblank`.
3. In the menu, choose **Import Override EDID…** and pick `mine.edid`. HertzBar checks the vendor/product ID matches, then applies it.
4. If something goes wrong, unplug and replug the monitor (that always restores the factory EDID) and choose **Restore Factory EDID**.

To share a profile without your monitor's serial: `python3 tools/edid_timing.py scrub mine.edid shareable.edid`.

## The Dell U4025QW example: how high can an M1 Max go?

These were tested by adding reduced-blanking timings and checking which ones macOS offers:

| Timing | Pixel clock | Offered by macOS on M1 Max? |
|---|---|---|
| 100 Hz (bundled default) | 1195.75 MHz | ✅ incl. "looks like 3840×1620" HiDPI |
| 110 Hz, reduced blanking | 1270.98 MHz | ✅ largest HiDPI backing 6720×2836 |
| 115 Hz, reduced blanking | 1328.76 MHz | ✅ largest HiDPI backing 6720×2836 |
| 120 Hz, reduced blanking | 1386.53 MHz | ❌ |
| 120 Hz, minimal vblank | 1366.56 MHz | ❌ |
| 120 Hz (factory) | 1485.00 MHz | ❌ |

The 110/115 Hz profiles are bundled as **experimental**: macOS offers them, but whether the monitor's scaler locks onto the tighter blanking hasn't been confirmed by eye. Macs with newer display engines (M3 and later, Pro/Max chips) may not need any of this.

## CLI

```bash
H=/Applications/HertzBar.app/Contents/MacOS/HertzBar
$H --status                  # EDID state + current mode
$H --apply [file.edid] [--force]
$H --reset                   # restore the factory EDID
$H --modes                   # refresh rates at the current resolution
$H --dump > current.edid     # raw EDID the display currently reports
$H --login-status
```

## Caveats

- This relies on private, undocumented Apple APIs. A macOS update could break it.
- Only one app should manage EDID overrides at a time. Quit other display utilities that do the same thing.
- An EDID the monitor can't actually display gives you a black screen until you replug it. Start with conservative timings.

## License

MIT
