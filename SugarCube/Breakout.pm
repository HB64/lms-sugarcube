# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file
#

# Breakout contain all the database calls
# Queue up one of them depending on our criteria

package Plugins::SugarCube::Breakout;

use strict;
use warnings;
use base qw(Slim::Web::Settings);
use Plugins::SugarCube::Plugin;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
###
# ADDED 2026-08-14, Edit 57. Until this build every word on the Live View candidate list was an
# English literal welded into this file, so none of it could be translated or reworded without a
# code change. It is now looked up like everything else.
#
# ⛔ THE LOOKUPS HERE ARE DELIBERATELY THE CLIENT-FREE FORM, Slim::Utils::Strings::string, AND NOT
# $client->string. Two of the four subs that build this table - getTSSongDetails and scShortDate -
# have no client in scope at all, and the table is ONE table on ONE page. Mixing the two forms
# would let a single row render half in one language and half in another, which is the
# one-thing-two-names fault this project keeps closing. One form, whole table. Do not "tidy" them
# into $client->string without giving those two subs a client first.
###
use Slim::Utils::Strings;
use File::Spec::Functions qw(:ALL);
use DBI qw(:sql_types);

my $log = logger('plugin.sugarcube');
my $prefs = preferences('plugin.SugarCube');
my $apc_enabled;

# Get a Random Track based on provided Genre
sub getRandom {
	my $client = shift;
	my $genre = shift;

	my ($SCTRACKURL, $CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum);

	$log->debug("\nGet Random Track");

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	$genre = $dbh->quote($genre);

	my $sql = "SELECT tracks.url, contributors.name, tracks.title, albums.title, genres.name, tracks.coverid, tracks.album FROM albums INNER JOIN contributors ON (albums.contributor = contributors.id) INNER JOIN tracks ON (tracks.album = albums.id) INNER JOIN genre_track ON tracks.id = genre_track.track INNER JOIN genres ON genre_track.genre = genres.id WHERE genres.name = $genre order by random() ASC limit 1";

	my $sth = $dbh->prepare($sql);
	$sth->execute();
	$sth->bind_col (1, \$SCTRACKURL);
	$sth->bind_col (2, \$CurrentArtist);
	$sth->bind_col (3, \$CurrentTrack);
	$sth->bind_col (4, \$CurrentAlbum);
	$sth->bind_col (5, \$CurrentGenre);
	$sth->bind_col (6, \$CurrentAlbumArt);
	$sth->bind_col (7, \$FullAlbum);

	if ($sth->fetch()) {
		$SCTRACKURL = Slim::Utils::Unicode::utf8decode ($SCTRACKURL, 'utf8');
		$CurrentArtist = Slim::Utils::Unicode::utf8decode ($CurrentArtist, 'utf8');
		$CurrentTrack = Slim::Utils::Unicode::utf8decode ($CurrentTrack, 'utf8');
		$CurrentAlbum = Slim::Utils::Unicode::utf8decode ($CurrentAlbum, 'utf8');
		$CurrentGenre = Slim::Utils::Unicode::utf8decode ($CurrentGenre, 'utf8');
		$CurrentAlbumArt = Slim::Utils::Unicode::utf8decode ($CurrentAlbumArt, 'utf8');
		$FullAlbum = Slim::Utils::Unicode::utf8decode ($FullAlbum, 'utf8');
	}

	$sth->finish();
	return ($SCTRACKURL, $CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum);
}

sub getalbum {
	my $client = shift;
	my $song = shift;
	my $SCAlbum;

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare('SELECT tracks.album FROM tracks WHERE tracks.url = ?');
	$sth->execute($song);
	$sth->bind_col (1, \$SCAlbum);
	if ($sth->fetch()) {
		$SCAlbum = Slim::Utils::Unicode::utf8decode ($SCAlbum, 'utf8');
	}
	$sth->finish();
	return ($SCAlbum);
}

sub getRealRandom {
	my $randomtrack;
	my $SCTitle;

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sql = "SELECT tracks.url FROM tracks order by random() limit 1";
	my $sth = $dbh->prepare($sql);
	$sth->execute();
	$sth->bind_col (1, \$randomtrack);
	if ($sth->fetch()) {
		$randomtrack = Slim::Utils::Unicode::utf8decode ($randomtrack, 'utf8');
	}

	$sth->finish();
	return ($randomtrack);
}

#Statistics
sub getTSSongDetails {
	my $song = shift;
	my ($CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum, $PC, $Rat, $LP, $Year);

	my $table = $apc_enabled ? 'alternativeplaycount' : 'tracks_persistent';
	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	###
	# REWRITTEN 2026-08-09. Three faults, all found together:
	###
	my $query = "SELECT contributors.name, tracks.title, albums.title, group_concat(DISTINCT genres.name), tracks.coverid, tracks.album, $table.playCount, tracks_persistent.rating, $table.lastPlayed, albums.year FROM tracks INNER JOIN albums ON (tracks.album = albums.id) INNER JOIN genre_track ON (genre_track.track = tracks.id) INNER JOIN genres ON (genre_track.genre = genres.id) INNER JOIN tracks_persistent ON (tracks.urlmd5 = tracks_persistent.urlmd5) INNER JOIN contributor_track ON (contributor_track.track = tracks.id AND contributor_track.role IN (1,6)) INNER JOIN contributors ON (contributors.id = contributor_track.contributor)";
	$query .= " left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5" if ($apc_enabled);
	$query .= " where tracks.url = ? group by tracks.url";

	my $sth = $dbh->prepare($query);

	$sth->execute($song);
	$sth->bind_col (1, \$CurrentArtist);
	$sth->bind_col (2, \$CurrentTrack);
	$sth->bind_col (3, \$CurrentAlbum);
	$sth->bind_col (4, \$CurrentGenre);
	$sth->bind_col (5, \$CurrentAlbumArt);
	$sth->bind_col (6, \$FullAlbum);
	$sth->bind_col (7, \$PC);
	$sth->bind_col (8, \$Rat);
	$sth->bind_col (9, \$LP);
	$sth->bind_col (10, \$Year);

	if ($sth->fetch()) {
		if (!defined($PC) || $PC eq '') {
			$PC = Slim::Utils::Strings::string('PLUGIN_SC_LV_NEVERPLAYED');
		}
		if (!defined($Rat) || $Rat eq '') {
			$Rat = Slim::Utils::Strings::string('PLUGIN_SC_LV_NOTRATED');
		}

		if (!defined($LP) || $LP == -1) {
			$LP = Slim::Utils::Strings::string('PLUGIN_SC_LV_NEVERPLAYED');
		} else {
			# scShortDate turns 0 and undef into "Never Played" itself; the 1970 test that used to be
			# here was catching an epoch of 0 formatted as a date.
			$LP = scShortDate($LP);
		}

		$CurrentAlbum = scYearAlbum($Year, $CurrentAlbum);
		$CurrentGenre = scGenres($CurrentGenre);

		$CurrentArtist = Slim::Utils::Unicode::utf8decode ($CurrentArtist, 'utf8');
		$CurrentTrack = Slim::Utils::Unicode::utf8decode ($CurrentTrack, 'utf8');
		$CurrentAlbum = Slim::Utils::Unicode::utf8decode ($CurrentAlbum, 'utf8');
		$CurrentGenre = Slim::Utils::Unicode::utf8decode ($CurrentGenre, 'utf8');
		$CurrentAlbumArt = Slim::Utils::Unicode::utf8decode ($CurrentAlbumArt, 'utf8');
		$FullAlbum = Slim::Utils::Unicode::utf8decode ($FullAlbum, 'utf8');
		$PC = Slim::Utils::Unicode::utf8decode ($PC, 'utf8');
		$Rat = Slim::Utils::Unicode::utf8decode ($Rat, 'utf8');
		$LP = Slim::Utils::Unicode::utf8decode ($LP, 'utf8');
	}

	$sth->finish();

	return ($CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum, $PC, $Rat, $LP);
}

