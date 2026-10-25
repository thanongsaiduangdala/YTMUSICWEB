# iOS fixes (untested on a device - built without Xcode)

1. Download (HTTP 403)
   - lib/main.dart `_downloadWithDart`: pieces now use the app identity (User-Agent) that matches the stream link
     (`c=` in the link), retry 4x per piece (Range header, `&range=` in link, fresh link), and fall back to the
     iPhone-app endpoint links.
2. Personalize sound for downloaded / added songs
   - NEW ios/Runner/FxPlayer.swift (AVAudioEngine: 10-band EQ, bass, clarity, room, width, booster + limiter),
     registered in AppDelegate.swift and ios/Runner.xcodeproj/project.pbxproj.
   - lib/main.dart: `IosFxEngine` + handler routes on-device playback to it on iOS only. Android code path unchanged.
3. Added MP3 "could not play this file"
   - iOS picker now uses the Files app (FileType.audio opens the Music library only).
   - File type is read from the file's first bytes; the file gets the right ending (iPhone decides by ending).
   - Saved paths are repaired if the app folder address changed.
   - The error toast now shows the real reason.
4. Streaming effects check now shows `signal` (0 = no sound reaches the effects chain).
