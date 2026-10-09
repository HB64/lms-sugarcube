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
my $sc_mipVersionCacheTTL = 300;

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

sub getMipCacheStatus {
	if ($sc_mipCache->{data} && (time() - $sc_mipCache->{ts} < $sc_mipCacheTTL)) {
		return $sc_mipCache->{data};
	}

	my $status = { total => '?', mixable => '?', todo => '?', active => 'Unreachable', cpuuse => '', reload => 0, mixer => 0 };

	my $miphosturl = $prefs->get('miphosturl');
	my $sugarport = $prefs->get('sugarport');
	my $ua = _mipUA(2);
	my $http = $ua->get("http://$miphosturl:$sugarport/server");

	if ($http && $http->is_success) {
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
	} else {
		# No /server page: MusicMagicMixer.exe. Only the API is available - total songs and status.
		my $cnt = _mipUA(2)->get("http://$miphosturl:$sugarport/api/getSongCount");
		if ($cnt && $cnt->is_success && $cnt->content =~ /(\d+)/) {
			$status->{total}   = $1;
			$status->{mixable} = 'n/a';
			$status->{todo}    = 'n/a';
			$status->{active}  = 'Active';
			$status->{mixer}   = 1;
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
	my $sugarport = $prefs->get('sugarport');
	my $url = "http://$miphosturl:$sugarport$path";
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

# Mixer only: the mip-refresh sidecar (port 8199) restarts the Mixer so it reloads its library.
sub mipSidecarRefresh {
	my $miphosturl = $prefs->get('miphosturl');
	my $http = _mipUA(10)->get("http://$miphosturl:8199/refresh");
	my $ok = $http && $http->is_success;
	$log->warn("SC MusicIP - sidecar refresh failed (" . ($http ? $http->status_line : 'no response') . ")\n")
		unless $ok;
	return $ok;
}

# Search returns an HTML results page rather than a status - strip it down to plain text the same
# way MIP's own page does client-side (block elements become line breaks, tags stripped).
sub mipSearch {
	my ($query) = @_;

	my $miphosturl = $prefs->get('miphosturl');
	my $sugarport = $prefs->get('sugarport');
	my $ua = _mipUA(5);
	my $http = $ua->get("http://$miphosturl:$sugarport/server/search?query=" . URI::Escape::uri_escape($query));

	unless ($http && $http->is_success) {
		$log->warn("SC MusicIP - search failed (" . ($http ? $http->status_line : 'no response') . ")\n");
		return undef;
	}

	my $body = $http->content;
	$body =~ s/<br\s*\/?>/\n/gi;
	$body =~ s/<\/(p|tr|li|div|h[1-4])\s*>/\n/gi;
	$body =~ s/<[^>]*>//g;
	$body =~ s/&amp;/&/g;
	$body =~ s/&lt;/</g;
	$body =~ s/&gt;/>/g;
	$body =~ s/&quot;/"/g;
	$body =~ s/&#0?39;/'/g;
	$body =~ s/[ \t]+\n/\n/g;
	$body =~ s/\n{2,}/\n/g;
	$body =~ s/^\s+|\s+$//g;

	return $body ne '' ? $body : undef;
}

sub handler {
	 my ( $class, $client, $params ) = @_;

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
		# Disabled field submits nothing when the checkbox is unchecked - default to the standard path.
		my $root = $params->{'sc_mip_add_root'} || 'Z:\music';
		my $ok = mipCommand('/server/add', root => $root);
		$params->{'prefs'}->{'mip_cache_feedback'} = $ok ? 'sent' : 'failed';
		$sc_mipCache->{ts} = 0;
	 } elsif ( $params->{'sc_mip_cache_refresh'} ) {
		my $ok = getMipCacheStatus()->{mixer} ? mipSidecarRefresh() : mipCommand('/server/refresh');
		$params->{'prefs'}->{'mip_cache_feedback'} = $ok ? 'sent' : 'failed';
		$sc_mipCache->{ts} = 0;
	 } elsif ( $params->{'sc_mip_cache_search'} ) {
		my $query = $params->{'sc_mip_search_query'} || '';
		$params->{'prefs'}->{'mip_search_query'} = $query;
		if ($query eq '') {
			$params->{'prefs'}->{'mip_cache_feedback'} = 'empty';
		} else {
			my $result = mipSearch($query);
			$params->{'prefs'}->{'mip_search_result'} = defined $result ? $result : 'No results.';
		}
	 } elsif ( $params->{'sc_mip_cache_reload'} ) {
		my $ok = mipCommand('/server/reload');
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
	 $params->{'prefs'}->{'mip_version'} = getMipVersion();
	 $params->{'prefs'}->{'mip_mixer'} = $mipcache->{mixer};

	 return $class->SUPER::handler( $client, $params );
}

1;
