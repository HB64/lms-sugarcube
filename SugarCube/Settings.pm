# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::SugarCube::Settings;

use strict;
use warnings;
use base qw(Plugins::SugarCube::SettingsBase);
use Slim::Utils::Prefs;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.SugarCube');

# THE DEFAULT SUBPAGE. This is the one LMS's own settings list shows and links to directly - the
# '1' told to SettingsBase::new is what makes that happen. Every other subpage (Exports, ported from
# MIPster) passes nothing here and is reachable only through the chooser this page and theirs share.
sub new {
	my ($class, $plugin) = @_;
	$class->SUPER::new($plugin, 1);
}

sub name {
	 return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SUGARCUBE');
}

sub page {
	 return Slim::Web::HTTP::CSRF->protectURI('plugins/SugarCube/settings/settings.html');
}

sub currentPage {
	 return Slim::Utils::Strings::string('PLUGIN_SC_SUBPAGE_MAIN');
}

sub pages {
	 return [{ 'name' => Slim::Utils::Strings::string('PLUGIN_SC_SUBPAGE_MAIN'), 'page' => page() }];
}

sub handler {
	 my ( $class, $client, $params ) = @_;
	 if ( $params->{'saveSettings'} ) { # SAVE MODE
		my $sugarport = $params->{'sugarport'};
		$prefs->set( 'sugarport', "$sugarport" );
		my $miphosturl = $params->{'miphosturl'};
		$prefs->set( 'miphosturl', "$miphosturl" );
		my $sugardelay = $params->{'sugardelay'};
		$prefs->set( 'sugardelay', "$sugardelay" );
		my $sqlitetimeout = $params->{'sqlitetimeout'};
		$prefs->set( 'sqlitetimeout', "$sqlitetimeout" );
		my $nasconvertpath = $params->{'nasconvertpath'};
		$prefs->set( 'nasconvertpath', "$nasconvertpath" );
		my $localmediapath = $params->{'localmediapath'};
		$prefs->set( 'localmediapath', "$localmediapath" );

	 } # LOAD
	 $params->{'prefs'}->{'sugarport'} = $prefs->get('sugarport');
	 $params->{'prefs'}->{'miphosturl'} = $prefs->get('miphosturl');
	 $params->{'prefs'}->{'sugardelay'} = $prefs->get('sugardelay');
	 $params->{'prefs'}->{'sqlitetimeout'} = $prefs->get('sqlitetimeout');
	 $params->{'prefs'}->{'nasconvertpath'} = $prefs->get('nasconvertpath');
	 $params->{'prefs'}->{'localmediapath'} = $prefs->get('localmediapath');

	 return $class->SUPER::handler( $client, $params );
}

# MIP Export used to have its own Export Now/Abort handling and a beforeRender here (checkbox,
# time, replace-extension, rating-threshold fields, activelmsscan/activemipexport button-disabling,
# status-poll plumbing). Removed 2026-09-19, step 4 of the MIPster export port - all of it is fully
# superseded by the Exports subpage (SettingsExports.pm), including its own beforeRender.

1;
