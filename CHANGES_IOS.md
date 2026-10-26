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
5. Download via the YouTube page's own link
   - lib/main.dart: the page is hooked (`gvHookJs`) to note the audio link it uses; the download tries that link first
     (only for the song currently playing). New button "Check download link" under the equalizer shows what the page used.
6. Page link v2: the page fetches audio with POST (itag 251, Opus/WebM, with pot token). The hook now asks the page for AAC
   (MediaSource.isTypeSupported / canPlayType say no to Opus/WebM), captures POST links + body, and the download replays
   them as POST with &range= pieces. The check dialog shows method / itag / mime / ump.
7. HLS download (the way MaxMusic does it): asks the iPhone-app endpoint for the song's HLS playlist (hlsManifestUrl), picks the
   audio-only playlist, downloads the parts and joins them (fMP4 -> .m4a, MPEG-TS -> raw AAC .aac). Tried before the old routes.
8. UMP: the page's audio replies are wrapped in YouTube's "UMP" format. The page-link download now unwraps them (part type 21).
   HLS log lines now show which parts YouTube's iPhone-app reply had.
9. Songs that are not playing: the download opens the song in the YouTube page (muted, up to 45 s), grabs its link, then pauses.
   A song the library cannot read ("video is not available") no longer stops the download before the page link is tried.
