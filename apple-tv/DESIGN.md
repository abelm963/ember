# Ember for Apple TV: design study

How the big streaming apps behave on Apple TV 4K, and how Ember copies that *behaviour* with its
own look (Ember colours, Ember fonts, no other company's names, logos or artwork).

This study comes from using these apps and from Apple's tvOS design guidelines. Nothing was taken
from any app's code or files: App Store apps are encrypted, and Ember doesn't need anything from
inside them.

## 1. What makes it feel like "Netflix on Apple TV"

| # | Behaviour | What the person notices | How Ember does it |
| --- | --- | --- | --- |
| 1 | **Profile picker first** | "Who's watching?" with big rounded avatars; the focused one grows and gets a white ring | `ProfilesView`: one tile per account saved for this server, plus "Add profile" |
| 2 | **Collapsed side menu** | A thin column of icons on the left. Swiping left onto it expands it with labels and darkens the page | `SideMenu`: 112 pt wide closed, 470 pt open, gradient dim over the page |
| 3 | **Billboard that follows focus** | The top half of Home shows the title you're on: artwork fills the screen, the title's logo, a one-line "why" (★ rating, year, age rating, length, 4K/HDR), and a short synopsis. Moving along a row cross-fades the artwork | `HomeView` keeps a `spotlight` item. Focus on any tile updates it after a short delay (so fast swiping doesn't flicker) and the backdrop cross-fades |
| 4 | **Muted preview** | After a few seconds on the billboard, a trailer starts silently behind the info | `HeroPreview`: plays the Ember Trailers stream (or a local trailer) muted after 4 s, fades in, stops when focus leaves the top row |
| 5 | **Rows anchored on the left** | In a row the focused tile stays near the left edge and the row slides under it. Rows themselves snap so the focused row always sits just below the billboard | `MediaRow` uses a `ScrollView` with `scrollTargetBehavior(.viewAligned)` and a leading anchor; the page scrolls the focused row to a fixed position |
| 6 | **Tiles that lift** | 16:9 artwork. On focus: scale up ~1.1, white rounded border, a soft shadow; the title appears underneath | `MediaTile` uses a custom `ButtonStyle` (`TileButtonStyle`), not the default tvOS highlight, so it looks the same everywhere |
| 7 | **Continue Watching** | A thin progress bar on the artwork, "S2 : E4" or "38 min left" below | Same, from Jellyfin's resume data |
| 8 | **Top 10 / Trending** | A numbered row. Ember's version: titles trending now that aren't on the server, marked "Requested" or "Not on server" | Seerr trending row on Home |
| 9 | **Details page** | Full-screen artwork with a dark gradient from the left. Logo, metadata line, quality badges, synopsis, cast. Buttons: Play/Resume, Restart, Trailer, My List (+ / ✓). Below: Episodes (season picker + episode list) and More Like This | `DetailsView`, `EpisodesSection`, `SimilarRow` |
| 10 | **Native player** | The standard Apple TV player: swipe to scrub with thumbnails, swipe down for audio/subtitles, "Skip Intro" and "Next Episode" buttons in the bottom-right corner | `PlayerView` wraps `AVPlayerViewController`, so Siri Remote gestures, Dolby Vision, HDR10, Dolby Atmos and the Info panel come from tvOS itself. Skip Intro and Next Episode use `contextualActions` |
| 11 | **Back goes "up" before "out"** | Back on a row returns to the billboard, Back on Home's billboard opens the menu, Back again leaves the app | `onExitCommand` handlers at each level |
| 12 | **Search with a keyboard grid** | A letter grid on the left, results on the right updating as you type | `SearchView`: a Netflix-style A–Z/0–9 grid (plus dictation through the Siri Remote's microphone via the system keyboard button). Results combine your library and Seerr |
| 13 | **Calm, dark, big type** | Everything is readable from the sofa: 25–30 pt body text, 100 pt titles, no thin fonts | Ember's palette and type scale (below), written in 1920×1080 points like the Flutter app |

## 2. Where Ember intentionally differs

- **Brand**: Ember's ember-orange accent (`#FF7A2F`) instead of red, Bricolage Grotesque for titles,
  Figtree for everything else.
- **Requests**: titles that aren't on the server can be requested (Seerr) from Home, Search and
  New & Hot, and the Requests page shows download progress.
- **Your server, your files**: the format badges (4K, Dolby Vision, HDR10, Atmos, DTS:X, 5.1)
  describe the actual file on Hearth.

## 3. Design tokens (shared with the Flutter app)

| Token | Value | Use |
| --- | --- | --- |
| `bg` | `#0A0A0B` | Page background |
| `surface` / `surface2` / `surface3` | `#141416` / `#1E1E22` / `#2A2A2F` | Cards, panels, unfocused buttons |
| `text` | `#F4F1EC` | Primary text; focused buttons turn this colour |
| `soft` / `muted` / `faint` | `#D9D4CC` / `#B9B4AC` / `#8E8982` | Synopsis / metadata / hints |
| `accent` | `#FF7A2F` | Eyebrows ("FILM · NEW IN YOUR LIBRARY"), progress bars, focus ring on the primary button |
| `good` / `warn` / `bad` / `blue` | `#7BD88F` / `#F2D27A` / `#F0A0A0` / `#9CC3F0` | Rating star, statuses |
| Display font | Bricolage Grotesque ExtraBold, tracking −2.5 % | Titles |
| Body font | Figtree 400–800 | Everything else |
| Focus scale | 1.05 buttons, 1.10 tiles | |
| Corner radius | 12 pt buttons, 10 pt tiles, 999 pt avatars | |
| Gutter | 80 pt left (after the 112 pt menu) | |

## 4. Playback on Apple TV

The Flutter app plays everything with mpv. Apple TV's player (AVPlayer) is pickier about file
types but is the only way to get **true Dolby Vision, HDR10 and Dolby Atmos**. So Ember tells
Jellyfin exactly what Apple TV 4K can play:

| The file is… | What happens |
| --- | --- |
| MP4 / MOV / M4V with H.264, HEVC (incl. Dolby Vision 5/8.1) and AAC / AC-3 / E-AC-3 / ALAC / FLAC | **Direct play**: the original file, untouched |
| MKV or anything else whose video and audio AVPlayer understands | **Remux**: Jellyfin repackages it into HLS (fMP4) without re-encoding, so quality is identical and Dolby Vision/Atmos survive |
| DTS, TrueHD, or a codec Apple TV can't decode | Jellyfin converts **just the audio** (to E-AC-3 5.1 or AAC); the picture is untouched |
| Picture-based subtitles (PGS, DVD) | Burned in by the server when you turn them on; text subtitles stay selectable |
| "Quality" set below Original in Settings | Full transcode to H.264 at that bitrate, for slow connections |

Ember reports start, progress and stop to Jellyfin so Continue Watching stays in sync with every
other device in the house.