sub getmyTSNextSong {
	no warnings 'numeric';

	my $client = shift;
	my $song;
	my ($CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum, $PC, $Rat, $LP, $Year);
	###
	# ⚠ PLAYING, NOT STREAMING. Two faults fixed here 2026-08-12, both long-standing and both
	# invisible until something other than SugarCube filled the queue.
	###
	my $songIndex = Slim::Player::Source::playingSongIndex($client);
	$songIndex++;
	my $listlength = Slim::Player::Playlist::count($client);
	return if $songIndex >= $listlength;
	my $url = Slim::Player::Playlist::song ($client, $songIndex);
	return unless defined $url;
	my $track = Slim::Schema->rs('Track')->objectForUrl({'url' => $url});
	return unless $track;
	my $trackid = $track->id;

	my $table = $apc_enabled ? 'alternativeplaycount' : 'tracks_persistent';
	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	# Same three fixes as getTSSongDetails - see the note there. Track artist not album artist, every
	# genre not an arbitrary one, genre_track joined before genres, and year folded into the album.
	my $query = "SELECT contributors.name, tracks.title, albums.title, group_concat(DISTINCT genres.name), tracks.coverid, tracks.album, $table.playCount, tracks_persistent.rating, $table.lastPlayed, albums.year FROM tracks INNER JOIN albums ON (tracks.album = albums.id) INNER JOIN genre_track ON (genre_track.track = tracks.id) INNER JOIN genres ON (genre_track.genre = genres.id) INNER JOIN tracks_persistent ON (tracks.urlmd5 = tracks_persistent.urlmd5) INNER JOIN contributor_track ON (contributor_track.track = tracks.id AND contributor_track.role IN (1,6)) INNER JOIN contributors ON (contributors.id = contributor_track.contributor)";
	$query .= " left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5" if ($apc_enabled);
	$query .= " where tracks.id = ? group by tracks.url";
	my $sth = $dbh->prepare($query);

	$sth->execute($trackid);
	$sth->bind_col (1, \$CurrentArtist);
	$sth->bind_col (2, \$CurrentTrack);
	$sth->bind_col (3, \$CurrentAlbum);
	$sth->bind_col (4, \$CurrentGenre);
	$sth->bind_col (5, \$CurrentAlbumArt);
	$sth->bind_col (6, \$FullAlbum);
	$sth->bind_col (7, \$PC);
	$sth->bind_col (8, \$Rat);
	$sth->bind_col (9, \$LP);
	$sth->bind_col (10, \$Year);

	if ($sth->fetch()) {
		if (!defined($PC) || $PC eq '') {
			$PC = Slim::Utils::Strings::string('PLUGIN_SC_LV_NEVERPLAYED');
		}
		if (!defined($Rat) || $Rat eq '') {
			$Rat = Slim::Utils::Strings::string('PLUGIN_SC_LV_NOTRATED');
		}

		if (!defined($LP) || $LP == -1) {
			$LP = Slim::Utils::Strings::string('PLUGIN_SC_LV_NEVERPLAYED');
		} else {
			$LP = scShortDate($LP);
		}

		$CurrentAlbum = scYearAlbum($Year, $CurrentAlbum);
		$CurrentGenre = scGenres($CurrentGenre);

		$CurrentArtist = Slim::Utils::Unicode::utf8decode ($CurrentArtist, 'utf8');
		$CurrentTrack = Slim::Utils::Unicode::utf8decode ($CurrentTrack, 'utf8');
		$CurrentAlbum = Slim::Utils::Unicode::utf8decode ($CurrentAlbum, 'utf8');
		$CurrentGenre = Slim::Utils::Unicode::utf8decode ($CurrentGenre, 'utf8');
		$CurrentAlbumArt = Slim::Utils::Unicode::utf8decode ($CurrentAlbumArt, 'utf8');
		$FullAlbum = Slim::Utils::Unicode::utf8decode ($FullAlbum, 'utf8');
		$PC = Slim::Utils::Unicode::utf8decode ($PC, 'utf8');
		$Rat = Slim::Utils::Unicode::utf8decode ($Rat, 'utf8');
		$LP = Slim::Utils::Unicode::utf8decode ($LP, 'utf8');
	}

	$sth->finish();
	return ($CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum, $PC, $Rat, $LP);
}

sub getSongDetails {
	my $song = shift;
	my ($CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum);

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare('SELECT contributors.name, tracks.title, albums.title, genres.name, tracks.coverid, tracks.album FROM albums INNER JOIN contributors ON (albums.contributor = contributors.id) INNER JOIN tracks ON (tracks.album = albums.id) INNER JOIN genres ON (genre_track.genre = genres.id) INNER JOIN genre_track ON (genre_track.track = tracks.id) where tracks.url = ?');
	$sth->execute($song);
	$sth->bind_col (1, \$CurrentArtist);
	$sth->bind_col (2, \$CurrentTrack);
	$sth->bind_col (3, \$CurrentAlbum);
	$sth->bind_col (4, \$CurrentGenre);
	$sth->bind_col (5, \$CurrentAlbumArt);
	$sth->bind_col (6, \$FullAlbum);

	if ($sth->fetch()) {
		$CurrentArtist = Slim::Utils::Unicode::utf8decode ($CurrentArtist, 'utf8');
		$CurrentTrack = Slim::Utils::Unicode::utf8decode ($CurrentTrack, 'utf8');
		$CurrentAlbum = Slim::Utils::Unicode::utf8decode ($CurrentAlbum, 'utf8');
		$CurrentGenre = Slim::Utils::Unicode::utf8decode ($CurrentGenre, 'utf8');
		$CurrentAlbumArt = Slim::Utils::Unicode::utf8decode ($CurrentAlbumArt, 'utf8');
		$FullAlbum = Slim::Utils::Unicode::utf8decode ($FullAlbum, 'utf8');
	}

	$sth->finish();
	return ($CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum);
}

sub getGenre {
	my $client = shift;
	my $song = shift;
	my $SCGENRE;

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare('SELECT genres.name FROM contributor_track INNER JOIN tracks ON (contributor_track.track = tracks.id) INNER JOIN contributors ON (contributor_track.contributor = contributors.id) INNER JOIN genre_track ON (genre_track.track = tracks.id) INNER JOIN genres ON (genre_track.genre = genres.id) WHERE tracks.url = ?');
	$sth->execute($song);
	$sth->bind_col (1, \$SCGENRE);
	if ($sth->fetch()) {
		$SCGENRE = Slim::Utils::Unicode::utf8decode ($SCGENRE, 'utf8');
	}

	$sth->finish();

	return ($SCGENRE);
}

sub playlistcull {
	no warnings 'numeric';

	my $client = shift;
	my $songIndex = Slim::Player::Source::streamingSongIndex($client);
	###
	# FLOOR OF 50, from 2026-08-07. This setting stopped being cosmetic when DropInQueue started
	# reading the queue: how many tracks are kept behind the playing one IS how far back SugarCube
	# can see that it has already given you something. Below about 50 the skip-loop protection gets
	# thin, and a setting whose low end quietly disables a safety catch is the Dynamic Queuing trap
	# again.
	###
	my $songsToKeep = $prefs->client($client)->get('sugarcube_clutter');
	$songsToKeep = 50 if (!defined $songsToKeep || $songsToKeep eq '' || $songsToKeep < 50);
	if ($songIndex && $songsToKeep ne '' && $songIndex > $songsToKeep) {
		for (my $i = 0 ; $i < $songIndex - $songsToKeep ; $i++) {
			my $request = $client->execute ([ 'playlist', 'delete', 0 ]);
		}
	}
}

sub CheckPosition {
	my $client = shift;
	my $listlength = Slim::Player::Playlist::count($client);
	my $playingTrackPos = Slim::Player::Source::playingSongIndex($client);
	my $returnvalue = ($listlength - $playingTrackPos);
	return $returnvalue;
}

