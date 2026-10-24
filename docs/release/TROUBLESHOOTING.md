# HPC Whisper: troubleshooting

| What you see | What to try |
| --- | --- |
| Nothing appears on the phone | The HPC Whisper keyboard must be the one in use (switch with the keyboard picker) and the microphone allowed. Hold the phone within a metre of the handheld's speaker. Raise the handheld's volume in Settings. |
| "Weak signal" on the phone | Move the phone closer, microphone toward the speaker. Remove a case that covers the microphone. Try Settings, Speed: Normal. |
| "Waiting for a missing piece" | Wait a few seconds: it fills in by itself. If not, press Alt+R on the handheld. A piece still missing after half a minute is given up so it cannot hold up the text after it. |
| Some text is missing or left over | Press Alt+R. Turn on the return channel on both sides (handheld Settings, Return channel; phone Settings, Confirm to the handheld): it checks the whole page every 30 s. Report it with the phone's log (below). |
| Handheld: "No sound device found" | The sound device could not be opened. Close other programs that play or record sound and start again. |
| Handheld: "The sound device would not open at ... samples/s" | Settings, Sound rate: try 44,100. |
| Return channel: "On, but No microphone found" | This handheld has no microphone it can use. Everything still works as with the return channel off. |
| Return channel: "On, but The microphone would not open" | Another program has the microphone, or the sound rate does not match; try Settings, Sound rate: 44,100, and restart the program. |
| The handheld does not show "Delivered" | The phone is not answering: check that Confirm to the handheld is on, the keyboard is open on the phone, and the phone is close. Without answers the handheld simply repeats as set. |
| Enter does not send a message | Set Settings, Enter key to "Sends the message" and turn on the helper in the phone's accessibility settings, or use Alt+S. The app's field may have no Send key. |
| Send / Back / Home do nothing | They need the helper (the phone's accessibility settings). |
| Sound is audible or annoying | Lower Volume in Settings. Some people, children and pets hear the top of the range. |
| A wrong letter appears now and then | Press Alt+R. If it happens often, move closer, reduce background noise and try Speed: Normal. |
| It does not run on my handheld | It needs an ARM processor and Windows CE 3.0 or later. MIPS and SH3 machines (Jornada 680 and 690 and others) are not supported. |

## Sending the phone's log

In the phone app: Settings, Troubleshooting, **Share the log**. It is a zip with a text record of what the phone heard and the last 30 seconds of sound. It contains what the microphone heard in that time, which may include conversation in the room, so share it only if you are comfortable with that. Right after a problem is the best time to share it.
