# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::SugarCube::ProtocolHandler;

use strict;
use warnings;
use Plugins::SugarCube::Plugin;
use Slim::Utils::Log;
my $log = logger('plugin.sugarcube');

sub overridePlayback {
	my ($class, $client, $url) = @_;

	if ($url !~ m|^sugarcube:(.*)$|) {
		return undef;
	}
	my $kind = $1;

	# Henk, 2026-08-30: two alarm placeholders now (see Plugin.pm's getAlarmPlaylists) -
	# 'sugarcube:track' (the original, a continuous Chain mix) and 'sugarcube:batch' (an SC
	# Batch). Everything else about this handler - the match, the 1-second delay, the return
	# value - is unchanged; only which sub gets timered depends on which placeholder fired.
	if ($kind eq 'batch') {
		$log->debug("ProtocolHandler; Firing (batch)");
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1, \&Plugins::SugarCube::Plugin::AlarmFiredBatch, $client);
	} else {
		$log->debug("ProtocolHandler; Firing");
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1, \&Plugins::SugarCube::Plugin::AlarmFired, $client);
	}
	return 1;
}

sub canDirectStream { 0 }

sub contentType { return 'sugarcube'; }

sub isRemote { 0 }

sub getIcon { return Plugins::SugarCube::Plugin->_pluginDataFor('icon'); }

1;
