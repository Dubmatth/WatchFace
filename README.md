# Fenix Tactical — Garmin watch face

![Connect IQ](https://img.shields.io/badge/Garmin-Connect%20IQ-007CC3?logo=garmin&logoColor=white)
![Monkey C](https://img.shields.io/badge/language-Monkey%20C-orange)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

A tactical / outdoor watch face for the **Garmin Fenix 9 Pro**, written in Monkey C with the Connect IQ SDK.

<!-- Add a simulator screenshot here: docs/screenshot.png -->

## Features

- **Large time** with date, in the condensed style of a field watch
- **Graduated bezel** with cardinal letters (N / E / S / W)
- **Live compass heading** marker on the bezel, plus the heading label (e.g. `NE`)
- **Complications**: battery, temperature, altitude, sunrise & sunset
- Respects the device's **unit settings** (°C/°F, m/ft) and 12/24h format
- **Low-power mode** support (sleep / wake)
- Dark, high-contrast palette — burnt orange accent and olive tones

## Design process

The face was designed as HTML mockups first, then ported pixel by pixel to the watch:

| Mockup | Idea |
|---|---|
| `Main.dc.html` | Final approved design |
| `Minimaliste.dc.html` | Minimal variant |
| `DataDense.dc.html` | Data-dense variant |
| `VariantCompass.dc.html` | Compass-centric |
| `VariantTicks.dc.html` | Emphasis on bezel ticks |
| `VariantAsym.dc.html` | Asymmetric layout |

Colors were converted from the mockup's `oklch()` values to the closest sRGB hex values, and Oswald was replaced by the closest system font available on the device (Roboto Condensed).

## Performance

Watch faces run on a tight power budget, so the rendering is optimized:

- The **bezel ring and cardinal letters are pre-rendered once** into a `BufferedBitmap` in `onLayout`, instead of redrawing 120 line segments with trigonometry every frame.
- **Slow-changing data** (date, battery, temperature, altitude, sun times) is refreshed only every 30 updates; only the compass heading stays live every frame.
- Vector fonts are **cached** per face and size, with a bitmap-font fallback.

## Project structure

```
source/WatchFaceApp.mc    App entry point
source/WatchFaceView.mc   Rendering: bezel, time, heading, complications
resources/                Strings, drawables, launcher icon
manifest.xml              Target devices & permissions
*.dc.html                 Design mockups
```

## Build & run

1. Install the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) and the **Monkey C** VS Code extension.
2. Open the folder in VS Code.
3. `Monkey C: Run` → choose a Fenix 9 Pro device in the simulator.

## License

[MIT](LICENSE)
