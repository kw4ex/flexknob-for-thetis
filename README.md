# FlexControl Knob for Thetis

Version 1.0.0 · by KW4EX

Use the **FlexRadio FlexControl USB tuning knob** with **Thetis, Thetis HL2 and SDR-VST3** — no amplifier needed. A small stand-alone program for Windows 10/11 with its own installer.

It is the knob part of the [KPA1500 Thetis Bridge](https://github.com/kw4ex/kpa1500-thetis-bridge), for operators who have the knob but not the Elecraft KPA1500 amplifier.

## Download

**[FlexKnob_for_Thetis_v1.0.0.zip](https://github.com/kw4ex/flexknob-for-thetis/raw/main/FlexKnob_for_Thetis_v1.0.0.zip)** (about 165 KB). Step-by-step instructions: [READ ME FIRST (PDF)](docs/READ%20ME%20FIRST%20-%20FlexControl%20Knob%20for%20Thetis%20v1.0.0.pdf).

## Install (short version)

1. Plug in the knob. In Thetis turn on the TCI server (127.0.0.1:50001) and close Thetis.
2. Download the zip, right-click it, **Extract All…**.
3. Open the folder and double-click **1_RUN_THIS_Installer.bat**. Press Enter to accept the answer in [brackets].
4. Open http://127.0.0.1:8090 in your browser to see what the knob does and to choose what each press does.

The full, click-by-click guide (including how to turn the knob off in the KPA1500 Thetis Bridge if you have it) is in the PDF and in `README_Install.txt` inside the zip.

## What it does

- Turn the knob: tunes VFO A. Presses switch it to VFO B, AF volume, AGC gain, RIT, XIT, tuning step or TX drive; the three lights on the knob show which.
- 12 presses (knob press and buttons 1–3 × tap / double / long), each one programmable.
- A panel in your browser, and an optional window inside Thetis, show what the knob does right now.

Starting settings:

| Press | Tap | Double tap | Long press |
|---|---|---|---|
| Knob press | AF volume ⇄ VFO A | Mute | Back to VFO A |
| Button 1 | AF volume ⇄ VFO A | AGC gain ⇄ VFO A | Mute |
| Button 2 | VOX | Tuning step larger | Tuning step smaller |
| Button 3 | TUNE (transmits!) | Band up | Band down |

## Needs

Windows 10/11 · Thetis 2.10.3.12+ (HL2 2.10.3.15+, or SDR-VST3 5.x) with TCI on · Python 3.8+ and pyserial (the installer sets them up).

Only one program can use the knob at a time — close DDUtil, and switch off the knob in the KPA1500 Thetis Bridge if you have it (the installer helps).

## No warranty — use at your own risk

This program is shared by one radio operator, **as is**. There is **no warranty of any kind**: no promise that it works, that it is safe, or that it suits your equipment or your purpose. Amplifiers, radios and antennas can be damaged, and RF can be dangerous. TUNE and MOX on the knob really transmit. You are responsible for checking that it behaves correctly with your own station, and for operating within your license. The author is not liable for any damage or loss. It is not made, approved or supported by FlexRadio, Thetis, Thetis HL2 or SDR-VST3. Licensed under the MIT License (see LICENSE.txt).

"FlexRadio", "FlexControl" and "Thetis" are names of their owners; this is an independent, community-made program.

## License

[MIT](LICENSE) © 2026 KW4EX
