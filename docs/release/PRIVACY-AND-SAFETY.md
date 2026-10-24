# HPC Whisper: privacy and safety

**What the apps do and do not do**

- The Android app has **no internet access** (it declares no network permission). Nothing you type is sent to any server.
- The phone **listens through the microphone only while the HPC Whisper keyboard is open**, and only to decode the handheld's sound. The log's 30 seconds of sound are kept on the phone until you clear them (Settings, Troubleshooting) or share them yourself.
- What arrives from the handheld is kept on the phone as dated sessions, and you can switch that off (Settings, Saved sessions, Keep what arrives) or delete them.
- The optional **helper** is an Android accessibility service. It is off until you turn it on. It does only what the handheld asks (press Send, Back, Home, Recent apps), reads nothing and keeps nothing.
- The app asks for the microphone, and for vibration only for the optional "Buzz when text arrives" setting (off by default).
- The handheld program stores only its settings, in a small file next to the program.

**What to be aware of**

- **Sound is not private.** The text travels through the air. Anyone close enough with a microphone and the (published) format could decode it. Do not type passwords or anything secret.
- The tones are in the range of about 18 to 21.5 kHz. Most adults cannot hear them; some young people, dogs and cats can. Lower the Volume setting if it bothers anyone.
- The sound is not harmful at the volume of a handheld's small speaker; keep the volume modest anyway.
- Keep the phone's media volume up for the optional return channel: the phone plays a short, silent-to-most confirmation sound.
- The Android app is signed with a key that is in the repository on purpose (so new builds install over old ones). That means anyone can build an app that looks the same; **get it only from the official release page**.