sub init {
	$log->info("Initialising SugarCube Database\n");
	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');

	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	# || 30 because init() is called from initPlugin BEFORE the sqlitetimeout default is written,
	# so on a fresh install this is undef and the multiplication warns. Same 30 the default uses.
	# '//' NOT '||' - a stored 0 is a VALUE, not a missing one. See the note above %clientDefaults
	# in Plugin.pm. initPlugin guarantees this pref exists, so the 30 is belt and braces.
	my $sqlitetimeout = $prefs->get('sqlitetimeout') // 30;
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	$dbh->do("CREATE TABLE IF NOT EXISTS WorkingSet (id INTEGER PRIMARY KEY, client, trackingno, temptrack, SCtrack, SCalbum, SCgenres, SCartist, SCplaycount integer, SCrating integer, SClastplayed integer, cover, album)");
	###
	# ArtistTracker/AlbumTracker - Henk's request 2026-09-11. "een manier om artiesten of albums
	# voor bepaalde tijd te blokkeren net als in de normale SC versie" - ports the hoofdmap build's
	# rolling window of the last N tracks' worth of artist/album (see TrackRepeatRecord/
	# DropRepeatArtist/DropRepeatAlbum below) back in, DELIBERATELY, as a narrow, scoped exception
	# to the self-cleaning-database rule right below this comment. Phase 7 removed these same two
	# tables because recency was meant to be read from APC/tracks_persistent instead - a
	# LIBRARY-WIDE view ("when did this artist last play, ever"). What comes back here is a
	# different, narrower thing APC cannot express at all: "how many tracks ago, on THIS player's
	# own recent picks" - reset the moment the player is fully idle long enough for the tables to
	# empty out on their own via the cap below, never growing unbounded. Both tables are still
	# entirely owned and pruned by SugarCube itself, same as WorkingSet, so they are named
	# explicitly below rather than silently caught by the drop-anything-else sweep.
	###
	$dbh->do("CREATE TABLE IF NOT EXISTS AlbumTracker (id INTEGER PRIMARY KEY, client, SCalbum, UNIQUE(client, SCalbum))");
	$dbh->do("CREATE TABLE IF NOT EXISTS ArtistTracker (id INTEGER PRIMARY KEY, client, SCartist, UNIQUE(client, SCartist))");
	###
	# History - Henk's request 2026-09-11, ported back from the hoofdmap build exactly as it stands
	# there (queue-time logging, not play-time - kept identical on purpose, see GrabHistory/
	# SaveHistory below). Same deal as AlbumTracker/ArtistTracker above: a DELIBERATE, scoped
	# exception to the self-cleaning rule right below, not an oversight. Phase 7 dropped this one
	# as a "cobweb" (recorded what was queued, not what was played), but it's the only place that
	# shows whether a track was a random fallback pick, which Henk wants visible rather than
	# signalled by deliberately repeating a track the way saysaar/guptaas's original plugin does.
	###
	$dbh->do("CREATE TABLE IF NOT EXISTS History (id INTEGER PRIMARY KEY, client, artist,track,album,genre,albumart,fullalbum)");
	###
	# SELF-CLEANING DATABASE. WorkingSet, AlbumTracker, ArtistTracker and History are the only
	# tables SugarCube owns (see the comments on the CREATE TABLEs just above for why the latter
	# three are back).
	###
	my $tables = $dbh->selectcol_arrayref(
		"SELECT name FROM sqlite_master WHERE type='table' "
		. "AND name NOT IN ('WorkingSet', 'AlbumTracker', 'ArtistTracker', 'History') AND name NOT LIKE 'sqlite_%'");

	for my $tbl (@$tables) {
		# INFO, not WARN - housekeeping, and it happens once. Step 8.4c.
		$log->info("Removing table '$tbl' - left over from a removed feature or an older version.\n");
		$dbh->do("DROP TABLE " . $dbh->quote_identifier($tbl));
	}

	my $catalog_rowset = $dbh->selectall_arrayref("PRAGMA table_info(WorkingSet)");
	my @col_names = map { $_->[1] } @{$catalog_rowset};
	if (grep { $_ eq 'cover' } @col_names) {
		# $log->debug("Database tables are up to date\n");
	} else {
		$log->debug("Updating database table\n");
		$dbh->do("ALTER TABLE WorkingSet ADD cover");
		$dbh->do("ALTER TABLE WorkingSet ADD album");
	}
	$catalog_rowset = $dbh->selectall_arrayref("PRAGMA table_info(WorkingSet)");
	@col_names = map { $_->[1] } @{$catalog_rowset};
	if (grep { $_ eq 'scyear' } @col_names) {
		# nothing to do
	} else {
		# Year added 2026-08-09. Called scyear, not year, because "year" is close enough to a
		# reserved word to be worth not finding out. Same ALTER pattern as cover/album/trackid above.
		$log->debug("Adding year to the working set table\n");
		$dbh->do("ALTER TABLE WorkingSet ADD scyear");
	}
	if (grep { $_ eq 'trackid' } @col_names) {
		$log->debug("Database tables are ready\n");
	} else {
		$log->debug("Updating database table some more\n");
		$dbh->do("ALTER TABLE WorkingSet ADD trackid");
	}
	$dbh->do("DROP TABLE IF EXISTS sugarcubeversion");
	$dbh->do("DROP TABLE IF EXISTS MIPReturned");
	$dbh->disconnect;
}

sub postinitPlugin {
	my $class = shift;
	$apc_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::AlternativePlayCount::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Alternative Play Count" is enabled') if $apc_enabled;
}

sub myworkingset {
	no warnings 'numeric';

	my $client = shift;
	my (@miparray) = @_;

	my $clientid = Slim::Player::Client::id($client);
	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');

	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare("DELETE FROM WorkingSet WHERE client = '$clientid' ");
	$sth->execute();

	$sth = $dbh->prepare("INSERT INTO WorkingSet (client, trackingno, temptrack, SCtrack, SCalbum, SCgenres, SCartist, SCplaycount, SCrating, SClastplayed, cover, album, trackid, scyear) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)");

	my $arraysize = scalar(@miparray);
	my $i = 0;
	while ($i < $arraysize) {
		my $SCplaycount = $miparray[ $i + 5 ];
		my $SCrating = $miparray[ $i + 6 ];
		my $SClastplayed = $miparray[ $i + 7 ];

		# If these are not set ie. statistics not enabled set to -1

		$SCplaycount += 0;
		if ($SCplaycount <= 0) {
			$SCplaycount = -1;
		}
		$SCrating += 0;
		if ($SCrating <= 0) {
			$SCrating = -1;
		}
		$SClastplayed += 0;
		if ($SClastplayed <= 0) {
			$SClastplayed = -1;
		}

		$sth->bind_param (1, $clientid, SQL_VARCHAR);
		$sth->bind_param (2, 'OK', SQL_VARCHAR);
		$sth->bind_param (3, $miparray[$i], SQL_VARCHAR); # temptrack; track filename
		$sth->bind_param (4, $miparray[ $i + 1 ], SQL_VARCHAR); #SCTrack
		$sth->bind_param (5, $miparray[ $i + 2 ], SQL_VARCHAR); #SCAlbum
		$sth->bind_param (6, $miparray[ $i + 3 ], SQL_VARCHAR); #SCgenres
		$sth->bind_param (7, $miparray[ $i + 4 ], SQL_VARCHAR); # SCartist
		$sth->bind_param (8, $SCplaycount, SQL_INTEGER); # playcount
		$sth->bind_param (9, $SCrating, SQL_INTEGER); # rating
		$sth->bind_param (10, $SClastplayed, SQL_INTEGER); # last played
		$sth->bind_param (11, $miparray[ $i + 8 ], SQL_VARCHAR); # cover
		$sth->bind_param (12, $miparray[ $i + 9 ], SQL_VARCHAR); # album
		$sth->bind_param (13, $miparray[ $i + 10 ], SQL_VARCHAR); # trackid
		$sth->bind_param (14, $miparray[ $i + 11 ], SQL_VARCHAR); # year (added 2026-08-09)
		$sth->execute;
		$i = $i + 12; # INCREMENT IF ADDING COLUMNS - and the two strides in Plugin.pm with it
	}

	$sth->finish();

	###
	# WHEN THIS POOL WAS BUILT. Added 2026-08-13, Edit 52.
	###
	$prefs->client($client)->set('sugarcube_lastmip', time());

	return;
}

