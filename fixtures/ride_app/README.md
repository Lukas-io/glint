# ride_app

A glint fixture for location, built like a ride-hailing app: google_maps_flutter and geolocator.

The screen is a Google map with a "You" marker at the device position, plus the status, position, update count, speed and heading underneath, so a test can see every fix the app receives.

The Maps API key is the placeholder `no-key`, so the map tiles stay blank. glint reads markers and the camera from the Dart side, so that does not matter for tests. For real tiles, put a key in `android/app/src/main/AndroidManifest.xml` and `ios/Runner/AppDelegate.swift`.
