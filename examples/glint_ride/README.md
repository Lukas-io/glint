# glint Ride

A two-phone ride demo for glint. Ada rides on one simulator, Tunde drives on another. One prompt to an agent drives Tunde's GPS down the app's own route, and both phones update live.

![glint Ride: rider and driver phones at the pickup](../../docs/media/glint-ride.png)

- **Rider:** Tunde's car glides along the road, the road behind it turns grey, and a live bar counts down distance, speed, minutes and arrival time.
- **Driver:** a heading-up navigation view, turn-by-turn directions, the same live bar, and the Arrived, Start trip and End trip buttons.
- **Sheet:** a floating sheet on both phones. Drag it up or tap the handle for the full card.

The route is real: four turns through Lekki Phase 1, Lagos, to a pickup on Admiralty Way. It's about 1.7 km.

## Run it

1. Put the Maps keys in git-ignored files:
   - `ios/Flutter/Secrets.xcconfig`: `MAPS_API_KEY=<iOS key>`
   - `android/local.properties`: `MAPS_API_KEY=<Android key>`
2. Start the rider first. It hosts the link on port 8787, and the next phone to start becomes the driver.

   ```bash
   flutter run -d <first iPhone simulator>    # rider
   flutter run -d <second iPhone simulator>   # driver
   ```

   An Android emulator always drives, and reaches the rider at `10.0.2.2:8787`. To change the host, pass `--dart-define=RIDER_HOST=<ip>`. Pass `--dart-define=ROLE=rider|driver` to pick a role. Pass `--dart-define=SIM=true` to drive the route without GPS.

## Drive it with glint

With both apps attached, give your agent one prompt: *"Drive Tunde to Ada's pickup. Tell me when her app says he's there."* It runs:

1. `location op:route polylineId:route speedKmh:70 maxSpeedKmh:100` on the driver. glint drives the route the app draws on its map (polyline id `route`), with speed that varies between 70 and 100 km/h and slows for each turn.
2. `location op:wait until:arrived`, which reports progress every 15 s.
3. `tap text:"Arrived"` on the driver.
4. `get_scene` on the rider, which now reads "Tunde is here".

## Credits

The car marker is rendered from "Car Concept" in the Khronos glTF Sample Assets (CC BY 4.0), repainted silver. Instrument Sans is under the SIL Open Font License. Icons are from Lucide (ISC). See `assets/CREDITS.txt`.
