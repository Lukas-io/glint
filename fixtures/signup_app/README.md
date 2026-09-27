# Ember signup fixture

A dating app signup flow with planted bugs, for benchmarking agents on a realistic task. Eight steps: account, email code, name and birthday, preferences, photos, interests, prompts, review, then a welcome screen.

The finished profile is printed to the log as one line: `EMBER_PROFILE {json}`. Review rows carry `Semantics(identifier: 'review_<label>')` so tests can address them.

## Real gates (not bugs)

Each shows an honest error:

- a valid email, a password of 8+ characters, and the terms box;
- the 6-digit code `482915` (shown in a mail banner);
- a first name and an age of 18+;
- one "I am" and one "Show me" choice;
- at least one photo;
- at least 3 interests.

## Planted bugs

| Id | Page | Kind | Bug |
| --- | --- | --- | --- |
| B1 | Welcome | dead | "Continue with Google" ripples and does nothing |
| B2 | Account | misleading | The password eye icon flips, but the password stays hidden |
| B3 | Account | misleading | The strength meter says "Strong" for any password, even one character |
| B4 | Code | dead | "Resend code" looks like a link and is not tappable |
| B5 | Birthday | misleading | "you are N" is a year too young when the birthday has already passed this year |
| B6 | Preferences | dead | The "Non-binary" pill never selects |
| B7 | Photos | dead | "Skip for now" does nothing |
| B8 | Interests | misleading | The counter lags one behind ("2 of 3 picked" with 3 picked) |
| B9 | Prompts | blocking, skippable | "Done" does nothing; only "Skip" moves on, and the answer is lost |
| B10 | Review | dead | Every "Edit" link does nothing |
| B11 | Review | misleading | Distance is shown in miles after being chosen in km |
| B12 | Review | misleading | The notifications switch shows the opposite of the real setting; the text under it tells the truth |
