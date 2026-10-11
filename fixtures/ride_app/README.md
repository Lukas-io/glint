# ride_app

A glint fixture for location, built like a ride-hailing app: google_maps_flutter and geolocator.

The screen is a Google map with a "You" marker at the device position, a pickup and drop-off with the trip route between them, and a pickup zone. Underneath are the status, the location permission and accuracy, the trip line, the position, the update count, speed and heading, so a test can see every fix the app receives. Try again asks for location again.

## Rider and driver

The app bar switches between Rider and Driver. A driver sends each position to a relay on the host; a rider polls the relay every second, shows a Driver marker and says how far away it is, then "Driver arrived" within 50 m of the pickup. Start the relay before both apps:

```bash
dart run relay/relay.dart        # listens on :8790
```

The Android emulator reaches the host at `10.0.2.2:8790` and the iOS simulator at `127.0.0.1:8790`. For a phone, build with `--dart-define=RELAY=<host ip>:8790`. `curl -X DELETE http://127.0.0.1:8790/driver` forgets the driver.

The Maps API key is the placeholder `no-key`, so the map tiles stay blank. glint reads markers and the camera from the Dart side, so that does not matter for tests. For real tiles, put a key in `android/app/src/main/AndroidManifest.xml` and `ios/Runner/AppDelegate.swift`.
