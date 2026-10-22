# MyLoom

A menu-bar screen recorder for your Mac, with Loom's four recording modes:
- **Full Screen**
- **Custom Size:** an area you drag out
- **Window:** a single window, with the camera bubble included
- **Camera Only**

The round camera bubble can be moved and resized. It works with your Mac camera, a USB camera or your iPhone, plus any microphone, including a USB mic or the iPhone's, and optionally the sound your Mac is playing, mixed in. Every action can have a keyboard shortcut. When you stop, an `.mp4` is saved to your Movies folder. Nothing is uploaded, unless you set up [sharing](#share-a-recording-as-a-link) with your own Supabase project and choose to share a recording; then you get a link that works for 14 days.

## Set it up with Claude Code

Open Claude Code in the folder where you keep your projects and paste:

```
Clone https://github.com/automatorsplus/my-loom and set it up on my Mac by following its CLAUDE.md.
```

Claude Code builds the echo canceller and the app, runs its self-test and walks you through the permissions. It needs an Apple Silicon Mac on macOS 14 or later, and installs Homebrew's meson and ninja to build the echo canceller. The app is built on your own Mac, so macOS doesn't block it as a download from an unknown developer.

## Requirements

- Apple Silicon Mac, macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`). Xcode itself isn't needed.
- To build echo cancellation the first time: Homebrew's `meson` and `ninja` (`brew install meson ninja`). They're only needed for building, not for running MyLoom.

## Build and run by hand

```sh
./scripts/build-webrtc.sh   # once: builds WebRTC's echo canceller into Vendor/ (about 30 seconds)
./build.sh
open build/MyLoom.app
```

`scripts/build-webrtc.sh` downloads WebRTC's audio processing 2.1 (the freedesktop.org edition used by PulseAudio and PipeWire), checks it against its published SHA-256, and builds it, with the abseil library it needs, into static libraries in `Vendor/webrtc-audio-processing`. Those are built into MyLoom itself, so the app doesn't depend on Homebrew to run.

A record icon appears in the menu bar. There is no Dock icon or window. Everything is in that menu.

## First-time permissions

macOS asks for each one the first time it's needed:

1. **Screen Recording.** This is asked the first time you start a Full Screen, Custom Size or Window recording. Turn on MyLoom under System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen MyLoom. macOS may ask you again from time to time to confirm MyLoom can keep recording the screen. Camera Only doesn't need it, unless **Record Computer Sound** is on.
2. **Camera.** This is asked the first time you choose **Show Camera Bubble** or **Camera Only**.
3. **Microphone.** This is asked when you start a recording with a microphone selected.

If one of these was refused, MyLoom shows a message with a button that opens the right page in System Settings. The build is signed so these grants carry over when you rebuild.

## Use your iPhone as the camera

MyLoom uses Apple's **Continuity Camera**, which is also how Loom gets your iPhone. It needs:

- An iPhone XR or later on iOS 16 or later, signed in to the same Apple Account as the Mac.
- Wi-Fi and Bluetooth turned on, on both devices.
- On the iPhone: Settings → General → AirPlay & Continuity → **Continuity Camera** turned on.

Then:

1. Put the iPhone near the Mac, **locked**, **still** (on a stand or mount) and with its back cameras facing you. A USB cable works too.
2. In MyLoom, open **Camera** and choose your iPhone, for example "Sam's iPhone Camera". If it isn't listed yet, the menu says so; close and reopen the menu after a few seconds.
3. The iPhone's microphone appears under **Microphone** at the same time, if you'd like to use it. Point at it in that submenu to check it's picking you up (see [Check your microphone](#check-your-microphone-before-recording)).

If nothing has been picked under **Camera**, MyLoom uses the camera macOS prefers, which becomes the iPhone by itself once it's ready. If you pick the phone up during a session, the bubble falls back to the Mac's camera. It switches back to the iPhone when you put it down again. **Desk View** (the overhead desk shot) is listed under **Camera** too, when the iPhone offers it.

## Use a USB microphone

Plug it in, then open **Microphone** and choose it by name. MyLoom remembers the choice. The list is read fresh every time you open the menu, so a newly plugged-in mic shows up straight away. The level meter under **Microphone** shows whether it's picking you up.

If the mic is unplugged or disconnects during a recording, MyLoom switches to the Mac's default input so the recording keeps its sound. It tells you after saving. Choose **None** to record without sound.

## Check your microphone before recording

Open the menu and look just under **Microphone**. A live level meter shows the selected mic: its name, a bar that moves as you speak, and a word on how it's going.

- **Picking you up** (green): it hears speech-level sound.
- **Very loud** (red): the bar is in the red, near distortion. Turn the mic's gain down or sit further back.
- **Say something to test**: nothing loud right now, for example while you pause.
- **No audio detected** (orange): nothing speech-level has arrived in 3 seconds. Check the mic is plugged in, unmuted and the right one.

The bar is green for normal speech, yellow when loud, and red near the top. A small tick holds the loudest moment for a second.

**To try another mic without choosing it,** open the **Microphone** submenu and point at a mic. The meter switches to that one: your USB mic, your iPhone's mic (once Continuity Camera has connected it), or the built-in one. Speak, watch the bar, and click the one you want. Pointing at **None** says the recording will have no sound. Closing the submenu brings the meter back to the chosen mic.

The meter only runs while the menu is open and you're not recording. It listens in exactly the format recordings use, 48 kHz mono, so what it shows is what you'll get. The first time, it asks for Microphone access: click **Click to test your microphone**. If access was turned off, clicking it opens the right page in System Settings.

## Record computer sound

Turn on **Record Computer Sound** in the menu, under the microphone meter. Recordings then include what the Mac is playing (a video, a call, an app's sounds) mixed with your microphone into one stereo track. It works in all four modes.

- **No headphones needed.** On speakers, your mic also hears the computer's sound a moment later, which would sound like an echo. **Cancel Echo (No Headphones Needed)**, on by default and shown under Record Computer Sound when a mic is selected, removes it with WebRTC's echo canceller (AEC3), the same one Loom ships. It uses the computer's sound, which MyLoom captures anyway, as the reference, learns how that sound reaches your mic (speaker, room, delay), and subtracts it. Only your mic is processed; the computer's sound is mixed in untouched. Turn it off if you use headphones and want your voice completely unprocessed; the menu then reminds you to wear headphones.
- **Apps, not command-line tools.** macOS hands over sound per app, so sound from apps is recorded, but sound from command-line tools run in Terminal (such as `afplay`) isn't. Tested here: the same tone player was silent as a bare program and recorded perfectly once packaged as an app.
- **Your volume setting doesn't matter.** Sound is taken as each app plays it, before your volume setting. Tested here: a tone at 50% system volume was recorded at the app's full level.
- **MyLoom's own sounds are left out.**
- **Permission:** it uses the same Screen & System Audio Recording permission as screen recording, so Camera Only needs that permission too while this is on.
- **Mixing:** the two are lined up by timestamp and gently limited, so a loud video and your voice together don't distort.

## Choose what to record

The menu has Loom's four modes. The one with the tick is used when you start recording.

- **Screen:** which display Full Screen and Custom Size record. The default is the one with the menu bar.
- **Full Screen:** the whole display.
- **Custom Size…:** a part of the screen. The screen dims and you can:
  - **Drag** anywhere to draw the area. Its video size in pixels shows above it as you go.
  - **Drag inside** the area to move it, or drag any of its **eight handles** to resize it.
  - **Type** an exact width and height in pixels at the bottom, then press Return.
  - Pick a preset: **1080p** (1920×1080), **720p** (1280×720), **Square** (1080×1080) or **Vertical** (1080×1920, for phone-shaped video).
  - Press **Return** or click **Done** to keep it. **Esc** or **Cancel** leaves things as they were.

  Afterwards a dashed outline marks the area on screen. It turns red while recording. The outline sits just outside the area, so it never appears in the video. Choose **Custom Size…** again to change the area, or **Full Screen** to go back. The menu shows the area's video size, for example *Custom Size (1280 × 720)…*.

  On a Retina display one point is two pixels, so a 1280 × 720 video is an area 640 × 360 points across on screen.
- **Window…:** one window. Every screen gets a light overlay: point at a window and it's highlighted, with its app, title and video size shown. Click it to choose it, or press Esc to cancel. The menu then shows the window's name. While recording:
  - **Only that window** is recorded, plus the camera bubble wherever it overlaps it. Other windows in front of it are left out, as in Loom.
  - **A red frame** follows the window. The frame itself isn't recorded.
  - **Moving the window:** the recording follows it, and so does the bubble if it's sitting on the window.
  - **Resizing the window:** the video keeps its size and the window is scaled to fit.
  - **Closing the window:** the recording stops and is saved, and MyLoom tells you.
  - **Turning the bubble on mid-recording:** it's added to the recording.
- **Camera Only:** just the camera, with no screen at all. The bubble becomes a preview in the shape of the movie, so it shows exactly the picture being recorded. Choose the shape under **Recording Shape** before you start:
  - **Landscape** (the default): the camera's own shape, its full picture up to 1080p (1920×1080 for most cameras).
  - **Square:** 1080×1080, from the middle of the picture.
  - **Portrait (9:16):** for phone-shaped video, also from the middle of the picture. From a 1080p camera that's 606×1080: the camera has no more pixels across than that.

  Move and resize the preview like the bubble; **Preview Size** sets its size on screen, not the movie's. Hiding the preview during a recording doesn't stop it.

## Camera bubble

- **Show Camera Bubble** (⌘B while the menu is open, or the global shortcut ⌃⌥⌘B) turns it on and off.
- **Move it:** drag from the middle. Drop it near a corner of what's being recorded (the custom area, the window, or the screen in Full Screen) and it snaps neatly into that corner. Drop it anywhere else and it stays where you left it.
- **Resize it:** point at the edge until a ring in your accent colour appears (the bubble has no border otherwise), then drag outward or inward. Any size from 96 to 720 points works. **Bubble Size** also has Small (160), Medium (240), Large (320) and Extra Large (480). The size is remembered.
- **Shape it:** **Bubble Shape** has **Circle** (the default), **Square**, **Landscape** (the camera's own shape, 1.5 times as wide as the size) and **Portrait (9:16)**, 1.5 times as tall. The last three have rounded corners, like Loom's rounded rectangle. **Next Shape** steps through them. The shape is remembered, separately from Camera Only's. It can change at any time, even while recording the screen.
- **Camera:** switch cameras at any time, even mid-recording.
- **Mirror Camera** (under **Camera**): on by default, so you see yourself as in a mirror. Turn it off to show and record the camera the right way round, for example so writing held up to the camera reads correctly. It applies to the bubble and to Camera Only recordings.

The bubble is part of the screen image, so it's recorded exactly where you see it, as long as it's inside what you're recording. When you choose an area or window, or start a recording, MyLoom moves the bubble inside if it's outside.

## Background effects

**Background** in the menu blurs or replaces what's behind you, as Loom's camera backgrounds do:

- **Blur:** a lens-like blur of the room behind you. **Blur Strength**, the slider under it, goes from just softened (left) to nothing recognisable (right). The bubble follows the slider as you drag it, so you can watch while you set it. It's remembered, and it starts in the middle.
- **Studio, Ocean, Sunset, Evening Lights:** soft backdrops MyLoom draws itself. Loom ships five photos for this, which MyLoom doesn't copy.
- **Color…:** opens the Colors window. The background follows as you pick.
- **Picture…:** any JPEG, PNG or HEIC. It fills the frame, cropped from its middle. MyLoom remembers where the file is, so leave it there. If it goes missing, the camera shows unchanged.
- **Off:** the plain camera.

The effect is in the bubble, so it's in every screen recording, and it's in Camera Only recordings too. You can change it in the middle of a recording. The **Background Effect On / Off** shortcut switches between Off and the last effect you chose (Blur at first). It isn't set until you give it a key under **Shortcuts**.

## Draw on screen

Point things out while you record, like Loom's pen. Press **⌃⌥⌘D** or choose **Draw on Screen** in the menu. A toolbar appears at the top of the screen, and the mouse now draws instead of clicking. It works before and during a recording, in Full Screen, Custom Size and Window recordings.

- **Tools:**
  - **Pen:** freehand lines.
  - **Highlighter:** a broad see-through stroke, so what's under it still reads.
  - **Arrow:** drag from the tail to the point.
  - **Box:** drag from one corner to the opposite one.

  Press **1–4** to switch tools while drawing.
- **Colours:** red, yellow, green, blue and white. Each line has a faint shadow, so white and yellow show up on light backgrounds.
- **Fade** (the timer button, on at first): each drawing fades away 5 seconds after you finish it, so the screen clears itself as you go. Turn it off to keep drawings until you clear them.
- **Undo** (**⌘Z**) removes the last drawing. **Clear** (the bin, or **Delete**) removes them all.
- **Done**, **Esc** or **⌃⌥⌘D** again gives the mouse back. The drawings stay until they fade or you clear them. **Clear Drawings** in the menu, or its shortcut, clears them at any time.

The drawings are in the recording; the toolbar isn't. You can draw on any screen, but only what's inside the recording is recorded. MyLoom remembers your tool, colour and Fade setting.

## Record

The shortcuts below are the defaults; see [Shortcuts](#shortcuts) to change them.

1. Press **⌃⌥⌘R** (Control-Option-Command-R) from any app, or choose **Start Recording** in the menu.
2. A large **3, 2, 1** counts down in the middle of what you're recording (the middle of the screen for Camera Only). The recording starts the instant it reaches zero, so you can start talking on "go". The countdown itself never appears in the movie.
   - **Cancel the countdown** by clicking it, pressing **⌃⌥⌘S**, or choosing **Cancel Recording** from the menu. Nothing is saved.
   - **Skip the countdown:** turn off **Countdown Before Recording** in the menu.
3. While recording, the menu-bar icon is red and shows the recorded time, and a small control bar floats at the bottom of the screen (see [Recording controls](#recording-controls)).
4. **Pause** with **⌃⌥⌘P** or **Pause Recording** in the menu. The icon turns orange and the clock stops. Press **⌃⌥⌘P** again, or choose **Resume Recording**, to carry on. The paused time is left out of the movie entirely: it cuts straight from the moment you paused to the moment you resumed, with no gap or frozen frame. You can pause and resume as often as you like.
5. **Stop** with **⌃⌥⌘S** or **Stop Recording** in the menu. Stopping while paused works too. The movie is saved as `~/Movies/MyLoom 2026-10-16 at 09.41.07.mp4` and shown in Finder.

**Keeping the menu out of the movie:**
- Stopping from the menu ends the movie at the moment you opened the menu.
- Resuming from the menu waits for the menu to fade out.
- Pausing from the menu keeps a moment of the menu before the cut, because frames already written can't be taken back. For a clean cut, pause with the shortcut.

The drawing toolbar and the short notices shortcuts show (such as "Camera mirrored") are left out of recordings too.

If capture stops by itself, for example because a display was unplugged, you stopped sharing from the macOS menu bar, or the window being recorded was closed, what was recorded up to then is saved. Quitting during a recording saves it first; quitting during the countdown cancels it. **Open Movies Folder** opens where recordings go.

## Recording controls

From the moment you choose Start Recording until the movie is saved, a small dark bar floats at the bottom middle of the screen being recorded, like Loom's recording controls. It's left out of the recording, so it never appears in the movie, wherever it sits. From left to right:

- **The time recorded so far**, with a dot: red while recording, orange while paused, and grey during the countdown and while saving.
- **Pause / Resume.**
- **Draw:** turns drawing on screen on and off. It's lit while drawing is on, and greyed out in Camera Only.
- **Share** (the link): when it's lit, the recording is uploaded and its link copied as soon as you stop. See [Share a recording as a link](#share-a-recording-as-a-link). Each recording starts with it off.
- **Stop** (the red square): saves the movie. During the countdown it cancels instead.
- **Discard** (the bin): throws the recording away without saving. Click it twice within 3 seconds; the first click turns it red and asks "Discard?".

Drag the bar by its background to move it. It stays where you put it on that screen for later recordings. Hovering over a button shows its shortcut.

## Share a recording as a link

For recordings you want to send to someone, like a Loom link, MyLoom can upload a copy to your own Supabase project and give you a link. Anyone with the link can watch it in their browser, without an account, for 14 days. Then the link stops working and the video is deleted from Supabase. Nothing is uploaded unless you set this up and share a recording.

**Set it up once** (MyLoom menu → **Set Up Sharing…** shows the same steps):

1. In your Supabase dashboard, **Project Settings → Storage**: set the upload file size limit to 1 GB. A 10-minute share is usually 200–250 MB.
2. **Authentication → Users → Add user**: an email and password just for MyLoom. Tick Auto Confirm.
3. **SQL Editor**: paste the setup SQL. Get it from **Copy Setup SQL** in Set Up Sharing, or from `supabase/setup.sql`. Fill in the three lines at the top, then Run:
   - your project URL;
   - your secret key;
   - the MyLoom user's email.

   It makes:
   - a private bucket, `myloom-shares`;
   - a list of who may share, with just that user on it;
   - rules so only users on the list can upload to or delete from the bucket. Anyone else who signs up to the project can't use it;
   - a job that deletes videos once they're 14 days old.

   If it complains about `pg_cron` or `pg_net`, turn them on under **Database → Extensions** and run it again.
4. In MyLoom's **Set Up Sharing…**, enter:
   - the **Project URL** and **public key** (anon, or `sb_publishable_…`), from **Project Settings → API**;
   - the user's **email** and **password**.

   Then click **Sign In**. It checks it can reach the bucket and says "Ready to share".

**Share a recording:**
- **While recording:** click **Share** (the link) on the control bar, then stop as usual. MyLoom saves the movie, then uploads it.
- **Afterwards:** choose **Share Last Recording** from the menu.

A small **Share** window shows progress (making the copy, then uploading). When it's done, the link is **already on your clipboard**, ready to paste into a message or email. The window also has **Copy Link** and **Open**, and says when the link expires.

**Recent Shares** in the menu lists links that still work, with the days left. Each has **Copy Link**, **Open in Browser**, and **Delete Now**, which deletes the video at once so its link stops working.

**What's uploaded:** a copy made for streaming:
- at most 1080p, H.264, about 3 Mbit/s (less for still screens), with AAC sound;
- arranged so it starts playing before it has fully downloaded;
- uploaded in 6 MB pieces, so a dropped connection resumes rather than starting again.

The original in ~/Movies is untouched.

**14 days:**
- The link itself is made to expire after exactly 14 days, so it stops working on time even if your Mac is off.
- The video is deleted from Supabase within the hour after that by the job the setup SQL creates.
- MyLoom also deletes your expired videos itself whenever it's running.

**Privacy and security:**
- The bucket is private. Videos have random names that can't be guessed, and are only reachable through their links. Anyone you send a link to can pass it on until it expires.
- MyLoom signs in as the user you made, and the storage rules let it touch only its own folder.
- The sign-in and the MyLoom user's password are kept in your login keychain, not in a file. The password lets MyLoom sign itself back in if its sign-in is ever lost, so a share never fails for that reason. **Sign Out** in Sharing Setup removes both.
- The secret key is only ever in your Supabase database (Vault), for the cleanup job. MyLoom never has it.

## Shortcuts

Every action in the menu can have a shortcut. Four come set; the rest start unset, so MyLoom doesn't take keys you didn't ask for.

| Action | Default | Works |
|---|---|---|
| Start Recording | ⌃⌥⌘R | When you're not recording |
| Stop Recording | ⌃⌥⌘S | During a recording; also cancels the countdown |
| Pause / Resume | ⌃⌥⌘P | During a recording |
| Draw on Screen On / Off | ⌃⌥⌘D | At any time, except in Camera Only |
| Clear Drawings | not set | At any time |
| Show / Hide Camera Bubble | ⌃⌥⌘B | At any time |
| Mirror Camera On / Off | not set | At any time |
| Next Camera Shape | not set | At any time, except during a Camera Only recording |
| Background Effect On / Off | not set | At any time |
| Record Full Screen | not set | When you're not recording |
| Record Custom Size… | not set | When you're not recording (opens the area overlay) |
| Record Window… | not set | When you're not recording (opens the window picker) |
| Record Camera Only | not set | When you're not recording |
| Computer Sound On / Off | not set | When you're not recording |
| Echo Cancellation On / Off | not set | When you're not recording |
| Countdown On / Off | not set | When you're not recording |
| Open Movies Folder | not set | At any time |
| Share Last Recording | not set | When you're not recording |

They work whichever app is in front and need no extra permission. MyLoom only holds each shortcut while its action can run. For example, Start is held only when you're not recording, and Stop only from the countdown until the recording is saved. The rest of the time, those keys are free for other apps. Some shortcuts change something you wouldn't otherwise see: switching mode, countdown on or off, mirror on or off. Those briefly show a notice at the top of the screen, such as *Recording: Camera Only*.

**To change one:**

1. Open **Shortcuts** in the menu (when not recording) and choose the action. Each one shows its current shortcut, or *Not Set*. A small window opens.
2. Press the new key combination. While you hold modifier keys, the box shows them so you can see what you're about to press.
3. Read the line under the box:
   - **Red** means it can't be used. Either it has no ⌘, ⌥ or ⌃ (without one, that key would stop working everywhere else; function keys F1–F20 are allowed alone), or another MyLoom action already has it. Change that one first, as Loom also requires.
   - **Orange** means it's also a macOS shortcut. It's a warning, and **Save** becomes **Save Anyway**. MyLoom checks macOS's own shortcuts the way Loom does, by asking macOS for its full list (`CopySymbolicHotKeys`). Well-known ones are named, for example "Screenshots: Save picture of screen as a file" for ⇧⌘3. macOS may act on these instead of, or as well as, MyLoom, so turn the macOS one off in System Settings → Keyboard → Keyboard Shortcuts, or pick another.
   - **Grey** is information, such as no clash being found.
4. Press **Return** or click **Save**. **Esc** or **Cancel** keeps the old shortcut. **Clear** removes the shortcut so that action is menu-only. **Use Default** puts the original back; it only appears for actions that have one.

**One key for two jobs.** An action that works only when you're not recording may share a key with one that works only during a recording, because the two are never active at the same time. The useful pairs:
- **Start and Stop share a key:** that one key starts and stops recordings.
- **Start and Pause / Resume share a key:** that one key starts, then pauses and resumes. This is how Loom's "Start/Pause/Resume Recording" shortcut behaves.

Actions that work at any time can't share. The recorder window says when a key is shared.

The **Shortcuts** menu lists any clashes with macOS with ⚠︎ under the actions, and has **Restore Default Shortcuts**. While the recorder window is open, MyLoom lets go of all its shortcuts, so pressing a current one records it instead of starting or stopping anything.

**Other apps' shortcuts can't be checked.** macOS lets any number of apps claim the same shortcut without an error, and a press then reaches all of them. This was tested on this Mac: two programs both held ⌃⌥⌘S, and in every test run one press reached both. So if Loom, for example, uses the same keys as MyLoom, one press would act in both. If a shortcut does something unexpected, pick a different one.

## How it works

MyLoom does the same three jobs as Loom, all inside one app:

- **Screen:** Apple's ScreenCaptureKit delivers frames of the chosen display up to 30 times a second. For Custom Size it is told to deliver only that rectangle (`sourceRect`, the same setting Loom uses). Frames only arrive when something on screen changes.
- **Window:** done the way Loom's recorder does it (its `includedWindowIds` and `cropRect`):
  - ScreenCaptureKit captures the window's display with only the chosen windows drawn: the window itself and the bubble.
  - The picture is cropped to the window.
  - Once a frame (30 times a second) MyLoom checks where the window is, and moves the crop if it has moved.
  - A window that no longer exists ends the recording.
- **Camera Only:** no screen capture. The camera's own frames go straight to the encoder, from the same capture session as the preview, at up to 1080p in the camera's shape. For a square or portrait movie the encoder scales them to fill it and cuts off the sides (`AVVideoScalingModeResizeAspectFill`), so the movie is the middle of the picture, just as the preview shows it. It gets twice the bitrate per pixel of screen video, because a camera picture is busier. Loom's recorder has a matching camera-only mode (`camOnly`, `mirrorCamera`).
- **Camera bubble:** an ordinary always-on-top window showing the camera preview, in its chosen shape. Because it's a real window on the screen, ScreenCaptureKit captures it along with everything else. Loom instead records the camera as a separate track plus the bubble's position, and combines them later.
- **Background effects:**
  - Apple's Vision finds you in each camera frame with `VNGeneratePersonSegmentationRequest`, the request Loom uses. MyLoom runs it at its `.balanced` quality, at most 30 times a second.
  - Core Image softens the edge of the mask and blends you over the blurred frame, the colour, or the backdrop. A backdrop is drawn once at the frame's size and reused.
  - The result is shown in the bubble through an `AVSampleBufferDisplayLayer` on top of the plain preview, which shows through until the first finished frame arrives. The same frames go to Camera Only recordings.
  - Frames are only taken from the camera for this when an effect is on, so Off costs nothing.
  - **Blur Strength** sets the blur's size as a share of the frame's height, from 0.8% to 5.8%, so a setting looks the same from any camera.
  - **Speed, measured on an M3 Pro:** a median of 15–23 ms per 720p frame (it varies with what else the Mac is doing), the slowest around 30–40 ms, against the 33 ms a frame lasts at 30 fps. The very first frame takes 0.2–0.7 s while Vision loads its model.
- **Drawing:**
  - Each screen gets a clear, borderless window just above other apps' windows and below the menu bar. Each drawing is a Core Animation shape layer in it.
  - While drawing, that window takes the mouse, and the one on your screen takes the keys (Esc, ⌘Z, Delete, 1–4). It does this without activating MyLoom, so the app you're showing stays in front.
  - The windows are part of the screen, so ScreenCaptureKit records the drawings in Full Screen and Custom Size. A Window recording is told to include them, as it is the bubble.
  - The toolbar and notices are left out of the capture filter by window. They're looked up among all windows, not just visible ones, so they stay out even when they first appear mid-recording.
  - **Loom:** the same idea lives in its `ContextSelectionInteractionView` (`activeTool`, `persistingStrokes`, `opacity`), alongside a feature that picks out the on-screen element you draw around.
- **Microphone:** an AVFoundation capture session reads the mic as 48 kHz mono. Its timestamps are moved onto the same clock as the screen frames, so sound and picture line up.
- **Computer sound:** ScreenCaptureKit's `capturesAudio` delivers what apps are playing, 48 kHz stereo, on the same clock as the video. Loom instead installs a virtual audio driver into `/Library/Audio/Plug-Ins/HAL`, temporarily makes it the Mac's output, plays its sound on through to your speakers, and records that.
  - In Full Screen and Custom Size the recording stream itself carries the sound.
  - A window recording only hears the window's own app, which was verified by test. So MyLoom adds a tiny whole-display stream, one frame a second with its frames ignored, just for the sound. Camera Only uses the same.
  - A mixer places each piece of mic and computer sound at the sample its timestamp falls on, 150 ms behind real time so both have arrived.
  - It works in WebRTC's 10 ms blocks. For each block, WebRTC is given the computer's sound, looking 40 ms ahead, then cleans the mic. The look-ahead covers the two sources' clocks being slightly out.
  - The cleaned mic and the computer's sound are added together, peaks are gently limited, and one stereo track goes to the encoder.
  - WebRTC is configured with only echo cancellation and its high-pass filter on. Noise suppression and automatic gain are off, so your voice is otherwise untouched.
  - **How well it works, measured:** a simulated room, with a slightly distorting speaker, reflections, a reverb tail and mic noise, was fed through the real mixer with two synthetic voices. At room delays from 5 to 300 ms, and with the computer's sound stamped 30 ms late, it removed 31–45 dB of echo (99.9% or more of the echo's power) from the first seconds on. Your voice on its own kept its level (−0.6 dB). It costs about 2% of one CPU core. A real room and mic weren't tested.
- **Saving:** `AVAssetWriter` encodes the frames as H.264 and the sound as AAC and writes them into one `.mp4`. Loom instead cuts its recording into short segments and uploads them while you record.
- **Sharing:**
  - MyLoom talks to Supabase's HTTP APIs directly, with no extra libraries. It signs in with Auth's password grant and refreshes the session as needed.
  - It uploads with Storage's resumable (tus) uploads, in the 6 MB pieces Supabase requires. After a failed piece it asks how much arrived and carries on.
  - It makes a signed link (`/object/sign`) valid for 1,209,600 seconds, which is 14 days.
  - The share copy is re-encoded with `AVAssetReader` and `AVAssetWriter`.
  - Deletion in Supabase has to go through the Storage API: deleting rows from `storage.objects` would leave the files behind. So the hourly `pg_cron` job calls it with `pg_net`, using the secret key from Vault.
- **Countdown:** capture starts as soon as you choose Start Recording, behind the countdown, so it's already running at zero. Nothing from before zero is kept. The countdown's window is excluded from the capture.
- **Pause:** capture keeps running while paused, but nothing is written. Every frame and sound after you resume has its timestamp moved back by the paused time, so the movie closes the gap. Loom's recorder does the same (its `TimeShiftOnPauseFilter`).
- **Shortcuts:** registered with macOS's `RegisterEventHotKey`, the same mechanism Loom uses. They're stored by physical key, so they stay put if you switch keyboard layout. Clashes with macOS are found with `CopySymbolicHotKeys`, also as Loom does. Clashes with other apps can't be detected, because macOS accepts duplicates silently.

| File | Role |
|---|---|
| `Sources/ScreenRecorder.swift` | Capturing a display, area, window or the camera; following a window; mic session and fallback |
| `Sources/WindowPicker.swift` | Finding windows, and the click-to-choose window overlay |
| `Sources/Toast.swift` | The short notice shown after a shortcut changes a setting |
| `Sources/RecordingControls.swift` | The floating bar shown while recording: time, Pause, Draw, Share, Stop, Discard |
| `Sources/Sharing.swift` | Sharing: the steps, recent shares, the 14-day cleanup, the Share and Set Up Sharing windows |
| `Sources/Supabase.swift` | The Supabase calls: sign in and refresh, resumable upload, signed link, list, delete |
| `Sources/ShareCopy.swift` | Making the smaller copy that's uploaded |
| `Sources/Keychain.swift` | Keeping the Supabase sign-in in the login keychain |
| `supabase/setup.sql` | The one-time setup for your Supabase project: bucket, rules, 14-day cleanup job |
| `Sources/Drawing.swift` | Drawing on screen: the clear window over each screen, the four tools, Fade, Undo, and the toolbar |
| `Sources/MenuSlider.swift` | The slider inside a menu (Blur Strength) |
| `Sources/MicrophoneMeter.swift` | The live microphone level meter in the menu |
| `Sources/AudioMixer.swift` | Mixing the microphone and the computer's sound into one stereo track; echo cancellation in 10 ms blocks |
| `Native/EchoCanceller.cpp`, `.h` | A small C interface to WebRTC's echo canceller, for Swift |
| `scripts/build-webrtc.sh` | Downloads, checks and builds WebRTC's audio processing into `Vendor/` |
| `Sources/MovieWriter.swift` | H.264 and AAC encoding into the `.mp4`, the countdown start, cutting out pauses |
| `Sources/Countdown.swift` | The 3-2-1 window |
| `Sources/GlobalHotkeys.swift` | Registering the global shortcuts; the default keys |
| `Sources/Shortcut.swift` | Key combinations, their names, and clash checks against macOS and MyLoom |
| `Sources/ShortcutRecorder.swift` | The window for recording a new shortcut |
| `Sources/CameraBubble.swift` | The bubble and the Camera Only preview: shapes, moving, resizing, snapping, mirroring, showing the background effect, feeding camera frames to the recorder |
| `Sources/CameraEffects.swift` | Background blur and replacement: Vision person segmentation, the Core Image blend, the built-in backdrops |
| `Sources/AreaSelector.swift` | The Custom Size overlay and the on-screen area outline |
| `Sources/AppDelegate.swift` | Menu-bar icon, menu, permissions, camera hot-plugging |
| `Sources/Settings.swift` | Remembered choices, device lists, file names |

## What's in the file

- **Video:** H.264 High profile, up to 30 fps. The size depends on the mode:
  - **Full Screen:** the display's full pixel resolution.
  - **Custom Size:** the area's size.
  - **Window:** the window's size when recording started.
  - **Camera Only:** the camera's picture, up to 1920×1080, or the middle of it in a square or 9:16.

  Anything larger than 4096×2304 (for example a 5K display) is scaled down to fit H.264's limit.
- **Audio:** AAC at 48 kHz: mono at 128 kbps for the microphone alone, or stereo at 192 kbps when the computer's sound is mixed in.

## Checks without the menu

```sh
# Feeds 4 s of a test pattern and a tone through the same writer the app uses. The movie starts
# 0.5 s in (as after a countdown) and is paused for 1 s, so it should come out 2.5 s long.
# Needs no permissions.
build/MyLoom.app/Contents/MacOS/MyLoom --selftest /tmp/selftest.mp4

