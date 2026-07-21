# Changelog

## 7.0.9.8 (2026-07-20)

### Fixed
- "Replace This Track" / "Replace Next Track": the just-replaced track is now registered in `TrackTracker` so it's actually excluded from future picks (previously only logged for display, never excluded).
- Fixed a Perl bug where `Slim::Player::Playlist::song()` (which returns a Track object, not a URL string) was passed directly into path-decoding logic, silently breaking the exclusion match and corrupting `TrackTracker` with garbage entries.
- "Replace Next Track" now inserts the replacement right after the current track instead of appending it to the end of the playlist, so the "Coming Up Next" slot actually shows the fresh pick instead of stale leftover playlist content.
- Fixed a path-format mismatch (mixed backslash/forward-slash paths from incomplete NAS Dynamic-Path-Conversion substitution) that silently broke all track-level "avoid repeat" exclusion for NAS/DPC setups - likely present since this feature's inception.
- The random-track fallback (`randompuller`) now respects per-player blocked-genre settings instead of re-picking from the currently blocked genre.
- Fixed an operator-precedence bug in genre-block SQL (`DropGenreAndXMas`) that dropped per-client scoping for some conditions.
- Quick Settings: the ⓘ info tooltip for track-variety settings now shows correctly (previously truncated at the first embedded quote character, since it broke out of the HTML `title` attribute).

### Changed
- Quick Settings / Auto Mix: "How much Mix Style" and "How much Mix Variety" are now proper drag sliders instead of a number-stepper, which could trigger a page refresh (closing the settings section) on every single click.
- Quick Settings / Auto Mix: the ⓘ info icon next to Replace/Start-a-Mix buttons now opens a click-to-show popup (matching Material skin's own tooltip style) instead of relying on a native browser hover tooltip.
- Player Settings: "Block Artist Repeating", "Block Album Repeating" and "Remember last X tracks" now include a variety tip directly in their existing built-in help tooltip, instead of a separate (non-functional) info icon.
- README: added a "REPLACE TRACK - WHY THE SAME TRACKS CAN COME BACK QUICKLY" section explaining MusicIP's small candidate-list behaviour and which three settings need to be raised together for good variety.

## 7.0.9.7 (2026-07-18)

### Changed
- Quick Settings: wording tweak, "SugarCube is starting a new mix" -> "SugarCube has started a mix".

## 7.0.9.6 (2026-07-18)

### Fixed
- Quick Settings: "SugarCube is replacing the current track" was shown even when a fresh mix was started from an empty playlist (nothing was actually replaced). `replacedempty` now correctly reflects whether the playlist was genuinely empty, and shows "SugarCube is starting a new mix" in that case.

## 7.0.9.5 (2026-07-18)

### Fixed
- Quick Settings: the status message said "SugarCube is replacing the next track" even when replacing the "Currently Playing" (kick off) track instead. Now shows "...the current track" for that action.

## 7.0.9.4 (2026-07-18)

### Fixed
- Quick Settings: the "SugarCube Auto Mix / Start a Mix" empty-playlist prompt stayed visible above "Currently Playing" / "Coming Up Next" once a mix actually started, instead of being replaced by them.

## 7.0.9.3 (2026-07-18)

### Changed
- Quick Settings: when the playlist is empty, instead of showing nothing (or, previously, buttons with no track info attached), the page now shows "SugarCube Auto Mix" with a "Start a Mix" button to bootstrap a fresh mix.

## 7.0.9.1 (2026-07-18)

### Fixed
- Quick Settings page: fields below the "SugarCube Mix Mode: Standard MusicIP" section appeared permanently dimmed in Material Skin's browser view (likely a Material Skin CSS rule that dims siblings after a collapsed `<details>` element). Moved that collapsible section to the end of the form so nothing follows it.

## 7.0.9.0 (2026-07-18)

### Added
- **New "SugarCube Quick Settings" page**, accessible from the Extras menu (registered under `browseiPeng` so it also shows up in the Material app's Extras menu, not just the classic Material Skin browse menu). Lets you change, on the fly, without opening the full settings page:
  - Mix Style / Mix Variety (collapsible "SugarCube Mix Mode: Standard MusicIP" section)
  - Mix by Song or Album
  - Select Mix Type (None / Filter / Genre / Artist / Mood Mixing)
  - Available MIP Filters, Genres, Artists, Moods and Mood Filter - each field now only shown when relevant to the currently selected Mix Type
  - Optionally Add a MusicIP Recipe
  - All changes save instantly on change, no separate save button.
  - Page auto-returns after 60 seconds if left idle.
- **Automatic "Replace Next Track"**: changing Filter, Recipe, Genre, Artist, Mood or Mood Filter in Quick Settings now automatically replaces the upcoming track to match, with visual feedback ("SugarCube is replacing the next track") and a live "Currently Playing" / "Coming Up Next" display, each with its own "Replace This Track" button.
  - Replacing the "Coming Up Next" track leaves the currently playing track alone.
  - Replacing the "Currently Playing" (kick off) track now inserts the new track right after the current position, jumps to it, and only then removes the old one - so anything already queued after it is left untouched (previously this cleared the whole playlist).
  - If the playlist is empty, both actions bootstrap a fresh mix the same way the "SugarCube Auto Mix" button does.
  - If playback has stalled (eg. after a server restart with an empty buffer), changing a setting now also resumes playback, instead of endlessly queueing tracks that never get consumed.
- **"SugarCube Auto Mix" (quickplay) page** now also shows "Coming Up Next" alongside "Currently Playing", each with its own replace button. The existing "New Track" button now preserves anything already queued after the kick off track instead of clearing the whole playlist.
- Both "Currently Playing" / "Coming Up Next" widgets track the player's actual current position (`status -`) rather than a fixed playlist index, so they stay accurate even if the page is left open while playback continues.

### Fixed
- MusicIP Vintage Mode section on the main settings page (`player.html`) now collapses/expands correctly in the Material app (was broken due to a nested Template Toolkit `WRAPPER` call inside the `<summary>` element, unlike every other collapsible section).
- Genre/Artist/Mood Mixing no longer fail to produce a mix when kicking off from an empty playlist - the MIP request no longer sends an empty `&album=`/`&song=` parameter when there is no seed track.

### Known limitations
- Artist Mixing can still be "hit and miss" if the selected artist only has a single track in the library (nothing to mix from).
- Filter Mixing with no filter selected will report a configuration error / fall back to random tracks - this is existing, expected behaviour, not new in this release.
