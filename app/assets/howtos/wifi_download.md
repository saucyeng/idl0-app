# WiFi Download

The IDL0 device hosts its own WiFi access point so you can download sessions without an internet connection. This guide covers connecting to the device AP and transferring files.

## 1. Enable WiFi on the device

From the **Device** tab, tap **WiFi On**. The device starts the access point — the SSID is `IDL0-XXXXXX` and the password is printed on the device label (or shown in the BLE status panel).

## 2. Join the device network on your phone

On Android, go to **Settings → WiFi** and connect to the `IDL0-XXXXXX` network. You may see a "No internet" warning — this is expected. Keep the connection active.

## 3. Download sessions

Switch to the **Runs** tab. The Download panel automatically discovers the device and lists available sessions on the SD card. Tap a session to select it, then tap **Download**. A progress bar shows bytes transferred in real time.

## 4. Verify the download

Once complete, the session appears in the Session Library. Tap it to confirm the metadata (date, duration, channel count) looks correct before disconnecting from the device AP.

## 5. Rejoin your regular network

After downloading, return to **Settings → WiFi** on your phone and reconnect to your regular network. The app continues to work with the downloaded data offline.

## Troubleshooting

- **Device not listed:** Confirm the device LED is solid blue (AP mode active) and your phone is connected to the correct SSID.
- **Download stalls:** The file transfer retries automatically up to three times. If it continues to fail, check that the phone has not switched back to cellular data mid-transfer.
- **Large sessions:** A 1-hour session at default settings is approximately 155 MB. Downloads typically complete in under 30 seconds on a good WiFi link.