sub mystuff {
	my $client = shift;
	my @myworkingset = ();
	my $clientid = Slim::Player::Client::id($client);

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare("SELECT temptrack, SCTrack, SCalbum, SCgenres, SCartist, SCplaycount, SCrating, SClastplayed, cover, album FROM WorkingSet WHERE WorkingSet.trackingno = 'OK' AND client ='$clientid' ORDER BY id ASC");
	$sth->execute();

	my $array_ref = $sth->fetchall_arrayref();
	foreach my $row (@$array_ref) {
		push @myworkingset,
		my ($url, $track, $SCalbum, $genres, $artist, $playcount, $rating, $lastplayed, $cover, $album) = @$row;
	}
	$sth->finish();
	return @myworkingset;
}

###
# blockedfallback - the best MusicIP track even though a block rejected it.
###
sub blockedfallback {
	my $client = shift;
	my @myworkingset = ();
	my $clientid = Slim::Player::Client::id($client);

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	# The chosen row is found by id first, so the same row can then be relabelled. Its old label
	# says which block rejected it, which is no longer the interesting fact - the interesting fact
	# is that it was played in spite of that. Live View reads trackingno straight out of this table
	# and is rebuilt on every request, so relabelling here is all it takes for the page to say
	# 'SC BLOCK BREACH!' on exactly the track you are hearing. Step 8.4a, 2026-08-08.
	my ($rowid) = $dbh->selectrow_array(
		"SELECT id FROM WorkingSet WHERE client ='$clientid' AND WorkingSet.trackingno != 'DROPSEED' ORDER BY id ASC LIMIT 1");

	if (defined $rowid) {
		my $sth = $dbh->prepare("SELECT temptrack, SCTrack, SCalbum, SCgenres, SCartist, SCplaycount, SCrating, SClastplayed, cover, album FROM WorkingSet WHERE id = $rowid");
		$sth->execute();

		my $array_ref = $sth->fetchall_arrayref();
		foreach my $row (@$array_ref) {
			push @myworkingset,
			my ($url, $track, $SCalbum, $genres, $artist, $playcount, $rating, $lastplayed, $cover, $album) = @$row;
		}
		$sth->finish();

		# Not 'OK'. mystuff selects on 'OK' and this row deliberately never becomes one - it did
		# not pass, it was taken anyway.
		$dbh->do("UPDATE WorkingSet SET trackingno = 'BREACHED' WHERE id = $rowid");
	}

	$log->debug("blockedfallback returning;" . (scalar(@myworkingset) ? $myworkingset[0] : 'nothing') . "\n");
	return @myworkingset;
}

sub droptsmetrics {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);

	# || 0 rather than three "if not defined, write it back" blocks, which were a THIRD place
	# deciding what a missing setting meant (the settings page and the inline fallbacks being the
	# other two). Defaults now arrive when a player connects - see %clientDefaults in Plugin.pm.
	my $sugarcube_ts_trackrated = $prefs->client($client)->get('sugarcube_ts_trackrated') || 0;
	my $sugarcube_ts_pc_higher = $prefs->client($client)->get('sugarcube_ts_pc_higher') || 0;
	my $sugarcube_ts_lastplayed = $prefs->client($client)->get('sugarcube_ts_lastplayed') || 0;

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	# $log->debug("Track Rating: $sugarcube_ts_trackrated PlayCount: $sugarcube_ts_pc_higher LastPlayed: $sugarcube_ts_lastplayed\n");

	if ($sugarcube_ts_trackrated == 0) {
		$log->debug("Statistics - Use Track Rating - Disabled\n");
	} else {
		###
		# The threshold is now LMS's OWN 0-100 rating, used as typed. No translation.
		# $log->debug("Statistics - Drop between 0 and $sugarcube_ts_trackrated\n");

		my $sth = $dbh->prepare("SELECT DISTINCT WorkingSet.id FROM WorkingSet WHERE (WorkingSet.SCrating BETWEEN 0 AND '$sugarcube_ts_trackrated') AND WorkingSet.client ='$clientid' AND WorkingSet.trackingno = 'OK'");
		$sth->execute() or warn $dbh->errstr . "\n";
		my $array_ref = $sth->fetchall_arrayref();
		foreach my $row (@$array_ref) {
			my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno='DROPTSRATING' WHERE WorkingSet.id ='@$row'");
			$sth->execute();
		}
		$log->debug("Stats block - RATING 0..$sugarcube_ts_trackrated marked " . scalar(@$array_ref) . " rows\n");
		$sth->finish();
	}

	if ($sugarcube_ts_pc_higher == 0) {
		# $log->debug("Statistics - Drop Tracks with Playcount N/A - DISABLED\n");
	} else {
		# $log->debug("Statistics - Drop Tracks with Playcount >= $sugarcube_ts_pc_higher\n");
		my $sth = $dbh->prepare("SELECT DISTINCT WorkingSet.id FROM WorkingSet WHERE (WorkingSet.SCplaycount >= '$sugarcube_ts_pc_higher') AND WorkingSet.client ='$clientid' AND WorkingSet.trackingno = 'OK'");
		$sth->execute() or warn $dbh->errstr . "\n";
		my $array_ref = $sth->fetchall_arrayref();
		foreach my $row (@$array_ref) {
			my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno='DROPTSPLAYCOUNT' WHERE WorkingSet.id ='@$row'");
			$sth->execute();
		}
		$log->debug("Stats block - PLAYCOUNT >= $sugarcube_ts_pc_higher marked " . scalar(@$array_ref) . " rows\n");
		$sth->finish();
	}
	if ($sugarcube_ts_lastplayed == 0) {
		# $log->debug("Statistics - Drop tracks Lastplayed N/A - DISABLED\n");
	} else {
		my $currenttime = time; # Current time in epoch
		my $epochYestertime = time - (($sugarcube_ts_lastplayed * 24) * 60 * 60); # subtract secs in day from current epoch time
		# $log->debug("Statistics - Drop BETWEEN $epochYestertime AND $currenttime\n");

		my $sth = $dbh->prepare("SELECT DISTINCT WorkingSet.id FROM WorkingSet WHERE (WorkingSet.SClastplayed BETWEEN '$epochYestertime' AND '$currenttime') AND WorkingSet.client ='$clientid' AND WorkingSet.trackingno = 'OK'");
		$sth->execute() or warn $dbh->errstr . "\n";
		my $array_ref = $sth->fetchall_arrayref();
		foreach my $row (@$array_ref) {
			my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno='DROPTSLASTPLAYED' WHERE WorkingSet.id ='@$row'");
			$sth->execute();
		}
		# "or SKIPPED" since 2026-08-07 - SClastplayed now holds the later of APC's lastPlayed and
		# lastSkipped, so this stage catches a track you skipped as well as one you heard.
		$log->debug("Stats block - PLAYED or SKIPPED within last $sugarcube_ts_lastplayed day(s) marked " . scalar(@$array_ref) . " rows\n");
		$sth->finish();
	}

	# Pipeline summary. THE COUNTS DO NOT OVERLAP AND THE FIRST LABEL WINS. Every stage above
	# selects with AND trackingno = 'OK', so the moment a row is labeled no later stage can see
	# it. A stage logging "marked 0 rows" is therefore normal - whatever it would have caught was
	# usually caught earlier. This tally is the authoritative picture of what actually survives.
	# block added here must carry the guard or the displayed drop reason stops being the true one.
	my $sth = $dbh->prepare("SELECT trackingno, COUNT(*) FROM WorkingSet WHERE client = '$clientid' GROUP BY trackingno ORDER BY trackingno");
	$sth->execute();
	my $tally = join ', ', map { "$_->[0]=$_->[1]" } @{$sth->fetchall_arrayref()};
	$sth->finish();
	$log->debug("WorkingSet after all blocks; $tally\n");
}

