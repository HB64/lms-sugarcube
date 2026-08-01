# HB64 fork vs AF1 upstream `main` — unique settings/features inventory

Comparison date: 01-08-2026
HB64 fork version at time of writing: 7.0.9.11
AF1 upstream `main` version at time of writing: 7.1.0

Scope: this document lists settings/features/behaviour present in the HB64 fork (`HB64/lms-sugarcube`) that are **not** present in AF1's upstream `main` (`github.com/AF-1/lms-sugarcube`), based on a file-by-file comparison of the current state of both repos.

Explicitly excluded (already upstreamed separately, not repeated here):
- Multi-player database bug (`AlbumTracker`/`ArtistTracker`/`TrackTracker` UNIQUE constraint + per-client trim bug) — sent via PR #7
- Block Album Repeating slider minimum-0 fix — sent via PR #9

Status legend: ✅ done, 🔲 not yet compared

| File | Status |
|---|---|
| install.xml | ✅ |
| strings.txt | ✅ |
| overview.txt | ✅ (fork-only, not present upstream) |
| README.md / CHANGELOG.md | ✅ (fork-only files, not present upstream) |
| Settings.pm | ✅ |
| PlayerSettings.pm | ✅ |
| ProtocolHandler.pm | ✅ |
| Breakout.pm | ✅ |
| Plugin.pm | ✅ (fully verified — see below) |
| HTML settings pages | ✅ (fully verified against complete AF1 repo) |

---

## install.xml

