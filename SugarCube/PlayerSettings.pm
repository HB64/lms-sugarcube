# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::SugarCube::PlayerSettings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use LWP::UserAgent;

my $prefs = preferences('plugin.SugarCube');
my $log = logger('plugin.sugarcube');

my $timeoutvalue = 4;

###
# Henk, 2026-09-12 - EMERGENCY PERFORMANCE FIX. getFilterList/getReceipesList/getMoodsList each make
# a BLOCKING synchronous HTTP call to the MusicIP server (up to $timeoutvalue seconds each). Live
# View's handleWebList (Plugin.pm) calls all three of these on EVERY single request - not just the
# initial page load, but every 2-second ajaxUpdate tick too (this exact risk was flagged in a Plugin.
# pm comment when the Quick Settings merge added them there, but left unaddressed). Since LMS/Lyrion
# is single-threaded for web/JSON-RPC request handling, three sequential blocking calls inside ONE
# request stall the ENTIRE server for their combined duration, not just this one page - confirmed by
# Henk seeing Lyrion become unusably slow ("traag als dikke stront") server-wide, and a hard refresh
# (Ctrl+Shift+R) of Live View alone taking 10+ seconds, consistent with 3 x up to 4s of blocking MIP
# calls piling up on every tick faster than they can drain.
###
my %sc_listCache = (
	filters  => { data => undef, ts => 0 },
	receipes => { data => undef, ts => 0 },
	moods    => { data => undef, ts => 0 },
);
my $sc_listCacheTTL = 30;

sub needsClient {
	return 1;
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SUGARCUBE');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/SugarCube/settings/player.html');
}