###
# DropSeed - remove the seed track from its own results.
###
sub DropSeed {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);

	my $seed = Slim::Player::Playlist::url($client) || '';
	return unless length $seed;

	###
	# ⚠ THE TEMPORARY ADDRESS IS CONVERTED FIRST. Added 2026-08-12.
	###
	if ($seed =~ m/^tmp:/i) {
		my $z = substr $seed, 0, 3, "file"; # replaces tmp with file
	}

	$seed = Slim::Utils::Misc::pathFromFileURL($seed);
	$seed = Plugins::SugarCube::Plugin::dirtyencoder($seed);
	return unless length $seed;

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPSEED' "
		. "WHERE WorkingSet.temptrack = ? AND WorkingSet.client = ? "
		. "AND WorkingSet.trackingno = 'OK'");
	$sth->execute ($seed, $clientid);
	my $n = $sth->rows;
	$sth->finish();

	$log->debug("Seed drop - marked " . ($n > 0 ? $n : 0) . " row(s)\n");
	return;
}

###
# DropBlockedArtist / DropBlockedGenre - a permanent, per-player "never play this" list.
###
sub DropBlockedArtist {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);

	# CHANGED 2026-08-30 (Henk): was three separate prefs (one name each). Now one comma-separated
	# pref, split here instead - trims whitespace around each name so "A, B,C" behaves the same as
	# "A,B,C". A name containing a literal comma will still split into two entries; documented on
	# the settings page rather than solved here.
	my $blockedstr = $prefs->client($client)->get('scblockartist_list') // '';
	my @blocked = split(/,/, $blockedstr);
	foreach (@blocked) { s/^\s+//; s/\s+$//; }
	@blocked = grep { length $_ } @blocked;
	return unless @blocked;

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $total = 0;
	foreach my $name (@blocked) {
		my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPARTIST' "
			. "WHERE WorkingSet.client = ? AND WorkingSet.trackingno = 'OK' "
			. "AND WorkingSet.SCartist LIKE ?");
		$sth->execute ($clientid, '%' . $name . '%');
		$total += $sth->rows;
		$sth->finish();
	}
	$dbh->disconnect;

	$log->debug("Artist block - " . scalar(@blocked) . " name(s) configured, marked $total row(s)\n");
	return;
}

sub DropBlockedGenre {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);

	# Same change, same reasoning as DropBlockedArtist above.
	my $blockedstr = $prefs->client($client)->get('scblockgenre_list') // '';
	my @blocked = split(/,/, $blockedstr);
	foreach (@blocked) { s/^\s+//; s/\s+$//; }
	@blocked = grep { length $_ } @blocked;
	return unless @blocked;

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $total = 0;
	foreach my $name (@blocked) {
		my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPGENRE' "
			. "WHERE WorkingSet.client = ? AND WorkingSet.trackingno = 'OK' "
			. "AND WorkingSet.SCgenres LIKE ?");
		$sth->execute ($clientid, '%' . $name . '%');
		$total += $sth->rows;
		$sth->finish();
	}
	$dbh->disconnect;

	$log->debug("Genre block - " . scalar(@blocked) . " name(s) configured, marked $total row(s)\n");
	return;
}

###
# TrackRepeatRecord / DropRepeatArtist / DropRepeatAlbum - Henk's request 2026-09-11. "een manier
# om artiesten of albums voor bepaalde tijd te blokkeren net als in de normale SC versie" - ports
# the rolling ArtistTracker/AlbumTracker window from the hoofdmap build: the last N tracks' worth
# of artist/album are remembered (oldest evicted once the configured cap is exceeded), and a track
# whose artist/album is still in that window gets dropped, the same way DropBlockedArtist/
# DropBlockedGenre above drop a permanently-named one. See the CREATE TABLE comment in init()
# above for why bringing these two tables back is a deliberate, scoped exception rather than a
# reversal of the self-cleaning-database rule.
###
sub TrackRepeatRecord {
	my $client = shift;
	my $album  = shift;
	my $artist = shift;
	my $clientid = Slim::Player::Client::id($client);

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	# LMS/MIP can hand back a localized "no album" placeholder instead of an empty string - same
	# list the hoofdmap build's own tracker uses, so a trackless single somewhere in the library
	# does not get treated as one giant "album" that then blocks every OTHER trackless single too.
	my %noAlbum = map { $_ => 1 } (
		'', 'No Album', 'Žádné album', 'Intet album', 'Kein Album', 'Sin álbum', 'Ei levyä',
		"Pas d'album", 'Nessun album', 'Geen album', 'Ingen album', 'Brak albumu', 'Sem Álbum',
		'Inget album'
	);

	if (defined $album && !exists $noAlbum{$album}) {
		my $blockalbum = $prefs->client($client)->get('sugarcube_blockalbum');
		$blockalbum = 5 unless defined $blockalbum && length $blockalbum;

		if ($blockalbum > 0) {
			my $sth = $dbh->prepare("INSERT OR REPLACE INTO AlbumTracker (client, SCalbum) VALUES (?,?)");
			$sth->execute ($clientid, $album);
			$sth->finish();

			my ($count) = $dbh->selectrow_array(
				"SELECT COUNT(*) FROM AlbumTracker WHERE client = ?", undef, $clientid);
			if (defined $count && $count > $blockalbum) {
				for (1 .. ($count - $blockalbum)) {
					$dbh->do("DELETE FROM AlbumTracker WHERE id IN "
						. "(SELECT id FROM AlbumTracker WHERE client = ? ORDER BY id ASC LIMIT 1)",
						undef, $clientid);
				}
			}
		}
	}

	if (defined $artist && length $artist) {
		my $blockartist = $prefs->client($client)->get('sugarcube_blockartist');
		$blockartist = 5 unless defined $blockartist && length $blockartist;

		if ($blockartist > 0) {
			my $sth = $dbh->prepare("INSERT OR REPLACE INTO ArtistTracker (client, SCartist) VALUES (?,?)");
			$sth->execute ($clientid, $artist);
			$sth->finish();

			my ($count) = $dbh->selectrow_array(
				"SELECT COUNT(*) FROM ArtistTracker WHERE client = ?", undef, $clientid);
			if (defined $count && $count > $blockartist) {
				for (1 .. ($count - $blockartist)) {
					$dbh->do("DELETE FROM ArtistTracker WHERE id IN "
						. "(SELECT id FROM ArtistTracker WHERE client = ? ORDER BY id ASC LIMIT 1)",
						undef, $clientid);
				}
			}
		}
	}

	$dbh->disconnect;
	return;
}

sub DropRepeatArtist {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPARTIST' "
		. "WHERE WorkingSet.client = ? AND WorkingSet.trackingno = 'OK' "
		. "AND EXISTS (SELECT 1 FROM ArtistTracker WHERE ArtistTracker.client = ? "
		. "AND ArtistTracker.SCartist = WorkingSet.SCartist)");
	$sth->execute ($clientid, $clientid);
	my $total = $sth->rows;
	$sth->finish();
	$dbh->disconnect;

	$log->debug("Artist repeat block - marked $total row(s)\n");
	return;
}

sub DropRepeatAlbum {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPALBUM' "
		. "WHERE WorkingSet.client = ? AND WorkingSet.trackingno = 'OK' "
		. "AND EXISTS (SELECT 1 FROM AlbumTracker WHERE AlbumTracker.client = ? "
		. "AND AlbumTracker.SCalbum = WorkingSet.SCalbum)");
	$sth->execute ($clientid, $clientid);
	my $total = $sth->rows;
	$sth->finish();
	$dbh->disconnect;

	$log->debug("Album repeat block - marked $total row(s)\n");
	return;
}

