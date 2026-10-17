# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

# THE MUSICIP PAGE - mirrors MIP's own index page (Cache stats, Validation) on SugarCube's Global
# settings, using Main's host/port. Host/Port themselves stay on Main - this page only reads them.

package Plugins::SugarCube::SettingsMusicIP;

use strict;
use warnings;
use base qw(Plugins::SugarCube::SettingsBase);
use Slim::Utils::Prefs;
use Slim::Utils::Strings;
use LWP::UserAgent;
use URI::Escape;
use Slim::Utils::Log;

my $prefs = preferences('plugin.SugarCube');
my $log = logger('plugin.SugarCube');

sub name {
	 return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SC_SUBPAGE_MUSICIP');
}

sub page {
	 return Slim::Web::HTTP::CSRF->protectURI('plugins/SugarCube/settings/musicip.html');
}

sub currentPage {
	 return Slim::Utils::Strings::string('PLUGIN_SC_SUBPAGE_MUSICIP');
}

sub pages {
	 return [{ 'name' => Slim::Utils::Strings::string('PLUGIN_SC_SUBPAGE_MUSICIP'), 'page' => page() }];
}

# Short-TTL cache, same reasoning as PlayerSettings.pm's filter/recipe cache - bounds how often the
# blocking HTTP call fires.
my $sc_mipCache = { data => undef, ts => 0 };
my $sc_mipCacheTTL = 2;

my $sc_mipVersionCache = { data => undef, ts => 0 };
# Henk switches between MIP containers while testing - a long TTL here meant the version (and
# everything derived from it: the 1.8 Runs On field, the Add-folder default) stayed stale for
# minutes after a switch, surviving even a manual page refresh since this cache is per-process,
# not per-request. Lowered to match the page's own 4s poll interval.
my $sc_mipVersionCacheTTL = 5;

# Browser-identifying UA string - MIP's add/refresh endpoints silently no-op for a request
# that doesn't look like it came from a browser; validate/CPU-use don't seem to care, but this
# keeps all MIP calls consistent.
sub _mipUA {
	my ($timeout) = @_;
	my $ua = LWP::UserAgent->new();
	$ua->timeout($timeout);
	$ua->agent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36');
	return $ua;
}

sub getMipVersion {
	if ($sc_mipVersionCache->{data} && (time() - $sc_mipVersionCache->{ts} < $sc_mipVersionCacheTTL)) {
		return $sc_mipVersionCache->{data};
	}

	my $version = '';
	my $miphosturl = $prefs->get('miphosturl');
	my $sugarport = $prefs->get('sugarport');
	my $ua = _mipUA(2);
	my $http = $ua->get("http://$miphosturl:$sugarport/api/version");
	if ($http && $http->is_success) {
		$version = $http->content;
		$version =~ s/^\s+|\s+$//g;
	}

	$sc_mipVersionCache = { data => $version, ts => time() };
	return $version;
}

# Add-folder default: the configured "Music Path in MusicIP" (nasconvertpath), falling back to
# "Music Path in LMS" (localmediapath) when that's empty - same rule the path translation uses.
sub getMipDefaultRoot {
	return $prefs->get('nasconvertpath') || $prefs->get('localmediapath') || '';
}

# MusicIP Server port - separate from the Mixer's own Host/Port (Main page) for a "combined
# container" setup where they're genuinely different processes. Blank = same port as the Mixer.
sub _mipServerPort {
	return $prefs->get('mipserverport') || $prefs->get('sugarport');
}