sub prefs {
	my ($class,$client) = @_;
	return ($prefs->client($client), qw(scroll fdays));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
	# Save routine.. pull out the form and save them to disk
	if ($params->{'saveSettings'}) {

		my $scalarm_filter = $params->{'scalarm_filter'};
		$prefs->client($client)->set('scalarm_filter', "$scalarm_filter");

		my $sugarcube_status = $params->{'sugarcube_status'};
		$prefs->client($client)->set('sugarcube_status', "$sugarcube_status");

		my $sugarcube_style = $params->{'sugarcube_style'};
		$prefs->client($client)->set('sugarcube_style', "$sugarcube_style");

		my $sugarcube_variety = $params->{'sugarcube_variety'};
		$prefs->client($client)->set('sugarcube_variety', "$sugarcube_variety");

		my $sugarcube_rejectsize = $params->{'sugarcube_rejectsize'};
		$prefs->client($client)->set('sugarcube_rejectsize', "$sugarcube_rejectsize");

		my $sugarcube_size = $params->{'sugarcube_size'};
		$prefs->client($client)->set('sugarcube_size', "$sugarcube_size");

		my $sugarcube_batchsize = $params->{'sugarcube_batchsize'};
		$prefs->client($client)->set('sugarcube_batchsize', "$sugarcube_batchsize");

		###
		# MOOD IS SAVED FROM THIS PAGE AGAIN, 2026-09-19 - the MIPster-style merge put it in Mix
		# Settings' own separate little section, alongside Filter/Recipe/Reject Size/Style/Variety,
		# since a batch fired from a player now needs a default Mood the same way it needs a
		# default Filter. It was deliberately REMOVED from here on 2026-08-07 (moved to the
		# Controls/Live View page only) after the exact opposite mistake: reading it here while the
		# MEGASAVER below did not carry it caused "Sync Settings Across ALL Players" to write an
		# EMPTY mood to every player. The rule that removal was an instance of - when a control
		# leaves a page, its save site and its megasaver entry must leave with it - applies just as
		# much in reverse, so this addition brings its own MEGASAVER line straight back with it (see
		# MEGA SAVE below). Do not add one without the other again.
		###
		my $sugarcube_seedmood = $params->{'sugarcube_seedmood'};
		$prefs->client($client)->set('sugarcube_seedmood', "$sugarcube_seedmood");

		my $sugarcube_receipes = $params->{'sugarcube_receipes'};
		$prefs->client($client)->set('sugarcube_receipes', "$sugarcube_receipes");


		my $sugarcube_filteractive = $params->{'sugarcube_filteractive'};
		$prefs->client($client)->set('sugarcube_filteractive', "$sugarcube_filteractive");

		# The separate "Parameters for Batch Mode" section (its own Filter/Recipe/Size/Artist
		# Spacing/Style/Variety, the sugarcube_batch* prefs) is gone, 2026-09-19 - the MIPster-style
		# merge Henk asked for. A batch now reads the six settings above directly, the very same
		# ones continuous play uses (including sugarcube_size - see buildMIPReq in Plugin.pm),
		# rather than a separate duplicated set that Henk always kept in sync by hand anyway.


		my $sugarcube_reducevolume = $params->{'sugarcube_reducevolume'};
		$prefs->client($client)->set('sugarcube_reducevolume', "$sugarcube_reducevolume");

		my $sugarcube_sleep = $params->{'sugarcube_sleep'} ? 1 : 0;
		$prefs->client($client)->set('sugarcube_sleep', "$sugarcube_sleep");

		my $sugarcube_sleepfrom = $params->{'sugarcube_sleepfrom'};
		$prefs->client($client)->set('sugarcube_sleepfrom', "$sugarcube_sleepfrom");

		my $sugarcube_sleepto = $params->{'sugarcube_sleepto'};
		$prefs->client($client)->set('sugarcube_sleepto', "$sugarcube_sleepto");

		my $sugarcube_sleepduration = $params->{'sugarcube_sleepduration'};
		$prefs->client($client)->set('sugarcube_sleepduration', "$sugarcube_sleepduration");








		my $sugarcube_ts_lastplayed = $params->{'sugarcube_ts_lastplayed'};
		$prefs->client($client)->set('sugarcube_ts_lastplayed', "$sugarcube_ts_lastplayed");

		my $sugarcube_ts_pc_higher = $params->{'sugarcube_ts_pc_higher'};
		$prefs->client($client)->set('sugarcube_ts_pc_higher', "$sugarcube_ts_pc_higher");

		my $sugarcube_ts_trackrated = $params->{'sugarcube_ts_trackrated'};
		$prefs->client($client)->set('sugarcube_ts_trackrated', "$sugarcube_ts_trackrated");

		my $sugarcube_clutter = $params->{'sugarcube_clutter'};
		$prefs->client($client)->set('sugarcube_clutter', "$sugarcube_clutter");

		# Permanent artist/genre block - plain text, matched with LIKE in Breakout.pm's
		# DropBlockedArtist/DropBlockedGenre. See the comment there for why LIKE.
		# are simply abandoned, not migrated - re-enter them here as one list.
		my $scblockartist_list = $params->{'scblockartist_list'};
		$prefs->client($client)->set('scblockartist_list', "$scblockartist_list");

		my $scblockgenre_list = $params->{'scblockgenre_list'};
		$prefs->client($client)->set('scblockgenre_list', "$scblockgenre_list");

		# Repeat blocking, Henk's request 2026-09-11, ported from the hoofdmap build - rolling
		# window of the last N tracks' worth of artist/album (ArtistTracker/AlbumTracker,
		# TrackRepeatRecord/DropRepeatArtist/DropRepeatAlbum in Breakout.pm), separate from the
		# permanent block fields just above.
		my $sugarcube_blockartist = $params->{'sugarcube_blockartist'};
		$prefs->client($client)->set('sugarcube_blockartist', "$sugarcube_blockartist");

		my $sugarcube_blockalbum = $params->{'sugarcube_blockalbum'};
		$prefs->client($client)->set('sugarcube_blockalbum', "$sugarcube_blockalbum");

		# Wobble, ported from the hoofdmap build 2026-09-19 - see pickWobbleTrack's own comment in
		# Plugin.pm for what it does. A standalone dropdown, own section on this page (not inside
		# Mix Settings), matching where it sits in the hoofdmap build.
		my $sugarcube_wobble = $params->{'sugarcube_wobble'};
		$prefs->client($client)->set('sugarcube_wobble', "$sugarcube_wobble");

		# Artist Weighting, ported from Henk's HB64 fork 2026-08-30 - same comma-list convention as
		# the block fields above. A SOFT bias (see applyArtistWeighting in Breakout.pm), not a hard
		# exclusion like the block fields: Preferred names get more copies in the candidate pool,
		# Less Preferred names have a chance of being dropped, both scaled by one shared 1-5 weight
		# per list rather than HB64's per-name weight.
		my $scpreferartist_list = $params->{'scpreferartist_list'};
		$prefs->client($client)->set('scpreferartist_list', "$scpreferartist_list");

		my $scpreferartist_weight = $params->{'scpreferartist_weight'};
		$prefs->client($client)->set('scpreferartist_weight', "$scpreferartist_weight");

		my $sclessartist_list = $params->{'sclessartist_list'};
		$prefs->client($client)->set('sclessartist_list', "$sclessartist_list");

		my $sclessartist_weight = $params->{'sclessartist_weight'};
		$prefs->client($client)->set('sclessartist_weight', "$sclessartist_weight");

		my $sugarcube_megasaver = $params->{'sugarcube_megasaver'} ? 1 : 0;

		# MEGA SAVE START
		# a remembered selection is exactly the kind of hidden state this page has been removing.
		if ($sugarcube_megasaver == 1) {
			my $ownid = Slim::Player::Client::id($client);
			foreach my $player (Slim::Player::Client::clients()) {
				my $pid = Slim::Player::Client::id($player);
				next if ($pid eq $ownid);
				next unless ($params->{"sc_sync_player_$pid"});
				$prefs->client($player)->set('scalarm_filter', "$scalarm_filter");
				$prefs->client($player)->set('sugarcube_status', "$sugarcube_status");
				$prefs->client($player)->set('sugarcube_style', "$sugarcube_style");
				$prefs->client($player)->set('sugarcube_variety', "$sugarcube_variety");
				$prefs->client($player)->set('sugarcube_rejectsize', "$sugarcube_rejectsize");
				$prefs->client($player)->set('sugarcube_size', "$sugarcube_size");
				$prefs->client($player)->set('sugarcube_batchsize', "$sugarcube_batchsize");
				$prefs->client($player)->set('sugarcube_receipes', "$sugarcube_receipes");
				$prefs->client($player)->set('sugarcube_filteractive', "$sugarcube_filteractive");
				# sugarcube_seedmood comes back into the megasaver, 2026-09-19, together with its
				# save site above (Mix Settings) - see the comment there for why this pairing matters.
				$prefs->client($player)->set('sugarcube_seedmood', "$sugarcube_seedmood");
				$prefs->client($player)->set('sugarcube_reducevolume', "$sugarcube_reducevolume");
				$prefs->client($player)->set('sugarcube_sleep', "$sugarcube_sleep");
				$prefs->client($player)->set('sugarcube_sleepfrom', "$sugarcube_sleepfrom");
				$prefs->client($player)->set('sugarcube_sleepto', "$sugarcube_sleepto");
				$prefs->client($player)->set('sugarcube_sleepduration', "$sugarcube_sleepduration");
				$prefs->client($player)->set('sugarcube_ts_lastplayed', "$sugarcube_ts_lastplayed");
				$prefs->client($player)->set('sugarcube_ts_pc_higher', "$sugarcube_ts_pc_higher");
				$prefs->client($player)->set('sugarcube_ts_trackrated', "$sugarcube_ts_trackrated");
				$prefs->client($player)->set('sugarcube_clutter', "$sugarcube_clutter");
				$prefs->client($player)->set('scblockartist_list', "$scblockartist_list");
				$prefs->client($player)->set('scblockgenre_list', "$scblockgenre_list");
				$prefs->client($player)->set('sugarcube_blockartist', "$sugarcube_blockartist");
				$prefs->client($player)->set('sugarcube_blockalbum', "$sugarcube_blockalbum");
				$prefs->client($player)->set('sugarcube_wobble', "$sugarcube_wobble");
				$prefs->client($player)->set('scpreferartist_list', "$scpreferartist_list");
				$prefs->client($player)->set('scpreferartist_weight', "$scpreferartist_weight");
				$prefs->client($player)->set('sclessartist_list', "$sclessartist_list");
				$prefs->client($player)->set('sclessartist_weight', "$sclessartist_weight");
			}
		}
		# MEGA SAVE END

	} # LOAD ROUTINE.. PULL IN DATA AND PUT IT INTO THE SCALARS

	my $master = Slim::Player::Sync::isMaster($client); # Returns 1 if true
	my $slave = Slim::Player::Sync::isSlave($client); # Returns 1 if true
	my $name = Slim::Player::Client::name($client);
	if ($master == 1) {
		$params->{'prefs'}->{'master'} = "";
	} elsif ($slave == 1) {
		# One string, in strings.txt, shared with SC Controls in Plugin.pm. It was hardcoded in
		# English in both places and in neither string file until 2026-08-10.
		my $sync_master = $client->master()->name();
		$params->{'prefs'}->{'master'} = sprintf(
			Slim::Utils::Strings::string('PLUGIN_SC_WEB_SYNCWARNING'), $name, $sync_master);
	} else {
		$params->{'prefs'}->{'master'} = "";
	}

	###
	# THE DEFAULTS THAT USED TO BE HERE MOVED OUT ON 2026-08-07.
	###
	ensureSeedMood ($client);

	$params->{'prefs'}->{'sugarcube_status'} = $prefs->client($client)->get('sugarcube_status');
	$params->{'prefs'}->{'sugarcube_style'} = $prefs->client($client)->get('sugarcube_style');
	$params->{'prefs'}->{'sugarcube_variety'} = $prefs->client($client)->get('sugarcube_variety');
	$params->{'prefs'}->{'sugarcube_rejectsize'} = $prefs->client($client)->get('sugarcube_rejectsize');
	$params->{'prefs'}->{'sugarcube_size'} = $prefs->client($client)->get('sugarcube_size');
	$params->{'prefs'}->{'sugarcube_batchsize'} = $prefs->client($client)->get('sugarcube_batchsize');
	$params->{'prefs'}->{'sugarcube_filteractive'} = $prefs->client($client)->get('sugarcube_filteractive');
	$params->{'prefs'}->{'sugarcube_receipes'} = $prefs->client($client)->get('sugarcube_receipes');
	$params->{'prefs'}->{'sugarcube_seedmood'} = $prefs->client($client)->get('sugarcube_seedmood');
	$params->{'prefs'}->{'sugarcube_reducevolume'} = $prefs->client($client)->get('sugarcube_reducevolume');
	$params->{'prefs'}->{'sugarcube_sleep'} = $prefs->client($client)->get('sugarcube_sleep');
	$params->{'prefs'}->{'sugarcube_sleepfrom'} = $prefs->client($client)->get('sugarcube_sleepfrom');
	$params->{'prefs'}->{'sugarcube_sleepto'} = $prefs->client($client)->get('sugarcube_sleepto');
	$params->{'prefs'}->{'sugarcube_sleepduration'} = $prefs->client($client)->get('sugarcube_sleepduration');
	$params->{'prefs'}->{'sugarcube_ts_pc_higher'} = $prefs->client($client)->get('sugarcube_ts_pc_higher');

	$params->{'prefs'}->{'sugarcube_ts_trackrated'} = $prefs->client($client)->get('sugarcube_ts_trackrated');
	$params->{'prefs'}->{'sugarcube_ts_lastplayed'} = $prefs->client($client)->get('sugarcube_ts_lastplayed');
	$params->{'prefs'}->{'sugarcube_clutter'} = $prefs->client($client)->get('sugarcube_clutter');
	$params->{'prefs'}->{'scalarm_filter'} = $prefs->client($client)->get('scalarm_filter');
	$params->{'prefs'}->{'scblockartist_list'} = $prefs->client($client)->get('scblockartist_list');
	$params->{'prefs'}->{'scblockgenre_list'} = $prefs->client($client)->get('scblockgenre_list');
	$params->{'prefs'}->{'sugarcube_blockartist'} = $prefs->client($client)->get('sugarcube_blockartist');
	$params->{'prefs'}->{'sugarcube_blockalbum'} = $prefs->client($client)->get('sugarcube_blockalbum');
	$params->{'prefs'}->{'sugarcube_wobble'} = $prefs->client($client)->get('sugarcube_wobble') // 0;
	$params->{'prefs'}->{'scpreferartist_list'} = $prefs->client($client)->get('scpreferartist_list');
	$params->{'prefs'}->{'scpreferartist_weight'} = $prefs->client($client)->get('scpreferartist_weight') // 1;
	$params->{'prefs'}->{'sclessartist_list'} = $prefs->client($client)->get('sclessartist_list');
	$params->{'prefs'}->{'sclessartist_weight'} = $prefs->client($client)->get('sclessartist_weight') // 1;

	$params->{'filters'} = getFilterList();
	$params->{'receipes'} = getReceipesList();
	$params->{'moods'} = getMoodsList();
	$params->{'sc_players'} = getPlayerList($client);

	return $class->SUPER::handler($client, $params);
}

