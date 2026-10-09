# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::SugarCube::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.sugarcube',
	'defaultLevel' => 'WARN',
	'description' => getDisplayName(),
});

use Slim::Utils::Strings qw(string);
use Slim::Control::Request;
use Slim::Utils::OSDetect;
use Plugins::SugarCube::Settings;
use Plugins::SugarCube::PlayerSettings;
use Plugins::SugarCube::SettingsExports;
use Plugins::SugarCube::SettingsMusicIP;
use Plugins::SugarCube::Breakout;
use Plugins::SugarCube::ProtocolHandler;
use Scalar::Util qw(blessed);
use Slim::Utils::Timers;
use URI::Escape;
# Added for MIP export (see the comment above ExportStatsToMIP); not used elsewhere in SugarCube.
use LWP::UserAgent;
use Slim::Utils::Scheduler;
use Slim::Music::Import;
use base qw(Slim::Menu::Base);
my @unique = ();
my @myworkingset = ();
my $prefs = preferences('plugin.SugarCube');
# The per-player Currently Playing/Coming Up Next memory slots are gone; Live View reads the queue
# directly when the page is drawn, so nothing fills or reads them any more.
my $htmlTemplateLV = 'plugins/SugarCube/settings/liveview.html';
# quicksettings.html is retired - Live View's Mix/Mood Settings collapsibles cover everything this
# page did, and jiveSugarCubeSetting above already saves every pref it used to.
my $htmlTemplateQP = 'plugins/SugarCube/settings/quickplay.html';
my $global_quickmix = 0; # if quick fire mix from currently playing selected
my $mixstatus = ''; # Holds status of MusicIP service
my $apc_enabled;
my $material_enabled;
# MIP Export (POC) state - see ExportStatsToMIP. "in progress"/"result" also live in real prefs
# (sc_mipexport_inprogress/sc_mipexport_result) so the settings page can poll them via the generic
# 'pref' JSON-RPC command, since they need to be readable from outside this module's memory.
my $mipexport_errors = 0;
my @mipexport_songs = ();
my $mipexport_aborted = 0;

###
# scReplacedIds / scReplacedSeed - trackids rejected for the CURRENT seed (the currently playing
# track), kept in memory only, never written to sugarcube.db.
#
# ⚠ Every rejected id must be accumulated, not just the most recent one - with only the latest
# reject remembered, a third click re-excludes just the second pick and MusicIP's top choice
# reverts to the first pick, so two clicks alternate between the same two tracks forever.
###
my %scReplacedIds;   # client id => arrayref of trackids rejected for the seed below
my %scReplacedSeed;  # client id => the seed (currently playing track) those rejects belong to

sub scRememberReplaced {
	my ($client, $trackid) = @_;
	return unless ($client && defined $trackid);
	my $cid = Slim::Player::Client::id($client);
	push @{ $scReplacedIds{$cid} ||= [] }, $trackid;
}

# Called from gotMIP with the seed THIS request is built from. Resets and returns an empty list
# the moment that seed does not match what the accumulated rejects belong to - otherwise returns
# every id accumulated so far for this seed, unconsumed, so the list keeps growing across repeated
# Replace clicks instead of being emptied after each one.
sub scGetReplacedIds {
	my ($client, $curseed) = @_;
	return () unless $client;
	my $cid = Slim::Player::Client::id($client);
	$curseed //= '';
	if ( ($scReplacedSeed{$cid} // '') ne $curseed ) {
		delete $scReplacedIds{$cid};
		$scReplacedSeed{$cid} = $curseed;
		return ();
	}
	return @{ $scReplacedIds{$cid} || [] };
}

sub getIcon {
	return Plugins::SugarCube::Plugin->_pluginDataFor('icon');
}

sub getDisplayName { return 'PLUGIN_SUGARCUBE'; }

# The Up Next switch (`sugarcube_upnext`) is gone. Whether Coming Up Next appears is decided
# entirely by the Player Display Options dropdown; holding Pause on the remote does whatever LMS
# does with it.

###
# Defaults for a brand-new player, applied via $cprefs->init, which sets ONLY keys that are not
# already present - so an existing player is never touched.
###
my %clientDefaults = (
	# The mix itself. sugarcube_size is the MIP Ask Size - how many candidates MusicIP returns,
	# shared by Chain (which only ever takes the top 1) and Batch (which trims candidates down
	# with sugarcube_batchsize below, see the SC BATCH branch).
	sugarcube_status          => 0,   # off - never hijack a player that was just plugged in
	sugarcube_size            => 20,
	sugarcube_batchsize       => 50,  # cap on tracks a fired Batch queues into Lyrion, separate
	                                  # from sugarcube_size/MIP Ask Size above (player.html, Mix Settings)
	sugarcube_filteractive    => 0,   # (None)
	sugarcube_receipes        => 0,   # (None)
	sugarcube_rejectsize      => 0,
	sugarcube_style           => 0,
	sugarcube_variety         => 0,

	# Blocks - 0 means "do not block on this"
	sugarcube_ts_pc_higher    => 0,
	sugarcube_ts_trackrated   => 0,   # LMS's own 0-100 scale since 2026-08-06
	sugarcube_ts_lastplayed   => 0,

	# Alarm. (None) here does NOT mean "send no filter" - it means "use the player's own filter".
	# See buildMIPReq, constraints 'alarm'.
	scalarm_filter            => 0,

	# Auto Sleep. One section, one time window, one on/off. Volume reduction used to carry its own
	# switch and its own From/To pair; they were always set to the same hours as the sleep pair,
	# which is what made the two look like duplicates. 0 on the drop is now the off switch.
	sugarcube_sleep           => 0,
	sugarcube_sleepfrom       => 0,
	sugarcube_sleepto         => 0,
	sugarcube_sleepduration   => 0,
	sugarcube_reducevolume    => 0,   # points off a 0-100 scale at each track change. 0 = leave alone

	# Housekeeping
	sugarcube_clutter         => 50,  # NOT cosmetic since 2026-08-07 - this is also how far
	                                  # back DropInQueue can see, because playlistcull is what
	                                  # trims the queue it reads. 50 floor, see playlistcull.

	# Repeat blocking - rolling window of the last N tracks' worth of artist/album (see
	# ArtistTracker/AlbumTracker, TrackRepeatRecord/DropRepeatArtist/DropRepeatAlbum in Breakout.pm).
	# 0 means "do not block on this", same convention as the Blocks section above.
	sugarcube_blockartist     => 5,
	sugarcube_blockalbum      => 5,

	# Wobble - see pickWobbleTrack's own comment for what it does. 0 = Disabled, unchanged
	# behaviour: always the single best MusicIP match.
	sugarcube_wobble          => 0,

	# Live View's Mix Settings <details> open/closed state (pref name kept from when this panel
	# was called "Chain Settings"). Stored server-side rather than in localStorage, so the server
	# renders the <details> tag's "open" attribute directly from this pref - the first byte of HTML
	# is already correct and no script has to run for a fresh load to reflect the last-known state.
	# 1 (open) matches the template's old hardcoded default.
	# state) is gone along with that panel - Mood now lives inside this one.
	sugarcube_lv_chainsettings_open => 1,
);

###
# Give a player its defaults the moment it appears, rather than whenever someone opens a page.
# Called for every player already connected at startup, and then for each one that connects or
# reconnects afterwards.
###
sub applyClientDefaults {
	my $client = shift;
	return unless $client;

	# Batch reads sugarcube_style/sugarcube_variety (and filter/recipe/reject size/size) directly,
	# the same as Chain, and now has its own sugarcube_batchsize queue cap (see clientDefaults).
	my $cprefs = $prefs->client($client);
	$cprefs->init(\%clientDefaults);
}

sub scNewClientCallback {
	my $request = shift;
	my $client = $request->client() || return;
	applyClientDefaults ($client);
}

sub initPlugin {
	my $class = shift;
	my $client = shift;
	$class->SUPER::initPlugin();

	Plugins::SugarCube::Settings->new;
	Plugins::SugarCube::PlayerSettings->new;
	Plugins::SugarCube::SettingsExports->new;
	Plugins::SugarCube::SettingsMusicIP->new;

	Plugins::SugarCube::Breakout::init();

	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	if (!defined $sqlitetimeout || $sqlitetimeout eq '') {
		$sqlitetimeout = 30;
		$prefs->set ('sqlitetimeout', "$sqlitetimeout");
		$log->debug("Sqlitetimeout, default to 30secs\n");
	}

	my $sugarport = $prefs->get('sugarport');
	if (!defined $sugarport || $sugarport eq '') {
		$sugarport = '10002';
		$prefs->set ('sugarport', "$sugarport");
		$log->debug("SugarCube Port not Set; $sugarport for this client, default set to 10002\n");
	}
	my $miphosturl = $prefs->get('miphosturl');
	if (!defined $miphosturl || $miphosturl eq '') {
		$miphosturl = 'localhost';
		$prefs->set ('miphosturl', "$miphosturl");
		$log->debug("SugarCube MIP URL not Set; $miphosturl for this client, default set to localhost\n");
	}

	###
	# MIP Export (POC) - ported from AF-1's separate 'lms-exporttomusicip' plugin, folded directly
	# into SugarCube instead of kept as a second installable plugin. See the comment above
	# ExportStatsToMIP for what was deliberately left out of this pass. Deliberately no separate
	# host/port/timeout/path-remap prefs - reuses sugarport/miphosturl and this plugin's own
	# scPathPair().
	# scheduled export, and post-scan export has its own independent sc_mipexport_postscan toggle.
	my $sc_mipexport_enabled = $prefs->get('sc_mipexport_enabled');
	if (!defined $sc_mipexport_enabled) {
		$prefs->set ('sc_mipexport_enabled', 0);
		$log->debug("SC MIP Export enabled-flag not set; default set to 0\n");
	}

	# No default is forced into sc_mipexport_time - blank is the off switch for the scheduled
	# export (see scMIPExportScheduler); defaulting it would silently turn scheduled export on for
	# every fresh install that has never opened the Exports page.
	$prefs->set ('sc_mipexport_postscan', 0) unless defined $prefs->get('sc_mipexport_postscan');

	# Rating-band defaults for the new Exports page (Plugins::SugarCube::SettingsExports). Same
	# stock scale that page's own Restore Defaults writes, kept in one place here for a fresh
	# install rather than relying on that page having been opened at least once.
	my %sc_mipexport_banddefaults = (
		sc_mipexport_unrated => 0,
		sc_mipexport_band1   => 10,
		sc_mipexport_band2   => 30,
		sc_mipexport_band3   => 50,
		sc_mipexport_band4   => 70,
		sc_mipexport_band5   => 90,
	);
	foreach my $sc_mipexport_bandkey (keys %sc_mipexport_banddefaults) {
		$prefs->set ($sc_mipexport_bandkey, $sc_mipexport_banddefaults{$sc_mipexport_bandkey})
			unless defined $prefs->get($sc_mipexport_bandkey);
	}

	# A library rescan changes ratings/playcounts/lastplayed for nothing by itself, but a NEW track
	# has nothing in MIP's cache yet - export once, ten seconds after the scan settles, same
	# debounce the original plugin used (a scan can fire 'done' more than once in quick succession).
	Slim::Control::Request::subscribe (\&scMIPExportPostScanTimer, [ [ 'rescan' ], [ 'done' ] ]);
	# 'sugarlviconsize' is unused - Live View now asks for Material's own 300x300_f and draws it at
	# 100. It is an orphan in the prefs file; see _tools\Clean-SugarCubePrefs.ps1.
	###
	my $sugardelay = $prefs->get('sugardelay');
	if (!defined $sugardelay || $sugardelay !~ /^\d+$/ || $sugardelay < 1) {
		$sugardelay = 1;
		$prefs->set ('sugardelay', "$sugardelay");
		$log->debug("Pause before Next Fetch was unset or below the floor - set to 1\n");
	}
	###
	# useapcvalues is gone - there is no user-facing switch any more. APC is used whenever it is
	# installed, and Lyrion's own figures are the fallback when it is not; that fallback is the
	# real protection for the recency/playcount/rating blocks, since every read checks
	# $apc_enabled first.
	###

	###
	# One-time migration: the rating threshold moves to LMS's own 0-100 scale. "Block Tracks Rated
	# x and Below" used to be entered as 1-5 or 1-10 and converted internally; it is now entered
	# directly in LMS's units.
	###
	my $oldscale = $prefs->get('rating_10scale');
	if (defined $oldscale) {
		my %ten  = (1=>14, 2=>24, 3=>34, 4=>44, 5=>54, 6=>64, 7=>74, 8=>84, 9=>94);
		my %five = (1=>29, 2=>49, 3=>69, 4=>89);
		my $map  = ($oldscale == 1) ? \%ten : \%five;

		foreach my $client (Slim::Player::Client::clients()) {
			my $old = $prefs->client($client)->get('sugarcube_ts_trackrated');
			next unless defined $old && $old > 0;
			my $new = $map->{$old};
			if (defined $new) {
				$prefs->client($client)->set('sugarcube_ts_trackrated', "$new");
				# INFO, not WARN - housekeeping that happens once and then never again. Step 8.4c.
				$log->info("Rating threshold migrated to LMS 0-100 scale for "
					. Slim::Player::Client::id($client) . "; $old became $new\n");
			}
		}
		$prefs->remove('rating_10scale');
		$log->info("Rating Scale setting retired - the threshold is now LMS's own 0-100 value.\n");
	}

	####
	####
	####
	####

	Slim::Control::Request::subscribe (\&commandCallback,
		[ [ 'play', 'pause', 'stop', 'power', 'playlist' ] ]);

	# A player that connects after startup gets its defaults here. 'reconnect' is included because
	# a player that was off when LMS started announces itself that way rather than as 'new'.
	Slim::Control::Request::subscribe (\&scNewClientCallback,
		[ [ 'client' ], [ 'new', 'reconnect' ] ]);
	my $icon = Plugins::SugarCube::Plugin->_pluginDataFor('icon');

	my @menu = (
		{
			text => Slim::Utils::Strings::string('PLUGIN_SUGARCUBE'),
			id => 'pluginFoobarActivateSomething',
			'icon-id' => $icon,
			weight => 20,
			actions => {
				go => {
					player => 0,
					cmd => [ 'sugarcube', 'menu' ],
					params => { activate => '1', },
				}
			},
			window => {
				titleStyle => 'settings',
				'icon-id' => $class->_pluginDataFor('icon')
			},
		},
	);
	Slim::Control::Jive::registerPluginMenu (\@menu, 'settings');

	Slim::Control::Request::addDispatch(['sugarcube', 'menu'], [0, 0, 1, \&jiveSugarCubeMenu]);
	Slim::Control::Request::addDispatch(['sugarcube', 'setting'], [1, 0, 1, \&jiveSugarCubeSetting]);
	Slim::Control::Request::addDispatch(['sugarcube', 'filters', '_filter'], [1, 0, 0, \&jive_menu_save_filter]);
	Slim::Control::Request::addDispatch(['sugarcube', 'recipe', '_recipe'], [1, 0, 0, \&jive_menu_save_recipe]);
	Slim::Control::Request::addDispatch(['sugarcube', 'mood', '_mood' ], [1, 0, 0, \&jive_menu_save_mood]);
	# ['sugarcube','players','_sendplayer'] is gone along with the branch it reached - see the note
	# in jiveSugarCubeSetting. Nothing built a menu item for it, so nothing could send it.
	Slim::Control::Request::addDispatch(['sugarcube', 'batch', '_seedtype', '_idtype', '_id', '_mode'], [1, 0, 0, \&jiveSCBatch]);
	Slim::Control::Request::addDispatch(['sugarcube', 'replacesel', '_trackid'], [1, 0, 0, \&scReplaceSelection]);
	# Live View's "Start New Chain" button - same action as clicking Auto Mix, reached as a plain
	# slim.request from the page itself, so Live View never has to navigate away and back for it.
	Slim::Control::Request::addDispatch(['sugarcube', 'startchain'], [1, 0, 0, \&scStartChain]);
	# Live View's "Replace Track" button (under Coming Up Next) - same SC/MIP replace-next logic
	# SugarCubeReplaceNext that handleWebRN (replacenext.html, from SC Controls) uses, reached as a
	# plain slim.request instead of a full page navigation.
	Slim::Control::Request::addDispatch(['sugarcube', 'replacenext'], [1, 0, 0, \&scReplaceNext]);
	# Live View's "Start New Batch" button (under Currently Playing, only while a batch is
	# running) - the same PlaySCBatch('mood', ...) call SC Controls' "Play Mood Batch" button fires
	# via moodbatch=play (handleWebQuickSettings), reached as a plain slim.request instead.
	Slim::Control::Request::addDispatch(['sugarcube', 'startbatch'], [1, 0, 0, \&scStartBatch]);
	# Live View's "Add Mood Batch" button (under Coming Up Next, only while a batch is running) -
	# same reuse as "Start New Batch" above, but SC Controls' "add" side (moodbatch=add) instead of
	# "play": appends the batch instead of clearing the queue first.
	Slim::Control::Request::addDispatch(['sugarcube', 'addbatch'], [1, 0, 0, \&scAddBatch]);

	###
	# CONTEXT MENU - two items, both fire an SC Batch from what was clicked.
	###
	Slim::Menu::TrackInfo->registerInfoProvider(
		scbatchsong => (
			before => 'playitem',
			func => \&scBatchSongMenu,
		)
	);

	Slim::Menu::TrackInfo->registerInfoProvider(
		scbatchalbum => (
			after => 'scbatchsong',
			func => \&scBatchAlbumMenu,
		)
	);

	Slim::Menu::AlbumInfo->registerInfoProvider(
		scbatchalbum => (
			before => 'playitem',
			func => \&scBatchAlbumMenuFromAlbum,
		)
	);

	# The one context-menu item SqueezeClient's Android Auto integration needs - see
	# scMixFromHereMenu below for why.
	Slim::Menu::TrackInfo->registerInfoProvider(
		scmixfromhere => (
			after => 'scbatchalbum',
			func => \&scMixFromHereMenu,
		)
	);

	Slim::Player::ProtocolHandlers->registerHandler(
		sugarcube => 'Plugins::SugarCube::ProtocolHandler');

	getAlarmPlaylists();

}

sub postinitPlugin {
	my $class = shift;

	$apc_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::AlternativePlayCount::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Alternative Play Count" is enabled') if $apc_enabled;

	# Material has its OWN server-side notification command, and it is the only way to raise a
	# pop-up there. See scTellUser. Asked once at startup, exactly as RatingsLight does it.
	$material_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Material Skin" is enabled') if $material_enabled;

	# Breakout.pm keeps its own $apc_enabled, set via its own postinitPlugin - LMS only calls
	# postinitPlugin on the plugin's main module, so Breakout's copy would otherwise never be set.
	Plugins::SugarCube::Breakout->postinitPlugin();

	# MIP Export (POC) - arm the scheduler once library scanning has settled, same guard the
	# original plugin used. scMIPExportScheduler re-arms itself every 30 minutes from here on.
	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		Slim::Utils::Timers::setTimer (undef, time() + 2, \&scMIPExportScheduler);
	}

	# Players already connected when the plugin loads never fire 'new', so sweep them once here.
	# ->init only fills what is missing, so this is a no-op for every configured player.
	foreach my $client (Slim::Player::Client::clients()) {
		applyClientDefaults ($client);
	}

	###
	# SugarCube no longer registers itself with Don't Stop The Music. Use DSTM, or use SugarCube -
	# they are alternatives, not a hybrid; the player settings and Controls pages say so beside the
	# Status control.
	#
	# ⚠ This goes with the matching removal in commandCallback. That branch let SugarCube run while
	# switched OFF whenever DSTM named it as provider. DSTM keeps its stored provider value after
	# de-registration, so leaving that branch in place would have kept SugarCube running on a player
	# where the toggle said Disabled. Neither block can be restored without the other.
	###

	###
	# DSTM is switched off when Chain Mode starts, and back on when it stops, so a player can never
	# end up mixed by both at once.
	###
	my $dstmprefs = preferences('plugin.dontstopthemusic');

	$prefs->setChange(sub {
		my ($pref, $new, $client) = @_;
		return unless blessed($client);

		###
		# Two constraints from DSTM's own source (Slim::Plugin::DontStopTheMusic::Plugin):
		###
		my $dstmClient = $client->master;

		if ($new) {
			# Chain Mode just switched ON - remember DSTM's current provider before clobbering it,
			# so it can be handed back later. Nothing to remember (and nothing to touch) if DSTM was
			# already off for this player.
			my $dstm = $dstmprefs->client($dstmClient)->get('provider');
			return if !defined $dstm || $dstm eq '0';
			$prefs->client($client)->set('sugarcube_dstm_saved_provider', $dstm);
			$log->info('SC Chain switched on for ' . $client->name . ' - switching DSTM off (was: ' . $dstm . ')');
			$dstmClient->execute(['playerpref', 'plugin.dontstopthemusic:provider', 0]);
		} else {
			# Chain Mode just switched OFF - give DSTM back whatever it had before, if anything was
			# saved. The saved value is cleared straight after, so a later Chain-off with nothing new
			# saved in between does nothing (rather than restoring the same provider twice).
			my $saved = $prefs->client($client)->get('sugarcube_dstm_saved_provider');
			return unless defined $saved;
			$prefs->client($client)->set('sugarcube_dstm_saved_provider', undef);
			$log->info('SC Chain switched off for ' . $client->name . ' - restoring DSTM provider to ' . $saved);
			$dstmClient->execute(['playerpref', 'plugin.dontstopthemusic:provider', $saved]);
		}
	}, 'sugarcube_status');
}

###
# SC BATCH - the two context-menu item builders.
###
sub scMixFromHereMenu {
	my ($client, $url, $obj, $remoteMeta, $tags, $objectType) = @_;
	return unless $client;
	return {
		type => 'redirect',
		name => $client->string('PLUGIN_SUGARCUBEQP'),
		favorites => 0,
		player => {
			mode => 'PLUGIN_SUGARCUBEQP',
			modeParams => {
				objectType => $objectType,
				obj => $obj,
			},
		},
		jive => {
			actions => {
				go => {
					cmd => [ 'sugarcube', 'setting', 'mixfromhere:0' ],
					params => {
						menu => 1,
						id => $obj->id,
					},
					nextWindow => 'nowPlaying',
				}
			},
		},
	};
}