sub getMipCacheStatus {
	if ($sc_mipCache->{data} && (time() - $sc_mipCache->{ts} < $sc_mipCacheTTL)) {
		return $sc_mipCache->{data};
	}

	my $status = { total => '?', mixable => '?', todo => '?', active => 'Unreachable', cpuuse => '', reload => 0, mixer => 0, mixersongs => '?' };

	my $miphosturl = $prefs->get('miphosturl');
	my $sugarport = $prefs->get('sugarport');
	my $serverport = _mipServerPort();
	my $ua = _mipUA(2);
	my $http = $ua->get("http://$miphosturl:$serverport/server");
	my $hadServer = ($http && $http->is_success) ? 1 : 0;
	$status->{mixer} = $hadServer ? 0 : 1;

	if ($hadServer) {
		my $body = $http->content;
		if ($body =~ /id="st-total"[^>]*>([^<]*)</)   { $status->{total}   = $1; }
		if ($body =~ /id="st-mixable"[^>]*>([^<]*)</) { $status->{mixable} = $1; }
		if ($body =~ /id="st-todo"[^>]*>([^<]*)</)    { $status->{todo}    = $1; }
		if ($body =~ /id="st-active"[^>]*>(.*?)<\/span>/s) {
			my $activeText = $1;
			# Strip any link (e.g. MIP's own "Cancel") entirely - its text would otherwise survive as
			# inert, unclickable clutter once the tag itself is stripped below.
			$activeText =~ s/<a[^>]*>.*?<\/a>//gsi;
			$activeText =~ s/<[^>]*>//g;
			$activeText =~ s/^\s+|\s+$//g;
			$status->{active} = $activeText ne '' ? $activeText : 'Idle';
		}
		if ($body =~ /<select name="use"[^>]*>(.*?)<\/select>/s) {
			my $cpuBlock = $1;
			if ($cpuBlock =~ /<option\s+selected\s+value="(\d+)"/ || $cpuBlock =~ /<option\s+value="(\d+)"[^>]*\sselected/) {
				$status->{cpuuse} = $1;
			}
		}
		# MIP shows this when default.m3lib was replaced/touched on disk outside of MIP itself.
		# MIP's own template keeps a commented-out example of this block as documentation, always
		# present in the markup - strip comments first so that example is never mistaken for the real one.
		(my $bodyNoComments = $body) =~ s/<!--.*?-->//gs;
		if ($bodyNoComments =~ /class="reload-notice"/) { $status->{reload} = 1; }

		# Some companion pages show these same numbers in plain label+value cards instead of using
		# SugarCube's ids ("stat-label">Mixable</div> ... "stat-value">1234</div>") - try that layout
		# for whichever counts the id-based match above didn't find.
		my %labelFor = (total => 'Total songs', mixable => 'Mixable', todo => 'To validate');
		for my $key (qw(total mixable todo)) {
			next if $status->{$key} ne '?';
			my $label = quotemeta($labelFor{$key});
			if ($body =~ /class="stat-label">$label<\/div>\s*<div class="stat-value[^"]*">([^<]*)</) {
				$status->{$key} = $1;
			}
		}
		# This kind of page rarely has a separate status text - if we got real numbers but no active
		# text, the server clearly answered, so call it Active rather than the default Unreachable.
		if ($status->{total} ne '?' && $status->{active} eq 'Unreachable') {
			$status->{active} = 'Active';
		}
	}

	# Mixer song count - always fetched (not just a Total fallback), since the Mixer and Server
	# can briefly disagree after a library change (Mixer restarts 30-45s after Server).
	my $cnt = _mipUA(2)->get("http://$miphosturl:$sugarport/api/getSongCount");
	if ($cnt && $cnt->is_success && $cnt->content =~ /(\d+)/) {
		$status->{mixersongs} = $1;
	}

	# No matching ids found above - either /server failed outright, or it answered with a
	# companion page that doesn't use SugarCube's expected markup. Fall back to the Mixer's own
	# count for Total too - degrades to total count + a plain "Active", no mixable/todo breakdown.
	if ($status->{total} eq '?') {
		if ($status->{mixersongs} ne '?') {
			$status->{total}   = $status->{mixersongs};
			$status->{mixable} = 'n/a';
			$status->{todo}    = 'n/a';
			$status->{active}  = 'Active';
		}
	}

	$sc_mipCache = { data => $status, ts => time() };
	return $status;
}

# One-off command to MIP's own server (Processor use / Start-Stop validation) - not cached, same
# short timeout as the status read so a stalled MIP server cannot hang the page.
sub mipCommand {
	my ($path, %query) = @_;

	my $miphosturl = $prefs->get('miphosturl');
	my $serverport = _mipServerPort();
	my $url = "http://$miphosturl:$serverport$path";
	if (%query) {
		$url .= '?' . join('&', map { "$_=" . URI::Escape::uri_escape($query{$_}) } keys %query);
	}

	my $ua = _mipUA(2);
	my $http = $ua->get($url);
	my $ok = $http && $http->is_success;
	$log->warn("SC MusicIP - command to MIP failed: $path (" . ($http ? $http->status_line : 'no response') . ")\n")
		unless $ok;
	return $ok;
}

# The mip-refresh sidecar restarts/reloads the Mixer so it picks up library changes the Server
# just made (needed whenever the Mixer is a separate process from the Server). Blank port = the
# feature is off, a no-op success rather than an error.
sub mipSidecarRefresh {
	my ($endpoint) = @_;
	$endpoint ||= 'refresh-when-idle';

	my $refreshport = $prefs->get('miprefreshport');
	return 1 unless $refreshport;

	my $miphosturl = $prefs->get('miphosturl');
	my $http = _mipUA(10)->get("http://$miphosturl:$refreshport/$endpoint");
	my $ok = $http && $http->is_success;
	$log->warn("SC MusicIP - sidecar refresh failed (" . ($http ? $http->status_line : 'no response') . ")\n")
		unless $ok;
	return $ok;
}

