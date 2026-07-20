
SugarCube
====
![Min. LMS Version](https://img.shields.io/badge/Min._LMS_Version_Required-7.9-darkgreen)<br>

A modified version of the SugarCube plugin by [AF-1](https://github.com/AF-1/).<br>
**No guarantees that it will work or continue to do so**.<br>

> [!NOTE]
> ⚠️ **I'm maintaining this plugin. I do provide support for it, scarse .**<br>
> This version is based on the [**7.1.0** github version](https://github.com/AF-1/lms-sugarcube/), *<ins>not</ins> version 6.01*.<br>
> If you have any problems, check out the [Lyrion Community Support Forum](https://forums.lyrion.org/).

<br><br><br>

## Changes

✨ Added a new **SugarCube Quick Settings** page (under *Extras*) to change Mix Style/Variety, Mix Type, and whichever of Filter/Genre/Artist/Mood/Mood Filter/Recipe applies, on the fly - everything saves instantly.<br>
✨ Changing Filter, Recipe, Genre, Artist, Mood or Mood Filter in Quick Settings now automatically replaces the upcoming track to match, with a live "Currently Playing" / "Coming Up Next" view and a "Replace This Track" button under each.<br>
✨ The "SugarCube Auto Mix" page now also shows "Coming Up Next", with its own replace button. The "New Track" button no longer clears anything already queued after the current track.<br>
🐛 Fixed the "Replace Track" function, with the correct "Per Player" settings, replacement is reliable now. <br>
🐛 Fixed the MusicIP Vintage Mode section not collapsing correctly in the Material app.<br>
🐛 Fixed Genre/Artist/Mood Mixing not producing a mix when starting from an empty playlist.<br>
✨ Statistics (ratings, play counts…) are now pulled **directly from the LMS database**.<br>
❌ The deprecated **TrackStat** plugin is therefore no longer supported / required.<br>
✨ Added "Floating Wobble" option at the per player settings part of "Sugarcube Wobble"<br>
✨ Removed Google Traffic from the global settings part.<br>
✨ Added "Preferred Artist" and "Less Preferred Artist" with "Weighting" option at the per player settings part.<br>
  ⚠️ *Known issue: artist names with special characters (e.g. ö, é) may not match reliably yet.*<br>
✨ Changed the behavior of Sugarcube Auto Mix button

<br><br><br>

## Installation

- Add the repository URL below at the bottom of *LMS* > *Settings* > *Plugins* and click *Apply*:<br>
https://raw.githubusercontent.com/HB64/lms-sugarcube/main/public.xml

- Install the plugin from the added repository at the bottom of the page.

- If you want to see statistics (rating, play count…), go to `LMS > Settings > Advanced > SugarCube` and enable *Show statistics*.

<br><br><br>
