# Changelog

## 7.0.9.13 (2026-09-06)

Covers everything since 7.0.9.12 (2026-08-09) in one bump rather than splitting into separate releases for the undocumented gap period and the Live View/Quick Settings/MIP Export work - this build isn't distributed, so a second release number wouldn't get used by anyone. Numbering note: if this fork is ever actually merged into or replaces AF1's own line, with no further changes on top, it becomes 7.1.1 at that point (one past AF1's current 7.1.0) rather than continuing this 7.0.9.x count.

### Added
- Genre blocking on the Player Settings page gained a checkbox-based multi-select widget (`sc_genre_multiselect.html`) allowing more than three genres to be blocked at once, backed by a single `scblockgenre_list` preference. Superseded by the plain comma-separated text field below and since deleted, having never shipped in a release.
- MusicIP Export tooling (scheduled export of ratings/playcount/last-played to MusicIP, with a status UI) was built in the sibling SC-EXTMIP fork and in HB64, ahead of being ported into this hoofdmap build: configurable daily export time, optional file-extension replacement (for setups where MusicIP is indexed against a differently-encoded copy of the library), an "Adjust odd ratings" threshold that remaps low ratings to 0 stars in MusicIP and stretches the rest across MusicIP's 1-5 range, and an Export Now/Abort control with a live colour-coded status line, disabled while a scan or export is already running.
- Player Settings: "MusicIP Request No. of Tracks" ("MIPSize") is now set per player (directly under SugarCube Mix Mode) instead of once globally, and now also governs FreeStyle mode's track count, which previously had no such control at all.
- Live View: a Previous/Play-Pause/Next transport bar with SVG icons added, styled to match Material's own bottom player bar (a filled circle for Play/Pause, flat icons either side).
- Live View: "New Mix" (starts a completely fresh mix) and "Replace Track" (replaces just that track) icon buttons added under the Currently Playing and Coming Up Next covers, and a single "Play Next" icon added to each row of the MusicIP Track Recommendations table that swaps the picked track into the next-to-play queue slot (removes the current "next" track, inserts the picked one in its place) instead of appending it to the end of the queue.
- Live View: MusicIP Track Recommendations' old "Play Album"/"Add Album"/"Add Track to Queue"/"More" row (already broken before this - the "More" icon referenced `more_svg_17x17.png`, an early, never-completed attempt to reference one of Material's own icons directly, which doesn't exist as a file at all) is gone, replaced by the single "Play Next" icon above; the leftover unused `more.svg`/`more_svg.png` image assets have been deleted.
- Live View / Quick Settings: "New Mix", "Replace Track" and "Play Next" now refuse to act (and hide their icon/button) whenever more than one track is already queued ahead of the one playing - e.g. a fired SC Batch, a loaded album/playlist, or a hand-built queue - since SugarCube can only safely disturb a queue of its own making.
- Quick Settings: gained its own fixed Previous/Play-Pause/Next transport bar (identical to Live View's), so playback can be controlled without leaving the page.

### Changed
- Block-list preferences for blocked artists and blocked genres were converted from a small fixed number of exact-name slots to a single free-text preference per list, removing the old three-item cap; matching artists/genres are now matched with a partial (LIKE) match rather than an exact name match. Existing values in the old per-slot prefs are not migrated automatically and need to be re-entered as a comma list.
- Player Settings / Quick Settings: Permanent Block Artist(s) and Artist Weighting (Prefer/Less) moved to the same comma-separated free-text format as the block-list change above; Artist Weighting's Prefer/Less lists also moved out of a collapsed "(optional)" fold-out section to sit inline with the other block lists, and each side now shares one weight (1-5) across its whole list instead of a separate weight per name.
- Settings: the two NAS Dynamic Path Conversion field pairs are reduced to one pair ("Music Path in LMS" / "Music Path in MusicIP"); conversion now happens automatically whenever the MusicIP path field is filled in, replacing the old separate "Enable Dynamic Path Conversion" checkbox.
- Settings: "Live View Width", "Album Art Size" and the "Icon Position" fields for Live View/History are removed from the settings page (they had no effect in the Material skin); the values they used to control are now fixed internally at their last known defaults.
- Quickplay ("SugarCube Auto Mix") page simplified to a short splash screen ("Started a SugarCube Mix - Enjoy your Music!") that automatically jumps to Live View after about 3 seconds; the old New Track/Replace Next buttons and live Currently Playing/Coming Up Next display on this page are gone, superseded by Live View's own transport bar and buttons.
- Live View: dropped the redundant "SC Live View" title row, since Material's own dialog toolbar already shows that title.
- Quick Settings: Currently Playing / Coming Up Next now show cover art and text side by side per track (matching Live View's layout), with icon-only "Start New Mix"/"Replace Track" buttons under each cover instead of text-label buttons.
- Quick Settings: the empty-playlist "Start Mix" button now always starts a completely fresh mix (clears the queue and asks MusicIP for a new one), matching Live View's "New Mix" behaviour, instead of only replacing the kick-off track while leaving the rest of an existing queue in place.
- Quick Settings: the 60-second auto-return-to-menu timer is gone, since the live display now refreshes itself.
- Quick Settings: the "SugarCube is replacing/starting a mix..." status banner is gone, for the same reason - it was redundant now that the display refreshes on its own.

### Fixed
- Track candidates returned by MusicIP could lose their original acoustic-similarity/filter/recipe ranking once per-track metadata was pulled from the local database, because the SQL query used to fetch that metadata has no defined row order - so SugarCube could end up picking a track that wasn't actually MusicIP's top-ranked (or next-ranked) choice. A new `reorderByMIPRank` step now re-sorts the fetched results back into the order MusicIP originally returned them in before a track is chosen.
- MusicIP Export: fixed a path-encoding bug where converted paths could end up with mixed backslash/forward-slash separators depending on OS direction, breaking the rating/playcount push to MusicIP for NAS/DPC setups (mirrors an equivalent, previously-fixed bug in track selection's own path handling).
- Live View: cover art in Currently Playing / Coming Up Next and MusicIP Track Recommendations was stuck tiny (and, in Recommendations, square) as a side effect of a since-removed global icon-size setting; now a fixed 100x100 with rounded corners in both places.
- Live View: the page's own refresh interval was accidentally borrowing Lyrion's Classic-skin "refreshRate" server preference, which on this server happened to be set to 30 seconds for an unrelated Classic feature - so Live View (and its New Mix/Replace Track buttons) only actually refreshed once every 30 seconds instead of promptly. Live View now uses its own fixed 2-second refresh interval.
- Live View: pages reached directly from the SugarCube menu (rather than via the quickplay splash redirect) never auto-refreshed at all, leaving Currently Playing/Coming Up Next/Recommendations stale until manually reloaded. Auto-refresh is now always on for this page.
- Quick Settings: Currently Playing/Coming Up Next stopped refreshing a few seconds after the page loaded (only a short staggered catch-up, no ongoing refresh), unlike Live View's continuous 2-second refresh - noticeable with both pages open side by side. Quick Settings now refreshes on the same fixed 2-second interval as Live View.
- The recurring track-change/playlist-check timers (`SugarPlayerCheck` and related re-checks) used margins of +10/+15/+20 seconds, left over from when slow hardware was the bottleneck reading the LMS database; brought down to roughly 1 second now that this is no longer a common constraint, removing what looked like a "sometimes 10, sometimes way more" delay before a new mix or replacement actually appeared.

## 7.0.9.12 (2026-08-09)

### Fixed
- Live View "Play Album" / "Add Album" / "Add Track" buttons did nothing: they relied on `SqueezeJS.Controller.urlRequest(...)`, a classic-skin JS framework no longer loaded by current Lyrion Music Server, so every click silently failed (`SqueezeJS is not defined`). Rewritten to POST directly to `/jsonrpc.js`, the same pattern already used by Quick Settings' live Now Playing/Coming Up Next display.
- The player ID passed into that JSON-RPC call was reused from a variable already URL-encoded for query-string use (colons replaced with `%3A`), so even after the rewrite no player ever matched and the request silently failed. Now uses the raw, unencoded player ID for JSON-RPC calls.
- History page "Play Album" button did nothing: same dead `SqueezeJS.Controller.urlRequest(...)` dependency as the Live View buttons above, plus it concatenated the raw player object reference into the URL instead of a player ID string, so it could never have worked. Rewritten to use the same direct JSON-RPC POST to `/jsonrpc.js` with the actual player ID.

### Changed
- Plugin icon (`sugarcube.png`) and Live View "Add Track" icon (`sugarcube2.png`) redesigned; the Add Track icon's rendered size was bumped from 17x17 to 24x24 to match the neighbouring Play/Add Album icons.

## 7.0.9.11 (2026-07-31)

### Fixed
- Multi-player database: `AlbumTracker`, `ArtistTracker` and `TrackTracker` used a `UNIQUE` constraint on the value column alone instead of `(client, value)`, so `INSERT OR REPLACE` could silently steal a row from one player's client the moment another player played the same artist/album/track, causing that player to "forget" it. Existing databases are migrated automatically on plugin startup; the pre-migration table is kept (as `old_AlbumTracker`/`old_ArtistTracker`/`old_TrackTracker`) instead of being dropped, so the original data isn't lost if anything looks wrong afterwards.
- Multi-player database: the trim routines for `AlbumTracker`, `ArtistTracker`, `TrackTracker` and `History` counted rows per client but deleted the globally oldest row with no client filter, so one busy player's activity could evict a quieter player's tracked history.
- `mystuff()` (the candidate pull used for track selection when no statistics sorting is active) had no `ORDER BY`, so SQLite could return rows in an undefined order instead of MIP's own acoustic-similarity ranking. Now explicitly sorted by `id ASC`.
- Block Album Repeating slider could not be set to 0 (minimum was 1), even though the backend already treated 0 as "no blocking".
- "Sync Settings Across CHOSEN Players": several settings (FreeStyle file type, mode, year range, FreeStyle length, fade on/off, fade time, dupper) were accidentally written back to the current player instead of the target player during a sync, so they never actually got synced.
- FreeStyle mode: `$sugarcube_filetype == 0;` used a comparison instead of an assignment, so the "default to Anything" fallback for an empty file-type setting never actually happened.

### Changed
- "Sync Settings Across ALL Players" is now "Sync Settings Across CHOSEN Players": instead of blindly overwriting every known player, an expandable checklist lets you pick which players receive the synced settings. Your selection is remembered between visits.

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
