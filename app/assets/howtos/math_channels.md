# Math Channels

Math channels let you create derived signals by writing expressions over the raw sensor channels. Results are computed on demand and can be plotted alongside raw data in the Analyze tab.

## Opening the editor

Switch to the **Maths** tab. Tap **+** to create a new channel. The editor opens with a blank expression and the channel metadata bar at the top.

## Writing an expression

Type your expression in the text area. Raw channels are referenced by name in square brackets, for example `[IMU0_AccelZ]`. You can insert channel names, functions, and constants using the panels on the right (or the tabbed panel on narrow screens).

**Example expressions:**

| Expression | What it computes |
|---|---|
| `integrate([IMU0_AccelZ])` | Fork velocity (mm/s) from Z-axis accelerometer |
| `integrate(integrate([IMU1_AccelZ]))` | Shock travel (mm) via double integration |
| `[GPSSpeed] * 3.6` | GPS speed converted to km/h |
| `[IMU0_AccelX]^2 + [IMU0_AccelY]^2` | Lateral + longitudinal G squared |

## Setting metadata

Use the **Quantity** and **Units** dropdowns to declare what the channel measures. The default unit is set automatically based on your unit system preference (Settings → Units). Set **Rate** to the expected output sample rate in Hz, and **Decimals** for display rounding.

## Preview

The preview plot updates 500 ms after you stop typing. It shows the result of evaluating the expression over the currently selected session. Validation errors appear inline below the expression area.

## Using math channels in Analyze

Once saved, the channel appears in the channel picker when adding a chart in the **Analyze** tab. Math channels are evaluated lazily — the expression is stored, not the computed values, so they update if you modify the expression later.
