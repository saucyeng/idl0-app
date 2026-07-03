# First Setup

Welcome to IDL0. This guide walks you through pairing your device for the first time and recording your first session.

## 1. Power on the device

Hold the button on the IDL0 unit for two seconds until the LED flashes blue. The device begins advertising over BLE immediately.

## 2. Connect via Bluetooth

Open the **Device** tab in the app. Tap **Scan** and select your device from the list — it appears as `IDL0-XXXXXX` where the suffix is the last three bytes of the device MAC address. Once connected, the battery level and firmware version appear at the top of the tab.

## 3. Push a configuration

The device ships with a default configuration. Review the settings in the config editor — bike profile, IMU sample rate, GPS rate, and wheel speed — then tap **Push Config** to send it. Config is sent over WiFi: the app opens the device access point automatically, pushes the JSON, and reconnects BLE.

## 4. Calibrate the IMUs

Mount the device on your bike in its final orientation, then tap **Calibrate IMUs** on the Device tab. Hold the bike stationary on a level surface when prompted. Calibration captures the gravity vector and computes a rotation matrix that maps sensor body frame to vehicle frame (X=forward, Y=left, Z=up). The result is stored on the device and applied to all future recordings.

## 5. Record your first session

Tap **Start Recording** on the Device tab. Ride normally. Tap **Stop Recording** when finished. The session is written to the SD card and is ready to download.

## 6. Download the session

Switch to the **Runs** tab and tap **Connect** in the Download panel to join the device access point. Tap the session file and tap **Download**. Once downloaded, the session appears in your session library and is ready for analysis.
