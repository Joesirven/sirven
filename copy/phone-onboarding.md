# Phone onboarding: every word the owner sees

Draft for Jose's review, in the same format as `copy/consent-moment.md`: each `## key`
heading is one piece of text the owner reads, `>` lines are notes that never reach the
owner, and words in braces are filled in at the moment.

The moment comes once a day at most: the first time the owner opens a phone session that
day (`sirven phone allow`) with a trusted iPhone plugged in. sirven offers, and the owner
decides. Nothing is mapped until the owner types yes.

> The command line prints `onboarding.offer` and the question in `onboarding.ask` today.
> The other keys are the words for the app's onboarding screen and for the docs.

## onboarding.offer
First connection today: map your ride apps so your agent knows where to look? sirven phone onboard

## onboarding.ask
Map your iPhone's home screens and the {apps} apps, so your agent knows where to look? sirven only looks and taps through menus: it never types, buys, sends, or keeps a screenshot.

## onboarding.what.title
What mapping does

## onboarding.what.body
sirven reads the names of the apps on your home screens, then opens {apps} and taps through their menus to learn which screen is which and where the main buttons are. Your agent uses that map to find its way, instead of searching the screen every time.

## onboarding.never.title
What it never does or keeps

## onboarding.never.body
It never types, never taps anything that could spend money, book, send, delete, or sign you out, and it stops at once if your phone shows its own Apple Pay approval. It keeps no screenshots, nothing you have typed, no messages or other text from the screen, and nothing from a sign in screen: only a count of the sign in screens it skipped.

## onboarding.prices.body
Ride options keep their shape, not their numbers: "UberX, 4 min away, $18.40" is kept as "UberX, # min away, $#.#".

## onboarding.where.body
The map stays on this Mac, in your phone folder, readable only by you. Your agent reads it only while a phone session is open.

## onboarding.done.title
Your phone is mapped

## onboarding.done.body
{summary}. Every step it took is in sirven phone log.

## onboarding.stopped.body
Mapping stopped: {reason}. What it learned so far is kept. Run sirven phone onboard again when your phone is free.

## onboarding.see.label
See the map

## onboarding.see.body
sirven phone map shows every app, screen, and button it knows, in plain words. Add --json for the raw file.

## onboarding.refresh.label
Map again

## onboarding.refresh.body
sirven phone onboard --refresh maps your apps again from scratch, for when an app has changed. Add --app with a name, as often as you like, to choose which apps.

## onboarding.prune.label
Forget an app

## onboarding.prune.body
sirven phone map prune {app} forgets everything about one app. Add a screen to forget only that screen.