| | HB64 | AF1 main |
|---|---|---|
| version | 7.0.9.11 (own numbering scheme, ahead of AF1's) | 7.1.0 |
| creator | Charles Parker, AF, HB64 | Charles Parker, AF |
| homepageURL | https://github.com/HB64/lms-sugarcube | https://github.com/AF-1/lms-sugarcube |

Fork-unique: own version numbering line, HB64 added to creator credit, homepage points to HB64's fork.

## overview.txt

Present only in the HB64 fork. Informal developer notes describing the `kickoff` flow (MIP request build, `gotMIP` handling, DB save/drop logic). Not present in AF1 main at all (not a settings/feature difference, just internal dev documentation — noted for completeness).

## README.md / CHANGELOG.md

AF1 main has a minimal root `README.md` (states it's unmaintained, based on the 6.01 open-source version, notes that stats now come from the LMS DB instead of TrackStat, gives install instructions). It has **no CHANGELOG.md**.

HB64's `README.md` and `CHANGELOG.md` are fork-only additions documenting the fork's own history in detail (version 6.01 → 7.0.9.11). These files themselves are fork-unique, and their content overlaps with the feature diffs below (Artist Weighting, Floating Wobble, Traffic removal, Replace Track fixes, Quick Settings, Sync-to-chosen-players, etc.) — see per-file sections for the underlying code-level confirmation.

## strings.txt

**Removed entirely in HB64** (Google Traffic module strings, confirms full removal — AF1 main still ships these even though the feature "only worked on a car head unit and is no longer functional" per HB64's own changelog):
`PLUGIN_TRAF_JOURNEY`, `PLUGIN_TRAF_ORIGIN`, `PLUGIN_TRAF_DESTINATION`, `PLUGIN_TRAF_ORIGIN_TWO`, `PLUGIN_TRAF_DESTINATION_TWO`, `PLUGIN_TRAF_APIKEY`, `PLUGIN_TRAF_FROM`, `PLUGIN_TRAF_TO`, `PLUGIN_TRAF_ENABLE`, `PLUGIN_TRAF_ENABLE_TWO`, `PLUGIN_TRAF_DAYS`, `PLUGIN_TRAF_MON/TUE/WED/THU/FRI/SAT/SUN`.

Also removed from `PLUGIN_SUGARCUBE_DESCINSTALL`: the "Google Traffic" mention in the plugin description.

**New in HB64, not in AF1 main** (grouped by feature):

*Mood Mixing* (Mix Type option using MusicIP's Mood playlists):
`PLUGIN_SC_WEB_MOOD`, `PLUGIN_SC_WEB_MOODDESC`, `PLUGIN_SC_WEB_MOOD_FILTER`, `PLUGIN_SC_WEB_MOOD_FILTERDESC`, `PLUGIN_SC_WEB_ALARMMOOD`, `PLUGIN_SC_WEB_ALARMMOODDESC`.

*Artist Weighting* (per-player preferred/less-preferred artists with a 1–5 weight):
`PLUGIN_SC_WEB_ARTISTWEIGHT_HEADER`, `PLUGIN_SC_WEB_PREFERARTIST`, `PLUGIN_SC_WEB_PREFERARTISTDESC`, `PLUGIN_SC_WEB_PREFERARTIST_WEIGHT`, `PLUGIN_SC_WEB_PREFERARTIST_WEIGHTDESC`, `PLUGIN_SC_WEB_LESSARTIST`, `PLUGIN_SC_WEB_LESSARTISTDESC`, `PLUGIN_SC_WEB_LESSARTIST_WEIGHT`, `PLUGIN_SC_WEB_LESSARTIST_WEIGHTDESC`.

*SugarCube Quick Settings page* (on-the-fly mix controls, Extras menu):
`PLUGIN_SUGARCUBEQS`, `PLUGIN_SC_WEB_NEWTRACK`, `PLUGIN_SC_WEB_PICKING`, `PLUGIN_SC_WEB_QS_SAVED`, `PLUGIN_SC_WEB_QS_APPLY`, `PLUGIN_SC_WEB_QS_REPLACING`, `PLUGIN_SC_WEB_QS_REPLACING_CURRENT`, `PLUGIN_SC_WEB_QS_STARTING`, `PLUGIN_SC_WEB_QS_REPLACEAGAIN`, `PLUGIN_SC_WEB_QS_STARTMIX`, `PLUGIN_SC_WEB_VARIETY_INFO`, `PLUGIN_SC_WEB_CLOSE`.

*Sync Settings Across CHOSEN Players* (was "ALL Players" in AF1 — HB64 changed this to an opt-in player checklist):
`PLUGIN_SC_WEB_SETSAVE_PLAYERS`, `PLUGIN_SC_WEB_SETSAVE_PLAYERSDESC` are new; `PLUGIN_SC_WEB_SETSAVE` / `PLUGIN_SC_WEB_SETSAVEDESC` text changed from "ALL Players" / "overwrite ... across all current known Players" to "CHOSEN Players" / "overwrite ... on the Players selected below".

*Dynamic Path Conversion — extra description*:
`PLUGIN_SC_WEB_DYNAMICCONVERSIONDESC` is new (a fuller explanation of what DPC does). In addition, HB64 appended a troubleshooting tip ("after switching to a different MusicIP instance or version ... always clear and rescan your LMS library") to three existing DPC description strings: `PLUGIN_SC_WEB_NASCONVERTPATHDESC`, `PLUGIN_SC_WEB_LOCALMEDIAPATHDESC`, `PLUGIN_SC_WEB_LOCALMEDIAPATHDESCTWO`.

*Replace-Track / variety tooltips*: HB64 appended a "Tip: for best variety with Replace/Start a Mix, set this, ... high" hint to `PLUGIN_SC_WEB_BLOCKARTISTDESC`, `PLUGIN_SC_WEB_BLOCKALBUMDESC`, `PLUGIN_SC_WEB_REMEMBERTRACKSDESC`.

*Alarm Clock Settings wording*: `PLUGIN_SC_WEB_ALARM_TYPE` renamed "Auto Mix and Alarm Clock Settings" → "Alarm Clock Settings"; `PLUGIN_SC_WEB_ALARM_TYPEDESC` rewritten to mention Mood and clarify the regular Auto Mix button no longer uses this setting.

*Leftover branding quirk*: `PLUGIN_SUGARCUBE_DESCINSTALL` in HB64 still contains a link to "www.spicefly.com ... for Change Log" that AF1 main has already dropped — likely an oversight worth cleaning up rather than an intentional fork feature.

---

## Settings.pm (global/advanced settings backend)

**Removed in HB64**: all Google Traffic prefs (`traf_enable`, `traf_origin`, `traf_destination`, `traf_enable_two`, `traf_origin_two`, `traf_destination_two`, `traf_journey_one`, `traf_journey_two`, `traf_key`, `traf_from`, `traf_to`, `traf_mon/tue/wed/thu/fri/sat/sun`) — both the save (`saveSettings`) and load blocks. Confirms the string-level removal is backed by real code removal, not just hidden UI.

**Other observed differences (code-level, not user-facing features)**:
- AF1 normalizes several checkbox values with `? 1 : 0` (e.g. `sugarxmas`, `sugardpc`) before saving; HB64 saves the raw form value as-is. Not a feature difference, just something AF1 hardened that HB64's branch predates.
- HB64 still defines its own `getDisplayName` sub and registers the log category via `Slim::Utils::Log->addLogCategory({...})`; AF1 simplified this to a one-line `logger('plugin.sugarcube')`. Cosmetic/structural, not a setting.

## PlayerSettings.pm (per-player settings backend)

**New in HB64, not in AF1 main:**

*Mood Mixing* — new `getMoodsList()` sub calling MusicIP's `/api/moods` endpoint, plus prefs `sugarcube_mood`, `sugarcube_mood_filter`, `scalarm_mood` (Mood used for the Alarm Clock playlist). Fully separate from the pre-existing Genre/Artist/Filter mixing.

*Artist Weighting* — 6 new prefs: `scpreferartist_one/two/three` (+ matching `_weight`) and `sclessartist_one/two/three` (+ matching `_weight`). This is a separate mechanism from the old "Track Duplication Weighting" (`sugarcube_weighting` / `sugarcube_weightingtxt`), which both forks still carry unchanged.

*Sync Settings Across CHOSEN Players* — new `getPlayerList()` sub (returns all other known players as an id→name hash) plus prefs `sugarcube_megasaver_players` (remembers which player IDs were last selected) and the runtime-only `sc_players` / `sc_sync_selected` params used to render the checklist. Functionally replaces AF1's blind "loop over every client" mega-save with an opt-in per-player checklist; HB64 keeps the old `grabPlayers()` sub too (now effectively dead code, superseded by `getPlayerList()`).

**Other observed differences (code-level, not user-facing features)**:
- Same checkbox-normalization pattern as `Settings.pm`: AF1 coerces most checkbox params with `? 1 : 0` before saving (`sugarcube_dupper`, `sugarcube_vintage`, `sugarcube_restrict_genre`, `sugarcube_clear`, `sugarcube_volume_flag`, `sugarcube_sleep`, `sugarcube_vartist`, `sugarcube_dynamicq`, `sugarcube_clearstats`, `sugarcube_albumoveride`, `sugarcube_megasaver`), HB64 does not. Potential latent bug in HB64 (unchecked checkbox may save as empty string instead of `0`) — not a feature, just worth knowing since it could affect how those settings behave when a checkbox is unticked.
- HB64 keeps the old `getDisplayName` / `addLogCategory` pattern instead of AF1's simplified `logger(...)` call — same cosmetic difference as in `Settings.pm`.
- `sugarcube_fade`, `sugarcube_sn`, `scubelicense`, `sugarcube_weighting`/`weightingtxt`, `sugarcube_morningfilter`/`dayfilter`/`eveningfilter`, `sugarcube_upnext` are present in **both** forks unchanged (older Spicefly-era prefs, not fork-unique — noted here only because they could easily be mistaken for HB64 additions).

## ProtocolHandler.pm

No settings/feature differences. Only the same cosmetic logging-setup difference as the other `.pm` files (HB64: `getDisplayName` + `addLogCategory`; AF1: one-line `logger(...)`).

**Possible latent bug worth knowing about (not a feature):** in the `overridePlayback` timer call, HB64 has `\&Plugins::SugarCube::Plugin::AlarmFired($client),` — because of the parentheses, Perl calls `AlarmFired($client)` immediately and takes a reference to its *return value*, instead of deferring the call. AF1's version fixed this to `\&Plugins::SugarCube::Plugin::AlarmFired, $client` (a proper coderef + argument passed to the timer). This looks like a real functional bug carried over from the old codebase that could affect Alarm Clock playback timing — flagging here in case it's worth a fix, separate from the two already-upstreamed PRs.

## Breakout.pm (core database / track-selection logic)

Note: HB64 and AF1 format this file completely differently (HB64: 4-space perltidy-style wrapping; AF1: tab-indented single-line statements), so a raw line diff is mostly noise. The comparison below is semantic (sub-by-sub logic reading), done via subagent, cross-checked against the sub list. Excluded per scope: the multi-player database UNIQUE-constraint/migration fix and the Block Album Repeating slider min-0 fix (both already sent via PR #7/#9), wherever they appear in this file.

**New in HB64, not in AF1:**

*Artist Weighting* (`applyArtistWeighting`, ~100 new lines, called from `Plugin.pm` right after `mystuff()` builds the candidate list) — entirely new sub, no AF1 equivalent. Reads the 3 "Preferred Artist" prefs (`scpreferartist_one/two/three` + matching `_weight`, default weight 1) and 3 "Less Preferred Artist" prefs (`sclessartist_one/two/three` + matching `_weight`). For each candidate track it normalizes both the track's artist name and the configured name (lowercase, strip non-alphanumerics, collapse whitespace) and does a substring match. A "Preferred" match duplicates that track `weight + 1` times in the candidate array (so it's more likely to be picked later by the existing random-selection logic). A "Less Preferred" match randomly drops the track with probability `1 - 1/(weight + 1)` (soft suppression, not a hard block). If weighting would filter out every candidate, it falls back to the original unweighted list so a track always gets picked.

*Artist blocking widened to substring match* (`getRandom`) — AF1 blocks an artist only on an exact match (`contributors.name <> 'X'`); HB64 wraps the blocked name in `%...%` and uses `NOT LIKE`, so blocking "Beatles" in HB64 also excludes anything containing "Beatles" (e.g. a tribute act), where AF1 would only block an exact-name match. Small change, real behavioural difference for the "Always Block Selected Artist" fields.

**Possible bugs/regressions in HB64, not features (flagging for awareness, not part of the two known PRs):**
- `getmyTSNextSong` / `getmyNextSong`: missing AF1's `return unless $track;` guard after looking up the track object — if the playlist URL is no longer in the library, HB64 can die with a runtime error where AF1 safely bails out.
- `DropArtists`: HB64 dropped the parentheses around the artist-block OR-conditions that AF1 has (`WHERE (A OR B OR C) AND client = X`). Without them, SQL's AND-before-OR precedence means the client filter only applies to the third condition, so the first two "Always Block Selected Artist" conditions can leak across players sharing the WorkingSet table. Notably, HB64's own `DropGenreAndXMas` has a comment warning about exactly this precedence pitfall and gets it right there — the fix just wasn't carried over to `DropArtists`.
- `AlbumArtistTracker`: AF1 treats an unconfigured "Do not Block Various Artists" setting the same as "blocking enabled" (`!defined($sugarcube_vartist) || $sugarcube_vartist == 1`); HB64 checks only `$sugarcube_vartist == 1`, so a player that has never touched this setting gets the opposite default (Various Artists tracked/blocked instead of left alone).
- `SaveHistory` / `GrabHistory`: AF1 guards every field with `defined($_) ? $_ : ''` on both write and read; HB64 doesn't, so a NULL can end up in the History table and propagate as `undef` instead of an empty string downstream.

All other subs (`getalbum`, `getRealRandom`, the three `FSgetRealRandomSubset*` variants, `getTSSongDetails`, `getSongDetails`, `getGenre`, `getSongTechnical`, `wipeourtracks`, `playlistcull`, `CheckPosition`, `init`, `postinitPlugin`, `myworkingset`, `TrackTracker`, `mystuff`, `dup_tracks`, `tssorting`, `droptsmetrics`, `DropGenreAndXMas`, `DropAlbums`, `DropEmPunk`, `update_duplicate`, `StatsPuller`, `get_track_length`) are functionally equivalent between the two forks (formatting/whitespace differences only, plus AF1 having more defensive `defined()` guards that don't change behaviour in Perl's default warning-free comparisons).

## Plugin.pm (main plugin logic — 5300 lines)

Fully verified against AF1's complete `Plugin.pm` (fetched in two passes due to the ~76,000-character fetch-tool limit on the first pass, then cross-checked against the complete file Henk supplied locally). All findings below are direct, line-for-line comparisons, not corroboration-based guesses.

### Confirmed new in HB64 (verified against real AF1 code)

*Replace Next Track — full rework* (`SugarCubeReplaceNext`, ~90 changed/added lines vs AF1's ~35-line version): AF1's version just clears the next-track slot and calls a bare `kickoff($client)`. HB64 additionally (a) registers the just-replaced track in `TrackTracker` via `Breakout::TrackTracker` so it's genuinely excluded from future picks (previously only logged, per the 7.0.9.8 changelog entry), (b) passes the dropped track's URL into `kickoff($client, $droppedurl, 1)` as an "avoid this track" hint plus a flag to insert the replacement right after the current track instead of appending it to the playlist end, and (c) adds an empty-playlist fallback that routes through the same path as the "SugarCube Auto Mix" button instead of calling `kickoff` (which needs an existing seed track).

*`kickoff` / `gotMIP` — avoid-URL and insert-position plumbing*: `kickoff` gained two new optional params (`$avoidurl`, `$insertnext`) threaded through to `SendtoMIPAsync`. `gotMIP` uses them to (a) filter the just-replaced/just-playing track out of MusicIP's candidate list before falling into wobble/selection logic, and (b) insert the new track right after the current position (`addtrack($client, $song, 'insert')`) instead of only appending.

*"Replace Current Track" (kick-off track) plumbing in `gotMIP`*: a new `$creator eq 'SpiceflyReplaceKickoff'` branch inserts the new track right after the currently-playing one, jumps playback to it, then removes the old "now playing" entry — leaving anything already queued after it untouched. The triggering sub (`ReplaceKickoffTrack`) lives later in the file (see tail section below); this is the receiving half of that feature.

*NAS/Dynamic-Path-Conversion backslash fix* (`gotMIP`): after the existing `nasconvertpath`/`nasconvertpath_2` substitutions, HB64 adds `$element =~ s/\\/\//g;` to normalize any leftover Windows-style backslashes to forward slashes, fixing the path-format mismatch that silently broke track-level "avoid repeat" exclusion on NAS/DPC setups (7.0.9.8 changelog entry) — confirmed present in AF1-absent form.

*Artist Weighting call site* (`gotMIP`, line ~2635): `@myworkingset = Plugins::SugarCube::Breakout::applyArtistWeighting($client, @myworkingset);`, applied right before the avoid-URL filter and wobble logic — the wiring for the feature already documented under Breakout.pm.

*Floating Wobble (Random)* (`gotMIP`): AF1 only implements Wobble strengths 1–3 (Tight/Medium/Loose, fixed). HB64 adds a 4th wobble mode that picks randomly between the three each time a track is selected (`int(rand(3))+1`), matching the 7.0.8.1 changelog entry.

*`reorderByMIPRank`* — an entirely new sub (no AF1 equivalent at all), called twice from `gotMIP` to restore MusicIP's original acoustic-similarity ranking before results are handed to `myworkingset`/the drop logic. AF1 has no equivalent re-sort step.

*Genre-blocking respected by the Replace fallback* (`randompuller`): before falling back to "another track in the currently-playing genre," HB64 now checks that genre against the three "Always Block this Genre" prefs and returns `"FAILED"` if it's blocked, instead of handing back a track in an explicitly-blocked genre (7.0.8.3 changelog entry).

*New "smooth next track" one-shot mechanism* (`SugarDelay`, and repeated later in `commandCallback`): when pref `sugarcube_sn` is enabled and a one-shot `sugarcube_ns_active` flag is set, it overrides the player's server-level `transitionType` (crossfade/fade) with `sugarcube_fade`, clears the flag, and forces playlist repeat off. Not present in AF1. (Note: `sugarcube_sn`/`sugarcube_fade` prefs exist in both forks per the PlayerSettings.pm comparison, but this specific consuming logic in `SugarDelay` is HB64-only.)

**Possible bugs/regressions spotted in this range (not part of the two known excluded PRs):**
- `randompuller`: AF1 guards with `if (!defined($song) || $song eq 'sugarcube:track')`; HB64 dropped the `!defined($song)` half. If there's no current track, HB64 falls through into `Breakout::getGenre($client, $song)` with an undefined `$song` instead of safely returning `"FAILED"` like AF1 does.
- `SugarPlayerCheck`: AF1 defaults `$quicksong` with `|| ''`; HB64 doesn't. Likely cosmetic (a stray warning against `undef`) rather than a real behavioural difference, but noted for completeness.
- **One inconsistency worth a look (not a regression):** in `buildMIPReq`, the Artist-Mixing branch (mix type 3) discards the seed track entirely and rebuilds the request URL from scratch, while Filter/Genre/Mood all append onto the existing seeded URL. May be intentional (an artist-seeded mix arguably shouldn't also seed off a specific song) but is inconsistent with the other three mix types — worth double-checking it's deliberate.

### Confirmed new in HB64 — verified against AF1's complete `Plugin.pm`

*Mood Mixing request-building* (`buildMIPReq`, new `elsif ($sugarcube_mix_type == 4)` branch — AF1's chain only has 1/2/3, confirmed no trace of a 4th branch anywhere): reads `sugarcube_mood`, OS-appropriate-escapes it, appends `&mood=<value>` unless `'0'`/`'(None)'`; independently reads `sugarcube_mood_filter` and appends `&filter=<value>` the same way, so a Mood can be combined with an extra filter layer. The Alarm Clock equivalent lives in `AlarmFired` (new `sugarcube_alarm_type == 2` "Mood Mode" branch, confirmed absent from AF1 which only has Filter (0) and Genre (else)), using `scalarm_mood` + the shared `scalarm_filter` pref.

*Empty-seed-track handling in `buildMIPReq`* (confirmed HB64-only): `$seedpart = ($tracktitle eq '') ? '' : (...)"` — omits `&song=`/`&album=` entirely when there's no seed track. AF1 has no such guard and always sends the seed parameter, even empty. This is what makes kicking off a mix from an empty playlist actually work cleanly in HB64.

*NAS/Dynamic-Path-Conversion slash-direction fix in `buildMIPReq`* (confirmed HB64-only, separate from the similar fix already noted in `gotMIP`): after the `nasconvertpath`/`nasconvertpath_2` substitutions, HB64 adds `$tracktitle =~ s/\//\\/g` when the configured NAS path uses backslashes, so a Linux-formatted path converted for a Windows/NAS MusicIP instance doesn't end up with mixed slash styles. AF1 does the substitution but never flips the slash direction afterward.

*`AutoStartMix` redesign*: AF1's version duplicates `AlarmFired`'s Filter/Genre-only URL-building logic in a separate standalone block (no Mood, no Artist, needs its own "Auto Mix and Alarm Clock Settings" filter configured). HB64 replaced this with a simple call to `buildMIPReq($client, '')`, so Auto Mix automatically reuses whatever Mix Type (Filter/Genre/Artist/Mood/Recipe) is already configured for the player instead of needing a separate, duplicate configuration.

*SugarCube Quick Settings page* — confirmed 100% HB64-only (AF1's `webPages` registers only 3 pages: Live View, History, Quick Play; HB64 adds a 4th, `PLUGIN_SUGARCUBEQS`, with its own page links under `browseiPeng`/`browse`, icon, `quicksettings.html` route, and `handleWebQuickSettings` handler — this sub doesn't exist in AF1 at all). It saves every field instantly on change (`sugarcube_mix_type`, `sugarcube_filteractive`, `sugarcube_genre`, `sugarcube_artist`, `sugarcube_mood`, `sugarcube_mood_filter`, `sugarcube_style`, `sugarcube_variety`, `sugarcube_album_song`, `sugarcube_receipes`) with no separate Save button.

*Automatic "Replace Next/Current Track" wiring* — confirmed HB64-only: `handleWebQuickSettings` and `handleWebQP` both track whether an "identity" field (filter/genre/artist/mood/mood_filter/recipe) actually changed, and if so call `SugarCubeReplaceNext($client)` (or `ReplaceKickoffTrack($client)` — also entirely new, no AF1 equivalent sub at all — for the "replace current/kick-off track" button), force-resuming playback first if it had stalled. `SendtoMIPAsync` and `addtrack` both gained new parameters to support this (`avoidurl`/`insertnext` on `SendtoMIPAsync`; an `'insert'` vs `'add'` mode on `addtrack`, where AF1's only ever appends).

*`handleWebList` Mood configuration-error check*: HB64 adds an `elsif ($sugarcube_mix_type == 4)` branch to the "CONFIGURATION ERROR" status message ("No Mood is specified") — AF1 only checks types 1/2/3, consistent with Mood Mixing being HB64-only.

**Correction to the earlier (partial-data) pass:** the "Currently Playing"/"Coming Up Next" widget data in `handleWebList` (the `%cpartist`/`%cptrack`/... and `%upnartist`/`%upntrack`/... hashes) turns out to be **already present in AF1**, not an HB64 addition — only the Mood-specific status-message branch above is new. `ReplaceKickoffTrack` and `UpNext` themselves: `UpNext` (the on/off toggle) is identical in both forks; only `ReplaceKickoffTrack` is genuinely new.

*"Sync Settings Across CHOSEN Players"* — confirmed self-contained in `PlayerSettings.pm`; `Plugin.pm`/`commandCallback` has no wiring for `sugarcube_megasaver_players` at all (in either fork, trivially, since the pref doesn't exist upstream).

*Credits/confirmation page* — **correction after full HTML comparison (see below): this is NOT a HB64-unique feature.** AF1's `quickplay.html` already has the identical "Enjoy your mix!"-style confirmation with the same Material-skin-dialog-close trick and 10-second auto-return; HB64 just refactored it into named JS functions. What IS genuinely new is the interactive Currently-Playing/Coming-Up-Next widget layer built on top of that shared base — see the HTML section below.

*New "smooth next track" logic duplicated into `commandCallback`*: on top of the existing copy in `SugarDelay` (already noted above), HB64's `commandCallback` also resets `transitionType`/`sugarcube_ns_active`/playlist-repeat on the `play` command. Confirmed absent from AF1. Not necessarily a bug (may be deliberate belt-and-braces for both trigger points) but worth knowing it's duplicated logic.

Everything else in the file (`objectForUrl`, `gotErrorViaHTTP`, `gotErrorContinue`, `findtrackurl_frompos`, `dupper`, `slideVolume`, `sleepplayer`, `dirtyencoder`, `Shuffle`, `ToggleInjector`, `UpNext`, `ToggleVolume` — apart from the bug below, `ToggleSleep`, `SugarCubeEnabled`/`Disabled`, `getAlarmPlaylists`, `handleWebListHistory`, `CheckSong`, `Volume_Save`, `StartFade`, `ReverseFade`, `Volume_Reset`, `SugarPlayerCheck`'s Coming-Up-Next/Technical-Info display) is functionally identical between the two forks.

### Bugs found via the full comparison (not features, not part of the two excluded PRs)

- **`ToggleVolume` pref-key typo (real, confirmed bug):** HB64's `ToggleVolume` writes the "Volume Fade" toggle to pref key `sugarcubevolume_flag` (no underscore between "sugarcube" and "volume"). Every other place in the codebase — `commandCallback`, `CheckSong`-adjacent code, `PlayerSettings.pm`, and `player.html`'s checkbox (`name="sugarcube_volume_flag"`) — reads/writes `sugarcube_volume_flag` (with the underscore), matching AF1 exactly. Net effect: toggling Volume Fade via this specific menu path writes to a pref nothing else reads, so **the toggle silently does nothing** — the real flag is left untouched. Looks like a copy-paste/find-replace slip during the fork's refactor of this function, well worth an actual code fix.
- **Google Traffic hook removed from `SugarPlayerCheck`**: AF1 calls `Plugins::SugarCube::Traffic::start($client)` here when `traf_enable` is set; entirely absent from HB64. This is consistent with (not contradicting) the deliberate, documented Traffic removal already covered under strings.txt/Settings.pm — HB64 doesn't ship a `Traffic.pm` module at all (confirmed: no such file anywhere in the fork), so the removal is thorough across settings, strings, the runtime hook, and the module file itself, not a separate accidental loss.
- Minor undef-safety differences (`handleWebList`'s `ne ''` comparisons, a few missing `|| 0`/`|| ''` defaults elsewhere) — cosmetic warning-suppression gaps only, no behavioural impact given Perl's undef-to-0/''-in-comparisons behavior.

## HTML settings pages

Verified against the complete AF1 repo (`AF1-SC` folder), not just a partial fetch.

**settings.html**: AF1 is longer than HB64 here (149 vs 92 lines) — the extra AF1 content is the entire Google Traffic settings block (journey/origin/destination ×2, API key, active-hours, day-of-week checkboxes), confirming the Traffic removal from the earlier strings.txt/Settings.pm findings is complete at the UI level too. Also confirms the earlier-noted leftover: HB64 keeps a "www.spicefly.com" link in the page description and a "Spicefly.com" link in the footer that AF1 has already dropped.

**player.html** (HB64 443 / AF1 327 lines) — the main per-player settings page:
- *Artist Weighting UI*: an entirely new collapsible section (`PLUGIN_SC_WEB_ARTISTWEIGHT_HEADER`) with 3 Preferred + 3 Less-Preferred artist fields, each paired with a 1–5 weight slider (`scpreferartist_one/two/three` + `_weight`, `sclessartist_one/two/three` + `_weight`) — confirmed 100% absent from AF1.
- *Mood Mixing UI*: `sugarcube_mix_type` gets a 5th option ("Mood Mixing", value 4, absent in AF1), plus two new fields `sugarcube_mood` and `sugarcube_mood_filter`. The Alarm Clock section also gets a 3rd alarm type ("Mood") and a new `scalarm_mood` field — none of this exists in AF1's player.html.
- *"Sync Settings Across CHOSEN Players"*: a new collapsible per-player checklist (`sc_sync_player_<id>` checkboxes, one per known player, pre-checked from `sc_sync_selected`) after the existing sync checkbox. AF1 has only the flat "sync to all" toggle with no player-selection UI at all.
- *Whole-page UX change*: HB64 wraps every settings group (FreeStyle, MIP Settings, Track Weight, Stats, Alarm, Volume, Sleep, Vintage, Misc) in collapsible `<details>` accordion sections; AF1 renders them as flat, always-visible blocks. This is a page-wide restructuring, not just new fields.
- Cosmetic: HB64 keeps a "Spicefly.com" credits link in the footer that AF1 dropped (same pattern as settings.html).

**quickplay.html** (HB64 203 / AF1 42 lines) — the "SugarCube Auto Mix" page:
- **Correction to the earlier Plugin.pm analysis:** the simplified "Started a SugarCube Mix - Enjoy your Music!" confirmation message, with its 10-second auto-return timer and the Material-skin dialog-close trick, **already exists in AF1** — it is not a HB64-only fix, despite being listed as a fork change in the CHANGELOG. HB64 only refactored the same logic into named JS functions (`scGoBack()`/`scArmAutoReturn()`).
- What genuinely is new in HB64, confirmed absent from AF1 (whose file ends right after the confirmation message): the "Currently Playing"/"Coming Up Next" display boxes with cover art, `scShowNowPlaying()` AJAX polling of `/jsonrpc.js` for live playlist state, the "New Track" button (`forcereplacekickoff=1`) and "Replace This Track" button (`forcereplace=1`), and an info-icon/popover tooltip system showing the variety tip (`PLUGIN_SC_WEB_VARIETY_INFO`).

**quicksettings.html** — HB64-only file, no AF1 equivalent exists at all. A standalone AJAX "Quick Settings" page: live Now-Playing/Coming-Up-Next display (same polling pattern as quickplay.html) each with its own Start-Mix/Replace-Again button and info popover; an auto-submitting form (`onchange="this.form.submit()"`) with `sugarcube_style`/`sugarcube_variety` as live-readout range sliders, `sugarcube_album_song`, the 5-way `sugarcube_mix_type` select, and conditionally-shown fields per mix type (`sugarcube_artist`/`sugarcube_genre`/`sugarcube_filteractive`/`sugarcube_mood`+`sugarcube_mood_filter`), plus `sugarcube_receipes`. Matches `handleWebQuickSettings` in Plugin.pm exactly.

**history.html**: byte-for-byte identical between the two forks.

**liveview.html**: essentially identical; AF1 has one extra defensive-default line (`refresh = refresh || 0`) that HB64 lacks — cosmetic, not functional.
