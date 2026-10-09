# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

# THE EXPORTS PAGE. Ported from MIPster (guptaas), 2026-09-19. The export controls and the rating
# bands the export writes, on one page, with one Save. The bands are validated AS A SET - each must
# start higher than the one before - and a set that fails refuses the whole page, the export time
# included. That is deliberate: a half-saved page is worse than a refused one.
# Plugin.pm reads them any more. Removing that section is step 4, not yet done.

package Plugins::SugarCube::SettingsExports;

use strict;
use warnings;
use base qw(Plugins::SugarCube::SettingsBase);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings;
use Slim::Utils::Scheduler;
use Slim::Music::Import;

my $prefs = preferences('plugin.SugarCube');
my $log = logger('plugin.SugarCube');

# The stock scale. Restore Defaults writes exactly these, and they are the same numbers the export
# will fall back to once step 3 wires the conversion up, so there is one set of defaults rather than
# two that could drift.
my %BANDDEFAULTS = (
	sc_mipexport_unrated => 0,
	sc_mipexport_band1   => 10,
	sc_mipexport_band2   => 30,
	sc_mipexport_band3   => 50,
	sc_mipexport_band4   => 70,
	sc_mipexport_band5   => 90,
);

sub name {
	 return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SC_SUBPAGE_EXPORTS');
}

sub page {
	 return Slim::Web::HTTP::CSRF->protectURI('plugins/SugarCube/settings/exports.html');
}

sub currentPage {
	 return Slim::Utils::Strings::string('PLUGIN_SC_SUBPAGE_EXPORTS');
}

sub pages {
	 return [{ 'name' => Slim::Utils::Strings::string('PLUGIN_SC_SUBPAGE_EXPORTS'), 'page' => page() }];
}

sub scValidateBands {
	my $params = shift;

	my @keys = qw(sc_mipexport_band1 sc_mipexport_band2 sc_mipexport_band3 sc_mipexport_band4 sc_mipexport_band5);
	my @vals;

	my $unrated = $params->{'sc_mipexport_unrated'};
	return (0, 'unrated') unless defined $unrated && $unrated =~ /^\d+$/ && $unrated >= 0 && $unrated <= 5;

	foreach my $k (@keys) {
		my $v = $params->{$k};
		return (0, $k) unless defined $v && $v =~ /^\d+$/ && $v >= 1 && $v <= 100;
		push @vals, $v;
	}

	for my $i (1 .. $#vals) {
		return (0, 'order') unless $vals[$i] > $vals[$i - 1];
	}

	return (1, '');
}

sub handler {
	 my ( $class, $client, $params ) = @_;

	 # Restore Defaults is its own button and does not go through the validator - the stock scale is
	 # valid by definition, and needing a valid page in order to get back to a valid page would be a
	 # trap. It writes and returns; nothing else on the page is saved by that press.
	 if ( $params->{'screstorebands'} ) {
		foreach my $key (keys %BANDDEFAULTS) {
			$prefs->set( $key, $BANDDEFAULTS{$key} );
		}
		$log->info("SC MIP Export - rating bands restored to the stock scale\n");
		$params->{'scbandsrestored'} = 1;

	 } elsif ( $params->{'saveSettings'} ) {
		my ($bandsok, $why) = scValidateBands($params);
		if ($bandsok) {
			foreach my $key (keys %BANDDEFAULTS) {
				$prefs->set( $key, $params->{$key} );
			}

			# The time may be saved empty, and empty will be the off switch for the daily export once
			# step 3 wires the scheduler to this page. Do not refuse a blank value or substitute a
			# default here - that would remove the only way to turn it off.
			my $exporttime = $params->{'sc_mipexport_time'};
			if (defined $exporttime) {
				$exporttime =~ s/^\s+|\s+$//g;
				$prefs->set( 'sc_mipexport_time', "$exporttime" );
			}
			my $replaceext = $params->{'sc_mipexport_replaceextension'};
			if (defined $replaceext) {
				$prefs->set( 'sc_mipexport_replaceextension', "$replaceext" );
			}
			$prefs->set( 'sc_mipexport_postscan', $params->{'sc_mipexport_postscan'} ? 1 : 0 );

		} else {
			$log->error("SC MIP Export - rating bands refused ($why) - each band must start higher than "
				. "the one before it. NOTHING on this page was saved.\n");
			$params->{'scbandserror'} = 1;
		}
	 }

	 # Export Now is never gated by the automatic controls above; it is pressable the moment this
	 # build is installed, on the STOCK bands rather than this user's values if they have not saved
	 # yet - same reasoning as MIPster's own Exports page.
	 if ( $params->{'sc_mipexport_exportnow'} ) {
		if ( $prefs->get('sc_mipexport_inprogress') ) {
			$log->warn("SC MIP Export - Export Now ignored, an export is already running\n");
		} else {
			$log->info("SC MIP Export - Export Now pressed, starting an export\n");
			Slim::Utils::Scheduler::add_task( \&Plugins::SugarCube::Plugin::ExportStatsToMIP );
		}
	 } elsif ( $params->{'sc_mipexport_abort'} ) {
		Plugins::SugarCube::Plugin::scMIPExportAbort();
	 }

	 foreach my $key (keys %BANDDEFAULTS) {
		$params->{'prefs'}->{$key} = $prefs->get($key);
	 }
	 $params->{'prefs'}->{'sc_mipexport_time'} = $prefs->get('sc_mipexport_time');
	 $params->{'prefs'}->{'sc_mipexport_replaceextension'} = $prefs->get('sc_mipexport_replaceextension');
	 $params->{'prefs'}->{'sc_mipexport_postscan'} = $prefs->get('sc_mipexport_postscan');

	 return $class->SUPER::handler( $client, $params );
}

sub beforeRender {
	my ($class, $params) = @_;

	$params->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';
	$params->{'activelmsscan'} = 1 if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning);
	$params->{'activemipexport'} = 1 if $prefs->get('sc_mipexport_inprogress');
}

1;