sub handler {
	 my ( $class, $client, $params ) = @_;

	 # OS type select submits on its own (onchange), independent of the action buttons below - save
	 # it unconditionally whenever present, rather than fitting it into the elsif chain.
	 if ( defined $params->{'sc_mip_ostype'} ) {
		$prefs->set( 'mipostype', $params->{'sc_mip_ostype'} );
	 }

	 # MusicIP Server / refresh sidecar ports - plain fields, saved via this page's own Save button.
	 if ( $params->{'saveSettings'} ) {
		$prefs->set( 'mipserverport', $params->{'sc_mip_serverport'} );
		$prefs->set( 'miprefreshport', $params->{'sc_mip_refreshport'} );
	 }

	 # sc_mip_cpuuse is always present once this form has been posted once (it's a <select>, not an
	 # optional field) - the Start/Stop buttons must be checked first or they'd never be reached.
	 if ( $params->{'sc_mip_validate_start'} ) {
		my $ok = mipCommand('/server/validate', action => 'Start Validation');
		$params->{'prefs'}->{'mip_validate_feedback'} = $ok ? 'sent' : 'failed';
		$sc_mipCache->{ts} = 0;
	 } elsif ( $params->{'sc_mip_validate_stop'} ) {
		my $ok = mipCommand('/server/validate', action => 'Stop Validation');
		$params->{'prefs'}->{'mip_validate_feedback'} = $ok ? 'sent' : 'failed';
		$sc_mipCache->{ts} = 0;
	 } elsif ( $params->{'sc_mip_cache_add'} ) {
		my $root = getMipDefaultRoot();
		my $ok = mipCommand('/server/add', root => $root);
		mipSidecarRefresh() if $ok;
		$params->{'prefs'}->{'mip_cache_feedback'} = $ok ? 'sent' : 'failed';
		$sc_mipCache->{ts} = 0;
	 } elsif ( $params->{'sc_mip_cache_refresh'} ) {
		my $mixerOnly = getMipCacheStatus()->{mixer};
		my $ok = $mixerOnly ? mipSidecarRefresh() : mipCommand('/server/refresh');
		mipSidecarRefresh() if !$mixerOnly && $ok;
		$params->{'prefs'}->{'mip_cache_feedback'} = $ok ? 'sent' : 'failed';
		$sc_mipCache->{ts} = 0;
	 } elsif ( $params->{'sc_mip_cache_reload'} ) {
		my $ok = mipCommand('/server/reload');
		mipSidecarRefresh() if $ok;
		$params->{'prefs'}->{'mip_cache_feedback'} = $ok ? 'sent' : 'failed';
		$sc_mipCache->{ts} = 0;
	 } elsif ( defined $params->{'sc_mip_cpuuse'} ) {
		mipCommand('/server/updateProcessorUse', use => $params->{'sc_mip_cpuuse'});
		$sc_mipCache->{ts} = 0;
	 }

	 my $mipcache = getMipCacheStatus();
	 $params->{'prefs'}->{'mip_total'} = $mipcache->{total};
	 $params->{'prefs'}->{'mip_mixable'} = $mipcache->{mixable};
	 $params->{'prefs'}->{'mip_todo'} = $mipcache->{todo};
	 $params->{'prefs'}->{'mip_active'} = $mipcache->{active};
	 $params->{'prefs'}->{'mip_cpuuse'} = $mipcache->{cpuuse};
	 $params->{'prefs'}->{'mip_reload'} = $mipcache->{reload};
	 $params->{'prefs'}->{'mip_mixersongs'} = $mipcache->{mixersongs};
	 my $mipVersion = getMipVersion();
	 $params->{'prefs'}->{'mip_version'} = $mipVersion;
	 $params->{'prefs'}->{'mip_mixer'} = $mipcache->{mixer};
	 # 1.8 ships as both a Linux and a Windows build; 1.9.x is Windows-only, so the OS picker only
	 # makes sense (and is only shown) for 1.8.
	 $params->{'prefs'}->{'mip_is_18'} = ($mipVersion && $mipVersion =~ /1\.8/) ? 1 : 0;
	 my $mipOstype = $prefs->get('mipostype') || 'linux';
	 $params->{'prefs'}->{'mipostype'} = $mipOstype;
	 $params->{'prefs'}->{'mip_default_root'} = getMipDefaultRoot();
	 $params->{'prefs'}->{'mipserverport'} = $prefs->get('mipserverport');
	 $params->{'prefs'}->{'miprefreshport'} = $prefs->get('miprefreshport');

	 return $class->SUPER::handler( $client, $params );
}

1;