sub scBatchSongMenu {
	my ($client, $url, $obj, $remoteMeta, $tags, $objectType) = @_;
	return scBatchMenuItem ($client, $obj, 'song', 'track', 'PLUGIN_SC_BATCH_SONG', $tags || {});
}

sub scBatchAlbumMenu {
	my ($client, $url, $obj, $remoteMeta, $tags, $objectType) = @_;
	return scBatchMenuItem ($client, $obj, 'album', 'track', 'PLUGIN_SC_BATCH_ALBUM', $tags || {});
}

sub scBatchAlbumMenuFromAlbum {
	my ($client, $url, $obj, $remoteMeta, $tags, $objectType) = @_;
	return scBatchMenuItem ($client, $obj, 'album', 'album', 'PLUGIN_SC_BATCH_ALBUM', $tags || {});
}

sub scBatchMenuItem {
	my ($client, $obj, $seedtype, $idtype, $stringtoken, $tags) = @_;
	return unless $client;
	return unless $obj && ref($obj) && $obj->can('id');

	# Resolved now purely to decide whether to offer the item at all. The action resolves it
	# again from the id, because a menu item cannot be trusted to carry a path intact through
	# every surface's escaping.
	return unless length scBatchSeedPath ($idtype, $obj->id);

	###
	# CLASSIC WEB. A menu client (iPeng, Material) and the Classic web pages ask for these items
	# with the SAME call but different tags, and want completely different answers back: a menu
	# client wants jive actions, Classic wants a rendered link. LMS signals which by menuMode.
	###
	if (!$tags->{menuMode}) {
		return {
			type => 'text',
			name => $client->string($stringtoken),
			scseedtype => $seedtype,
			scidtype => $idtype,
			scobjid => $obj->id,
			scadd => $client->string('PLUGIN_SC_BATCH_ADD'),
			web => {
				'type' => 'htmltemplate',
				'value' => 'plugins/SugarCube/HTML/scbatchlink.html',
			},
		};
	}

	# player => 0 tells the client to send the current player's id with the command. EVERY other
	# item in a trackinfo response carries it; the five old SugarCube items did not, because they
	# were only ever used from iPeng, where a player is implicit. This dispatch needs a client, so
	# without it Material would fire the command and get "needs client" back.
	# click and follows Play.
	my $playaction = {
		player => 0,
		cmd => [ 'sugarcube', 'batch', $seedtype, $idtype, $obj->id, 'play' ],
		params => { menu => 1 },
		nextWindow => 'nowPlaying',
	};

	my $addaction = {
		player => 0,
		cmd => [ 'sugarcube', 'batch', $seedtype, $idtype, $obj->id, 'add' ],
		params => { menu => 1 },
		nextWindow => 'parent',
	};

	# SHAPED LIKE LMS'S OWN ITEMS. Compare the "Album: ..." and "Genre: ..." entries in any
	# trackinfo response: type 'playlist', a play/add/add-hold trio, and play carrying
	# nextWindow => 'nowPlaying'. 'playlist' is what tells a client this entry yields TRACKS, which
	# is how it earns the standard play and append treatment instead of being drawn as a link.
	# 'redirect' was wrong here - that is for an item that opens another screen.
	# favorite would need a sugarcube: URL that carries the seed, which is a separate job.
	return {
		type => 'playlist',
		name => $client->string($stringtoken),
		favorites => 0,
		jive => {
			actions => {
				go => $playaction,
				play => $playaction,
				add => $addaction,
				'add-hold' => $addaction,
			},
			nextWindow => 'nowPlaying',
		},
	};
}

###
# scBatchWeb - the Classic web end of the two context links.
###
sub scBatchWeb {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $seedtype = $params->{'seedtype'} || 'song';
	my $idtype = $params->{'idtype'} || 'track';
	my $id = $params->{'id'};
	my $mode = ($params->{'mode'} && $params->{'mode'} eq 'add') ? 'add' : 'play';

	if (defined $client && defined $id && length $id) {
		PlaySCBatch ($client, $seedtype, $idtype, $id, $mode);
		$params->{'scbatchdone'} = 1;
		$params->{'scbatchmsg'} = Slim::Utils::Strings::string($mode eq 'add'
			? 'PLUGIN_SC_BATCH_ADDING'
			: 'PLUGIN_SC_BATCH_STARTING');
	} else {
		$log->error("SC Batch from the web with no player or no id - nothing done\n");
	}

	return Slim::Web::HTTP::filltemplatefile
		('plugins/SugarCube/HTML/scbatchdone.html', $params);
}

###
# scBatchSeedPath - LMS id to the file path MusicIP needs.
###
sub scBatchSeedPath {
	my ($idtype, $id) = @_;
	return '' unless defined $id && length $id;

	my $track;
	if ($idtype eq 'album') {
		my $album = Slim::Schema->rs('Album')->find($id);
		return '' unless $album;
		# Any track on the record will do - album= is matched on the record, not the track.
		$track = $album->tracks->first;
	} else {
		$track = Slim::Schema->rs('Track')->find($id);
	}
	return '' unless $track;

	my $trackurl = $track->url;
	return '' unless defined $trackurl && length $trackurl;
	return '' if Slim::Music::Info::isRemoteURL($trackurl);

	my $path = Slim::Utils::Misc::pathFromFileURL($trackurl);
	return defined $path ? $path : '';
}

###
# jiveSCBatch - the action behind both context items.
###
sub jiveSCBatch {
	my $request = shift;
	my $client = $request->client();

	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}

	my $seedtype = $request->getParam('_seedtype') || 'song';
	my $idtype = $request->getParam('_idtype') || 'track';
	my $id = $request->getParam('_id');
	my $mode = $request->getParam('_mode') || 'play';

	PlaySCBatch ($client, $seedtype, $idtype, $id, $mode);

	$request->setStatusDone();
}

###
# PlaySCBatch - fire one SC Batch and stop.
###
sub PlaySCBatch {
	my ($client, $seedtype, $idtype, $id, $mode) = @_;
	$mode = 'play' unless defined $mode && $mode eq 'add';

	###
	# OFF MEANS OFF. 06-10-2026 - same guard AutoStartMix already had (Start New Chain); covers
	# both Start New Batch (mode play) and Add/Top Up (mode add), neither of which checked this.
	###
	if (!($prefs->client($client)->get('sugarcube_status') || 0)) {
		$client->showBriefly(
			{
				'line1' => $client->string('PLUGIN_SUGARCUBE'),
				'line2' => $client->string('PLUGIN_INJECTOROFF_MENU_DISABLED')
			},
			{ 'duration' => 5, 'block' => 0 }
		);
		$log->info("SC Batch refused - the Chain is off for this player\n");
		return;
	}

	###
	# A mood is a name, not a path, so there is nothing to look up. Song and album batches are
	# seeded from something you right-clicked and must resolve to a file MusicIP knows about; a
	# mood batch is fired from the Controls page and buildMIPReq reads the mood from the pref.
	###
	my $seedpath = '';
	if ($seedtype eq 'mood') {
		# Guarantee a mood is stored before asking for one. Any surface that fires a mood batch
		# gets this for free, so none of them has to remember to do it.
		Plugins::SugarCube::PlayerSettings::ensureSeedMood ($client);
	} elsif ($seedtype eq 'none') {
		# Nothing to resolve and nothing to guarantee - buildMIPReq below just omits the seed.
	} else {
		$seedpath = scBatchSeedPath ($idtype, $id);
		if (!length $seedpath) {
			$log->error("SC Batch asked for but no seedable path found for $idtype id;"
				. (defined $id ? $id : 'undef') . "\n");
			return;
		}
	}

	$log->debug("SC Batch; mode=$mode seedtype=$seedtype seed=$seedpath\n");

	my $mypageurl = buildMIPReq ($client, $seedpath,
		{ seedtype => $seedtype, constraints => 'batch' });

	# buildMIPReq returns undef when the seed cannot be resolved. No request, no queue wiped.
	if (!defined $mypageurl) {
		$log->error("SC Batch; no request could be built - queue left alone\n");
		return;
	}

	$client->showBriefly(
		{
			'jive' => {
				'type' => 'popupplay',
				'text' => [ $client->string('PLUGIN_SUGARCUBE'), ' ',
					$client->string($mode eq 'add'
						? 'PLUGIN_SC_BATCH_ADDING'
						: 'PLUGIN_SC_BATCH_STARTING') ],
			}
		}
	);

	###
	# Play clears the queue. Add appends - but in BOTH cases the single track SugarCube itself
	# queued ahead is dropped first, since it was built from the continuous-play settings and would
	# sit between you and the batch you just asked for.
	###
	if ($mode ne 'add') {
		my $request = $client->execute ([ 'playlist', 'clear' ]);
		$request->source('PLUGIN_SUGARCUBE');
	} else {
		if (Plugins::SugarCube::Breakout::CheckPosition($client) == 2) {
			my $songIndex = Slim::Player::Source::streamingSongIndex($client) + 1;
			my $request = $client->execute ([ 'playlist', 'delete', $songIndex ]);
			$request->source('PLUGIN_SUGARCUBE');
			$log->debug("SC Batch Add - dropped the one track queued ahead; it came from the "
				. "continuous settings, not from this batch\n");
		}
	}

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotMIP,
		\&gotErrorViaHTTP,
		{
			caller => ($mode eq 'add') ? 'SCBatchAdd' : 'SCBatch',
			callerProc => \&PlaySCBatch,
			client => $client,
			timeout => 60
		}
	);
	$http->get($mypageurl);
}