# Records for 5 s through the real recorder, starting capture a second early as the countdown does:
# the main display; an area (x,y,width,height in points from the top-left); the frontmost window;
# or the camera alone. The app you run this from, such as Terminal, needs the permissions (Screen
# Recording, or Camera for "camera"; Microphone for sound), and the display must be awake.
build/MyLoom.app/Contents/MacOS/MyLoom --record-test /tmp/capture.mp4 5
build/MyLoom.app/Contents/MacOS/MyLoom --record-test /tmp/area.mp4 5 100,100,640,360
build/MyLoom.app/Contents/MacOS/MyLoom --record-test /tmp/window.mp4 5 window
build/MyLoom.app/Contents/MacOS/MyLoom --record-test /tmp/camera.mp4 5 camera
# Add --computer-sound to any of these to mix in what the Mac is playing.
build/MyLoom.app/Contents/MacOS/MyLoom --record-test /tmp/sound.mp4 5 --computer-sound

# Draws the Custom Size overlay, the countdown, the microphone meter and the shortcut recorder into
# PNGs, to check their layout.
build/MyLoom.app/Contents/MacOS/MyLoom --render-ui /tmp/myloom-ui

# Shows a photo of a person in the camera bubble in place of the camera, with each background
# effect and shape, and saves what the screen shows (what a recording would get) as PNGs. Prints
# the time per frame and checks the colour background and switching the effect off. Needs Screen
# Recording access, not the camera. The bubble appears on screen for about 15 s.
build/MyLoom.app/Contents/MacOS/MyLoom --effects-test ~/Pictures/someone.jpg /tmp/myloom-effects