#####
# PLAYERS - for the "Choose Players" list beside Apply to Chosen Players. Excludes the
# current client; syncing a player to itself is a no-op the list shouldn't even offer.
sub getPlayerList {
	my $client = shift;
	my %playerHash = ();
	my $ownid = Slim::Player::Client::id($client);
	foreach my $player ( Slim::Player::Client::clients() ) {
		my $pid = Slim::Player::Client::id($player);
		next if ($pid eq $ownid);
		$playerHash{$pid} = Slim::Player::Client::name($player);
	}
	return \%playerHash;
}

###
# FILTERS
sub getFilterList {
	if ($sc_listCache{filters}{data} && (time() - $sc_listCache{filters}{ts} < $sc_listCacheTTL)) {
		return $sc_listCache{filters}{data};
	}

	my @filters = ();
	my %filterHash = ();

	my $MMSport = $prefs->get('sugarport');
	my $miphosturl = $prefs->get('miphosturl');

	my $url = 'http://' . $miphosturl . ":$MMSport/api/filters";
	my $ua = LWP::UserAgent->new();
	$ua->timeout($timeoutvalue);
	my $http = $ua->get($url);

	if ($http) {
		@filters = split(/\n/, $http->content);
	}
	my $none = sprintf('(%s)', Slim::Utils::Strings::string('NONE'));
	push @filters, $none;
	foreach my $filter ( @filters ) {
		if ($filter eq $none) {
			$filterHash{0} = $filter;
			next
		}
		$filterHash{$filter} = $filter;
	}
	if (($http->header("Client-Warning") || '' ) =~ /Internal response/) {
		# did not reach the server at all
	$log->warn("\nMusicIP is NOT Running!");
	$timeoutvalue = 2;
	}
	$sc_listCache{filters} = { data => \%filterHash, ts => time() };
	return \%filterHash;
}