sub jiveSugarCubeMenu {
	no warnings 'numeric'; # stop annoying warnings about numerics

	$log->debug("jiveSugarCubeMenu\n");
	my $request = shift;
	my $client = $request->client();

	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}
	# MIP request size. The page has a 10-100 slider; Jive gets four steps to tap through, which
	# is all this setting needs in practice. selectedIndex is 1-based. Matched by RANGE rather
	# than exact value, the same way Mix Style is, so a player already on something off-step
	# (51, say) shows the nearest step instead of showing nothing selected.
	# '//' NOT '||' - see the note above %clientDefaults. A stored 0 is a VALUE, not a missing value.
	my $sugarcube_size_j = $prefs->client($client)->get('sugarcube_size') // 20;
	my $size_menu = 1;
	if    ($sugarcube_size_j >= 70) { $size_menu = 4 }
	elsif ($sugarcube_size_j >= 50) { $size_menu = 3 }
	elsif ($sugarcube_size_j >= 30) { $size_menu = 2 }

	my $sugarcube_style = $prefs->client($client)->get('sugarcube_style') || 0;
	my $style_menu;
	if ($sugarcube_style == 0 || $sugarcube_style < 20) {
		$style_menu = 1;
	} elsif ($sugarcube_style == 20 || $sugarcube_style < 40) {
		$style_menu = 2;
	} elsif ($sugarcube_style == 40 || $sugarcube_style < 60) {
		$style_menu = 3;
	} elsif ($sugarcube_style == 60 || $sugarcube_style < 80) {
		$style_menu = 4;
	} elsif ($sugarcube_style == 80 || $sugarcube_style < 100) {
		$style_menu = 5;
	} elsif ($sugarcube_style == 100 || $sugarcube_style < 120) {
		$style_menu = 6;
	} elsif ($sugarcube_style == 120 || $sugarcube_style < 140) {
		$style_menu = 7;
	} elsif ($sugarcube_style == 140 || $sugarcube_style < 160) {
		$style_menu = 8;
	} elsif ($sugarcube_style == 160 || $sugarcube_style < 180) {
		$style_menu = 9;
	} elsif ($sugarcube_style == 180 || $sugarcube_style < 200) {
		$style_menu = 10;
	} elsif ($sugarcube_style == 200) {
		$style_menu = 11;
	}

	# Artist Spacing (rejectsize). The web sliders (player.html, quicksettings.html) go to 30 - MIP
	# itself has no trouble with values that high, the 0-3 cap was only ever this Jive menu's own
	# four-choice limit, never a MIP ceiling. The list is built (below, @spacing_menu_values) rather
	# than typed out by hand, to match the sliders at 0-30 without writing 31 near-identical
	# entries. selectedIndex is 1-based.
	my $sugarcube_rejectsize = $prefs->client($client)->get('sugarcube_rejectsize') || 0;
	my $spacing_menu = $sugarcube_rejectsize + 1;
	$spacing_menu = 1 if ($spacing_menu < 1 || $spacing_menu > 31);
	my @spacing_menu_values = (0..30);

	my $sugarcube_variety = $prefs->client($client)->get('sugarcube_variety') || 0;
	my $variety_menu;
	if ($sugarcube_variety == 0) { $variety_menu = 1; }
	elsif ($sugarcube_variety == 1) { $variety_menu = 2; }
	elsif ($sugarcube_variety == 2) { $variety_menu = 3; }
	elsif ($sugarcube_variety == 3) { $variety_menu = 4; }
	elsif ($sugarcube_variety == 4) { $variety_menu = 5; }
	elsif ($sugarcube_variety == 5) { $variety_menu = 6; }
	elsif ($sugarcube_variety == 6) { $variety_menu = 7; }
	elsif ($sugarcube_variety == 7) { $variety_menu = 8; }
	elsif ($sugarcube_variety == 8) { $variety_menu = 9; }
	elsif ($sugarcube_variety == 9) { $variety_menu = 10; }

	my @menuItems = (
		{
			text =>
			 Slim::Utils::Strings::string('PLUGIN_SUGARCUBE_JIVE_STATUS'),
			choiceStrings => [
				ucfirst (Slim::Utils::Strings::string('OFF')),
				ucfirst (Slim::Utils::Strings::string('ON'))
			],
			selectedIndex => ($prefs->client($client)->get('sugarcube_status') || 0) + 1,
			actions => {
				do => {
					choices => [
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_status:0' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_status:1' ],
						},
					]
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_SUGARCUBE_JIVE_SIZE'),
			selectedIndex => $size_menu,
			choiceStrings => [ "20", "40", "60", "80" ],
			actions => {
				do => {
					choices => [
						{
							player => 0,
							cmd => [ 'sugarcube', 'setting', 'sugarcube_size:20' ],
						},
						{
							player => 0,
							cmd => [ 'sugarcube', 'setting', 'sugarcube_size:40' ],
						},
						{
							player => 0,
							cmd => [ 'sugarcube', 'setting', 'sugarcube_size:60' ],
						},
						{
							player => 0,
							cmd => [ 'sugarcube', 'setting', 'sugarcube_size:80' ],
						},
					],
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_SUGARCUBE_JIVE_FILTER'),
			actions => {
				go => {
					player => 0,
					cmd =>
					 [ 'sugarcube', 'setting', 'sugarcube_filtertypes:0' ],
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_SUGARCUBE_JIVE_RECIPE'),
			actions => {
				go => {
					player => 0,
					cmd =>
					 [ 'sugarcube', 'setting', 'sugarcube_recipetypes:0' ],
				},
			},
		},
		# Artist Spacing (rejectsize), 0-30 matching the web sliders - built from
		# @spacing_menu_values above rather than 31 hand-typed entries.
		{
			text => Slim::Utils::Strings::string('PLUGIN_SUGARCUBE_JIVE_SPACING'),
			selectedIndex => $spacing_menu,
			choiceStrings => [ map { "$_" } @spacing_menu_values ],
			actions => {
				do => {
					choices => [
						map {
							{
								player => 0,
								cmd => [ 'sugarcube', 'setting', "sugarcube_rejectsize:$_" ],
							}
						} @spacing_menu_values
					],
				},
			},
		},
		{
			text =>
			 Slim::Utils::Strings::string('PLUGIN_SUGARCUBE_JIVE_MIXSTYLE'),
			selectedIndex => $style_menu,
			choiceStrings => [
				"0", "20", "40", "60", "80", "100",
				"120", "140", "160", "180", "200"
			],
			actions => {
				do => {
					choices => [
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:0' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:20' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:40' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:60' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:80' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:100' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:120' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:140' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:160' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:180' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_style:200' ],
						},
					],
				},
			},
		},
		{
			text =>
			 Slim::Utils::Strings::string('PLUGIN_SUGARCUBE_JIVE_VARIETY'),
			selectedIndex => $variety_menu,
			choiceStrings =>
			 [ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" ],
			actions => {
				do => {
					choices => [
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:0' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:1' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:2' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:3' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:4' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:5' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:6' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:7' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:8' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_variety:9' ],
						},
					],
				},
			},
		},

		# Actions, not settings. Plain do-items with NO choiceStrings. The old shape was a
		# one-element choice list with selectedIndex => 0 - an index deliberately out of range, since
		# everything else here is 1-based - which printed "Replacing" / "Starting" into the value
		# column so an action rendered as a permanent state.
		# never produced a toast there. The SC Batch context items use this pattern too.
		{
			text => Slim::Utils::Strings::string('PLUGIN_JIVE_NEXT'),
			nextWindow => 'refresh',
			actions => {
				do => {
					player => 0,
					cmd => [ 'sugarcube', 'setting', 'sugarcube_next:0' ],
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_SUGARCUBE_KICKOFF'),
			nextWindow => 'refresh',
			actions => {
				do => {
					player => 0,
					cmd => [ 'sugarcube', 'setting', 'sugarcube_auto:0' ],
				},
			},
		},

		# Mood, then the two ways to fire it. A song or an album batch is fired by right-clicking
		# the thing itself; a mood has nothing to right-click, so it needs its own pair.
		# the log - the same dead end the web page reaches.
		{
			text => Slim::Utils::Strings::string('PLUGIN_SC_WEB_SEEDMOOD'),
			actions => {
				go => {
					player => 0,
					cmd => [ 'sugarcube', 'setting', 'sugarcube_moodtypes:0' ],
				},
			},
		},

		# Actions, so the same plain do-item shape as Replace Next Track above - no choiceStrings,
		# nextWindow at ITEM level. idtype and id are placeholders: a mood seed carries no path, so
		# PlaySCBatch never looks them up. The mood itself comes from the pref the picker sets.
		{
			text => Slim::Utils::Strings::string('PLUGIN_SC_WEB_QS_MOODPLAY'),
			nextWindow => 'refresh',
			actions => {
				do => {
					player => 0,
					cmd => [ 'sugarcube', 'batch', 'mood', 'none', 0, 'play' ],
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_SC_WEB_QS_MOODADD'),
			nextWindow => 'refresh',
			actions => {
				do => {
					player => 0,
					cmd => [ 'sugarcube', 'batch', 'mood', 'none', 0, 'add' ],
				},
			},
		},

		# Volume reduction and Coming Up Next are not on this menu - set-and-forget player prefs,
		# not things you reach for mid-listen. The volume drop is half of Auto Sleep and rides on
		# the switch below; both still appear on player.html.
		{
			text => Slim::Utils::Strings::string('PLUGIN_SUGARCUBE_JIVE_SLEEP'),
			choiceStrings => [
				ucfirst (Slim::Utils::Strings::string('OFF')),
				ucfirst (Slim::Utils::Strings::string('ON'))
			],
			selectedIndex => ($prefs->client($client)->get('sugarcube_sleep') || 0) + 1,
			actions => {
				do => {
					choices => [
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_sleep:0' ],
						},
						{
							player => 0,
							cmd =>
							 [ 'sugarcube', 'setting', 'sugarcube_sleep:1' ],
						},
					]
				},
			},
		},

		# Override Shuffle is not a setting - the behavior is unconditional. See the note on the
		# song= branch of buildMIPReq.
	);
	my $cnt = 0;
	foreach my $item (@menuItems) {
		$request->setResultLoopHash ('item_loop', $cnt, $item);
		$cnt++;
	}
	$request->addResult ('offset', 0);
	$request->addResult ('count', scalar(@menuItems));
	$request->setStatusDone();
}

sub filter_filter {
	$log->debug("Filter_filter\n");

	my $request = shift;
	my $client = $request->client();
	my $l_filters = Plugins::SugarCube::PlayerSettings::getFilterList($client);
	my @listRef = ();
	foreach my $filter (sort keys %$l_filters) {
		push @listRef, $l_filters->{$filter};
	}

	my $activefilter = $prefs->client($client)->get('sugarcube_filteractive') || '';

	my @filtermenu = ();
	my $val;
	foreach my $filter (@listRef) {
		if ($filter eq $activefilter) {
			$val = 1;
		} else {
			$val = 0;
		}
		push @filtermenu,
		 {
			id => $filter,
			text => $filter,
			radio => $val,
			actions => {
				do => {
					player => 0,
					cmd => [ 'sugarcube', 'filters', $filter ],
				},
			},
		 };
	}

	my $numitems = scalar(@filtermenu);

	$request->addResult ("base", { window => { titleStyle => 'noidea' } });
	$request->addResult ("count", $numitems);
	$request->addResult ("offset", 0);
	my $cnt = 0;
	for my $eachPreset (@filtermenu[ 0 .. $#filtermenu ]) {
		$request->setResultLoopHash ('item_loop', $cnt, $eachPreset);
		$cnt++;
	}

	$request->setStatusDone();

	Slim::Control::Jive::sliceAndShip ($request, $client, \@filtermenu);
}

sub recipe_filter {
	$log->debug("recipe_filter\n");
	my $request = shift;
	my $client = $request->client();
	my $l_recipes = Plugins::SugarCube::PlayerSettings::getReceipesList($client);
	my @listRef = ();
	foreach my $recipe (sort keys %$l_recipes) {
		push @listRef, $l_recipes->{$recipe};
	}
	my $activerecipe = $prefs->client($client)->get('sugarcube_receipes') || '';
	my @recipemenu = ();
	my $val;
	foreach my $recipe (@listRef) {
		if ($recipe eq $activerecipe) {
			$val = 1;
		} else {
			$val = 0;
		}
		push @recipemenu,
		 {
			id => $recipe,
			text => $recipe,
			radio => $val,
			actions => {
				do => {
					player => 0,
					cmd => [ 'sugarcube', 'recipe', $recipe ],
				},
			},
		 };
	}
	my $numitems = scalar(@recipemenu);
	$request->addResult ("base", { window => { titleStyle => 'noidea' } });
	$request->addResult ("count", $numitems);
	$request->addResult ("offset", 0);
	my $cnt = 0;
	for my $eachPreset (@recipemenu[ 0 .. $#recipemenu ]) {
		$request->setResultLoopHash ('item_loop', $cnt, $eachPreset);
		$cnt++;
	}
	$request->setStatusDone();
	Slim::Control::Jive::sliceAndShip ($request, $client, \@recipemenu);
}

# Mood picker for the Jive menu. Same shape as recipe_filter, with one deliberate difference:
# NO "(None)" entry. getMoodsList does not add one - Seed set to Mood with no mood chosen can
# only produce a mix nobody asked for, or none at all, so it is not a state worth being able
# to pick. An empty list here means MusicIP reported no moods, which is normal if none exist.
sub mood_filter {
	$log->debug("mood_filter\n");
	my $request = shift;
	my $client = $request->client();
	my $l_moods = Plugins::SugarCube::PlayerSettings::getMoodsList($client);
	my @listRef = ();
	# Case-insensitive, so this list is in the same order as the settings page and the Controls
	# page. Perl's plain sort is ASCII and would put every capitalised mood above every
	# lowercase one, giving three surfaces three different orderings of the same three moods.
	foreach my $mood (sort { lc($a) cmp lc($b) } keys %$l_moods) {
		push @listRef, $l_moods->{$mood};
	}
	# Same reason as the Controls page: settle the stored mood before drawing, or the list opens
	# with no radio filled in on a player whose settings page has never been opened.
	my $activemood = Plugins::SugarCube::PlayerSettings::ensureSeedMood ($client);
	my @moodmenu = ();
	my $val;
	foreach my $mood (@listRef) {
		if ($mood eq $activemood) {
			$val = 1;
		} else {
			$val = 0;
		}
		push @moodmenu,
		 {
			id => $mood,
			text => $mood,
			radio => $val,
			actions => {
				do => {
					player => 0,
					cmd => [ 'sugarcube', 'mood', $mood ],
				},
			},
		 };
	}
	my $numitems = scalar(@moodmenu);
	$request->addResult ("base", { window => { titleStyle => 'noidea' } });
	$request->addResult ("count", $numitems);
	$request->addResult ("offset", 0);
	my $cnt = 0;
	for my $eachPreset (@moodmenu[ 0 .. $#moodmenu ]) {
		$request->setResultLoopHash ('item_loop', $cnt, $eachPreset);
		$cnt++;
	}
	$request->setStatusDone();
	Slim::Control::Jive::sliceAndShip ($request, $client, \@moodmenu);
}


sub playalbum {
	my $client = shift;
	my $song = Slim::Player::Playlist::url($client);
	my $SCQAlbum = Plugins::SugarCube::Breakout::getalbum ($client, $song);

	$client->execute ([ "playlist", 'clear' ]);
	$client->execute ([ "playlist", 'addtracks', "album.id=$SCQAlbum" ]);
	$client->execute (["play"]);

	my $msg = $client->string('PLUGIN_SC_POPUP_ALBUMQUEUED');
	$client->showBriefly(
		{
			'jive' => {
				'type' => 'popupplay',
				'text' => [ $client->string('PLUGIN_SUGARCUBE'), ' ', $msg ],
			 }

		}
	);
}

# Starts the Chain - the continuous mode. Called from the player or from a web page.
sub mixfromplaying {
	my $request = shift;
	my $whocalled = shift;
	my $client;

	no warnings 'numeric';

	if ($whocalled eq "yes")
	{ # if yes then came from web page otherwise came from player
		$client = $request;
	} else {
		$client = $request->client();
	}

	###
	# ⛔ This deliberately reuses PLUGIN_SUGARCUBE_START - "Starting SC Chain" - rather than getting
	# a key of its own: this sub ends in AutoStartMix, the same action the other caller of
	# PLUGIN_SUGARCUBE_START performs, so it is one event with one announcement. Do not split them.
	###
	my $msg = $client->string('PLUGIN_SUGARCUBE_START');

	$client->showBriefly(
		{
			'jive' => {
				'type' => 'popupplay',
				'text' => [ $client->string('PLUGIN_SUGARCUBE'), ' ', $msg ],
			}
		}
	);

	AutoStartMix($client);

}


# Jive Menu Save Filter
sub jive_menu_save_filter {
	my $request = shift;
	my $client = $request->client();

	# $log->debug("jive_menu_save_filter\n");

	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}
	if (defined($request->getParam('_filter'))) {
		$log->debug("Param _filter\n");
		my $new = $request->getParam('_filter');
		my $was = $prefs->client($client)->get('sugarcube_filteractive');
		my $changed = (!defined $was || $was ne $new);
		$prefs->client($client)->set('sugarcube_filteractive', $new);
		# Picking a filter now takes effect at once in One Track mode, matching the Controls page.
		# Previously this surface only stored the value, so the change was inaudible until the next
		# track happened to be built.
		scApplyRequestChange ($client, $changed);
	}
	$request->setStatusDone();
}

sub jive_menu_save_recipe {
	my $request = shift;
	my $client = $request->client();
	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}
	if (defined($request->getParam('_recipe'))) {
		$log->debug("Param _recipe\n");
		my $new = $request->getParam('_recipe');
		my $was = $prefs->client($client)->get('sugarcube_receipes');
		my $changed = (!defined $was || $was ne $new);
		$prefs->client($client)->set('sugarcube_receipes', $new);
		scApplyRequestChange ($client, $changed);
	}
	$request->setStatusDone();
}

sub jive_menu_save_mood {
	my $request = shift;
	my $client = $request->client();
	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}
	if (defined($request->getParam('_mood'))) {
		$log->debug("Param _mood\n");
		$prefs->client($client)->set('sugarcube_seedmood', $request->getParam('_mood'));
	}
	$request->setStatusDone();
}

sub jiveSugarCubeSetting {
	no warnings 'numeric';

	my $request = shift;
	my $client = $request->client();

	# $log->debug("jiveSugarCubeSetting\n");

	if (!defined $client) { $request->setStatusNeedsClient(); return; }

	if (defined($request->getParam('sugarcube_next'))) {
		SugarCubeReplaceNext($client);
	}
	# playalbum / enable_disable / sendtoplayer have no callers via this path any more. playalbum
	# itself survives - it is still on the front-panel menu (see the topMenuItems push below) - but
	# nothing reaches it this way. mixfromplaying survives too; it has four other callers.
	# runs the player's normal Auto Mix and never uses the clicked track.
	if (defined($request->getParam('mixfromhere'))) {
		AutoStartMix($client);
	}

	if (defined($request->getParam('sugarcube_filtertypes'))) {
		filter_filter($request);
	}
	if (defined($request->getParam('sugarcube_recipetypes'))) {
		recipe_filter($request);
	}
	if (defined($request->getParam('sugarcube_moodtypes'))) {
		mood_filter($request);
	}
	if (defined($request->getParam('sugarcube_auto'))) {
		AutoStartMix($client);
	}

	###
	# There is no _sendplayer branch here (see loadSettings for its dispatch). Sending a track to
	# another player is not SugarCube's business - no MusicIP, no mix, no seed, no plugin state -
	# and Material already does the player-to-player job properly at queue level (copy/move/swap).
	###

	if (defined($request->getParam('sugarcube_sleep'))) {
		$prefs->client($client)->set('sugarcube_sleep', $request->getParam('sugarcube_sleep'));
	}
	if (defined($request->getParam('sugarcube_status'))) {
		$prefs->client($client)->set('sugarcube_status', $request->getParam('sugarcube_status'));
	}
	if (defined($request->getParam('sugarcube_style'))) {
		$prefs->client($client)->set('sugarcube_style', $request->getParam('sugarcube_style'));
	}
	if (defined($request->getParam('sugarcube_variety'))) {
		$prefs->client($client)->set('sugarcube_variety', $request->getParam('sugarcube_variety'));
	}
	if (defined($request->getParam('sugarcube_size'))) {
		$prefs->client($client)->set('sugarcube_size', $request->getParam('sugarcube_size'));
	}
	# Style, Variety and Size deliberately do NOT replace: the tap-through widget fires once per
	# tap, so sweeping 0 -> 20 -> 40 would queue three replaces. Same pile-up the earlier iPeng work
	# hit. Seed and Mood do not replace either - buildMIPReq forces Song in One Track mode, so
	# changing them there cannot alter the next request anyway.
	if (defined($request->getParam('sugarcube_rejectsize'))) {
		my $new = $request->getParam('sugarcube_rejectsize');
		my $was = $prefs->client($client)->get('sugarcube_rejectsize');
		my $changed = (!defined $was || $was ne $new);
		$prefs->client($client)->set('sugarcube_rejectsize', $new);
		scApplyRequestChange ($client, $changed);
	}

	###
	# Filter/Recipe save for Live View's "Chain Settings" panel. quicksettings.html saves these two
	# via its own handler (handleWebQuickSettings, a plain form GET) with the same
	# change-triggers-a-replace semantics as Reject Size above - not shared with it, since that
	# handler is written against $params (a page navigation's query string) while this one is
	# written against $request->getParam (a JSON-RPC call). Kept in exact lockstep with the Reject
	# Size block above: same "did the value actually change" guard, same scApplyRequestChange call.
	###
	if (defined($request->getParam('sugarcube_filteractive'))) {
		my $new = $request->getParam('sugarcube_filteractive');
		my $was = $prefs->client($client)->get('sugarcube_filteractive');
		my $changed = (!defined $was || $was ne $new);
		$prefs->client($client)->set('sugarcube_filteractive', $new);
		scApplyRequestChange ($client, $changed);
	}
	if (defined($request->getParam('sugarcube_receipes'))) {
		my $new = $request->getParam('sugarcube_receipes');
		my $was = $prefs->client($client)->get('sugarcube_receipes');
		my $changed = (!defined $was || $was ne $new);
		$prefs->client($client)->set('sugarcube_receipes', $new);
		scApplyRequestChange ($client, $changed);
	}

	###
	# Seed Mood lives in Live View's (and player.html's) "Mix Settings" panel. Plain set, no
	# scApplyRequestChange: it only affects a future SC Batch (read when one of the Mood Batch
	# buttons fires), never the currently queued next track.
	###
	if (defined($request->getParam('sugarcube_seedmood'))) {
		$prefs->client($client)->set('sugarcube_seedmood', $request->getParam('sugarcube_seedmood'));
	}

	###
	# Mix Settings <details> open/closed state - see the %clientDefaults comment (near the top of
	# this file) for why this is stored server-side. Plain set, no scApplyRequestChange - purely a
	# UI preference, never affects what gets queued.
	###
	if (defined($request->getParam('sugarcube_lv_chainsettings_open'))) {
		$prefs->client($client)->set('sugarcube_lv_chainsettings_open',
			$request->getParam('sugarcube_lv_chainsettings_open'));
	}
	$request->setStatusDone();
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe (\&commandCallback);
}

sub SugarCubeReplaceNext {
	no warnings 'numeric';

	my $client = shift;

	###
	# OFF MEANS OFF. 06-10-2026 - same guard AutoStartMix already had (Start New Chain); this one
	# was missing it, so Replace Track kept replacing whatever another provider (e.g. Random Flow)
	# had queued, and kicking off a fresh SC/MusicIP mix, even while SC itself was switched off.
	###
	if (!($prefs->client($client)->get('sugarcube_status') || 0)) {
		$client->showBriefly(
			{
				'line1' => $client->string('PLUGIN_SUGARCUBE'),
				'line2' => $client->string('PLUGIN_INJECTOROFF_MENU_DISABLED')
			},
			{ 'duration' => 5, 'block' => 0 }
		);
		$log->info("Replace Track refused - the Chain is off for this player\n");
		return;
	}

	my $request;
	my $songIndex = Slim::Player::Source::streamingSongIndex($client);
	$songIndex++;
	my $listlength = Slim::Player::Playlist::count($client);
	if ($listlength == 1 || $listlength == 0 || $listlength == $songIndex) {
	} else {
		###
		# Remember what we are throwing away, so kickoff's MusicIP request cannot hand it straight
		# back. The seed here is always the currently playing track (buildMIPReq), unchanged
		# between clicks, so with the same seed/Filter/Recipe/rejectsize MusicIP's ranking is
		# deterministic and would otherwise return the same track again. scRememberReplaced below
		# accumulates every id rejected while this same track keeps playing - see
		# scGetReplacedIds/gotMIP.
		###
		my $discardurl = Slim::Player::Playlist::song ($client, $songIndex);
		if ($discardurl) {
			my $discardtrack = Slim::Schema->rs('Track')->objectForUrl({'url' => $discardurl});
			my $discardid = eval { $discardtrack->id } if $discardtrack;
			scRememberReplaced ($client, $discardid) if (defined $discardid && $discardid =~ /^\d+$/);
		}

		# There is no History page to write the discarded track to any more - APC keeps the real
		# per-player play log instead.
		$request = $client->execute ([ 'playlist', 'delete', $songIndex ]);
	}
	my $msg = $client->string('PLUGIN_SC_POPUP_REPLACINGTRACK');
	$client->showBriefly(
		{
			'jive' => {
				'type' => 'popupplay',
				'text' => [ $client->string('PLUGIN_SUGARCUBE'), ' ', $msg ],
			 }

		}
	);
	kickoff($client);
}

###
# scApplyRequestChange - the ONE place that decides what a request-changing setting does.
###
sub scPathPair {
	my $lmspath = $prefs->get('localmediapath') // '';
	my $mippath = $prefs->get('nasconvertpath') // '';

	return () unless length $mippath; # MusicIP sees what LMS sees - nothing to convert

	if (!length $lmspath) {
		my $dirs = preferences('server')->get('mediadirs');
		$lmspath = (ref $dirs eq 'ARRAY' && @$dirs) ? $dirs->[0] : '';
	}

	return () unless length $lmspath;
	return () if $lmspath eq $mippath; # identical - nothing to convert

	return ($lmspath, $mippath);
}

###
# scReplaceSelection - Live View's one manual action: lets you manually supersede the MIP/SC
# automatic selection.
###
sub scReplaceSelection {
	my $request = shift;
	my $client = $request->client();
	return unless $client;

	###
	# A refusal is not an error, by design: the link reloads the page when the server answers,
	# which is right for a replacement but wrong for a refusal, since the only explanation would
	# otherwise go to the player's screen as a pop-up - the one screen you are not looking at while
	# you click. So a refusal returns normally with 'scmsg', and the link puts that text in place
	# of itself instead of reloading; the answer travels back in the reply to the click.
	###
	my $trackid = $request->getParam('_trackid');
	if (!defined($trackid) || $trackid eq '') {
		$log->warn("Use as Next Track called with no track\n");
		$request->addResult ('scmsg', $client->string('PLUGIN_SC_LV_NOTRACK'));
		$request->setStatusDone();
		return;
	}

	my $track = Slim::Schema->find('Track', $trackid);
	if (!blessed($track) || !$track->url) {
		# Most likely a rescan since this list was built - track ids change library-wide in a
		# clear-and-rescan, so the row is pointing at a number that no longer means anything.
		$log->warn("Use as Next Track - no track found for id $trackid\n");
		$request->addResult ('scmsg', $client->string('PLUGIN_SC_LV_NOTINLIBRARY'));
		$request->setStatusDone();
		return;
	}

	my $ahead = Plugins::SugarCube::Breakout::CheckPosition($client);
	if ($ahead > 2) {
		$log->info("Use as Next Track ignored - $ahead tracks queued. SugarCube only replaces a "
			. "queue of its own making\n");
		$request->addResult ('scmsg', $client->string('PLUGIN_SC_LV_TOOMANY'));
		$request->setStatusDone();
		return;
	}

	my $songIndex = Slim::Player::Source::streamingSongIndex($client);
	$songIndex++;
	my $listlength = Slim::Player::Playlist::count($client);
	if (!($listlength == 1 || $listlength == 0 || $listlength == $songIndex)) {
		my $del = $client->execute ([ 'playlist', 'delete', $songIndex ]);
		$del->source('PLUGIN_SUGARCUBE');
	}

	addtrack ($client, $track->url);
	$log->info("Use as Next Track - queued '" . $track->title . "' by hand\n");


	$request->setStatusDone();
	return;
}

###
# scStartChain - Live View's "Start New Chain" button.
###
sub scStartChain {
	my $request = shift;
	my $client = $request->client();
	return unless $client;

	AutoStartMix ($client);

	$request->setStatusDone();
	return;
}

###
# scReplaceNext - Live View's "Replace Track" button (under Coming Up Next).
###
sub scReplaceNext {
	my $request = shift;
	my $client = $request->client();
	return unless $client;

	SugarCubeReplaceNext($client);

	$request->setStatusDone();
	return;
}

###
# scStartBatch - Live View's "Start New Batch" button (under Currently Playing, shown only while
# a batch is running - see sc_in_batch).
###
sub scStartBatch {
	my $request = shift;
	my $client = $request->client();
	return unless $client;

	PlaySCBatch($client, 'mood', '', '', 'play');

	$request->setStatusDone();
	return;
}

###
# scAddBatch - Live View's "Add Mood Batch" button (under Coming Up Next, shown only while a
# batch is running - see sc_in_batch), same shape as scStartBatch above but SC Controls' "add"
# side: PlaySCBatch's 'add' mode appends the batch to the end of the queue instead of clearing it
# first, exactly as SC Controls' own "Add Mood Batch" button does via moodbatch=add.
###
sub scAddBatch {
	my $request = shift;
	my $client = $request->client();
	return unless $client;

	PlaySCBatch($client, 'mood', '', '', 'add');

	$request->setStatusDone();
	return;
}

sub scApplyRequestChange {
	no warnings 'numeric';

	my ($client, $changed) = @_;
	return '' unless ($client && $changed);

	if (Slim::Player::Playlist::count($client) == 0) {
		# Nothing queued. SugarCubeReplaceNext would call kickoff and append with nothing
		# consuming it, so start a mix properly instead.
		mixfromplaying ($client, "yes");
		return 'started';
	}

	###
	# Only disturb a track SugarCube queued itself. Continuous play keeps exactly one track queued
	# ahead, so swapping it for one built from the new setting is a clean exchange - delete it and
	# you are on the last track, which is what kickoff needs before it will build.
	###
	my $ahead = Plugins::SugarCube::Breakout::CheckPosition($client);
	if ($ahead > 2) {
		$log->debug("Request setting changed, but $ahead tracks are queued - SugarCube only "
			. "replaces a queue of its own making. Leaving it alone\n");
		return '';
	}

	SugarCubeReplaceNext ($client);
	return 'replaced';
}

sub setMode {
	no warnings 'numeric';

	my $class = shift;
	my $client = shift;
	my $method = shift || '';
	my $item;
	if ($method eq 'pop') { Slim::Buttons::Common::popMode($client); return; }
	my $sugarcube_status = $prefs->client($client)->get('sugarcube_status') || 0;
	my $sugarcube_sleep = $prefs->client($client)->get('sugarcube_sleep') || 0;
	my @topMenuItems = ();
	push @topMenuItems, '{PLUGIN_SUGARCUBE_KICKOFF}';

	if ($sugarcube_status == 1) {
		push @topMenuItems, '{PLUGIN_SUGARCUBE_INJECTOR_OFF}';
	}
	if ($sugarcube_status == 0) {
		push @topMenuItems, '{PLUGIN_SUGARCUBE_INJECTOR_ON}';
	}
	push @topMenuItems, '{PLUGIN_JIVE_NEXT}';
	push @topMenuItems, '{PLUGIN_SG_PLAYALBUM}'; #test

	if ($sugarcube_sleep == 1) {
		push @topMenuItems, '{PLUGIN_SUGARCUBE_SLEEP_OFF}';
	}
	if ($sugarcube_sleep == 0) {
		push @topMenuItems, '{PLUGIN_SUGARCUBE_SLEEP_ON}';
	}
	# Volume reduction is half of Auto Sleep, switched by the Sleep entry above and by its own 0
	# setting. Override Shuffle is unconditional - no menu entry for it. The Up Next switch is gone
	# too - nothing reads it.
	push @topMenuItems, '{PLUGIN_FILTERS}';

	my %params = (
		header => '{PLUGIN_SUGARCUBE} {count}',
		listRef => \@topMenuItems,
		modeName => 'MYSUGARCUBE',
		onRight => sub {
			 ($client, $item) = @_;
			enterCategoryItem ($client, $item);
			$client->update();
		},
	);
	if ($method eq 'push') {
		Slim::Buttons::Common::pushModeLeft ($client, 'INPUT.Choice',
			\%params);
	} else {
		Slim::Buttons::Common::pushMode ($client, 'INPUT.Choice', \%params);
		$client->update();
	}
}

sub getDisplayText {
	my ($client, $item) = @_;
	my $name = '';
	if ($item) {
		$name = $item->{'name'};
	}
	return $name;
}

sub getFunctions {
	return {};
}

sub enterCategoryItem {
	no warnings 'numeric';

	my $client = shift;
	my $item = shift;
	if ($item eq '{PLUGIN_SUGARCUBE_KICKOFF}') {
		AutoStartMix ($client, $item);
	} elsif ($item eq '{PLUGIN_SUGARCUBE_SLEEP_ON}') {
		ToggleSleep ($client, $item);
	} elsif ($item eq '{PLUGIN_SUGARCUBE_SLEEP_OFF}') {
		ToggleSleep ($client, $item);
	} elsif ($item eq '{PLUGIN_SUGARCUBE_INJECTOR_ON}') {
		ToggleInjector ($client, $item);
	} elsif ($item eq '{PLUGIN_SUGARCUBE_INJECTOR_OFF}') {
		ToggleInjector ($client, $item);
	} elsif ($item eq '{PLUGIN_JIVE_NEXT}') {
		SugarCubeReplaceNext($client);
	} elsif ($item eq '{PLUGIN_SG_PLAYALBUM}') {
		playalbum($client);
	} elsif ($item eq '{PLUGIN_FILTERS}') {
		my $genres = Plugins::SugarCube::PlayerSettings::getFilterList($client);
		my @listRef = ();
		foreach my $genre (sort keys %$genres) {
			push @listRef, $genres->{$genre};
		}
		Slim::Buttons::Common::pushModeLeft(
			$client,
			'INPUT.Choice',
			{
				header => '{PLUGIN_FILTERS}',
				headerAddCount => 1,
				listRef => \@listRef,
				modeName => 'MYSUGARCUBE',
				overlayRef => sub {
					my ($client, $account) = @_;
					my $curAccount = $prefs->client($client)->get('sugarcube_filteractive') || '';
					if ($account eq $curAccount) {
						return [ undef, '[X]' ];
					} else {
						return [ undef, '[ ]' ];
					}
				},
				callback => sub {
					my ($client, $exittype) = @_;
					$exittype = uc $exittype;
					if ($exittype eq 'LEFT') {
						Slim::Buttons::Common::popModeRight($client);
					} elsif ($exittype eq 'RIGHT') {
						my $value = $client->modeParam('valueRef');
						my $curAccount;
						if ($$value == 0) { $curAccount = "(None)"; }
						$prefs->client($client)->set('sugarcube_filteractive', "$$value");
						$client->update();
					} else {
						$client->bumpRight;
					}
				},
			}
		);
		$client->update();
	}
}

# Fires on track change and when timers expire
sub kickoff {
	no warnings 'numeric';

	my $client = shift;
	return unless $client; # Catch when client has disappeared
	my $track;
	my $song;

	my $quicksong = Slim::Player::Playlist::url($client) || '';;

	# BLOCK STREAMS
	if (Slim::Music::Info::isRemoteURL($quicksong) == 1) {
		return;
	}

	# This is the only copy of this streaming-URL-scheme list.
	# If streaming dont queue up a track
	if ($quicksong =~ m/^napster:/i
		|| $quicksong =~ m/.pls/i
		|| $quicksong =~ m/http:/i
		|| $quicksong =~ m/.asx/i
		|| $quicksong =~ m/rtmp:/i
		|| $quicksong =~ m/^lfm:/i
		|| $quicksong =~ m/^pandora:/i
		|| $quicksong =~ m/^slacker:/i
		|| $quicksong =~ m/^live365:/i
		|| $quicksong =~ m/^mediafly:/i
		|| $quicksong =~ m/^mog:/i
		|| $quicksong =~ m/https:/i
		|| $quicksong =~ m/^deezer:/i
		|| $quicksong =~ m/^spotify:/i
		|| $quicksong =~ m/^rhapd:/i
		|| $quicksong =~ m/^classical:/i
		|| $quicksong =~ m/^loop:/i)
	{ # Check whether we are streaming if so abort
		return;
	}

	if (!defined($song)) { $song = Slim::Player::Playlist::url($client); }

 # If playing tracks not in the library LMS uses tmp which you cant seed from
 # Try replacing it with file and then request a track
	if ($song =~ m/^tmp:/i) {
		my $z = substr $song, 0, 3, "file"; # replaces tmp with file
	}

	$track = Slim::Utils::Misc::pathFromFileURL($song);
	my $untouchedtrack = $track;

	$track = Plugins::SugarCube::Plugin::dirtyencoder($track);

	###
	# Always wait until we are playing the last track in the queue - unconditional, not gated on
	# any mode. One track queued ahead, you play it, you are therefore on the last track, another
	# is queued; this is also what lets a launched playlist play out and hand back to continuous
	# mixing at the end without anything having to track that a playlist is in flight.
	###
	my $scposition = Plugins::SugarCube::Breakout::CheckPosition($client); # If we dont require a track exit the routine

	if ($scposition != 1) {
		$prefs->client($client)->set ('sugarcube_working', 0); # clear the mix-in-progress flag Live View reads
		return;
	}

	$prefs->client($client)->set ('sugarcube_working', 1); # raise the mix-in-progress flag Live View reads

	#
	# Add routine to randomly select a track here
	# Standard MusicIP Mode
	my $mypageurl = buildMIPReq ($client, $untouchedtrack);

	# buildMIPReq refuses to build when the seed cannot be resolved - Mood chosen with no mood
	# set, for instance. No request, no queued track; the reason is in the log.
	if (!defined $mypageurl) {
		$prefs->client($client)->set ('sugarcube_working', 0); # clear the mix-in-progress flag Live View reads
		return;
	}

	my $diditwork = SendtoMIPAsync ($client, $mypageurl);
}

###
# gotMIP - Receive back list URL data dump and process
###
sub gotMIP {
	no warnings 'numeric';

	my $http = shift;
	my $params = $http->params();
	my $client = $params->{'client'};
	my ($element, $song, $track, $changeindex, $temptrack);
	# Set when the relaxed-rejectsize retry (see 'MUSICIP EMPTY' below) has been fired for this
	# pass, so the FAILED STOP check further down knows an empty $song here is expected - the
	# retry's own gotMIP call is what decides the outcome, not this one.
	my $retrying = 0;
	my @quickone;
	my $content = $http->content();
	my @miparray = split (/\n/, $content);

	$log->debug("\n#### MusicIP Responded with ####\n$content\n");

	$mixstatus = ''; # Reset MIP Status

	my $creator = $params->{'caller'}; # CHECK WHETHER ASYNC WAS FROM QUICK MIX

	$global_quickmix = 0;

	$changeindex = 0;
	# Read once for the whole response rather than per line. Empty list means no conversion needed.
	my ($lmspath, $mippath) = scPathPair();

	foreach (@miparray) {
		my $enc = Slim::Utils::Unicode::encodingFromString ($miparray[$changeindex]);
		$element = Slim::Utils::Unicode::utf8decode_guess ($miparray[$changeindex],
			$enc);

		if (defined $lmspath) { # MusicIP path -> LMS path

			my $nasconvertpath = $mippath;
			my $localmediapath = $lmspath;

			$nasconvertpath = quotemeta $nasconvertpath;

			# $log->debug("Dynamic Change Using;$nasconvertpath\n");
			# $log->debug("Dynamic Replace With;$localmediapath\n");
			# $log->debug("Original element;$element\n");
			$element =~ s/$nasconvertpath/$localmediapath/i;

			# $log->debug("Converted element;$element\n");

			# ⚠ Do not remove the second path pair from the public build - it is needed for a
			# library spanning two mount points. If both its path fields are left empty, the
			# substitution pattern is empty and Perl silently reuses the LAST SUCCESSFUL pattern
			# instead (here, the pair above), so make sure it is guarded the same way as the first.
		}

		$element = dirtyencoder($element);
		push (@unique, $element);
		$changeindex++;
	}

	# THE ALARM CHECK WENT IN EDIT 41 (2026-08-12). It looked up the details of whatever was playing
	# and filed them into the Currently Playing slots, skipping itself for the alarm track, Auto Mix
	# and SC Batch because none of those have a current track to save. Live View no longer reads
	# those slots, so the lookup had no consumer. The PANIC log line that sat with it went too - it
	# tested the result of that same lookup, and it was written at info level, below the default
	# WARN threshold, so it had never appeared in a log.

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $table = $apc_enabled ? 'alternativeplaycount' : 'tracks_persistent';

	###
	# A skip counts as a touch. APC only records a PLAY once the track passes its played
	# threshold (20% by default); skip earlier than that and APC writes skipCount/lastSkipped
	# instead, leaving lastPlayed unchanged. The recency block reads lastPlayed, so without this a
	# skipped track looks untouched and can come straight back - and two tracks that are each
	# other's top acoustic match can then alternate forever.
	###
	my $lasttouched = $apc_enabled
		? "MAX(ifnull(alternativeplaycount.lastPlayed, 0), ifnull(alternativeplaycount.lastSkipped, 0))"
		: "tracks_persistent.lastPlayed";

	###
	# group_concat(DISTINCT genres.name) gives every genre for a track, comma separated, still one
	# row per track thanks to "group by tracks.url" below - a plain "genres.name" would show only
	# one genre, arbitrarily, from whichever row SQLite happened to return last.
	###
	my $query = "SELECT tracks.url, tracks.title, albums.title, group_concat(DISTINCT genres.name), contributors.name, $table.playCount, tracks_persistent.rating, $lasttouched, tracks.coverid, tracks.album, tracks.id, albums.year FROM contributors, tracks INNER JOIN genre_track ON (genre_track.track = tracks.id) INNER JOIN tracks_persistent ON (tracks.urlmd5 = tracks_persistent.urlmd5)";
	$query .= " left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5" if ($apc_enabled);
	$query .= " INNER JOIN genres ON (genre_track.genre = genres.id) INNER JOIN albums ON (tracks.album = albums.id) INNER JOIN contributor_track ON tracks.id = contributor_track.track AND contributor_track.contributor = contributors.id AND contributor_track.role in (1,6) WHERE tracks.url = ";

	# Not "my" - $changeindex is already declared at the top of this sub and used by the loop
	# above; a second "my" here would shadow it and warn.
	$changeindex = 0;
	foreach (@unique) {
		my $addme = $dbh->quote ($unique[$changeindex]);
		$query = ($query . $addme . " OR tracks.url = ");
		$changeindex++;
	}

	$query = substr ($query, 0, -17);
	$query = $query
	 . " group by tracks.url"; # one row per track; group_concat above collects every genre
	my $sth = $dbh->prepare($query);
	$sth->execute();

	while (my @results = $sth->fetchrow_array()) {
		push @quickone, $results[0], $results[1], $results[2], $results[3],
		 $results[4], $results[5], $results[6], $results[7], $results[8],
		 $results[9], $results[10], $results[11]; # [11] = year
	}
	if ($sth->rows == 0) {
		$log->debug("Failed to obtain LMS metadata from database\n\n"); # Need to do something probably :)
	}

	# Restore MIP acoustic order before saving to WorkingSet
	# STRIDE IS 12 since year was added - it must match the push above AND myworkingset's own
	# stride. Three places, one number; change one and the rows silently shear apart.
	my %mip_order;
	for my $idx (0 .. $#unique) { $mip_order{$unique[$idx]} //= $idx; }
	my @groups;
	for (my $i = 0; $i < scalar(@quickone); $i += 12) {
		push @groups, [@quickone[$i .. $i+11]];
	}
	@groups = sort { ($mip_order{$a->[0]} // 9999) <=> ($mip_order{$b->[0]} // 9999) } @groups;
	@quickone = map { @$_ } @groups;

	Plugins::SugarCube::Breakout::myworkingset ($client, @quickone); # Save all our stuff

	# Genre, artist, album and played-track blocking all removed (BUILD_PLAN Phase 7).
	# What remains is the statistics recency block in droptsmetrics, which is live,
	# library-wide and reads APC - and this, which stops MusicIP handing back the seed.
	Plugins::SugarCube::Breakout::DropSeed($client);

	# Nothing already in this player's queue may be queued again. Sharper than the recency
	# block and immediate - APC does not write lastPlayed or lastSkipped until a track ENDS,
	# so during fast skipping there is a window where nothing has been recorded yet and the
	# recency block is blind. The queue is true the moment a track is added. See DropInQueue.
	Plugins::SugarCube::Breakout::DropInQueue($client);

	# Strikes every track SugarCubeReplaceNext has deleted from the queue FOR THIS SEED - not just
	# the last one, or repeated clicks alternate between the same two MusicIP picks. Keyed on the
	# raw playlist URL only to detect a genuine seed change; DropLastReplaced matches on trackid,
	# so no path conversion is needed here the way DropSeed needs it. See scGetReplacedIds above.
	my @scReplacedIds = scGetReplacedIds($client, (Slim::Player::Playlist::url($client) // ''));
	Plugins::SugarCube::Breakout::DropLastReplaced($client, \@scReplacedIds)
		if @scReplacedIds;

	# Permanent artist/genre block, built on WorkingSet only. MIP Filters cannot do this on the fly
	# from a Lyrion player, and Live View / Replace both need the player watched by a person - this
	# needs configuring once and then nothing. Same "hard block, independent of statistics" tier as
	# droptsmetrics below, so it runs alongside it.
	Plugins::SugarCube::Breakout::DropBlockedArtist($client);
	Plugins::SugarCube::Breakout::DropBlockedGenre($client);

	# Repeat blocking - see TrackRepeatRecord/DropRepeatArtist/DropRepeatAlbum in Breakout.pm and
	# the CREATE TABLE comment in Breakout::init for ArtistTracker/AlbumTracker. Record what is
	# CURRENTLY PLAYING (the seed for this cycle) into the rolling window first, then drop any
	# candidate still inside that window, so this cycle's own seed is remembered before next
	# cycle's pool is filtered.
	Plugins::SugarCube::Breakout::TrackRepeatRecord($client, currentTrackAlbum($client), currentTrackArtist($client));
	Plugins::SugarCube::Breakout::DropRepeatArtist($client);
	Plugins::SugarCube::Breakout::DropRepeatAlbum($client);

# Try and detect when return track is the same as the playing track but from a different directory
# Ie. greatest hits, do a comparison of the track title to guess
# $log->debug("Dropping as per statistics Block metrics\n");
	Plugins::SugarCube::Breakout::droptsmetrics($client);

	# There is no statistics-based re-sorting here - that would override MIP's own acoustic
	# ranking, which must be preserved. Recipes shape the mix better, MIP-side. The hard blocks
	# above (droptsmetrics) are a separate concern and remain load-bearing.
	$log->debug("Stats blocks applied; keeping MIP order\n");
	@myworkingset = Plugins::SugarCube::Breakout::mystuff($client);

	# Artist Weighting - a SOFT bias, unlike DropBlockedArtist's hard exclusion, and pure in-memory
	# array work with no tracker table. See the comment on the sub itself for the full reasoning.
	# Applied right here, immediately after mystuff and before the SC BATCH branch below, so a
	# batch pull sees the same biased pool a continuous-play mix would.
	@myworkingset = Plugins::SugarCube::Breakout::applyArtistWeighting($client, @myworkingset);

###
### SC BATCH - queue the whole surviving working set in one go.
### Limitations; Live View and tracks within the queue stack can be from the same album
	# afterwards (below).
	my $isbatch = (($creator || '') eq 'SCBatch' || ($creator || '') eq 'SCBatchAdd');
	if ($isbatch) {
		my $arraysize = scalar $#myworkingset + 1;

		# Divide by 10 = number of tracks
		if ($arraysize != 0) {
			my $stack_size = $arraysize / 10;

			# Batch Queue Limit - cap how many of the surviving candidates actually get queued
			# into Lyrion. Independent of sugarcube_size/MIP Ask Size above, which only sizes the
			# request to MusicIP; this trims what Batch does with the result.
			my $sugarcube_batchsize = $prefs->client($client)->get('sugarcube_batchsize') // 50;
			$stack_size = $sugarcube_batchsize if ($stack_size > $sugarcube_batchsize);

			for (my $i = 0 ; $i < $stack_size ; $i++) {
				$log->debug("SC Batch; queueing; $myworkingset[$i*10]\n");
				# SaveHistory - see the History CREATE TABLE comment in Breakout.pm's init(). Called
				# unconditionally here for every batch item.
				Plugins::SugarCube::Breakout::SaveHistory(
					$client,
					$myworkingset[ ($i * 10) + 4 ],
					$myworkingset[ ($i * 10) + 1 ],
					$myworkingset[ ($i * 10) + 2 ],
					$myworkingset[ ($i * 10) + 3 ],
					$myworkingset[ ($i * 10) + 8 ],
					$myworkingset[ ($i * 10) + 9 ]
				);
				addtrack ($client, $myworkingset[ $i * 10 ]); # song is hashed up
			}
		} else {
			# MusicIP answered and the answer held nothing usable - a batch never reaches
			# blockedfallback, so this is the empty case, not the unreachable one.
			$log->error("SC BATCH GOT NO TRACKS - MusicIP returned nothing for the batch Filter and Recipe\n");
			gotErrorContinue ($client, $http, 'empty');
		}

	} else {
		###
		### Just take a single track
		###

		{
			# SELECT THE FIRST TRACK AND ADD DETAILS INTO OUR HISTORY ARRAY
			# so this is a no-op change in behaviour until a player actually turns Wobble on.
			$song = pickWobbleTrack($client, \@myworkingset) // '';

			###
			# STAY INSIDE THE REQUEST. Every track MusicIP sent has been blocked - played too
			# recently, rated too low, playcount too high. Rather than reaching outside the Filter
			# and Recipe, take the best MusicIP track anyway: it is the closest acoustic match on
			# offer and it is inside the constraints by construction, because MusicIP built the list
			# with them applied. The seed is excluded, so nothing plays twice running. In plain
			# terms: "everything I found was played too recently - here is the best one anyway",
			# instead of a random track from the genre or from the whole library.
			###
			if (length($song) == 0) {
				$log->debug("All tracks blocked; falling back to the best MusicIP track\n");
				@myworkingset = Plugins::SugarCube::Breakout::blockedfallback($client);
				# Wobble applies here too (Henk, 2026-09-19) - blockedfallback already decided
				# WHICH tracks are offered ("best MusicIP track anyway"), Wobble only changes
				# which one of those offered tracks actually gets picked.
				$song = pickWobbleTrack($client, \@myworkingset) // '';

				if (length($song) != 0) {
					# WARN, not ERROR - music did arrive. It just was not music that passed your
					# own playcount / rating / recency rules.
					$log->warn("SC BLOCK BREACHED - every track MusicIP offered was blocked; "
						. "playing its best one anyway\n");

					# DELIBERATELY NOT $mixstatus. liveview.html wraps the whole candidate list in
					# [% IF mixstatus == '' %], so anything written there HIDES the list - and the
					# list is where the 'SC BLOCK BREACH!' label lives, and is the only route that
					# reaches Material at all. mixstatus is for "there is nothing to show"; a breach
					# is the opposite, there is something to show and it needs looking at.
					scTellUser ($client, $client->string('PLUGIN_SC_POPUP_BREACHED'));
				}
			}

			if (length($song) == 0) {
				$log->error("MUSICIP RETURNED NOTHING - the Filter and Recipe found no tracks\n");
				$mixstatus = 'MusicIP returned nothing. Check Filter/Recipe';
				scTellUser ($client, $client->string('PLUGIN_SC_POPUP_NOTRACKS'), 'error');

				###
				# NEVER INVENT A TRACK. The user's decision, 2026-08-12, Edit 47. This is MUSICIP
				# EMPTY - MusicIP answered, but with no tracks, so the Filter or Recipe found
				# nothing. It used to queue a random track and carry on, which meant an evening
				# could drift out of the filter you asked for without you noticing.
				#
				# ⚠ STOPPING DEAD WAS THE FIRST SHAPE. IT WAS BUILT, DEPLOYED AND TESTED - the log
				# carries 'STOPPING - nothing queued' three times at 21:12 on 2026-08-12 - AND IT
				# WAS REJECTED ON THE EVIDENCE. Lyrion wraps to the first entry in the queue and
				# falls silent, so the display shows a track from earlier and a failure cannot be
				# told apart from the end of a playlist. In his words: "If driving, one can't be
				# sure what happened. You hit a button and realize 2-3 tracks later you heard it a
				# little while back - not great." What replaced it is the repeat below. Do not
				# restore the silent stop.
				#
				# ⛔ THE ALARM IS THE ONE EXCEPTION, and it is his ruling too: "Alarm should work,
				# song immaterial." An alarm exists to wake you; silence is a failed alarm and it is
				# the one failure you cannot notice in time. So the random fallback survives HERE
				# ONLY, for the alarm, and that is the only reason randompuller and getRealRandom
				# are still called at all.
				###
				if ( (($params->{'caller'} // '') eq 'SpiceflyAlarm') ) {
					$song = randompuller($client); # Assumes something is playing; fails harmlessly if not
					$log->debug("MIP returned nothing. ALARM - got Random Track instead;$song\n");
					if ( (length($song) == 0) || ($song eq 'FAILED')) {
						$log->debug("Track still not good have;$song .Getting RealRandom track to use\n");
						$song = Plugins::SugarCube::Breakout::getRealRandom();
						$log->error("COMPLETELY RANDOM TRACK USED FOR ALARM - nothing from MusicIP, "
							. "and nothing playing to take a genre from\n");
					}
				} else {
					###
					# ONE RETRY, ARTIST SPACING RELAXED, BEFORE THE REPEAT BELOW. Proposed by Henk,
					# tested against the case saysaar predicted he would hit: a small Filter/Recipe
					# neighbourhood where 'rejectsize' (artist spacing) trims the last surviving
					# candidates to nothing. Filter, Recipe and seed are untouched here - whatever
					# comes back is still entirely MusicIP's own acoustic choice, nothing is invented
					# locally, only the spacing demand is loosened for this one retry. Scoped to
					# continuous play / Use as Next Track (caller 'Spicefly' - AutoStartMix and SC
					# Batch build their own request and never set this caller) and bounded to a
					# single attempt via the retry flag SendtoMIPAsync now carries. If the retry also
					# comes back empty, the repeat below runs exactly as it always has.
					###
					if ((($params->{'caller'} // '') eq 'Spicefly') && (($params->{'retry'} // 0) == 0)) {
						my $requrl = eval { $http->url } || '';
						if ($requrl =~ /&rejectsize=\d+&rejecttype=tracks/) {
							(my $relaxedurl = $requrl) =~ s/&rejectsize=\d+&rejecttype=tracks//;
							$log->warn("MUSICIP EMPTY - retrying once with artist spacing relaxed, before repeating\n");
							SendtoMIPAsync($client, $relaxedurl, 1);
							$retrying = 1;
						}
					}

					if ($retrying) {
						# Leave $song empty and skip the repeat - the retry above is its own async
						# call and will run this same function again with retry=1. Everything below
						# still runs on THIS pass (slideVolume, playlistcull, sleepplayer); none of
						# it queues anything while $song is empty, so running it twice is harmless.
					} else {
						###
						# REPEAT THE CURRENT TRACK AS AN AUDIBLE WARNING. The user's decision,
						# 2026-08-12. Hearing the same song again says "something is wrong" through the
						# only channel that reaches him in a car - the speakers. Every visual route we
						# have is a five-second pop-up, and one of them does not reach iPeng at all.
						#
						# ⛔ DO NOT SWITCH ON LYRION'S REPEAT MODE TO DO THIS. That is a setting the user
						# owns, and reaching into Lyrion's own settings is the recurring fault named four
						# times in EXPERIENCE.md. Appending to the queue is SugarCube's own business and
						# leaves his settings untouched.
						###
						$song = Slim::Player::Playlist::url($client) // '';

						# The tmp: guard, copied from kickoff verbatim - the same two lines used in Live
						# View. Players on this system do hold tmp: urls, so this is not hypothetical.
						if ($song =~ m/^tmp:/i) {
							my $z = substr $song, 0, 3, "file";
						}

						if (length($song) != 0) {
							$log->error("MUSICIP EMPTY - repeating the current track as an audible warning\n");
						} else {
							$log->error("STOPPING - nothing queued, and nothing playing to repeat\n");
						}
					}
				}
			} else {
				# The Coming Up Next slots were filled here in Edit 40 and earlier, from the row
				# MusicIP picked. Removed in Edit 41 - nothing read them. The artwork field was
				# defaulted to "0" here for the same reason and went with them.
				$log->debug("\nQueueing; $myworkingset[4] : $myworkingset[1]\n");

				# SaveHistory - Henk's request 2026-09-11, ported back from the hoofdmap build (see
				# the History CREATE TABLE comment in Breakout.pm's init()). Same row indices the
				# hoofdmap build uses: 4=artist, 1=track, 2=album, 3=genre, 8=albumart, 9=fullalbum.
				Plugins::SugarCube::Breakout::SaveHistory(
					$client,          $myworkingset[4], $myworkingset[1],
					$myworkingset[2], $myworkingset[3], $myworkingset[8],
					$myworkingset[9]
				);
			}

			# GUARDED IN EDIT 47. $song can now legitimately be empty - situation B on anything that
			# is not the alarm stops rather than inventing a track - and objectForUrl('') has no
			# meaning. The "FAILED STOP" test just below is what handles the empty case, and it was
			# already there; nothing reached it before because a random track was always produced.
			if (length($song) != 0) {
				$log->debug("Asking LMS to Queue Track;\n$song\n");
				$song = Slim::Schema->rs('Track')->objectForUrl($song);
			}
		}

		if (length($song) == 0) {
			if ($retrying) {
				# Not a failure - the relaxed-rejectsize retry above is already in flight and its
				# own gotMIP call will queue a track or repeat, whichever MusicIP answers with.
				$log->debug("Retry in flight after MUSICIP EMPTY - not logging FAILED STOP for this pass\n");
			} else {
				# The true dead end - not even a random track came back, so NOTHING was queued. If
				# anything in this plugin is an error, this is. It sat at info, which the user's WARN
				# logger never showed. Step 8.4c.
				$log->error("********* FAILED STOP - Nothing to work with, no track queued *********\n");
			}
		} else {
			addtrack ($client, $song); # song is hashed up
		}
	}

	# End of classic mode

	$#unique = -1;
	slideVolume($client); # decides for itself - Auto Sleep on, inside the hours, drop above 0
	Plugins::SugarCube::Breakout::playlistcull($client);
	sleepplayer($client);

	$creator = $params->{'caller'};

	# ASYNC WAS FROM ALARM DO THE TIDY UP FUNCTIONS
	if ($creator eq 'SpiceflyAlarm') {

		my $request = $client->execute ([ 'playlist', 'delete', 0 ]);
		$request->source('PLUGIN_SUGARCUBE');
		$request = $client->execute (['play']);
		$request->source('PLUGIN_SUGARCUBE');
		return 1; # Need to return 1 to stop being attacked by alarm calls
	}
	# SCBatchAdd is deliberately absent: Add appends to a queue that is already playing and must
	# not interrupt it. Only Play starts playback.
	if ($creator eq 'SpiceflyAutoMix' || $creator eq 'SCBatch') {
		my $request = $client->execute (['play']);
		$request->source('PLUGIN_SUGARCUBE');
	}
}

###
# WOBBLE, ported from Henk's HB64 hoofdmap build (github.com/HB64/lms-sugarcube) 2026-09-19.
# Chain mode normally always takes the single BEST MusicIP match ($myworkingset[0]) as the next
# seed - Wobble instead picks randomly from a window at the top of that same list, so playback
# doesn't always travel the single most-similar path. Never applies to a Batch - a batch already
# queues the whole surviving list at once, there is nothing to wobble.
# changes which one of those offered tracks gets picked.
sub pickWobbleTrack {
	my ($client, $workingsetRef) = @_;
	my @myworkingset = @$workingsetRef;

	my $wobble = $prefs->client($client)->get('sugarcube_wobble') // 0;
	return $myworkingset[0] // '' unless ($wobble >= 1 && $wobble <= 4);

	my $effective = $wobble;
	$effective = int(rand(3)) + 1 if ($wobble == 4); # Floating: fresh 1/2/3 coin-flip, every call

	my $arraysize = scalar @myworkingset; # total slots, ten per track - see Breakout.pm's mystuff
	return '' if ($arraysize == 0);
	my $trackcount = $arraysize / 10;

	# Default: anywhere in the whole surviving pool (Loose Wobble, mode 3, and Tight/Medium's own
	# fallback whenever the pool is too small for their window to mean anything).
	my $pick = int(rand($trackcount));

	if ($effective == 1 && $arraysize > 31) {
		$pick = int(rand(3)); # Tight Wobble - first 3
	} elsif ($effective == 2 && $arraysize > 51) {
		$pick = int(rand(5)); # Medium Wobble - first 5 (the hoofdmap bug fix, see above)
	}

	return $myworkingset[$pick * 10] // '';
}

# Random track selector assuming that we have a track currently playing (otherwise it will fail)
# Random track based on Currently Playing Genre
sub randompuller {
	my $client = shift;

	my $song = Slim::Player::Playlist::url($client); # CHECK WHETHER ASYNC WAS FROM ALARM or AUTOMIX - IF SO THEN DONT SAVE CURRENT TRACK

	if (!defined($song) || $song eq 'sugarcube:track') { # Breakout if there is no currently playing track we can pull the genre from
		$song = "FAILED";
		$log->debug("\nNo Currently Playing Track to get Genre from\n");
		return $song;
	}
	$log->debug("\nLMS Reported Track Playing;\n$song\n");

	 (my $NEWSCgenre) = Plugins::SugarCube::Breakout::getGenre ($client, $song);
	$log->debug("\nCurrently Playing; $song\n");
	$log->debug("\nCurrently Playing Genre; $NEWSCgenre\n");

	# getRandom hands back seven values. Edit 41 stopped reading the last four here (they only fed
	# Live View's Coming Up Next display, which no longer needs them) - but SaveHistory below wants
	# them again, so all seven are captured once more as of 2026-09-11.
	(
		my $SCTRACKURL,
		my $RNDArtist,
		my $RNDTrack,
		my $RNDAlbum,
		my $RNDGenre,
		my $RNDAlbumArt,
		my $RNDFullAlbum
	) = Plugins::SugarCube::Breakout::getRandom ($client, $NEWSCgenre);

	# The " (SugarCube Random Selection)" marker flags this row on the History page - Henk's
	# request 2026-09-11, History came back specifically so a random fallback like this one is
	# visible there, not just in the server log. Raised to ERROR in Step 8.4 (2026-08-08) - going
	# random means the setup failed to deliver what it was asked for, and ERROR now means exactly
	# that and nothing else; that log line stays too, for anyone watching SCDEBUG.
	# fires only at the true dead end.
	$log->error("RANDOM FALLBACK USED - not a MusicIP choice: $RNDTrack by $RNDArtist\n");
	my $RNDHistGenre = $RNDGenre . '    (SugarCube Random Selection)';
	Plugins::SugarCube::Breakout::SaveHistory ($client, $RNDArtist, $RNDTrack,
		$RNDAlbum, $RNDHistGenre, $RNDAlbumArt, $RNDFullAlbum);

## $song = Slim::Schema->rs('Track')->objectForUrl($SCTRACKURL);
	return $SCTRACKURL;

}

sub SugarDelay {
	my $client = shift;

	###
	# OVERRIDE SHUFFLE MOVED 2026-08-06. It used to run HERE, on every single track change, which
	# meant you could not shuffle a queued batch by hand: press shuffle, get one track, and
	# SugarCube switched it off again a second later. It looked broken rather than deliberate.
	###
	if (Slim::Player::Sync::isSlave($client)) {
		return;
	} else {
		kickoff($client);
	}
}

###
# THE 20-SECOND HEARTBEAT, SugarPlayerCheck, WAS REMOVED IN FULL IN EDIT 46 (2026-08-12).
# This closes parked item 1. Parked item 2 closed with it - see scReplaceSelection above.
###

# The ARTIST tag of the track this player is currently on - NOT the album artist, and NOT the
# folder name. Measured against the live MIP server 2026-08-02 and again 2026-08-03:
# artist=<ARTIST tag> seeds correctly (HTTP 200), while the folder name returns HTTP 500.
# An unknown artist fails loudly rather than falling through to a default mix - see BUILD_PLAN 3.6.
# 'The Soul Brothers'; the latter seeds a coherent reggae mix.)
sub currentTrackArtist {
	my $client = shift;
	return '' unless $client;

	my $url = Slim::Player::Playlist::url($client) || '';
	return '' unless length $url;

	my $artist = '';
	eval {
		my $dbh = Slim::Schema->dbh;
		my $sth = $dbh->prepare (
			'SELECT contributors.name FROM contributors '
			. 'INNER JOIN contributor_track ON contributor_track.contributor = contributors.id '
			. 'INNER JOIN tracks ON tracks.id = contributor_track.track '
			. 'WHERE tracks.url = ? AND contributor_track.role IN (1,6) '
			. 'ORDER BY contributor_track.role DESC LIMIT 1'
		);
		$sth->execute ($url);
		($artist) = $sth->fetchrow_array;
		$sth->finish;
	};
	if ($@) {
		$log->warn("Could not read the track artist for $url;$@\n");
		return '';
	}
	$artist = '' unless defined $artist;
	$log->debug("Track artist for seeding;$artist\n");
	return $artist;
}

# currentTrackAlbum - Henk's request 2026-09-11, same shape as currentTrackArtist just above (same
# URL lookup, same "empty string on anything missing" contract) but for the album, so
# TrackRepeatRecord (Breakout.pm) has both values it needs to remember for the repeat-block window
# without a second round trip through Plugin.pm.
sub currentTrackAlbum {
	my $client = shift;
	return '' unless $client;

	my $url = Slim::Player::Playlist::url($client) || '';
	return '' unless length $url;

	my $album = '';
	eval {
		my $dbh = Slim::Schema->dbh;
		my $sth = $dbh->prepare (
			'SELECT albums.title FROM albums '
			. 'INNER JOIN tracks ON tracks.album = albums.id '
			. 'WHERE tracks.url = ?'
		);
		$sth->execute ($url);
		($album) = $sth->fetchrow_array;
		$sth->finish;
	};
	if ($@) {
		$log->warn("Could not read the track album for $url;$@\n");
		return '';
	}
	$album = '' unless defined $album;
	return $album;
}

###
# MIP EXPORT - proof of concept, Henk 2026-08-31.
###

# Re-arms itself every 30 minutes, ALWAYS - even when off, so a time set later is never stalled
# until an LMS restart. Ported from MIPster, 2026-09-19: the gate is the time field itself, not a
# separate enable checkbox - blank sc_mipexport_time means no scheduled daily export. Independent
# of Post-scan Automatic Export (scMIPExportPostScanFire), which has its own toggle below.
sub scMIPExportScheduler {
	Slim::Utils::Timers::killTimers (undef, \&scMIPExportScheduler);
	Slim::Utils::Timers::setTimer (undef, time() + 1800, \&scMIPExportScheduler);

	my $exporttime = $prefs->get('sc_mipexport_time');
	return unless defined $exporttime && length $exporttime;

	if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		$log->info("SC MIP Export - scan in progress, scheduler will retry in 30 minutes\n");
		return;
	}

	if ($prefs->get('sc_mipexport_inprogress')) {
		$log->info("SC MIP Export - export already running, scheduler will retry in 30 minutes\n");
		return;
	}

	my $lastday = $prefs->get('sc_mipexport_lastday');
	$lastday = -1 unless defined $lastday;

	my $target = 0;
	if ($exporttime =~ /^([01]?[0-9]|2[0-3]):([0-5][0-9])$/) {
		$target = ($1 * 3600) + ($2 * 60);
	} else {
		$log->warn("SC MIP Export - invalid export time '$exporttime', skipping this check\n");
		return;
	}

	my ($sec, $min, $hour, $mday) = (localtime(time()))[0, 1, 2, 3];
	my $nowseconds = ($hour * 3600) + ($min * 60);

	if ($lastday != $mday && $nowseconds > $target) {
		$log->info("SC MIP Export - starting scheduled export\n");
		eval { Slim::Utils::Scheduler::add_task (\&ExportStatsToMIP); };
		$log->error("SC MIP Export - scheduled export failed to start; $@\n") if $@;
		$prefs->set ('sc_mipexport_lastday', $mday);
	}
}

# Debounced post-rescan trigger. A rescan can announce 'done' more than once in quick succession -
# each call just re-arms the same ten-second timer, so only the last one actually fires. Not
# gated here on purpose (matches MIPster) - gating only in scMIPExportPostScanFire below means a
# setting flipped to No takes effect immediately, not only on the next rescan.
sub scMIPExportPostScanTimer {
	Slim::Utils::Timers::killOneTimer (undef, \&scMIPExportPostScanFire);
	Slim::Utils::Timers::setTimer (undef, time() + 10, \&scMIPExportPostScanFire);
}

# Gated on sc_mipexport_postscan and nothing else, 2026-09-19 (ported from MIPster) - independent
# of the scheduled daily export above, and runs even if the scheduled export already succeeded
# today: a scan is the one event that changes what there is to export.
sub scMIPExportPostScanFire {
	return unless $prefs->get('sc_mipexport_postscan');
	if (Slim::Music::Import->stillScanning) {
		scMIPExportPostScanTimer();
		return;
	}
	$log->info("SC MIP Export - starting post-scan export\n");
	eval { Slim::Utils::Scheduler::add_task (\&ExportStatsToMIP); };
	$log->error("SC MIP Export - post-scan export failed to start; $@\n") if $@;
}

# The main job. Runs as an LMS scheduler task (main::idleStreams between tracks, same as the
# original plugin), not a plain sub call, so a large library does not stall playback.
# result codes (1 success, 2 aborted, 3 errors) as the original plugin.
sub ExportStatsToMIP {
	if ($prefs->get('sc_mipexport_inprogress')) {
		$log->info("SC MIP Export - export already running, not starting a second one\n");
		return;
	}

	if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		$log->info("SC MIP Export - active scan, not exporting\n");
		return;
	}

	my $miphosturl = $prefs->get('miphosturl');
	my $sugarport = $prefs->get('sugarport');

	$prefs->set ('sc_mipexport_inprogress', 1);
	$prefs->set ('sc_mipexport_result', 0);
	$mipexport_aborted = 0;
	$mipexport_errors = 0;
	@mipexport_songs = ();

	# Same reachability check the original plugin did - no point walking the whole library if MIP
	# is not even listening.
	my $ua = LWP::UserAgent->new;
	$ua->timeout(15);
	my $testresponse = $ua->get("http://$miphosturl:$sugarport/api/cacheid");
	unless ($testresponse->is_success) {
		$log->error("SC MIP Export - cannot reach MusicIP at $miphosturl:$sugarport - aborting export\n");
		$prefs->set ('sc_mipexport_result', 3);
		$prefs->set ('sc_mipexport_inprogress', 0);
		return;
	}

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	# Same $apc_enabled branch buildMyStuff/mystuff already use elsewhere in this plugin - keeps
	# the exported stats consistent with whatever SugarCube itself is reading for its own mixing.
	my $table = $apc_enabled ? 'alternativeplaycount' : 'tracks_persistent';
	my $lasttouched = $apc_enabled
		? "MAX(ifnull(alternativeplaycount.lastPlayed, 0), ifnull(alternativeplaycount.lastSkipped, 0))"
		: 'tracks_persistent.lastPlayed';

	my $query = "SELECT tracks.url, tracks_persistent.rating, $table.playCount, $lasttouched"
		. " FROM tracks INNER JOIN tracks_persistent ON (tracks.urlmd5 = tracks_persistent.urlmd5)";
	$query .= " LEFT JOIN alternativeplaycount ON tracks.urlmd5 = alternativeplaycount.urlmd5" if ($apc_enabled);
	$query .= " WHERE ifnull(tracks.remote,0) = 0";

	# Ported from MIPster, 2026-09-19: this scope restriction only applies when Unrated Tracks
	# Export As is still 0 (the default). Set it to a non-zero MIP rating on the Exports page and
	# every track is sent, including ones never rated and never played, so they actually pick up
	# that value in MusicIP instead of being skipped here before scMIPConvertRating ever runs.
	$query .= " AND (tracks_persistent.rating > 0 OR ifnull($table.playCount,0) > 0)"
		unless ($prefs->get('sc_mipexport_unrated') // 0) > 0;

	###
	# 2026-09-01 (Henk) - switched from bind_columns()+fetch() to fetchrow_array() in a while loop,
	# matching every other multi-row query in this plugin (mystuff included). Investigated as a
	# possible cause of that day's export failures; turned out those tracked back to Lidarr-replaced
	# files and a stale MusicIP index instead, unrelated to the fetch style. Kept the change anyway
	# since it matches the rest of the codebase's proven pattern rather than a one-off variant.
	###
	my $sth = $dbh->prepare($query);
	eval {
		$sth->execute();
		while (my ($url, $rating, $playcount, $lastplayed) = $sth->fetchrow_array()) {
			push @mipexport_songs, {
				url => $url,
				rating => $rating,
				playcount => $playcount,
				lastplayed => $lastplayed,
			};
		}
		$sth->finish();
	};
	if ($@) {
		$log->warn("SC MIP Export - SQL error building export list; $@\n");
		$prefs->set ('sc_mipexport_result', 3);
		$prefs->set ('sc_mipexport_inprogress', 0);
		return;
	}

	my $count = scalar @mipexport_songs;
	$log->info("SC MIP Export - $count track(s) to send\n");

	foreach (@mipexport_songs) {
		scMIPExportTrack ($_, $miphosturl, $sugarport);
		last if $mipexport_aborted;
		main::idleStreams();
	}

	unless ($mipexport_aborted) {
		my $flushresponse = $ua->get("http://$miphosturl:$sugarport/api/flush");
		$log->warn("SC MIP Export - flush call failed\n") unless $flushresponse->is_success;
	}

	$log->info("SC MIP Export - done, $mipexport_errors error(s)"
		. ($mipexport_aborted ? ", aborted\n" : "\n"));

	# 1 success, 2 aborted, 3 errors - same codes the original plugin's exportResult used.
	if ($mipexport_aborted) {
		$prefs->set ('sc_mipexport_result', 2);
	} elsif ($mipexport_errors > 0) {
		$prefs->set ('sc_mipexport_result', 3);
	} else {
		$prefs->set ('sc_mipexport_result', 1);
	}
	$prefs->set ('sc_mipexport_inprogress', 0);
	$mipexport_aborted = 0;
	@mipexport_songs = ();
}

# Called from the settings page's Abort button. Just raises the flag ExportStatsToMIP's per-track
# loop checks - the current track still finishes, same as the original plugin's abortExport.
sub scMIPExportAbort {
	return unless $prefs->get('sc_mipexport_inprogress');
	$log->info("SC MIP Export - abort requested\n");
	$mipexport_aborted = 1;
}

sub scMIPExportTrack {
	my $track = shift;
	my $miphosturl = shift;
	my $sugarport = shift;

	return unless $track->{'url'};

	my $mipfile = scMIPExportPath ($track->{'url'});
	return unless length $mipfile;

	my $ua = LWP::UserAgent->new;
	$ua->timeout(15);

	###
	# ALWAYS SENT, even when rating is 0/unset - fixed 2026-08-31 per guptaas' review of the
	# original plugin. Every track reaching this sub already matched the SQL's rating>0 OR
	# playcount>0 test, so a track that arrives here with rating 0 is either unrated-but-played (was
	# never rated - fine, MIP setRating=0 is a no-op there) or WAS rated and has since been demoted
	# below the threshold or cleared outright in LMS. The old guard here (skip when rating is 0)
	# meant that second case never reached MIP at all - a demoted or removed LMS rating left MIP's
	# copy exactly where it was, indefinitely. guptaas confirmed setRating with rating=0 clears
	# MusicIP's rating outright (no rating line afterwards) and still replies success, so the
	# existing $result > 0 check needed no change - only the guard that was skipping the call.
	###
	my $miprating = scMIPConvertRating ($track->{'rating'});
	my $response = $ua->get("http://$miphosturl:$sugarport/api/setRating?song=$mipfile&rating=$miprating");
	my $result = $response->is_success ? $response->content : 0;
	chomp $result if defined $result;
	unless ($result && $result > 0) {
		$log->warn("SC MIP Export - failed to set rating for $mipfile"
			. "; http=" . $response->status_line
			. "; body='" . (defined $response->content ? $response->content : '<undef>') . "'\n");
		$mipexport_errors++;
	}
	if ($track->{'playcount'}) {
		my $response = $ua->get("http://$miphosturl:$sugarport/api/setPlayCount?song=$mipfile&count=" . $track->{'playcount'});
		my $result = $response->is_success ? $response->content : 0;
		chomp $result if defined $result;
		unless ($result && $result > 0) {
			$log->warn("SC MIP Export - failed to set playcount for $mipfile"
				. "; http=" . $response->status_line
				. "; body='" . (defined $response->content ? $response->content : '<undef>') . "'\n");
			$mipexport_errors++;
		}
	}
	if ($track->{'lastplayed'}) {
		my $response = $ua->get("http://$miphosturl:$sugarport/api/setLastPlayed?song=$mipfile&time=" . $track->{'lastplayed'});
		my $result = $response->is_success ? $response->content : 0;
		chomp $result if defined $result;
		unless ($result && $result > 0) {
			$log->warn("SC MIP Export - failed to set lastplayed for $mipfile"
				. "; http=" . $response->status_line
				. "; body='" . (defined $response->content ? $response->content : '<undef>') . "'\n");
			$mipexport_errors++;
		}
	}
}

# LMS 0-100 -> MIP 0-5, band-based. Replaced 2026-09-19, ported from MIPster's scMIPExportBand as
# part of the full export-page port - see SettingsExports.pm. Five independently configurable
# ascending thresholds (sc_mipexport_band1-5, stock 10/30/50/70/90) plus a separate unrated value
# (sc_mipexport_unrated, stock 0), instead of the old single 0-4 "stretch the surviving range"
# threshold. Evaluated highest band first; SettingsExports.pm's scValidateBands already guarantees
# band1 < band2 < ... < band5 before any of this runs, so no ordering check is needed here.
# one band lower on the next export, which is the behaviour Henk asked to match exactly.
sub scMIPConvertRating {
	my $rating100 = shift;

	return ($prefs->get('sc_mipexport_unrated') // 0) unless $rating100 && $rating100 > 0;

	return 5 if $rating100 >= ($prefs->get('sc_mipexport_band5') // 90);
	return 4 if $rating100 >= ($prefs->get('sc_mipexport_band4') // 70);
	return 3 if $rating100 >= ($prefs->get('sc_mipexport_band3') // 50);
	return 2 if $rating100 >= ($prefs->get('sc_mipexport_band2') // 30);
	return 1 if $rating100 >= ($prefs->get('sc_mipexport_band1') // 10);
	return 0;
}

# tracks.url (a file:// URL) -> whatever path MIP itself expects. Reuses scPathPair() exactly as
# buildMIPReq does for the opposite direction (MIP path -> LMS path), just applied the other way.
sub scMIPExportPath {
	my $url = shift;

	my $path = Slim::Utils::Misc::pathFromFileURL ($url);
	return '' unless length $path;

	my ($lmspath, $mippath) = scPathPair();
	if (defined $lmspath && length $lmspath) {
		my $quotedlms = quotemeta $lmspath;
		$path =~ s/$quotedlms/$mippath/i;
	}

	###
	# EXTENSION REPLACE - not Henk's own setup (his LMS and MIP point at the same files), but kept
	# in "for other users" (Henk, 2026-08-31): some setups have MIP indexed against a differently-
	# encoded mirror of the library (e.g. LMS plays FLAC, MIP was pointed at an MP3 copy of the same
	# tracks) - without this, the filename sent to MIP carries the wrong extension and the
	# rating/playcount/lastplayed push silently fails to match a track. Ported from the original
	# plugin's getMusicIpURL, one pref instead of a per-setup guess.
	###
	my $sc_mipexport_replaceextension = $prefs->get('sc_mipexport_replaceextension');
	if (defined $sc_mipexport_replaceextension && length $sc_mipexport_replaceextension) {
		$sc_mipexport_replaceextension = '.' . $sc_mipexport_replaceextension
			unless substr ($sc_mipexport_replaceextension, 0, 1) eq '.';
		$path =~ s/\.[^.]*$/$sc_mipexport_replaceextension/;
	}

	###
	# 2026-09-01 (Henk) - matches buildMIPReq's own OS-branching escape logic (see the tracktitle
	# handling there) instead of a simplified forward-slash-only version this started with, and no
	# longer double-runs utf8decode_locale on a path that already came in properly decoded from the
	# SQL query below. Turned out NOT to be the actual cause of that day's export failures though -
	# those tracked back to files Lidarr had silently replaced with high-res versions after MusicIP's
	# own library scan, a mismatch entirely outside SugarCube/LMS. Kept anyway: both changes make
	# this function consistent with the rest of the plugin's proven Unicode handling, which is worth
	# having regardless of what actually caused that particular round of errors.
	###
	if (defined $lmspath && length $lmspath) {
		my $findos = index ($path, "/", 0);
		if ($findos != 0) {
			# Linux LMS, Wintel MIP - Henk's own setup.
			$path = escape ($path);
			$path =~ s/%2F/%5C/g;
			$path =~ s/:/%3A/g;
		} else {
			# Wintel LMS, Linux MIP.
			$path =~ s/\\/\//g;
			$path = escape ($path);
		}
	} else {
		# No NAS path pair set - LMS and MIP point at the same files. Same fallback buildMIPReq uses
		# for a seed with no conversion: the stray-replacement-character fixup first, then escape.
		$path =~ s/\x{FFFD}/%96/g;
		$path = escape ($path);
		$path =~ s/%2596/%96/g;
	}

	return $path;
}

# OS-dependent escaping for a MIP filter name. Was duplicated in three places.
sub escapeFilterName {
	my $name = shift;
	my $myos = Slim::Utils::OSDetect::OS();
	if ($myos eq 'win' || $myos eq 'mac') {
		return URI::Escape::uri_escape($name);
	}
	return Slim::Utils::Misc::escape($name);
}

###
# buildMIPReq - THE single MusicIP URL builder. AutoStartMix and AlarmFired both call this.
###
sub buildMIPReq {

	#$log->debug("\n#### Building MusicIP Request ####\n");
	my $client = shift;
	my $tracktitle = shift;
	my $opts = shift || {};

	my $seedtype = $opts->{'seedtype'};
	my $constraints = $opts->{'constraints'} || 'normal';

	$tracktitle = '' unless defined $tracktitle;

	###
	# Seed resolution happens HERE, before path conversion, because only song and album seeds are
	# paths. Resolving it afterwards would send a mood name through the drive-letter rewriter.
	###
	$seedtype = 'song' unless defined $seedtype;

	my $seedname = ''; # the mood or artist name, when one of those is the seed

	if ($seedtype eq 'mood') {
		$seedname = $opts->{'seedname'};
		$seedname = $prefs->client($client)->get('sugarcube_seedmood')
			unless defined $seedname;
		$seedname = '' unless defined $seedname;

		if ($seedname eq '' || $seedname eq '0' || $seedname eq '(None)') {
			$log->error("Seed is Mood but no mood is set - building no request\n");
			return undef;
		}
	} elsif ($seedtype eq 'artist') {
		$seedname = $opts->{'seedname'};
		$seedname = currentTrackArtist ($client) unless defined $seedname;
		$seedname = '' unless defined $seedname;

		if (!length $seedname) {
			$log->error("Seed is Artist but the playing track has no artist - building no request\n");
			return undef;
		}
	}

	# THE SEED ANCHOR WAS HERE, and went with the mode on 2026-08-07. It existed only because a
	# Full Playlist refilled at its last track and drifted away from the album you chose. A fired
	# SC Batch queues once and never refills, so there is nothing to drift and nothing to anchor.

	# A name seed carries no path, so there is nothing for the conversion block below to do.
	$tracktitle = '' unless ($seedtype eq 'song' || $seedtype eq 'album');

	# A path seed with no path falls back to no seed at all - MIP then picks from the filter.
	$seedtype = 'none'
		if (($seedtype eq 'song' || $seedtype eq 'album') && !length $tracktitle);

	my $sugarport = $prefs->get('sugarport');
	my $miphosturl = $prefs->get('miphosturl');
	# Track count is per-player. 20 covers a player whose settings page has never been
	# opened; the old global 'sugarmipsize' was removed once every player had its own.
	# '//' NOT '||' - a stored 0 is a VALUE. See the note above %clientDefaults.
	# a NEW value above 300 from being saved, not an old one already sitting in prefs.
	my $sugarmipsize = $prefs->client($client)->get('sugarcube_size') // 20;
	$sugarmipsize = 300 if ($sugarmipsize > 300);

	###
	# REMOVED 7.1.0.50, on the user's instruction: "New players should get 0 and there should be
	# nothing to suggest otherwise."
	###
	my $mypageurl;

	my ($lmspath, $mippath) = scPathPair();

	# Nothing to convert when there is no seed - skip it rather than log a dozen empty lines.
	if (defined $lmspath && length $tracktitle) {

		my $nasconvertpath = $mippath;
		my $localmediapath = $lmspath;
		$log->debug("localmediapath Change Using;$localmediapath\n");
		$log->debug("nasconvertpath Replace With;$nasconvertpath\n");

		$localmediapath = quotemeta $localmediapath;

		$log->debug("Dynamic Change Using;$localmediapath\n");
		$log->debug("Dynamic Replace With;$nasconvertpath\n");
		$log->debug("Original tracktitle;$tracktitle\n");
		$tracktitle =~ s/$localmediapath/$nasconvertpath/i;
		$log->debug("Converted tracktitle;$tracktitle\n");

		# Second path pair removed 2026-08-06 - see the matching note in the other direction.

		my $findos = index ($tracktitle, "/", 0);
		if ($findos != 0) {

	 # Works with Linux LMS and Wintel MIP
	 # $log->debug("LINUX LMS with Wintel MIP - PreTracktitle;$tracktitle\n");
			$tracktitle = Slim::Utils::Unicode::utf8decode_locale($tracktitle);
			$tracktitle = escape($tracktitle);
			$tracktitle =~ s/%2F/%5C/g;
			$tracktitle =~ s/:/%3A/g;
		} else {
			# Wintel LMS and Linux MIP
			$tracktitle =~ s/\\/\//g;

	 # $log->debug("WINTEL LMS with LINUX MIP - PreTracktitle;$tracktitle\n");
		}

	} else {
# $log->debug("\nTrack title before decoding;\n$tracktitle\n");
# Without this LMS explodes for Deadmau5%5C01%20-%20Deadmau5%20%96%20Sofi%20Needs%20A%20Ladder.mp3
# However it enocdes it as 2596 so need to switch it back to 96
		$tracktitle =~ s/�/%96/g;
		$tracktitle = Slim::Utils::Unicode::utf8decode_locale($tracktitle);
		$tracktitle = escape($tracktitle);
		$tracktitle =~ s/%2596/%96/g;

		# $log->debug("Track title after decoding;$tracktitle\n\n");
	}
	###
	# STYLE AND VARIETY. Batch had its own separate pair from 7.1.0.50 until 2026-09-19, when the
	# MIPster-style merge retired sugarcube_batchstyle/batchvariety - Henk always kept them in sync
	# with the Chain's own values by hand anyway, so the separate prefs were pure duplication.
	# Batch now reads exactly what Chain (and the alarm, which was always Chain-shaped) reads.
	###
	my $stylevalue = $prefs->client($client)->get('sugarcube_style');
	my $varietyvalue = $prefs->client($client)->get('sugarcube_variety');

	my $sugarcube_style = '&style=' . $stylevalue;
	my $sugarcube_variety = '&variety=' . $varietyvalue;

	# Seed. Resolved above; here it only becomes a query parameter.
	my $seedparam = '';
	if ($seedtype eq 'album') {
		$seedparam = '&album%3d' . $tracktitle; # album= takes a full path to ANY song on it
	} elsif ($seedtype eq 'song') {
		$seedparam = '&song%3d' . $tracktitle;

		###
		# OVERRIDE SHUFFLE - triggered HERE, and only here. Rule set by the user 2026-08-06:
		# "The automatic trigger to disable shuffle should be when SC sends out an API request
		# with Song=. Otherwise shuffle is whatever is chosen by user control of Lyrion."
		# with shuffling a queued batch, which was the only legitimate reason to want it off.
		my $lmsshuffle = Slim::Player::Playlist::shuffle($client);
		if ($lmsshuffle == 1 || $lmsshuffle == 2) {
			$log->debug("Song seed sent; switching LMS shuffle off to protect the chain\n");
			$client->execute ([ "playlist", "shuffle", 0 ]);
		}
	} elsif ($seedtype eq 'mood') {
		# song= is deliberately omitted. Sending both is measured to blend into a third result
		# belonging to neither seed - see MIP_1.9_Undocumented_Reference.md section I.
		# Escaped for the same reason filter names are: mood names here look like '1 Qawwalis',
		# and a raw space in a query string is malformed.
		$seedparam = '&mood=' . escapeFilterName ($seedname);
		$log->debug("Seeding from mood;$seedname\n");
	} elsif ($seedtype eq 'artist') {
		$seedparam = '&artist=' . escapeFilterName ($seedname);
		$log->debug("Seeding from artist;$seedname\n");
	} else {
		$log->debug("No seed - MIP will pick a random song from within the current filter\n");
	}

	$mypageurl = ( 'http://'
		 . $miphosturl . ':'
		 . $sugarport
		 . '/api/mix?&sizetype=tracks&size='
		 . $sugarmipsize
		 . $seedparam
		 . $sugarcube_style
		 . $sugarcube_variety);

	if ($constraints eq 'alarm') {
		# The alarm keeps its own Filter/Genre - an alarm genuinely is a different occasion.
		###
		my $scalarm_filter = $prefs->client($client)->get('scalarm_filter') || '';
		if ($scalarm_filter eq '' || $scalarm_filter eq '0' || $scalarm_filter eq '(None)') {
			$scalarm_filter = $prefs->client($client)->get('sugarcube_filteractive') || '';
			$log->debug("No alarm-specific filter set; using the player's own filter\n");
		}

		if ($scalarm_filter eq '' || $scalarm_filter eq '0' || $scalarm_filter eq '(None)') {
			$log->debug("Filter is set to NONE\n");
		} else {
			$mypageurl = $mypageurl . '&filter=' . escapeFilterName($scalarm_filter);
		}
	} else {
		# Genre Mixing and the Mix Type selector were removed (BUILD_PLAN Step 3.3). MusicIP
		# matches genre as one exact whole string, and genres here are fine-grained and
		# multi-term, so "same genre" was effectively "same artist" - measured at 20 of 20 tracks
		# by Lionel Hampton from a 'Jazz Swing' seed. The filter is now the only constraint.
		# Do not upstream that removal - the control is useful to anyone tagged plain Rock / Jazz.
		# never actually exercised - safe to retire in favour of the one shared filter.
		my $sugarcube_activefilter = $prefs->client($client)->get('sugarcube_filteractive') || 0;

		if ($sugarcube_activefilter eq '0') {
			$log->debug("Filter is set to NONE\n");
		} else {
			$mypageurl = $mypageurl . '&filter=' . escapeFilterName($sugarcube_activefilter);
		}
	}
	###
	# RECIPE. Escaped since 2026-08-06 - it never was, so any recipe name containing a space went
	# out malformed, e.g. "recipe=2-Genre Agnostic" with a raw space in the query string. Every
	# other value here is escaped: both seed paths, the mood name, the artist name and the filter
	# name. The recipe was simply missed, and MusicIP is tolerant enough that nobody noticed.
	# rest of the sugarcube_batch* prefs - see the %clientDefaults comment.
	my $recipename = $prefs->client($client)->get('sugarcube_receipes');
	$recipename = '0' unless defined $recipename;

	if ($recipename ne '0' && $recipename ne '' && $recipename ne '(None)') {
		$mypageurl = $mypageurl . '&recipe=' . escapeFilterName($recipename);
	}
	# Artist spacing - MIP puts at least N tracks between two by the same artist,
	# backfilling from deeper in the neighborhood rather than leaving holes.
	# rejectsize=0.
	my $sugarcube_rejectsize = $prefs->client($client)->get('sugarcube_rejectsize') // 0;
	if ($sugarcube_rejectsize > 0) {
		###
		# rejecttype, TWO t's. It was 'rejectype' - a real typo, inherited, and silently swallowed:
		# MusicIP ignored the whole parameter and fell back to its default, which happens to be
		# 'tracks', which is what we send anyway. So this corrects the spelling WITHOUT changing
		# what you get. Measured 2026-08-06 on 1.96b headless, same seed each time:
		#   rejectsize=30 rejecttype=min   -> 1837 chars   (honored)
		#   rejectsize=30 rejectype=min    -> 1845 chars   (ignored, = the tracks default)
		# The official 1.9 help gives 'rejecttype= (tracks|min|mbytes)', units for rejectsize, 1.1.6.
		###
		$mypageurl = $mypageurl . '&rejectsize=' . $sugarcube_rejectsize . '&rejecttype=tracks';
	}

# Use to generate a MIP Error for testing
# $mypageurl = 'http://localhost:10002/api/mix?&sizetype=tracks&size=15&genre=a';

	# Every caller logs the same thing, so log it once here. AutoStartMix never used to log its URL
	# at all, which made the alarm-settings bug (Step 2.1a) invisible for as long as it existed.
	$log->debug("\n#### Built URL Request for MusicIP:\n $mypageurl\n####\n");
	return $mypageurl;
}

sub objectForUrl {
	my $url = shift;
	return Slim::Schema->objectForUrl ({ 'url' => $url });
}

###
# scTellUser - one pop-up, sent in BOTH display forms. Step 8.4b, 2026-08-08.
###
sub scTellUser {
	my $client = shift;
	my $msg = shift;
	my $type = shift // 'info'; # 'info' or 'error' - Material accepts only those two

	return unless defined $client && defined $msg && length $msg;

	###
	# ⛔⛔ MEASURED 2026-08-13, AND IT CONTRADICTS THE NOTES BELOW. READ THIS FIRST.
	#
	# ⛔ SO THE CLAIM BELOW THAT THE 'jive' FORM "demonstrably works", CITING 'Building SC Batch'
	# AND 'Album Queued', IS UNPROVEN. Those two were never seen to appear on this system. The claim
	# was written down once and then relied on - including by the session that went looking, which
	# picked the wrong control test because of it. Treat the rest of this note as a record of what
	# was TRIED, not of what WORKS.
	#
	# ⛔ THE USER RULED THIS UNIMPORTANT, 2026-08-13. DO NOT CHASE IT. The two failure messages it
	# used to carry are now answered audibly - the Chain repeats the current track when MusicIP
	# cannot supply one - and that reaches him in the car, which no pop-up ever did. What is left on
	# this route is the block-breach warning and two "your tap registered" confirmations.
	###
	my $hasdisplay = $client->display && !$client->display->isa('Slim::Display::NoDisplay');

	if ($hasdisplay) {
		$client->showBriefly(
			{ 'line' => [ $client->string('PLUGIN_SUGARCUBE'), $msg ] },
			5
		);
	}

	$client->showBriefly(
		{
			'jive' => {
				'type' => 'popupplay',
				'text' => [ $client->string('PLUGIN_SUGARCUBE'), ' ', $msg ],
			}
		}
	);

	$log->debug("scTellUser; " . $client->id . " hasdisplay=" . ($hasdisplay ? 1 : 0)
		. " material=" . ($material_enabled ? 1 : 0) . "; $msg\n");

	###
	# ALWAYS 'info' TO MATERIAL, NEVER 'error'. Measured on hardware 2026-08-09 and traced to the
	# skin's own source - this is a MATERIAL BUG, not ours, and it cost an hour to find.
	###
	if ($material_enabled) {
		my $who = Slim::Player::Client::name($client) // '';
		my $matmsg = length $who ? "$who: $msg" : $msg;
		Slim::Control::Request::executeRequest (undef,
			[ 'material-skin', 'send-notif', 'type:info', 'msg:' . $matmsg, 'timeout:5' ]);
	}
}

sub gotErrorViaHTTP {
	my $http = shift;
	my $params = $http->params();
	my $client = $params->{'client'};
	gotErrorContinue ($client, $http, 'unreachable');
}

###
# gotErrorContinue - the recovery path, and where two of the three failures are announced.
###
sub gotErrorContinue {
	my $client = shift;
	my $http = shift;
	my $case = shift // 'unreachable';

	my $content = $http->content();

	# $log->debug("MIP Error - Response;\n$content\n");

	my $why;
	if ($content eq 'API error - invalid request or internal error.') {
		$why = 'API error - invalid request or internal error';
	} elsif ($content eq '') {
		$why = 'no reply at all - check the MusicIP service is running';
	} else {
		$why = 'unrecognized reply';
	}

	if ($case eq 'empty') {
		$log->error("MUSICIP RETURNED NOTHING; $why\n");
		$mixstatus = 'MusicIP returned nothing. Check Filter/Recipe';
		scTellUser ($client, $client->string('PLUGIN_SC_POPUP_NOTRACKS'), 'error');
	} else {
		$log->error("MUSICIP COULD NOT BE REACHED; $why\n");
		$mixstatus = 'Cannot reach MusicIP. Check service/SC plugin settings';
		scTellUser ($client, $client->string('PLUGIN_SC_POPUP_NOMIP'), 'error');
	}

	###
	# NEVER INVENT A TRACK. The user's decision, 2026-08-12, Edit 47. This is MUSICIP SILENT - no
	# answer at all. Everything below this guard used to run for every caller, so a dead MusicIP
	# quietly became an evening of random tracks. It now runs FOR THE ALARM ONLY.
	#
	# ⛔ THE ALARM STILL PLAYS SOMETHING - his ruling, "Alarm should work, song immaterial." Silence
	# is a failed alarm, and it is the one failure that cannot be noticed in time to matter. This
	# guard is the ONLY reason randompuller and getRealRandom still have a caller on this path.
	###
	my $errcreator = $http->params()->{'caller'} || '';
	if ($errcreator ne 'SpiceflyAlarm') {
		###
		# REPEAT THE CURRENT TRACK AS AN AUDIBLE WARNING. Same decision, same reasoning, and the
		# same two lines as the MusicIP-empty case in gotMIP - see the long note there.
		###
		my $repeaturl = Slim::Player::Playlist::url($client) // '';

		if ($repeaturl =~ m/^tmp:/i) {
			my $z = substr $repeaturl, 0, 3, "file";
		}

		if (length($repeaturl) != 0) {
			$log->error("MUSICIP SILENT - repeating the current track as an audible warning\n");
			addtrack ($client, $repeaturl);
		} else {
			$log->error("STOPPING - nothing queued, and nothing playing to repeat\n");
		}
		return;
	}

	$log->debug("\nALARM with no MusicIP - requesting (from LMS db) a Random Track matching the Current Playing Tracks Genre\n");
	my $song = randompuller($client) // 'FAILED';
	if ($song eq 'FAILED') {
		$log->debug("\nFAILED, likely no playing track to use or track has no Genre\n");
		$log->error("COMPLETELY RANDOM TRACK USED - no MusicIP, and nothing playing to take a genre from\n");
		my $track = Plugins::SugarCube::Breakout::getRealRandom();
		$log->debug("Selected Completely Random Track;\n$track\n");
		# The lookup stays - the log line below names the track and artist. The four remaining
		# fields it returns described the choice for Live View's Coming Up Next, and went in Edit 41
		# with the slots that held them - captured again as of 2026-09-11 since SaveHistory below
		# (History, Henk's request) wants them too. No " (SugarCube Random Selection)" marker here -
		# the hoofdmap build doesn't add one on this completely-random (no genre match at all) path
		# either, only on randompuller's genre-matched fallback above.
		my ($CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum)
			= Plugins::SugarCube::Breakout::getSongDetails($track);

		$log->error("RANDOM FALLBACK USED - not a MusicIP choice: $CurrentTrack by $CurrentArtist\n");
		Plugins::SugarCube::Breakout::SaveHistory ($client, $CurrentArtist, $CurrentTrack,
			$CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum);

		addtrack ($client, $track); # song is hashed up
		my $request = $client->execute (["play"]);

	} else { # Random Track selected was ok

		my $currentsong = Slim::Player::Playlist::url($client) // '';
		if (length($currentsong) != 0) {
			# The test above is the point of this branch: something is playing, so the genre-matched
			# track randompuller found can be queued behind it. The details lookup that used to sit
			# here only filled the Currently Playing slots and went in Edit 41.
			$log->debug("\nTrying to Queue Track;$song\n");

			addtrack ($client, $song); # song is hashed up
		} else {
			$log->debug("\nCould not use Playing Tracks Genre and LMS did not return anything usable\n");
			$log->debug("\n$song\n");
		}
	}

	###
	# THE ALARM TIDY-UP ON THE FAILURE PATH. ADDED IN EDIT 46 (2026-08-12). This is the fix that let
	# the 20-second heartbeat be removed - see the note where SugarPlayerCheck used to be defined.
	#
	# ⚠ EDIT 47 NOTE: only the alarm now reaches this far - everything else returned at the guard
	# above. The caller test below is therefore always true today. IT IS KEPT DELIBERATELY, because
	# it is what makes this block correct on its own terms rather than correct by accident of where
	# it sits. If the guard above is ever relaxed, this still cannot fire on the wrong caller.
	#
	# ⚠ $errcreator IS THE ONE DECLARED NEAR THE TOP OF THIS SUB, DELIBERATELY REUSED. It was
	# declared a SECOND time here in Edit 47 and Perl warned about it on every startup - '"my"
	# variable $errcreator masks earlier declaration in same scope', in the user's own log. Harmless
	# to behaviour, both copies held the same value, but this plugin's standard is that the log
	# holds nothing from SugarCube. Do not re-add 'my' here.
	###
	if ($errcreator eq 'SpiceflyAlarm') {
		$log->error("ALARM WITH NO MUSICIP - clearing the alarm placeholder and playing the fallback track\n");
		my $request = $client->execute ([ 'playlist', 'delete', 0 ]);
		$request->source('PLUGIN_SUGARCUBE');
		$request = $client->execute (['play']);
		$request->source('PLUGIN_SUGARCUBE');
	}
}

# Set up Async HTTP request
sub SendtoMIPAsync {
	my $client = shift;
	my $mypageurl = shift;
	# Retry count, 0 on a normal request. gotMIP reads this back out of $params to decide whether
	# an empty answer is allowed one relaxed-rejectsize retry before it falls back to repeating the
	# current track - see the note beside 'MUSICIP EMPTY' in gotMIP. Not touched by AutoStartMix or
	# SC Batch, which build their own request separately and are not part of this retry.
	my $retry = shift || 0;
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotMIP,
		\&gotErrorViaHTTP,
		{
			caller => 'Spicefly',
			callerProc => \&SendtoMIPAsync,
			client => $client,
			retry => $retry,
			timeout => 60
		}
	);
	# URL is logged by buildMIPReq now, so every caller gets it - not just this one.
	$http->get($mypageurl);
}

# Add Track at End of Queue
sub addtrack {
	my $client = shift;
	my $track = shift;
	# The lifetime queued-track counter that stood here went in Step 8.2d (2026-08-08). It wrote a
	# pref to disk on EVERY track queued, to feed a Live View percentage that could not warn about
	# anything.
	if ($track ne "") {
		my $request = $client->execute ([ "playlist", "add", $track ]);
		$request->source('PLUGIN_SUGARCUBE');
	}
}

*escape = main::ISWINDOWS ? \&URI::Escape::uri_escape : \&URI::Escape::uri_escape_utf8;

sub commandCallback {
	my $request = shift;
	my $client = $request->client();
	return unless $client; # Catch when client has disappeared
	my $checklive = $prefs->client($client)->get('sugarcube_status');
	if (!defined $checklive) {
		$checklive = 0;
		$prefs->client($client)->set( 'sugarcube_status', 0 );
		$log->debug("SugarCube Prefs Not Set for this client, default to Disabled.\n");
	}

	###
	# Off means off. Removed 2026-08-12, with the DSTM registration in postinitPlugin.
	###
	return if $checklive == 0;

	my $source = $request->source() || '';
	if ( ($source eq 'PLUGIN_SUGARCUBE')
		|| ($source eq 'ALARM'))
	{
		return 1;
	}

	# THE 'play' BRANCH THAT STOOD HERE WENT IN EDIT 46 (2026-08-12). It did one thing: start the
	# 20-second heartbeat, ten seconds after playback began. The heartbeat itself is gone - see the
	# note where it used to be defined. Nothing else was in this branch.

	if ($request->isCommand ([ ['playlist'], ['newsong'] ])) {
		###
		# ⚠ THIS PAUSE IS LOAD-BEARING. IT IS NOT A PERFORMANCE SETTING. Measured 2026-08-10.
		###
		my $sugardelay = $prefs->get('sugardelay');
		$sugardelay = 1 if (!defined $sugardelay || $sugardelay !~ /^\d+$/ || $sugardelay < 1);
		Slim::Utils::Timers::killTimers ($client, \&SugarDelay);
		Slim::Utils::Timers::setTimer ($client,
			Time::HiRes::time() + $sugardelay,
			\&SugarDelay);
		# A second setTimer stood here, arming the 20-second heartbeat 15 seconds after every track
		# change. Removed in Edit 46 (2026-08-12) with the heartbeat itself. THE SugarDelay TIMER
		# ABOVE IS A DIFFERENT THING AND STAYS - it is the load-bearing pause described above, one
		# shot per track change, and it is what calls kickoff.
	}
	if ($request->isCommand ([ ['stop'] ])) {
		$log->debug("We Stopped :(\n");
	}
	if ($request->isCommand ([ ['pause'] ])) {
		$log->debug("We Paused :(\n");
	}

}

# Are we inside this player's Auto Sleep hours? One window now serves both halves of the section.
# The odd-looking test is the original's and is kept deliberately: it handles a window that crosses
# midnight, which the obvious from <= hour <= to does not.
sub inSleepWindow {
	my $client = shift;
	my $from = $prefs->client($client)->get('sugarcube_sleepfrom') || 0;
	my $to   = $prefs->client($client)->get('sugarcube_sleepto') || 0;
	my ($sec, $min, $hour) = localtime(time);
	return ($from - $hour <= 0 && $to - $hour <= 0
		|| $from - $hour >= 0 && $to - $hour > 0) ? 1 : 0;
}

# Take a few points off the volume at each track change, so the music walks itself down while you
# fall asleep. A flat step on LMS's 0-100 scale, not a percentage, and it floors at 0.
# that section now, not a setting of its own.
sub slideVolume {
	my $client = shift;

	my $sugarcube_sleep = $prefs->client($client)->get('sugarcube_sleep') || 0;
	return if $sugarcube_sleep != 1;

	my $sugarcube_reducevolume = $prefs->client($client)->get('sugarcube_reducevolume') || 0;
	return if $sugarcube_reducevolume <= 0; # 0 is the off switch now that the tickbox has gone

	return unless inSleepWindow($client);

	my $volumeslide = Slim::Player::Client::volume($client);

	###
	# NOTHING IS REMEMBERED AND NOTHING IS RESTORED - user, 2026-08-09: "no restoration required".
	# The volume walks down and stays down. Set it where you want it next time you play.
	#
	# ⚠ Do NOT reason from a player's current volume when judging this. The user sets volumes to 0
	# by hand for reasons of his own, so a low reading proves nothing either way. An earlier draft
	# of this comment cited one as evidence and was wrong.
	###
	$volumeslide = $volumeslide - $sugarcube_reducevolume;
	if ($volumeslide < 0) { $volumeslide = 0; }
	$log->debug("Auto Sleep - dropping volume by $sugarcube_reducevolume to $volumeslide\n");
	$client->execute ([ "mixer", "volume", $volumeslide ]);
}

sub sleepplayer {
	my $client = shift;
	my $sugarcube_sleep = $prefs->client($client)->get('sugarcube_sleep') || 0;
	if ($sugarcube_sleep == 1) {
		my $sleeper = $client->sleepTime();
		if ($sleeper == 0) {
			my $sugarcube_sleepduration = $prefs->client($client)->get('sugarcube_sleepduration') || 0;
			if (inSleepWindow($client)) {
				$sugarcube_sleepduration = $sugarcube_sleepduration * 60;
				$client->execute ([ "sleep", $sugarcube_sleepduration ]);
			}
		}
	}
}

# This always felt terrible but it did the job
sub dirtyencoder {
	my $mytitle = shift || '';

	#$log->debug("Pre-Conversion; $mytitle\n");
	$mytitle =~ s/%/%25/g;
	$mytitle =~ s/\^/%5E/g;
	$mytitle =~ s/{/%7B/g;
	$mytitle =~ s/}/%7D/g;
	$mytitle =~ s/�/%80/g;
	$mytitle =~ s/�/%82/g;
	$mytitle =~ s/�/%83/g;
	$mytitle =~ s/�/%84/g;
	$mytitle =~ s/�/%85/g;
	$mytitle =~ s/�/%86/g;
	$mytitle =~ s/�/%87/g;
	$mytitle =~ s/�/%88/g;
	$mytitle =~ s/�/%89/g;
	$mytitle =~ s/�/%8A/g;
	$mytitle =~ s/�/%8B/g;
	$mytitle =~ s/�/%8C/g;
	$mytitle =~ s/�/%91/g;
	$mytitle =~ s/�/%92/g;
	$mytitle =~ s/�/%93/g;
	$mytitle =~ s/�/%94/g;
	$mytitle =~ s/�/%95/g;
	$mytitle =~ s/�/%96/g;
	$mytitle =~ s/�/%97/g;
	$mytitle =~ s/�/%98/g;
	$mytitle =~ s/�/%99/g;
	$mytitle =~ s/�/%9A/g;
	$mytitle =~ s/�/%9B/g;
	$mytitle =~ s/�/%9C/g;
	$mytitle =~ s/�/%9E/g;
	$mytitle =~ s/�/%9F/g;
	$mytitle =~ s/�/%A1/g;
	$mytitle =~ s/�/%A2/g;
	$mytitle =~ s/�/%A3/g;
	$mytitle =~ s/�/%A5/g;
	$mytitle =~ s/�/%A7/g;
	$mytitle =~ s/�/%A8/g;
	$mytitle =~ s/�/%A9/g;
	$mytitle =~ s/�/%AA/g;
	$mytitle =~ s/�/%AB/g;
	$mytitle =~ s/�/%AC/g;
	$mytitle =~ s/�/%AE/g;
	$mytitle =~ s/�/%AF/g;
	$mytitle =~ s/�/%B0/g;
	$mytitle =~ s/�/%B1/g;
	$mytitle =~ s/�/%B2/g;
	$mytitle =~ s/�/%B3/g;
	$mytitle =~ s/�/%B4/g;
	$mytitle =~ s/�/%B5/g;
	$mytitle =~ s/�/%B6/g;
	$mytitle =~ s/�/%B7/g;
	$mytitle =~ s/�/%B8/g;
	$mytitle =~ s/�/%B9/g;
	$mytitle =~ s/�/%BA/g;
	$mytitle =~ s/�/%BB/g;
	$mytitle =~ s/�/%BC/g;
	$mytitle =~ s/�/%BD/g;
	$mytitle =~ s/�/%BE/g;
	$mytitle =~ s/�/%BF/g;
	$mytitle =~ s/�/%C0/g;
	$mytitle =~ s/�/%C1/g;
	$mytitle =~ s/�/%C2/g;
	$mytitle =~ s/�/%C3/g;
	$mytitle =~ s/�/%C4/g;
	$mytitle =~ s/�/%C5/g;
	$mytitle =~ s/�/%C6/g;
	$mytitle =~ s/�/%C7/g;
	$mytitle =~ s/�/%C8/g;
	$mytitle =~ s/�/%C9/g;
	$mytitle =~ s/�/%CA/g;
	$mytitle =~ s/�/%CB/g;
	$mytitle =~ s/�/%CC/g;
	$mytitle =~ s/�/%CD/g;
	$mytitle =~ s/�/%CE/g;
	$mytitle =~ s/�/%CF/g;
	$mytitle =~ s/�/%D0/g;
	$mytitle =~ s/�/%D1/g;
	$mytitle =~ s/�/%D2/g;
	$mytitle =~ s/�/%D3/g;
	$mytitle =~ s/�/%D4/g;
	$mytitle =~ s/�/%D5/g;
	$mytitle =~ s/�/%D6/g;
	$mytitle =~ s/�/%D7/g;
	$mytitle =~ s/�/%D8/g;
	$mytitle =~ s/�/%D9/g;
	$mytitle =~ s/�/%DA/g;
	$mytitle =~ s/�/%DB/g;
	$mytitle =~ s/�/%DC/g;
	$mytitle =~ s/�/%DD/g;
	$mytitle =~ s/�/%DE/g;
	$mytitle =~ s/�/%DF/g;
	$mytitle =~ s/�/%E0/g;
	$mytitle =~ s/�/%E1/g;
	$mytitle =~ s/�/%E2/g;
	$mytitle =~ s/�/%E3/g;
	$mytitle =~ s/�/%E4/g;
	$mytitle =~ s/�/%E5/g;
	$mytitle =~ s/�/%E6/g;
	$mytitle =~ s/�/%E7/g;
	$mytitle =~ s/�/%E8/g;
	$mytitle =~ s/�/%E9/g;
	$mytitle =~ s/�/%EA/g;
	$mytitle =~ s/�/%EB/g;
	$mytitle =~ s/�/%EC/g;
	$mytitle =~ s/�/%ED/g;
	$mytitle =~ s/�/%EE/g;
	$mytitle =~ s/�/%EF/g;
	$mytitle =~ s/�/%F0/g;
	$mytitle =~ s/�/%F1/g;
	$mytitle =~ s/�/%F2/g;
	$mytitle =~ s/�/%F3/g;
	$mytitle =~ s/�/%F4/g;
	$mytitle =~ s/�/%F5/g;
	$mytitle =~ s/�/%F6/g;
	$mytitle =~ s/�/%F7/g;
	$mytitle =~ s/�/%F8/g;
	$mytitle =~ s/�/%F9/g;
	$mytitle =~ s/�/%FA/g;
	$mytitle =~ s/�/%FB/g;
	$mytitle =~ s/�/%FC/g;
	$mytitle =~ s/�/%FD/g;
	$mytitle =~ s/�/%FE/g;
	$mytitle =~ s/�/%FF/g;
	$mytitle =~ s/'/%27/g;
	$mytitle =~ s/\#/%23/g;
	$mytitle =~ s/;/%3B/g;
	$mytitle =~ s/\\/\//g;
	$mytitle =~ s/ /%20/g;
	$mytitle =~ s/`/%60/g;
	$mytitle =~ s/\?/%BF/g;
	$mytitle =~ s/�/%A9/g;
	$mytitle =~ s/\xa0/%A0/g;

	#$log->debug("Post Conversion but Pre-Encoded Path; $mytitle\n");
	my $a = substr ($mytitle, 0, 4);
	if ($a =~ m/:/i) {
		$mytitle = 'file:///' . $mytitle;
	} else {
		$mytitle = 'file://' . $mytitle;
	}
	#$log->debug("Post-Encoded Path; $mytitle\n");
	return $mytitle;
}

sub ToggleInjector {
	my ($client, $item) = @_;
	my $sugarcube_status;
	my $line;
	if ($item eq '{PLUGIN_SUGARCUBE_INJECTOR_ON}') {
		$sugarcube_status = 1;
		my $players = Slim::Player::Client::name($client);
		$prefs->client($client)->set ('sugarcube_status', "$sugarcube_status");
		$line = $client->string('PLUGIN_INJECTORON_MENU_ENABLE');
	} else {
		$sugarcube_status = 0;
		my $players = Slim::Player::Client::name($client);
		$prefs->client($client)->set ('sugarcube_status', "$sugarcube_status");
		$line = $client->string('PLUGIN_INJECTOROFF_MENU_DISABLED');
	}
	$client->showBriefly(
		{
			'line1' => $client->string('PLUGIN_SUGARCUBE'),
			'line2' => $line
		},
		{ 'duration' => 5, 'block' => 0 }
	);
	return;
}

sub AutoStartMix {
	my ($client, $item) = @_;

	###
	# OFF MEANS OFF. Added 2026-08-12.
	###
	if (!($prefs->client($client)->get('sugarcube_status') || 0)) {
		$client->showBriefly(
			{
				'line1' => $client->string('PLUGIN_SUGARCUBE'),
				'line2' => $client->string('PLUGIN_INJECTOROFF_MENU_DISABLED')
			},
			{ 'duration' => 5, 'block' => 0 }
		);
		$log->info("Start New Chain refused - the Chain is off for this player\n");
		return;
	}

	my $line = $client->string('PLUGIN_SUGARCUBE_START');
	$client->showBriefly(
		{
			'line1' => $client->string('PLUGIN_SUGARCUBE'),
			'line2' => $line
		},
		{ 'duration' => 5, 'block' => 0 }
	);
	my $request = $client->execute ([ 'playlist', 'clear' ]);
	$request->source('PLUGIN_SUGARCUBE');

	# Uses the player's OWN Filter/Genre, not the alarm's - see BUILD_PLAN Step 2.1a.
	# No seed, so MIP picks a random song from within the current filter.
	my $mypageurl = buildMIPReq ($client, '', { seedtype => 'none' });

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotMIP,
		\&gotErrorViaHTTP,
		{
			caller => 'SpiceflyAutoMix',
			callerProc => \&AutoStartMix,
			client => $client,
			timeout => 60
		}
	);
	$http->get($mypageurl);
}

# ToggleVolume removed 2026-08-08, Step 8.3 - it switched sugarcube_volume_flag, which has gone.

sub ToggleSleep {
	my ($client, $item) = @_;
	my $sugarcube_sleep;
	my $line;
	if ($item eq '{PLUGIN_SUGARCUBE_MENU_SLEEP_ENABLE}') {
		$sugarcube_sleep = 0;
		$prefs->client($client)->set ('sugarcube_sleep', "$sugarcube_sleep");
		$line = $client->string('PLUGIN_SUGARCUBE_MENU_SLEEP_DISABLED');
	} else {
		$sugarcube_sleep = 1;
		$prefs->client($client)->set ('sugarcube_sleep', "$sugarcube_sleep");
		$line = $client->string('PLUGIN_SUGARCUBE_MENU_SLEEP_ENABLE');
	}
	$client->showBriefly(
		{
			'line1' => $client->string('PLUGIN_SUGARCUBE'),
			'line2' => $line
		},
		{ 'duration' => 5, 'block' => 0 }
	);
	return;
}

# SugarCubeEnabled / SugarCubeDisabled REMOVED 2026-08-08, Step 8.2c, along with their three call
# sites and the sugarcube_albumoveride checkbox that switched them on.
# LMS's own setting is left exactly as the user has it. The plugin no longer touches it.

sub getAlarmPlaylists {
	my $class = shift;
	Slim::Utils::Alarm->addPlaylists(
		'PLUGIN_SUGARCUBE',
		[
			{
				title => '{PLUGIN_SUGARCUBE_TRACK}',
				url => 'sugarcube:track'
			},
			# Henk, 2026-08-30: second alarm playlist option, an SC Batch instead of the
			# continuous Chain mix above. Same wake-up mechanism (Lyrion plays this placeholder
			# URL, ProtocolHandler intercepts it) - see the comment there for how the two are
			# told apart, and AlarmFiredBatch below for what actually fires.
			{
				title => '{PLUGIN_SC_BATCH_ALARM}',
				url => 'sugarcube:batch'
			},
		]
	);
}

sub AlarmFired {
	my $client = shift;
	my $track;
	my $mypageurl;
	my $sugarcube_activefilter;
	# The alarm keeps its OWN Filter/Genre (scalarm_*) - an alarm is a different occasion.
	# No seed, so MIP picks a random song from within that filter.
	$mypageurl = buildMIPReq ($client, '', { seedtype => 'none', constraints => 'alarm' });

	$log->debug("Alarm URL created; $mypageurl\n");

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotMIP,
		\&gotErrorViaHTTP,
		{
			caller => 'SpiceflyAlarm',
			callerProc => \&AlarmFired,
			client => $client,
			timeout => 60
		}
	);
	$http->get($mypageurl);
}

###
# AlarmFiredBatch - the batch equivalent of AlarmFired above, added 2026-08-30 (Henk).
###
sub AlarmFiredBatch {
	my $client = shift;
	return unless $client;
	PlaySCBatch ($client, 'none', '', '', 'play');
}

sub webPages {
	my $class = shift;
	my $urlBase = 'plugins/SugarCube/settings';

	###
	# TWO MENU ENTRIES, NOT FIVE (2026-08-06). Only real destinations are listed here:
	#     SC Controls  -  SC Live View
	###
	Slim::Web::Pages->addPageLinks ("browseiPeng", { 'PLUGIN_SUGARCUBELV' => $htmlTemplateLV }); #fuck knows

	Slim::Web::Pages->addPageLinks ("browse", { 'PLUGIN_SUGARCUBELV' => $htmlTemplateLV });
	Slim::Web::Pages->addPageLinks("icons", { 'PLUGIN_SUGARCUBELV' => 'plugins/SugarCube/HTML/images/sugarcube.png' });
	Slim::Web::Pages->addPageFunction ("$urlBase/liveview.html", \&handleWebList);
	Slim::Web::HTTP::CSRF->protectURI("$urlBase/liveview.html");

	###
	# Replace Queue - Henk 2026-09-12, REVISED. "TWO MENU ENTRIES, NOT FIVE" (saysaar, 2026-08-06,
	# above) deliberately left this off both Classic's browse menu AND Material's Extras, as an
	# ACTION rather than a destination. That held for as long as every install still carried an old
	# Jive menu entry Material had cached client-side from before this plugin's several renames -
	# what Henk has been calling "SugarCube Auto Mix", still pointing at this same quickplay.html
	# action, which is why it still works and survives a restart on HIS install specifically.
	#
	# ⚠ A FRESH INSTALL HAS NO SUCH CACHE ENTRY. Henk's own follow-up: "hoe moet dan iemand die de
	# plugin nog nooit gebruikt heeft hem daar wel krijgen?" - someone who has never run an older
	# version of this plugin never had that stale Jive item to begin with, so for them 2026-08-06's
	# "declutter" was not a cleanup, it was the only path to this action disappearing entirely, in
	# EVERY skin, not just Classic/Default. So this is now added to "browseiPeng" (Material's
	# Extras) as well as "browse" (Classic/Default), same two-call pattern SC Controls/SC Live View
	# already use just above - no skin is left depending on a legacy cache entry a new install will
	# never have.
	###
	Slim::Web::Pages->addPageLinks ("browseiPeng", { 'PLUGIN_SUGARCUBEQP' => $htmlTemplateQP });
	Slim::Web::Pages->addPageLinks ("browse", { 'PLUGIN_SUGARCUBEQP' => $htmlTemplateQP });
	Slim::Web::Pages->addPageLinks ("icons", { 'PLUGIN_SUGARCUBEQP' => 'plugins/SugarCube/HTML/images/sugarcube.png' });
	Slim::Web::Pages->addPageFunction ("$urlBase/quickplay.html", \&handleWebQP);
	Slim::Web::HTTP::CSRF->protectURI("$urlBase/quickplay.html");

	# Live controls (Phase 5) used to register quicksettings.html/PLUGIN_SUGARCUBEQS here too - both
	# the page and its handler (handleWebQuickSettings) were retired 2026-09-12, see the
	# $htmlQuickSettings comment near the top of this file.

	# Replace Next Track - no menu entry, it is a button on the Controls page. URL still live.
	# There is no replacenext.html template. handleWebRN performs the replacement and then renders
	# Live View - but the button's target must still be THIS url, because that is what routes to
	# handleWebRN. Pointing the button straight at liveview.html would open Live View and replace
	# nothing.
	Slim::Web::Pages->addPageFunction ("$urlBase/replacenext.html", \&handleWebRN);
	Slim::Web::HTTP::CSRF->protectURI("$urlBase/replacenext.html");

	# SC Batch, fired from a Classic context-menu link. No addPageLinks - this is not a
	# destination, it is what the two links in scbatchlink.html point at.
	Slim::Web::Pages->addPageFunction ("$urlBase/scbatch.html", \&scBatchWeb);
	Slim::Web::HTTP::CSRF->protectURI("$urlBase/scbatch.html");

	if (UNIVERSAL::can ("Slim::Plugin::Base", "addWeight")) {
		###
		# 84 and 83 were the stored values on every install here; they are now fixed. The slider that
		# set them ("Live View Icon Position") went on 2026-08-09: it does not affect Live View, it
		# only decides where SugarCube sits in Classic's browse list, and MATERIAL IGNORES WEIGHTS
		# ENTIRELY and sorts its Extras alphabetically - so on the main skin it did nothing at all.
		# Keeping the numbers rather than dropping the calls keeps Classic's order exactly as it was.
		# One lower for Controls so the live controls sort first among the SugarCube entries.
		###
		Slim::Plugin::Base->addWeight ("PLUGIN_SUGARCUBELV", 84);
	}
}

# handleWebQuickSettings (quicksettings.html's page handler) removed 2026-09-12 along with the
# page itself - see the $htmlQuickSettings comment near the top of this file for why. It used to
# live here: pref-saving foreach loops (filteractive/receipes/rejectsize triggering a replace,
# style/variety/size/seedmood/batchfilter/batchrecipe not), the Play/Add Mood Batch buttons, and a
# forcestart/mixfromplaying bootstrap for Replace Queue. All of that is now covered by
# jiveSugarCubeSetting (same pref set, same replace semantics) and Live View's own always-visible
# Play/Add Mood Batch buttons; Replace Queue was already a Controls-page button pointing at
# quickplay.html/handleWebQP, not something unique to this page.

# Replace Next Track, from the Home page. Deliberately NOT on the player settings page: that page
# is save-then-apply and carries "copy settings to other players" at the bottom, so an action that
# fires immediately does not belong there. Same shape as handleWebQP - do the thing, then land on
# Live View so you can see what it did, rather than on a splash page of its own.
sub handleWebRN {
	my ($client, $params) = @_;
	$client = Slim::Player::Client::getClient ($params->{player});
	if ($client) {
		if (Slim::Player::Playlist::count($client) == 0) {
			# Nothing queued, so there is no "next" to replace. Start a mix instead - the same
			# choice the Controls page makes, for the same reason: SugarCubeReplaceNext would
			# call kickoff and append with nothing consuming it.
			mixfromplaying ($client, "yes");
		} else {
			SugarCubeReplaceNext ($client);
		}

		# See handleWebQP for why both of these are needed - refresh is off at this moment
		# because the MIP request has only just been fired, and path must point at Live View
		# or its own reload re-enters this handler and replaces the track over and over.
		$params->{refresh} = 1;
		$params->{path} = $htmlTemplateLV;

		return handleWebList ($client, $params);
	}
	return Slim::Web::HTTP::filltemplatefile ($htmlTemplateLV, $params);
}

sub handleWebQP {
	my ($client, $params) = @_;
	$client = Slim::Player::Client::getClient ($params->{player});
	if ($client) {
		mixfromplaying ($client, "yes");

		# Land directly on Live View, no splash - Henk, 05-10-2026 (quickplay.html's few-second
		# wait is gone). Same shape as handleWebRN above: refresh must be on since the MIP request
		# has only just been fired, and path must point at Live View or its own reload would
		# re-enter this handler and start another mix over and over.
		$params->{refresh} = 1;
		$params->{path} = $htmlTemplateLV;

		return handleWebList ($client, $params);
	}
	return Slim::Web::HTTP::filltemplatefile ($htmlTemplateLV, $params);
}

# LiveView
sub handleWebList {
	my ($client, $params) = @_;
	$client = Slim::Player::Client::getClient ($params->{player});

	###
	# FIXED 2-SECOND REFRESH, Henk 2026-09-05 (ported from the hoofdmap build, same bug). This used
	# to borrow LMS's own Classic-skin "refreshRate" server pref (floored against 0/unset to avoid
	# a tight loop). That pref is set to a real value on Henk's server for the Classic skin's own
	# unrelated auto-refresh feature, which the floor correctly left untouched since it was not
	# "unset" - so Live View was only polling once every refreshRate seconds (30+ on that server),
	# and "Start New Chain"/"Replace Track" felt like they did nothing: the click itself still
	# fired straight away, but the page had no reason to show the result until the next slow tick.
	# Live View has no reason to share Classic's setting - it's Material-only in practice - so this
	# is now a fixed, short interval of its own instead of a borrowed one.
	###
	$params->{'refreshRate'} = 2000;

	# Auto-refresh Live View regardless of how you arrive, Henk 2026-09-05 (ported from the
	# hoofdmap build). 'refresh' used to only be set to 1 inside the branches further down, and
	# only when certain conditions held (e.g. the playlist already had a current track) - so a
	# player that landed here, or clicked a button, in the split second the queue was empty (which
	# "Start New Chain" itself causes, by clearing the queue before asking MusicIP for a fresh one)
	# could end up with no auto-refresh at all for the rest of the page's life. Always on now;
	# nothing in this plugin has a reason to want it off.
	$params->{'refresh'} = 1;

	# Live View Width removed 2026-08-06. It was handed to the page as 'tablewidth' and NO template
	# ever read it, so the slider had never changed anything. Third control found wired to nothing,
	# after Coming Up Next and the Track Weight pair.
	# 'size' is no longer handed to liveview.html - the template asks Lyrion for Material's 300x300_f
	# and draws it at 100, both written into the template itself. Removed with the slider 2026-08-09.
	$params->{'track'} = '';

	if ($client) {

		# sc_can_act - Henk, 2026-09-05 (ported from the hoofdmap build). Live View's "Start New
		# Chain" button must never disturb a queue it didn't build itself - a fired SC Batch, a
		# loaded album/playlist, or a hand-built queue. Rather than showing the button and refusing
		# on click, the template hides it outright whenever more than one track is already queued
		# ahead of the one playing. Same CheckPosition <= 2 test scReplaceSelection/
		# scApplyRequestChange already use for the identical reason.
		$params->{'sc_can_act'} =
			( Plugins::SugarCube::Breakout::CheckPosition($client) <= 2 ) ? 1 : 0;

		# sc_in_batch - Henk, 2026-09-05. "Als je in Chain mode zit werken de knoppen daar in
		# batchmode niet [...] is het te doen dat als je in batchmode zit er onder de spelende
		# track de knop verschijnt om een nieuwe batch te starten?" Simple inverse of sc_can_act -
		# same CheckPosition test, just the other side of it, so exactly one of the two states is
		# ever offered at once (New Chain/Replace Track while continuous play, Start New Batch
		# while a batch is running) rather than the page trying to show both or neither.
		$params->{'sc_in_batch'} = $params->{'sc_can_act'} ? 0 : 1;

		###
		# 'sc_on' - Henk's request 2026-09-12, first piece of the Live View/Quick Settings merge:
		# the Chain (automatic queuing) Enabled/Disabled toggle, ported onto Live View's own top
		# bar. Same underlying pref as Quick Settings' own sc_on (see handleWebQuickSettings/
		# quicksettings.html) - this page reads it fresh on every ajaxUpdate tick rather than
		# caching anything client-side, so flipping it from EITHER page shows up here within one
		# refresh (2s) without needing to coordinate the two pages directly.
		###
		$params->{'sc_on'} = $prefs->client($client)->get('sugarcube_status') || 0;

		###
		# Chain Settings - Henk's request 2026-09-12, second piece of the Live View/Quick Settings
		# merge (after the sc_on toggle above): Filter, Recipe, Reject Size, Style, Variety, ported
		# from quicksettings.html's own collapsible "Chain Settings" <details> section.
		###
		$params->{'sclv_filters'} = Plugins::SugarCube::PlayerSettings::getFilterList();
		$params->{'sclv_receipes'} = Plugins::SugarCube::PlayerSettings::getReceipesList();
		# sugarcube_size joined this list 2026-09-19, for Mix Settings' new MIP Ask Size slider -
		# the first place this pref has ever been adjustable from Live View rather than only from
		# player.html. sugarcube_lv_moodsettings_open (the old separate "Mood Batch Settings"
		# panel's own open/closed state) is gone along with that panel - Mood now lives inside this
		# same 'sclv_chainsettings_open'-gated panel (kept its old pref name; only the visible
		# heading became "Mix Settings" - see liveview.html).
		foreach my $pref (qw(sugarcube_filteractive sugarcube_receipes sugarcube_rejectsize
			sugarcube_style sugarcube_variety sugarcube_lv_chainsettings_open))
		{
			$params->{'sclv_prefs'}->{$pref} = $prefs->client($client)->get($pref);
		}

		# sugarcube_size is NOT in the generic foreach above because it needs the same 300 cap
		# buildMIPReq applies (Henk's own MIP instance's ceiling) - a pre-existing value above 300
		# (from before that cap existed) would otherwise print here uncapped, showing e.g. "100"
		# next to a slider whose max="300" already silently clamps its own handle position, which is
		# exactly the mismatch Henk spotted (2026-09-19).
		my $sclv_size = $prefs->client($client)->get('sugarcube_size') // 20;
		$sclv_size = 300 if ($sclv_size > 300);
		$params->{'sclv_prefs'}->{'sugarcube_size'} = $sclv_size;

		###
		# Seed Mood - Henk's request 2026-09-12, now living inside Mix Settings (the former "Chain
		# Settings") rather than its own separate "Mood Batch Settings" panel, which is gone as of
		# 2026-09-19 along with Batch Filter/Batch Recipe/Batch Artist Spacing/Batch Style/Batch
		# Variety - a batch now reads the very same Filter/Recipe/Reject Size/Style/Variety Mix
		# Settings already shows, so there was nothing left in that panel except Mood itself. The
		# Play/Add Mood Batch BUTTONS are still not duplicated here - Live View already has these
		# under Current/Next Track ("Start New Batch"/"Add Mood Batch", scStartBatch/scAddBatch,
		# gated by sc_in_batch/sc_can_act above); this is only the dial that decides what such a
		# batch seeds from.
		###
		$params->{'sclv_moods'} = Plugins::SugarCube::PlayerSettings::getMoodsList();
		Plugins::SugarCube::PlayerSettings::ensureSeedMood ($client);
		$params->{'sclv_prefs'}->{'sugarcube_seedmood'} = $prefs->client($client)->get('sugarcube_seedmood');

		###
		# 'history' - Henk's request 2026-09-11, for the Live View/Quick Settings accordion merge.
		# Independent of sugarcube_working/mixstatus below (unlike 'filters') - History is a log of
		# what was queued in the past, not a read of the current MIP answer, so it fills in every
		# state rather than only while SugarCube is actively mixing.
		###
		$params->{'history'} = Plugins::SugarCube::Breakout::HistoryPuller($client);

		###
		# THE LABEL ABOVE THE CANDIDATE LIST CARRIES ITS OWN DATE. Edit 52, 2026-08-13.
		#
		# ⛔ WITH NO DATE IT PRINTS THE BARE LABEL AND NO COLON - "Last MIP Response". The colon
		# appears only when there is something to put after it. DO NOT PUT A WORD THERE.
		###
		my $lvstamp = Plugins::SugarCube::Breakout::scStampDate(
			$prefs->client($client)->get('sugarcube_lastmip') // 0);
		$params->{'mode'} = 'Last MIP Response' . (length $lvstamp ? ': ' . $lvstamp : '');

		###
		# 'mip_date' - Henk's request 2026-09-12. The 2026-09-11 menu button/panel redesign (see
		# liveview.html) needs this combined label split into two DIFFERENT wordings that share the
		# same date: a plain, static "MIP Response" for the dropdown menu entry (a nav item, not a
		# heading - it never carried a date even back when 'mode' alone sat in the old accordion's
		# <summary>), and "Last Response: <date>" for the panel heading once opened. Rather than
		# have the template regex the date back out of 'mode' (fragile if the "Last MIP Response"
		# wording above ever changes), the bare stamp is just handed over on its own; 'mode' itself
		# is untouched; the "no date -> no colon" rule from Edit 52 above still applies, just re-run
		# in the template for the new wording instead of re-derived here for a second string.
		###
		$params->{'mip_date'} = $lvstamp;

		my $master = Slim::Player::Sync::isMaster($client); # Returns 1 if true
		my $slave = Slim::Player::Sync::isSlave($client); # Returns 1 if true
		my $name = Slim::Player::Client::name($client);
		if ($master == 1) {
			$params->{'master'} = '';
		} elsif ($slave == 1) {
			# Same string as the player settings page - see PlayerSettings.pm.
			my $sync_master = $client->master()->name();
			$params->{'master'} = sprintf(
				Slim::Utils::Strings::string('PLUGIN_SC_WEB_SYNCWARNING'), $name, $sync_master);
		} else {
			$params->{'master'} = '';
		}

		my $sugarcubeworking = $prefs->client($client)->get('sugarcube_working') // 0; # the mix-in-progress flag, read back for Live View

		###
		# LIVE VIEW IS ALWAYS ON. The switched-off substitute page was removed 2026-08-12.
		###
		$params->{'mixstatus'} = $mixstatus; # Error reporting

		# The two Live View statistics lines - lifetime queued total, lifetime random total and its
		# percentage, plus the last random track and when - went in Step 8.2d (2026-08-08), along
		# with the Reset tickbox on the player settings page.

		if ($sugarcubeworking == 0) {
			$params->{refresh} = 1;

			###
			# 2026-08-09: THIS BRANCH USED TO BLANK THE LIST. It no longer does.
			###
			$params->{'filters'} = Plugins::SugarCube::Breakout::StatsPuller($client);

			# 'Last set MusicIP supplied' stood here and was removed in Edit 52. The label is now
			# set once, above, and reads the same in both states because it is dated. Do not put a
			# second wording back - that is how one table ended up with two names.
			$params->{'track'} = 'Disabled or Album/Playlist playing. SugarCube is waiting.';

		} else {
			# Warn in Live View when there is no filter. The Genre half of this check went with
			# Genre Mixing (Step 3.3); the filter is now the only constraint.
			my $sugarcube_activefilter = $prefs->client($client)->get('sugarcube_filteractive') || 0;
			if ($sugarcube_activefilter eq '0') {
				$params->{'mixstatus'} = "CONFIGURATION ERROR: No MusicIP Filter is specified";
			}

			# Get Currently Playing Metric. (The "previousset array" the old comment here named
			# was an empty package variable that nothing ever wrote to; removed 2026-08-12.)

			my $url = Slim::Player::Playlist::song($client) // '';
			if ($url ne '') {
				my $track = Slim::Schema->rs('Track')->objectForUrl ({ 'url' => $url, });
				$params->{'track'} = $track->title;
				$params->{refresh} = 1;
			}
			$params->{'filters'} = Plugins::SugarCube::Breakout::StatsPuller($client);

		}
		###
		# CURRENTLY PLAYING / COMING UP NEXT ARE READ FROM THE QUEUE. Changed 2026-08-12.
		#
		# ⚠ THE HEADINGS WERE RENAMED IN EDIT 53 BECAUSE OF THIS VERY CHANGE, and the two go
		# together. They read "Currently Playing" and "Coming Up Next" - a claim about NOW - while
		# what they draw is a claim about the QUEUE, and a queue exists whether or not anything is
		# playing. Lyrion keeps a player's queue when it is powered off, so this page was showing a
		# track and a follow-up, convincingly, for a player that was off and silent. They now read
		# "Current Track" and "Next Track", which is true in every state and needs no test for any
		# of them. The user's wording. DO NOT PUT A PLAYBACK CLAIM BACK IN THESE TWO HEADINGS.
		###
		# ⚠ THE SEED MUST BE PUT THROUGH THE SAME TWO CONVERSIONS AS EVERY OTHER CALLER.
		###
		my $lvnowurl = Slim::Player::Playlist::url($client) // '';
		my ($lvArtist, $lvTrack, $lvAlbum, $lvGenre, $lvArt, $lvFull, $lvPC, $lvRat, $lvLP);
		if (length $lvnowurl) {
			###
			# ⚠ THE TEMPORARY ADDRESS IS CONVERTED FIRST. Added 2026-08-12.
			###
			if ($lvnowurl =~ m/^tmp:/i) {
				my $z = substr $lvnowurl, 0, 3, "file"; # replaces tmp with file
			}

			$lvnowurl = Slim::Utils::Misc::pathFromFileURL($lvnowurl);
			$lvnowurl = dirtyencoder($lvnowurl);
			($lvArtist, $lvTrack, $lvAlbum, $lvGenre, $lvArt, $lvFull, $lvPC, $lvRat, $lvLP)
				= Plugins::SugarCube::Breakout::getTSSongDetails ($lvnowurl);
		}

		if (defined $lvTrack && $lvTrack ne '') {
			$params->{'showstats'} = "ON";
			$params->{'currentartist'} = $lvArtist;
			$params->{'currenttrack'} = $lvTrack;
			$params->{'currentalbum'} = $lvAlbum;
			$params->{'currentgenre'} = $lvGenre;
			$params->{'currentalbumart'} = $lvArt || '0';
			$params->{'currentpc'} = $lvPC;
			$params->{'currentrat'} = $lvRat;
			$params->{'currentlp'} = $lvLP;

			# Returns an empty list when there is nothing after the current track, so guard it.
			my ($nxArtist, $nxTrack, $nxAlbum, $nxGenre, $nxArt, $nxFull, $nxPC, $nxRat, $nxLP)
				= Plugins::SugarCube::Breakout::getmyTSNextSong ($client);

			if (defined $nxTrack && $nxTrack ne '') {
				$params->{'comingupnextartist'} = $nxArtist;
				$params->{'comingupnexttrack'} = $nxTrack;
				$params->{'comingupnextalbum'} = $nxAlbum;
				$params->{'comingupnextgenre'} = $nxGenre;
				$params->{'comingupnextalbumart'} = $nxArt || '0';
				$params->{'comingupnextpc'} = $nxPC;
				$params->{'comingupnextrat'} = $nxRat;
				$params->{'comingupnextlp'} = $nxLP;
			} else {
				$params->{'comingupnextartist'} = 'Nothing queued';
				$params->{'comingupnexttrack'} = 'Nothing queued';
				$params->{'comingupnextalbum'} = '';
				$params->{'comingupnextgenre'} = '';
				$params->{'comingupnextalbumart'} = '0';
				$params->{'comingupnextpc'} = '';
				$params->{'comingupnextrat'} = '';
				$params->{'comingupnextlp'} = '';
			}
		} else {
			$params->{'currentartist'} = "N/A";
			$params->{'currenttrack'} = "N/A";
			$params->{'currentalbum'} = "N/A";
			$params->{'currentgenre'} = "N/A";
			$params->{'currentalbumart'} = '0';
			$params->{'comingupnextartist'} = 'N/A';
			$params->{'comingupnexttrack'} = 'N/A';
			$params->{'comingupnextalbum'} = 'N/A';
			$params->{'comingupnextgenre'} = 'N/A';
			$params->{'comingupnextalbumart'} = '0';
		}
	} else {
		$params->{'currentartist'} = "N/A";
		$params->{'currenttrack'} = "N/A";
		$params->{'currentalbum'} = "N/A";
		$params->{'currentgenre'} = "N/A";
		$params->{'currentalbumart'} = '0';
		$params->{'comingupnextartist'} = 'N/A';
		$params->{'comingupnexttrack'} = 'N/A';
		$params->{'comingupnextalbum'} = 'N/A';
		$params->{'comingupnextgenre'} = 'N/A';
		$params->{'comingupnextalbumart'} = '0';
	}

	return Slim::Web::HTTP::filltemplatefile ($htmlTemplateLV, $params);
}

# Fade Volume on Track Transition was removed 2026-08-08, Phase 8 Step 8.3.
# Five routines went with it - CheckSong, Volume_Save, StartFade, ReverseFade and Volume_Reset -
# along with the two hashes that held the pre-fade level and the "are we fading" flag.
# there - nothing is remembered and nothing is restored, by decision 2026-08-09. See slideVolume.

1;
