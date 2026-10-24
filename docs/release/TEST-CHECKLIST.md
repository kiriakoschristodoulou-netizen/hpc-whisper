# HPC Whisper 1.2: test checklist before publishing

Fill in as you go. Mark each line OK / FAIL / n.a. and write what you saw. Run the block with the return channel **off** and again with it **on** (both sides), as marked ◐.

**Devices:** handheld ______ phone ______ Android ______ date ______

## A. Fresh install
- [ ] A1 Phone: install the APK on a phone that never had it; the three steps work, wording clear
- [ ] A2 Handheld: copy the folder, run after a reboot; the title bar says it is ready
- [ ] A3 Type a sentence in notes, a browser search box, a chat app, a multi-line field; text identical ◐

## B. Reliability
- [ ] B1 Long text, about 1,000 characters, wait a minute, compare with the original ◐
- [ ] B2 Edits: Backspace, Ctrl+Backspace, retype, arrows, Ctrl+A C X V Z Y: no leftover or missing characters ◐
- [ ] B3 Accents, Greek and symbols (é, ü, α, €, emoji if you use them) ◐
- [ ] B4 Fast typing for one minute, then stop: it settles completely ◐
- [ ] B5 With talking and music in the room ◐
- [ ] B6 Distance: 30 cm / 1 m / 2 m, phone facing the speaker; note where it starts failing ______
- [ ] B7 Phone face-down, in a pocket, in a case: note the result ______

## C. Return channel (both sides on)
- [ ] C1 Type, stop: the handheld says Delivered
- [ ] C2 Stop typing for 40 s: still Delivered, no pop-ups, nothing odd on the phone
- [ ] C3 Cover the phone's microphone 20 s while typing, then uncover: it catches up, nothing left over
- [ ] C4 One side on, the other off (both ways): text still arrives
- [ ] C5 Restart the keyboard on the phone mid-text; switch apps; lock the screen; take a call: it resumes or fails with a clear message
- [ ] C6 Handheld battery: 30 minutes idle with the program running, return channel on and off; note the loss ______

## D. Enter key and Send
- [ ] D1 Enter key set to "Sends the message": test in three chat apps ______ ______ ______
- [ ] D2 Shift+Enter gives a new line; Alt+S sends
- [ ] D3 Helper off: what happens in an app with no Send key? (clear, not silent)
- [ ] D4 Helper on: Send, Back, Home, Recent apps all work

## E. Handheld
- [ ] E1 Settings: change volume, speed, band, sound rate, repeats; they stick after Quit and restart
- [ ] E2 Run for an hour: no crash, sound does not drop out
- [ ] E3 A second Jornada 720 or other Windows CE ARM device (if you can): result ______

## F. Other phones
- [ ] F1 A second Android phone of another brand / older Android version: setup and typing ______
- [ ] F2 iPhone: the receiver page (index.html on the site): receives text, Copy and Share work

## G. Mic Scan / Return Test / Duplex Test
- [ ] G1 They run and save their reports on a second handheld (if you have one)

## H. Before you post
- [ ] H1 The release has the APK, the handheld zip, the checksums and the version number everywhere the same (About, app Settings, file names)
- [ ] H2 README, user guide and troubleshooting are on the repository's front page
- [ ] H3 Decide the licence for the code and add a LICENSE file
- [ ] H4 A demo video or GIF recorded
- [ ] H5 Read the forum's rules for posting software
- [ ] H6 Screenshots taken (see SCREENSHOTS-AND-VIDEO.md)