# Draws a pen line, a highlight, an arrow and a box with the real mouse while recording the main
# display, then checks the movie for each drawing and that the toolbar and notices were left out,
# repeats with a Window recording, and checks Esc, Undo and fading. A grey window covers the main
# display for about 12 s. Needs Screen Recording and Accessibility (to move and click the mouse);
# it checks MyLoom's drawing window is under the pointer before every click.
build/MyLoom.app/Contents/MacOS/MyLoom --drawing-test /tmp/myloom-drawing
```

All but `--render-ui` print `PASS` or `FAIL`.

To check devices as MyLoom sees them, run these through `open`, so macOS treats them as MyLoom (with its permissions) rather than as Terminal:

```sh
# The cameras and microphones macOS offers MyLoom, and its Camera, Microphone and Screen Recording access.
open -W --stdout /tmp/devices.txt build/MyLoom.app --args --list-devices; cat /tmp/devices.txt
# Listens to a microphone for 5 s, in its own format and in MyLoom's, and prints the level of each.
open -W --stdout /tmp/mic.txt build/MyLoom.app --args --mic-probe Sennheiser; cat /tmp/mic.txt
# Holds the iPhone camera open and reads the iPhone microphone at the same time.
open -W --stdout /tmp/iphone.txt build/MyLoom.app --args --continuity-probe; cat /tmp/iphone.txt
```

To check sharing end to end, `--share-test` takes a movie and does what Share does, checking each step:
- makes the copy;
- signs in, and refreshes the sign-in;
- uploads it;
- makes the 14-day link and plays the video through it;
- lists it, then deletes it and checks the link has stopped working.

```sh
# With the project and sign-in saved by Set Up Sharing (no password needed). Uploads, then deletes, one test video.
open -W --stdout /tmp/share.txt build/MyLoom.app --args --share-test /path/to/a/recording.mp4 --stored; cat /tmp/share.txt
# Or against any project and user given directly.
build/MyLoom.app/Contents/MacOS/MyLoom --share-test recording.mp4 https://abcd.supabase.co PUBLIC_KEY EMAIL PASSWORD
```

## If something doesn't work

- **A recording has no sound:** MyLoom now says so after saving, naming the mic that sent nothing.
  - Point at the mic under **Microphone** before recording. If the meter stays still while you talk, the mic itself is silent.
  - A USB mic that is muted on the device sends exact silence, and macOS doesn't show it as muted. The Sennheiser Profile, for example, has a mute on top, with a light that shows red when muted, and a gain knob.
  - `--mic-probe` (above) shows whether the mic is silent in its own format, before MyLoom touches it.
- **The iPhone camera or mic isn't listed:** see [Use your iPhone as the camera](#use-your-iphone-as-the-camera). `--list-devices` shows what macOS offers.
- **Diagnostics:** MyLoom logs which mic it opened, when its sound first arrived and how much came:

  ```sh
  log show --last 10m --predicate 'subsystem == "local.myloom"'
  ```
- **A crash:** macOS keeps a report in `~/Library/Logs/DiagnosticReports/MyLoom-*.ips`.

## Limits

- **Share links are long:** they carry their own expiry, so they're a long `…supabase.co/storage/v1/object/sign/…` address rather than a short one. A watch page with a short link would need a small website as well.

- **The iPhone's mic can be unreliable:** in testing here, over Continuity, it once sent nothing for a whole short recording, then recorded normally in the next. If a recording comes out silent, MyLoom tells you.

- **Window recordings stay on one screen:** a window dragged to another display leaves the picture until it comes back.
- **Dragging a window during a recording:** the picture catches up with the window within a frame or two, about 60–75 ms when measured here. Until it does, an edge of the picture may show a thin black sliver.
- **Window corners:** outside a window's rounded corners there's nothing to draw, so those corners (and a minimised window) are likely to come out black.
- **Camera Only is camera-only:** there's no bubble-over-screen picture-in-picture in that mode.
- **While drawing, the mouse only draws:** you can't click apps, or move the camera bubble, until you press Esc or Done. If Esc or ⌘Z ever stop working while drawing (the drawing window can lose the keyboard if you click outside it, such as on the menu bar), use Done or ⌃⌥⌘D instead.
- **No drawing in Camera Only:** there's no screen in the recording to draw on.
- **Background effects find people, not things:** something you hold out away from your body may be blurred or replaced along with the room. In poor light, or with hair against a busy background, the edge around you can shimmer a little.
- **Background effects add a moment:** with one on, the bubble shows you about 15 ms later than without, well under a frame. Turning one on takes up to a second the first time, while Vision loads; you see the plain camera until then.
- **Portrait Camera Only movies are narrow:** they're cut from the camera's landscape picture, so a 1080p camera gives 606×1080.
- **Echo cancellation while you talk over the computer:** when you and the computer's sound speak at the same moment, WebRTC sometimes trims your voice slightly to make sure no echo slips through. Every echo canceller trades off here, Loom's included.
- **Echo cancellation's delay:** it delays your voice by a fixed ~8 ms (WebRTC's frequency-band processing), far below anything noticeable in lip sync.
- **Computer sound from command-line tools isn't recorded,** only from apps (see [Record computer sound](#record-computer-sound)).
- **Camera only from the iPhone:** Continuity Camera gives MyLoom the iPhone's camera and mic, not its screen.
- **Some shortcuts may not record:** macOS can act on some of its own shortcuts (such as ⇧⌘3, which takes a screenshot) before the recorder window sees them. If pressing one does the macOS thing instead of filling the box, turn the macOS shortcut off first.

## Third-party code

Echo cancellation uses [WebRTC's audio processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) (BSD 3-clause licence) and [abseil](https://abseil.io) (Apache 2.0), both built into the app from source by `scripts/build-webrtc.sh`.