###
# applyArtistWeighting - ported from Henk's own HB64 fork (2026-08-30), adapted to the
# comma-separated-list convention this build already uses for DropBlockedArtist/DropBlockedGenre
# above, rather than HB64's three individually-weighted name slots: ONE list of Preferred names
# sharing ONE weight (1-5), and ONE list of Less Preferred names sharing ONE weight (1-5).
###
sub applyArtistWeighting {
	my $client = shift;
	my @workingset = @_;

	my $preferstr = $prefs->client($client)->get('scpreferartist_list') // '';
	my @prefer_artists = split(/,/, $preferstr);
	foreach (@prefer_artists) { s/^\s+//; s/\s+$//; }
	@prefer_artists = grep { length $_ } @prefer_artists;
	my $prefer_weight = $prefs->client($client)->get('scpreferartist_weight') // 1;

	my $lessstr = $prefs->client($client)->get('sclessartist_list') // '';
	my @less_artists = split(/,/, $lessstr);
	foreach (@less_artists) { s/^\s+//; s/\s+$//; }
	@less_artists = grep { length $_ } @less_artists;
	my $less_weight = $prefs->client($client)->get('sclessartist_weight') // 1;

	# Nothing configured either side - skip the pass rather than rebuild the array for no reason.
	return @workingset unless (@prefer_artists || @less_artists);

	my $block = 10;    # matches mystuff's column order above
	my $track_count = scalar(@workingset) / $block;

	my @weighted = ();

	for (my $i = 0; $i < $track_count; $i++) {
		my $artist = $workingset[$i * $block + 4] // '';
		my $copies = 1;

		my $artist_norm = lc($artist);
		$artist_norm =~ s/[^a-z0-9 ]//g;
		$artist_norm =~ s/\s+/ /g;
		$artist_norm =~ s/^\s+|\s+$//g;

		foreach my $name (@prefer_artists) {
			my $pref_norm = lc($name);
			$pref_norm =~ s/[^a-z0-9 ]//g;
			$pref_norm =~ s/\s+/ /g;
			$pref_norm =~ s/^\s+|\s+$//g;
			next unless length $pref_norm;
			if (index($artist_norm, $pref_norm) >= 0) {
				my $w = int($prefer_weight);
				$w = 1 if $w < 1;
				$w = 5 if $w > 5;
				$copies = $w + 1;
				$log->debug("Prefer weighting: $artist x$copies\n");
				last;
			}
		}

		foreach my $name (@less_artists) {
			my $less_norm = lc($name);
			$less_norm =~ s/[^a-z0-9 ]//g;
			$less_norm =~ s/\s+/ /g;
			$less_norm =~ s/^\s+|\s+$//g;
			next unless length $less_norm;
			if (index($artist_norm, $less_norm) >= 0) {
				my $w = int($less_weight);
				$w = 1 if $w < 1;
				$w = 5 if $w > 5;
				my $keep_chance = 1 / ($w + 1);
				if (rand() > $keep_chance) {
					$log->debug("Less weighting: $artist dropped (weight $w)\n");
					$copies = 0;
				} else {
					$log->debug("Less weighting: $artist kept (weight $w)\n");
				}
				last;
			}
		}

		for (1 .. $copies) {
			push @weighted, @workingset[$i * $block .. $i * $block + $block - 1];
		}
	}

	if (scalar(@weighted) == 0) {
		$log->debug("Artist weighting: all tracks dropped, returning original set\n");
		return @workingset;
	}

	return @weighted;
}

###
# DROPINQUEUE - nothing already sitting in this player's queue may be queued again.
###
sub DropInQueue {
	my $client = shift;
	return unless $client;
	my $clientid = Slim::Player::Client::id($client);

	my $count = Slim::Player::Playlist::count($client) || 0;
	return unless $count;

	# Read the queue the way getmyTSNextSong already does - Playlist::song for the URL at an index,
	# then objectForUrl. That pair is proven in this plugin; Playlist::track with an index is not
	# used anywhere here, and inventing a shape is what cost an evening over the context menus.
	my @ids;
	for (my $i = 0; $i < $count; $i++) {
		my $url = Slim::Player::Playlist::song ($client, $i);
		next unless $url;
		my $track = Slim::Schema->rs('Track')->objectForUrl({'url' => $url});
		next unless $track;
		my $id = eval { $track->id };
		push @ids, $id if (defined $id && $id =~ /^\d+$/);
	}
	return unless @ids;

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $placeholders = join ',', ('?') x scalar(@ids);
	my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPINQUEUE' "
		. "WHERE WorkingSet.client = ? AND WorkingSet.trackingno = 'OK' "
		. "AND WorkingSet.trackid IN ($placeholders)");
	$sth->execute ($clientid, @ids);
	my $n = $sth->rows;
	$sth->finish();
	$dbh->disconnect;

	$log->debug("In-queue drop - " . scalar(@ids) . " track(s) in the queue, marked "
		. ($n > 0 ? $n : 0) . " row(s)\n");
	return;
}

###
# DROPLASTREPLACED - strikes every track SugarCubeReplaceNext has deleted from the queue while
# the same track keeps playing.
#
# ⚠ ONE ID WAS NOT ENOUGH - Henk found this by testing. Excluding only the single most recent
# reject let a third click's top pick be the FIRST reject again (nothing else about the request
# had changed), so repeated clicks alternated between the same two tracks. $idsref is therefore
# every id rejected since this seed started playing, kept by Plugin.pm's scReplacedIds/
# scGetReplacedIds and reset there the moment the seed itself changes - nothing to expire here.
###
sub DropLastReplaced {
	my $client = shift;
	my $idsref = shift;
	return unless ($client && ref($idsref) eq 'ARRAY');
	my @ids = grep { defined $_ && /^\d+$/ } @$idsref;
	return unless @ids;
	my $clientid = Slim::Player::Client::id($client);

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');
	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	# Same IN(...) shape as DropInQueue, for the same reason - one call covers every id
	# accumulated for this seed rather than one row at a time.
	my $placeholders = join ',', ('?') x scalar(@ids);
	my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPLASTREPLACED' "
		. "WHERE WorkingSet.client = ? AND WorkingSet.trackingno = 'OK' "
		. "AND WorkingSet.trackid IN ($placeholders)");
	$sth->execute ($clientid, @ids);
	my $n = $sth->rows;
	$sth->finish();
	$dbh->disconnect;

	$log->debug("Last-replaced drop - " . scalar(@ids) . " id(s) excluded, marked "
		. ($n > 0 ? $n : 0) . " row(s)\n");
	return;
}

###
# scShortDate / scStampDate / scYearAlbum - the ONE place each of these is formatted.
#
# ⚠ IT RETURNS AN EMPTY STRING, NOT A WORD, WHEN THERE IS NO DATE - and that is deliberate, not an
# oversight. It first returned "None", which was wrong on the very first player it was seen on: the
# candidate list was full, so the page said there was no response while displaying one. The thing
# that is missing is the DATE, never the response. The caller drops the colon and prints the bare
# label, so a missing date can never be mistaken for a value that failed to render.
# scYearAlbum: "1963 - Les Racines de Nova". An untagged year is 0 or empty in Lyrion, in which case
# the album stands alone rather than showing a dash with nothing before it.
###
sub scStampDate {
	my $epoch = shift;
	return '' if (!defined($epoch) || $epoch <= 0);
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	my @t = localtime($epoch);
	return sprintf ('%s %d, %d %02d:%02d',
		$months[ $t[4] ], $t[3], $t[5] + 1900, $t[2], $t[1]);
}

sub scShortDate {
	my $epoch = shift;
	return Slim::Utils::Strings::string('PLUGIN_SC_LV_NEVERPLAYED') if (!defined($epoch) || $epoch <= 0);
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	my @t = localtime($epoch);
	return $months[ $t[4] ] . ' ' . $t[3] . ' ' . ($t[5] + 1900);
}

sub scYearAlbum {
	my ($year, $album) = @_;
	$album = '' unless defined $album;
	return $album if (!defined($year) || $year eq '' || $year == 0);
	return $year . ' - ' . $album;
}

###
# scGenres - SQLite's group_concat has no separator argument when DISTINCT is used, so it returns
# "Vocal Pop,Traditional Pop,Jazz Vocal" with no spaces. Space them for reading. Nothing else.
###
sub scGenres {
	my $genres = shift;
	return '' unless defined $genres;
	$genres =~ s/,/, /g;
	return $genres;
}