#####
# RECEIPES
sub getReceipesList {
	if ($sc_listCache{receipes}{data} && (time() - $sc_listCache{receipes}{ts} < $sc_listCacheTTL)) {
		return $sc_listCache{receipes}{data};
	}

	my @filters = ();
	my %filterHash = ();

	my $MMSport = $prefs->get('sugarport');
	my $miphosturl = $prefs->get('miphosturl');

	my $url = 'http://' . $miphosturl . ":$MMSport/api/recipes";
	my $ua = LWP::UserAgent->new();
	$ua->timeout($timeoutvalue);
	my $http = $ua->get($url);

	if ($http) {
		@filters = split(/\n/, $http->content);
	}
	my $none = sprintf('(%s)', Slim::Utils::Strings::string('NONE'));
	push @filters, $none;
	foreach my $filter ( @filters ) {
		if ($filter eq $none) {
			$filterHash{0} = $filter;
			next
		}
		$filterHash{$filter} = $filter;
	}
	if (($http->header("Client-Warning") || '' ) =~ /Internal response/) {
		$log->warn("\nMusicIP is NOT Running!"); # did not reach the server at all
	}
	$sc_listCache{receipes} = { data => \%filterHash, ts => time() };
	return \%filterHash;
}

#####
# MOODS
###
sub ensureSeedMood {
	my $client = shift;
	return '' unless $client;

	my $mood = $prefs->client($client)->get('sugarcube_seedmood');
	return $mood if (defined $mood && $mood ne '');

	my $moods = getMoodsList();
	my ($first) = sort { lc($a) cmp lc($b) } keys %$moods;
	return '' unless defined $first;

	$prefs->client($client)->set('sugarcube_seedmood', $first);
	$log->debug("Seed Mood not set; defaulting to '$first'\n");
	return $first;
}

sub getMoodsList {
	if ($sc_listCache{moods}{data} && (time() - $sc_listCache{moods}{ts} < $sc_listCacheTTL)) {
		return $sc_listCache{moods}{data};
	}

	my @moods = ();
	my %moodHash = ();

	my $MMSport = $prefs->get('sugarport');
	my $miphosturl = $prefs->get('miphosturl');

	my $url = 'http://' . $miphosturl . ":$MMSport/api/moods";
	my $ua = LWP::UserAgent->new();
	$ua->timeout($timeoutvalue);
	my $http = $ua->get($url);

	if ($http) {
		@moods = split(/\n/, $http->content);
	}

	foreach my $mood ( @moods ) {
		next unless defined $mood;
		$mood =~ s/^\s+|\s+$//g;
		next unless length $mood;
		$moodHash{$mood} = $mood;
	}

	if (($http->header("Client-Warning") || '' ) =~ /Internal response/) {
		$log->warn("\nMusicIP is NOT Running!"); # did not reach the server at all
	}
	$sc_listCache{moods} = { data => \%moodHash, ts => time() };
	return \%moodHash;
}

1;
