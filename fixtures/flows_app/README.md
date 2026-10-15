# flows_app

A glint fixture of small, real-world flows, each written in a different Flutter style so glint is tried against the variety of codebases it meets. The screens follow real apps on Mobbin (Wise, Wealthsimple and KOHO for sending money; Careem and inDrive for rides; Plenty of Fish and Cleo for verification).

| Flow | Style | What it exercises |
|---|---|---|
| Send money | Riverpod, go_router sub-routes | contact search, a keypad of gesture detectors (no buttons), PIN dots, success screen with Updates / Details tabs |
| Book a ride | flutter_bloc (Cubit) | a painted map, a draggable sheet of ride cards, fare stepper, searching then a driver card, star rating |
| Verify phone | ValueNotifier, no packages | country code in a Cupertino picker, six one-digit code boxes that move focus, resend countdown, a step checklist |
| Chat | GetX, Cupertino widgets | reversed bubble list, long-press action sheet, swipe to delete, typing indicator, a reply notification while the app is in the background |
| Checkout | setState, Navigator 1 | a large collapsing sliver app bar, quantity steppers, promo code error, payment radio group, a payment that fails once then succeeds |

The app shell is a go_router `StatefulShellRoute` with Flows and Activity tabs, so every flow runs inside a nested navigator.

Codes to finish the flows: the PIN is `2468`, the verification code is `482913`, the promo code is `GLINT10`.

Notifications: Amara replies 6 s after you send a message. If the app is in the background by then, the reply arrives as a local notification (flutter_local_notifications) with Reply and Mark as read. Tapping it opens the chat, Reply opens it with the message quoted, and Mark as read logs to Activity and opens that tab. iOS suspends a backgrounded app, so there the timer only fires once the app comes back; test iOS notifications with `notifications op:send`, which posts a push with the same `message` category.
