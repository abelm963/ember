# Ember for Apple TV

The native Apple TV app: same Jellyfin and Seerr servers, same Ember look, browsing like the big
streaming apps, and Apple's own player for true Dolby Vision, HDR10 and Dolby Atmos.

The Windows app (Flutter) and this app live side by side in the repo; they don't share code,
but they share the design (`apple-tv/DESIGN.md`) and talk to the servers the same way.

## Put it on your Apple TV

You need a **Mac** with **Xcode** (free from the Mac App Store) and an **Apple Account**. A free
account works, but the app then stops opening after 7 days until you install it again; a paid
Apple Developer membership ($99/year) makes it last a year and is needed for the App Store and
TestFlight.

1. On the Mac, download this repo (GitHub › Code › Download ZIP, or `git clone`).
2. Open `apple-tv/EmberTV.xcodeproj` in Xcode.
3. Click **EmberTV** at the top of the file list › **Signing & Capabilities** › choose your
   **Team** (add your Apple Account under Xcode › Settings › Accounts if it's not listed). If
   Xcode complains the bundle identifier is taken, change `app.ember.tv` to something unique like
   `app.ember.tv.yourname`.
4. Pair the Apple TV with the Mac: on the Apple TV open **Settings › Remotes and Devices ›
   Remote App and Devices**; in Xcode open **Window › Devices and Simulators**, pick the Apple TV
   and enter the code it shows. (Both must be on the same network.)
5. At the top of Xcode pick your Apple TV as the destination and press **▶ Run**.

To try it without an Apple TV, pick an **Apple TV 4K** simulator instead and press ▶. Use the
arrow keys and Return on the Mac keyboard, or Window › Show Apple TV Remote.

## First launch

1. **Connect**: type the address you use for Jellyfin (`hearth:8096` at home, or the Tailscale
   address away from home: install Tailscale on the Apple TV from the App Store).
2. **Sign in**: approve the Quick Connect code from Jellyfin on your phone, or type a password.
3. **Who's watching?**: add a profile for each person. Each keeps their own Continue Watching,
   My List and Seerr requests.
4. **Seerr**: Settings › Requests › type the Seerr address › Connect. Ember signs in to Seerr
   with your Jellyfin account automatically (no password).

## Using it

| Remote | What happens |
| --- | --- |
| Swipe / arrows | Move around. On Home, the top of the screen follows the title you're on |
| Click | Open / play |
| Long-press a tile | My List and More Info |
| Back (‹ or Menu) | From rows: back to the top. At the top: opens the menu. On the menu: leaves Ember |
| Swipe down while playing | Audio, subtitles, and info |
| Bottom-right buttons while playing | Skip Intro, Next Episode |

For Dolby Vision and HDR, turn on **Settings › Video and Audio › Match Content › Match Dynamic
Range** (and Match Frame Rate) on the Apple TV.

## How it's organised

| Path | What's in it |
| --- | --- |
| `EmberKit/` | Jellyfin and Seerr clients (Swift package, ported from `lib/api`). `swift test` runs its 22 tests, even on Linux |
| `EmberTV/App/` | App start-up, saved profiles and settings (`AppModel`), navigation (`Router`) |
| `EmberTV/Screens/` | One file per screen: Connect, Sign in, Profiles, Main (side menu), Home, Library (Shows / Movies / My List), Search, Details, Seerr details, Requests (and New & Hot), Settings |
| `EmberTV/UI/` | Colours and fonts (`Theme`), buttons, tiles and rows (`Components`), image loading |
| `EmberTV/Player/` | Full-screen playback with Apple's player, and the muted previews on Home |
| `project.yml` | Describes the Xcode project. After adding or removing files run `xcodegen generate` (`brew install xcodegen`) |
| `DESIGN.md` | The design study: what makes it feel like a big streaming app, tokens, and how playback works |

Every push that changes `apple-tv/` is built on a Mac by GitHub Actions (`.github/workflows/apple-tv.yml`),
so you can see on GitHub whether it compiles before opening Xcode.

## Not done yet

- Trickplay thumbnails while scrubbing (Apple's player only shows them for streams that include them).
- Top Shelf (Continue Watching on the Apple TV home screen when Ember is in the top row).
- The Coming Soon calendar from the Ember Trailers plugin (New & Hot uses Seerr's upcoming lists for now).
- Installing / updating the Ember Trailers plugin from the Apple TV (use the Windows app).