sub StatsPuller {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);
	my ($line, $col1, $col2, $col3, $col4, $col5, $col6, $col7, $col8, $col9, $col10, $col11, $col12, $col13);
	$line = '';

	###
	# ALBUM ART FOLLOWS MATERIAL, 2026-08-09. User: "Seems the best is to follow Material exactly."
	###
	my $sugarlvartask = '300x300_f'; # what we ask Lyrion for - Material's own list/grid spec
	my $sugarlviconsize = 100;       # what we draw it at

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'sugarcube.db');

	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare("SELECT trackingno, SCtrack, SCalbum, SCartist, SCgenres, SCplaycount, SCrating, SClastplayed, temptrack, cover, album, trackid, scyear FROM WorkingSet WHERE WorkingSet.client = '$clientid' ORDER BY WorkingSet.id ASC");
	$sth->execute();
	$sth->bind_col (1, \$col1); # tracking status ie. played already, playcount etc
	$sth->bind_col (2, \$col2); # track name
	$sth->bind_col (3, \$col3); # album name
	$sth->bind_col (4, \$col4); # artist name
	$sth->bind_col (5, \$col5); # genres
	$sth->bind_col (6, \$col6); # playcount
	$sth->bind_col (7, \$col7); # rating
	$sth->bind_col (8, \$col8); # lastplayed
	$sth->bind_col (9, \$col9); # temptrack file url
	$sth->bind_col (10, \$col10); # albumart cover number
	$sth->bind_col (11, \$col11); # full album id
	$sth->bind_col (12, \$col12); # track id
	$sth->bind_col (13, \$col13); # year

	my $clientid_uri = $client->id;
	$clientid_uri =~ s/:/%3A/g; # URI player id - for links only, NEVER for a server command
	my $clientid_raw = $client->id; # unencoded - the server matches on this, %3A matches nothing

	###
	# DON'T OFFER WHAT CANNOT WORK, 2026-08-09. User: "replace selection should not really appear in
	# conditions where it is inapplicable."
	###
	my $scCanReplace = (Plugins::SugarCube::Breakout::CheckPosition($client) <= 2) ? 1 : 0;

	while ($sth->fetch) {
	if ($col6 == -1) { $col6 = Slim::Utils::Strings::string('PLUGIN_SC_LV_NEVERPLAYED'); }
	if ($col7 == -1) { $col7 = Slim::Utils::Strings::string('PLUGIN_SC_LV_NOTRATED'); }
	# Eight drops now: the artist and genre labels below are the Henk-requested permanent block
	# (DropBlockedArtist/DropBlockedGenre), new alongside this rebuild rather than a survivor of
	# Phase 7 - that removal is why the two names were free to reuse for a different feature.
	# DROPINQUEUE arrived 2026-08-07. DROPALBUM arrived 2026-09-11 alongside DropRepeatAlbum -
	# DROPARTIST is deliberately reused for DropRepeatArtist too (same label either way a track was
	# excluded for being that artist), matching the hoofdmap build's own precedent.
	if ($col1 eq 'DROPTSLASTPLAYED') {
		$col1 = Slim::Utils::Strings::string('PLUGIN_SC_LV_DROP_LASTPLAYED');
	} elsif ($col1 eq 'DROPINQUEUE') { $col1 = Slim::Utils::Strings::string('PLUGIN_SC_LV_DROP_QUEUE');
	} elsif ($col1 eq 'DROPTSPLAYCOUNT') { $col1 = Slim::Utils::Strings::string('PLUGIN_SC_LV_DROP_PLAYCOUNT');
	} elsif ($col1 eq 'DROPTSRATING') { $col1 = Slim::Utils::Strings::string('PLUGIN_SC_LV_DROP_RATING');
	} elsif ($col1 eq 'DROPARTIST') { $col1 = Slim::Utils::Strings::string('PLUGIN_SC_LV_DROP_ARTIST');
	} elsif ($col1 eq 'DROPGENRE') { $col1 = Slim::Utils::Strings::string('PLUGIN_SC_LV_DROP_GENRE');
	} elsif ($col1 eq 'DROPALBUM') { $col1 = Slim::Utils::Strings::string('PLUGIN_SC_LV_DROP_ALBUM');
	} elsif ($col1 eq 'DROPSEED') { $col1 = Slim::Utils::Strings::string('PLUGIN_SC_LV_DROP_SEED');

	###
	# ⛔ THE BREACH LABEL REUSES THE POP-UP'S OWN KEY, PLUGIN_SC_POPUP_BREACHED, RATHER THAN GETTING
	# ONE OF ITS OWN. Edit 57, 2026-08-14. The pop-up that fires when a block is breached and the row
	# that records it on this page are the same announcement on two surfaces, and this project has
	# spent four builds collapsing exactly that shape into one key. Do not split them.
	###
	} elsif ($col1 eq 'BREACHED') { $col1 = Slim::Utils::Strings::string('PLUGIN_SC_POPUP_BREACHED');
	} elsif ($col1 ne 'OK') {
		###
		# CATCH-ALL, added 2026-08-12. Anything not recognised above is a label from a rule this
		# build no longer has - DROPPLAYEDALREADY, from the drop that went in Phase 7, turned up on
		# screen as raw shouting because its translation was deleted with the rule while old rows
		# kept the word.
		###
		$col1 = Slim::Utils::Strings::string('PLUGIN_SC_LV_DROP_OTHER');
	}

	$col8 = ($col8 == -1)
		? Slim::Utils::Strings::string('PLUGIN_SC_LV_NEVERPLAYED')
		: scShortDate($col8);

	if (!defined($col10) || $col10 eq '') { $col10 = "0"; }

	###
	# ONE BUTTON, 2026-08-09. User: "This is SC Live view. If we want to do anything manually here,
	# above all it is to manually supersede the MIP/SC automatic selection. So the only button I
	# want here would replace the selected winner." And: "it is a track list. Why would a whole
	# album get queued when I click +."
	###
	# ⛔ THE IN-FLIGHT WORD GOES INSIDE A JAVASCRIPT SINGLE-QUOTED STRING, so it is escaped before it
	# is injected. Edit 57, 2026-08-14. It was the literal 'Replacing...' until this build, which was
	# safe precisely because nobody could change it. Now that it is translatable, one apostrophe in a
	# translator's wording - "Remplacement d'une piste" - would close the JS string early and break
	# the link for everybody in that language. The escape is not defensive dressing: enabling
	# translation is what made this reachable. Backslash first, then quote, or the escape eats itself.
	###
	(my $scLvReplacing = Slim::Utils::Strings::string('PLUGIN_SC_LV_REPLACING')) =~ s/([\\'])/\\$1/g;

	###
	# ICON BUTTON, Henk 2026-09-05 - visual only, ported from the hoofdmap build's "Play Next"
	# icon. The mechanism underneath (this.innerHTML swap for the in-flight/refusal message, the
	# onclick XHR, the 'replacesel' command, $scCanReplace hiding the whole link) is UNCHANGED -
	# only what renders inside the <a> before it is clicked moves from an underlined text label to
	# the same triangle+queue-bars SVG hoofdmap uses, in the .sc-mipbtn class hoofdmap defines.
	# Title/aria-label keep this build's own string key (PLUGIN_SC_LV_USEASNEXT) rather than
	# hoofdmap's hardcoded "Play Next" literal, since that is still the accurate description of
	# what this action does here.
	###
	my $scLvUseAsNext = Slim::Utils::Strings::string('PLUGIN_SC_LV_USEASNEXT');
	my $build = $scCanReplace
		? "<a class=\"sc-mipbtn\" title=\"$scLvUseAsNext\" aria-label=\"$scLvUseAsNext\" onclick=\"this.innerHTML='$scLvReplacing';var a=this;"
		. "var r=new XMLHttpRequest();r.open('POST','/jsonrpc.js',true);"
		. "r.setRequestHeader('Content-Type','application/json');"
		. "r.onloadend=function(){var m='';"
		. "try{m=JSON.parse(r.responseText).result.scmsg||'';}catch(e){}"
		. "if(m){a.innerHTML=m;}"
		. "else if(window.scLvRefresh){scLvRefresh();}else{location.reload();}};"
		. "r.send(JSON.stringify({id:1,method:'slim.request',params:['"
		. $clientid_raw
		. "',['sugarcube','replacesel','"
		. $col12
		. "']]}));\">"
		. '<svg width="40" height="24" viewBox="0 0 40 24" fill="currentColor"><polygon points="4,4 4,20 14,12"/><rect x="16" y="4" width="2.4" height="16"/><rect x="21" y="5" width="16" height="2.4"/><rect x="21" y="11" width="16" height="2.4"/><rect x="21" y="17" width="11" height="2.4"/></svg>'
		. "</a>"
		: '&nbsp;';

	# THIS IS STATISTICS BUILD UP
	# Row order is the user's own, 2026-08-09, and is identical in all three places on this page:
	# descriptor, Title, Artist, Year - Album, Genre, Rating, Playcount, Last Played.
	# No labels on the first four - the values say what they are. No album artist anywhere.
	###
	$line = $line
		. '<tr><td rowspan=9 class=pic><img style="width:'
		. $sugarlviconsize
		. 'px !important; height:'
		. $sugarlviconsize
		. 'px !important; border-radius:10px !important; object-fit:cover !important; display:block !important;" src=/music/'
		. $col10
		. "/cover_"
		. $sugarlvartask
		. '.jpg></td><td>'
		. $build
		. '</td></tr><tr><td class=txt>'
		. $col1
		. '</td></tr><tr><td style="vertical-align:middle">'
		. $col2
		. '</td></tr><tr><td style="vertical-align:middle">'
		. $col4
		. '</td></tr><tr><td style="vertical-align:middle">'
		. scYearAlbum($col13, $col3)
		. '</td></tr><tr><td style="vertical-align:middle">Genre: '
		. scGenres($col5)
		. '</td></tr><tr><td style="vertical-align:middle">Rating: '
		. $col7
		. '</td></tr><tr><td style="vertical-align:middle">Playcount: '
		. $col6
		. '</td></tr><tr><td style="vertical-align:middle">Last Played: '
		. $col8
		. '</td></tr><tr><td colspan=2 class=end>&nbsp;</td></tr><tr><td colspan=2>&nbsp;</td></tr>';
	}

	$sth->finish();
	return $line;
}

###
# GrabHistory / SaveHistory - Henk's request 2026-09-11, ported back verbatim from the hoofdmap
# build (see the History CREATE TABLE comment in init() above for why this build lost them and
# why they're back). Deliberately unchanged from the hoofdmap version, including the queue-time
# (not play-time) logging.
###
sub GrabHistory {
	my $client       = shift;
	my @myworkingset = ();
	my $clientid     = Slim::Player::Client::id($client);

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile( $path, 'plugin', 'sugarcube.db' );

	my $dbh = DBI->connect("dbi:SQLite:$path")
	  || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout( $sqlitetimeout * 1000 );

	my $sth = $dbh->prepare(
"SELECT artist, track, album, genre, albumart, fullalbum FROM History WHERE client ='$clientid' ORDER BY id DESC"
	);
	$sth->execute();

	my $array_ref = $sth->fetchall_arrayref();
	foreach my $row (@$array_ref) {
		push @myworkingset,
		  my ( $artist, $track, $album, $genre, $albumart, $fullalbum ) = @$row;
	}

	$sth->finish();
	return @myworkingset;
}

sub SaveHistory {
	my $client    = shift;
	my $artist    = shift;
	my $track     = shift;
	my $album     = shift;
	my $genre     = shift;
	my $albumart  = shift;
	my $fullalbum = shift;

	my $clientid = Slim::Player::Client::id($client);

	my $path ||= Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile( $path, 'plugin', 'sugarcube.db' );

	my $dbh = DBI->connect("dbi:SQLite:$path")
	  || die "Cannot connect: $DBI::errstr";
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout( $sqlitetimeout * 1000 );

	my $sql =
qq{INSERT INTO History (client, artist, track, album, genre, albumart, fullalbum) VALUES (?,?,?,?,?,?,?)};
	my $sth = $dbh->prepare($sql);
	$sth->bind_param( 1, $clientid,  SQL_VARCHAR );
	$sth->bind_param( 2, $artist,    SQL_VARCHAR );
	$sth->bind_param( 3, $track,     SQL_VARCHAR );
	$sth->bind_param( 4, $album,     SQL_VARCHAR );
	$sth->bind_param( 5, $genre,     SQL_VARCHAR );
	$sth->bind_param( 6, $albumart,  SQL_VARCHAR );
	$sth->bind_param( 7, $fullalbum, SQL_VARCHAR );

	$sth->execute;

	my $sth2 =
	  $dbh->prepare("SELECT COUNT(*) FROM History WHERE client ='$clientid'");
	eval {
		$sth2->execute();
		my $songIndex = undef;
		$sth2->bind_col( 1, \$songIndex );
		if ( $sth2->fetch() ) {
			if ( defined($songIndex) ) {
				if ( $songIndex > 30 ) {
					$dbh->do(
						"DELETE FROM History WHERE id IN "
						. "(SELECT id FROM History WHERE client = ? ORDER BY id ASC LIMIT ?)",
						undef, $clientid, ( $songIndex - 30 )
					);
				}
			}
		}
		$sth2->finish();
	};

	$dbh->disconnect;
	return;
}

###
# HistoryPuller - Henk's request 2026-09-11, added for the Live View/Quick Settings accordion
# merge. Builds the History section's row HTML from GrabHistory's flat 6-per-entry array, in the
# same rowspan/rounded-cover row shape StatsPuller already uses for Last MIP Response, so both
# lists read as one visual family inside the new menu. Field order (Track, Album, Artist, Genre)
# originally matched the hoofdmap build's own History page (handleWebListHistory) verbatim,
# including that page's "Play Album" action - REMOVED 2026-09-12 (Henk: "gaat in tegen het Mip
# principe"), see the removal's own comment further down for the full reasoning. Rows are purely
# informational now, same as every other field here - what got queued, when, nothing to tap.
###
sub HistoryPuller {
	my $client        = shift;
	# $clientid_raw removed 2026-09-12 along with the Play Album button below - it existed only to
	# address that button's own JSON-RPC call, and nothing else in this sub ever needed it.
	my $sugarlvartask = '300x300_f'; # same Material-matching cover request as StatsPuller
	my $sugarlviconsize = 100;

	my @history = GrabHistory($client);
	my $line = '';

	while (@history) {
		my ($artist, $track, $album, $genre, $albumart, $fullalbum) = splice(@history, 0, 6);
		if (!defined($albumart) || $albumart eq '') { $albumart = "0"; }

		###
		# "Play Album" REMOVED, Henk 2026-09-12. Ported in verbatim from the hoofdmap build's old
		# History page on 2026-09-11 (see this sub's own header comment above) without re-applying
		# the rule the user had already laid down for this exact pattern one build earlier - see
		# "ONE BUTTON, 2026-08-09" above StatsPuller's own $build: "This is SC Live view. If we want
		# to do anything manually here, above all it is to manually supersede the MIP/SC automatic
		# selection... it is a track list. Why would a whole album get queued when I click +." Same
		# objection, same answer: a one-tap full-album load sitting next to the Live View menu's
		# other MIP-driven controls "gaat in tegen het MIP principe" - it bypasses the dynamic mix
		# entirely rather than working with it, exactly what StatsPuller's Play Album/Add Album/Add
		# Track removal was for. Unlike StatsPuller's row, no MIP-aligned replacement is offered
		# here either: "Use as Next Track" needs a track id (col12 there), and the History table
		# only ever stored artist/track/album/genre/albumart/fullalbum (see GrabHistory/SaveHistory
		# below) - so for now the row simply carries no action, same as StatsPuller's own $build
		# falls back to when $scCanReplace is false.
		###
		my $build = '&nbsp;';

		$line = $line
			. '<tr><td rowspan=5 class=pic><img style="width:'
			. $sugarlviconsize
			. 'px !important; height:'
			. $sugarlviconsize
			. 'px !important; border-radius:10px !important; object-fit:cover !important; display:block !important;" src=/music/'
			. $albumart
			. "/cover_"
			. $sugarlvartask
			. '.jpg></td><td>'
			. $build
			. '</td></tr><tr><td style="vertical-align:middle">'
			. $track
			. '</td></tr><tr><td style="vertical-align:middle">'
			. $album
			. '</td></tr><tr><td style="vertical-align:middle">'
			. $artist
			. '</td></tr><tr><td style="vertical-align:middle">Genre: '
			. scGenres($genre)
			. '</td></tr><tr><td colspan=2 class=end>&nbsp;</td></tr><tr><td colspan=2>&nbsp;</td></tr>';
	}

	return $line;
}

1;
