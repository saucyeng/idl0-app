# GPS Lap Gate

A GPS lap gate lets the app automatically detect each time you cross the start/finish line, splitting your run into individual laps with accurate timing.

## How it works

You define a short line segment on the map (the "gate") by placing two GPS coordinates. The app detects each crossing using flat-earth segment intersection math applied to the GPS track recorded by the device.

## 1. Open a session in the Analyze tab

Select a session in the **Runs** tab, then switch to the **Analyze** tab. The session GPS track is visible on the GPS Map chart.

## 2. Place the gate

Open the session's workspace editor (tap the edit icon in the Analyze tab). In the Lap Gate section, tap **Place Gate**. Tap two points on the map to define the gate line — place them across the track at your preferred start/finish location.

## 3. Choose a lap mode

- **Circuit:** The gate is the start/finish line. Each crossing ends one lap and starts the next.
- **Point-to-point:** The gate is the start only. Use this for stages where the finish is elsewhere.

## 4. Apply and review

Tap **Apply**. The app re-detects laps automatically. Lap times appear in the **Lap Table** beneath the charts in the Analyze tab. The fastest lap is highlighted.

## Tips

- Place the gate on a straight section of track where GPS accuracy is highest.
- Avoid placing it in wooded sections where GPS signal may drift.
- If laps are not detected, confirm the GPS track passes through the gate line — zoom in on the GPS Map chart to verify alignment.
