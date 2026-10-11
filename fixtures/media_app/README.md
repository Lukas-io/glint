# media_app

A glint fixture for audio checks. One screen with three buttons:

- **Record 3 s** records the microphone and shows the loudest level it heard.
- **Play recording** plays that recording back.
- **Play beep** plays a bundled one-second 1 kHz tone.

`media op:listen` is checked against Play beep: it should report about one second of sound. Android needs the `RECORD_AUDIO` permission for Record (`media op:permission permission:microphone action:grant`).
