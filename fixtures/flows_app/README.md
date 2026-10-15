# flows_app

A glint fixture of small, real-world flows, each written in a different Flutter style so glint is tried against the variety of codebases it meets. The screens follow real apps on Mobbin (Wise, Wealthsimple and KOHO for sending money; Careem and inDrive for rides; Plenty of Fish and Cleo for verification).

| Flow | Style | What it exercises |
|---|---|---|
| Send money | Riverpod, go_router sub-routes | contact search, a keypad of gesture detectors (no buttons), PIN dots, success screen with Updates / Details tabs |
| Book a ride | flutter_bloc (Cubit) | a painted map, a draggable sheet of ride cards, fare stepper, searching then a driver card, star rating |
| Verify phone | ValueNotifier, no packages | country code in a Cupertino picker, six one-digit code boxes that move focus, resend countdown, a step checklist |
| Chat | GetX, Cupertino widgets | reversed bubble list, long-press action sheet, swipe to delete, typing indicator |
| Checkout | setState, Navigator 1 | a large collapsing sliver app bar, quantity steppers, promo code error, payment radio group, a payment that fails once then succeeds |

The app shell is a go_router `StatefulShellRoute` with Flows and Activity tabs, so every flow runs inside a nested navigator.

Codes to finish the flows: the PIN is `2468`, the verification code is `482913`, the promo code is `GLINT10`.
