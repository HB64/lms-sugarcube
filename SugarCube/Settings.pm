package Plugins::SugarCube::Settings;

use strict;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;
use Slim::Music::Import;
use Slim::Utils::Scheduler;

my $prefs = preferences('plugin.SugarCube');

use Slim::Utils::Log;
sub getDisplayName { return 'PLUGIN_SUGARCUBE'; }
my $log = Slim::Utils::Log->addLogCategory(
    {
        'category'     => 'plugin.sugarcube',
        'defaultLevel' => 'WARN',
        'description'  => getDisplayName(),
    }
);

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SUGARCUBE');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI(
        'plugins/SugarCube/settings/settings.html');
}

sub handler {
    my ( $class, $client, $params ) = @_;
    if ( $params->{'saveSettings'} ) {    # SAVE MODE
        my $sugarport = $params->{'sugarport'};
        $prefs->set( 'sugarport', "$sugarport" );
        my $miphosturl = $params->{'miphosturl'};
        $prefs->set( 'miphosturl', "$miphosturl" );
        my $sugardelay = $params->{'sugardelay'};
        $prefs->set( 'sugardelay', "$sugardelay" );
        my $sugarlvTS = $params->{'sugarlvTS'};
        $prefs->set( 'sugarlvTS', "$sugarlvTS" );
        my $rating_10scale = $params->{'rating_10scale'};
        $prefs->set( 'rating_10scale', "$rating_10scale" );
        my $useAPCvalues = $params->{'useapcvalues'};
        $prefs->set( 'useapcvalues', "$useAPCvalues" );
        # sugarmipsize moved to a per-player setting 2026-09-03 (Henk) - see PlayerSettings.pm.
        my $sugarxmas = $params->{'sugarxmas'};
        $prefs->set( 'sugarxmas', "$sugarxmas" );
        my $sqlitetimeout = $params->{'sqlitetimeout'};
        $prefs->set( 'sqlitetimeout', "$sqlitetimeout" );
        my $nasconvertpath = $params->{'nasconvertpath'};
        $prefs->set( 'nasconvertpath', "$nasconvertpath" );
        my $localmediapath = $params->{'localmediapath'};
        $prefs->set( 'localmediapath', "$localmediapath" );
        # Second path pair (nasconvertpath_2/localmediapath_2) removed 2026-09-02 (Henk) - DPC
        # simplified to one pair, matching the HB64 fork. sugardpc on/off toggle removed
        # 2026-09-03 (Henk) - matching SC-EXTMIP exactly: conversion is now implicit, via
        # scPathPair() in Plugin.pm (a filled-in nasconvertpath means convert).

        # MIP Export (Henk, 2026-09-02) - ported from the saysaar/SC-EXTMIP build and HB64 fork.
        my $sc_mipexport_enabled = $params->{'sc_mipexport_enabled'} ? 1 : 0;
        $prefs->set( 'sc_mipexport_enabled', "$sc_mipexport_enabled" );
        my $sc_mipexport_time = $params->{'sc_mipexport_time'};
        $prefs->set( 'sc_mipexport_time', "$sc_mipexport_time" );
        my $sc_mipexport_replaceextension = $params->{'sc_mipexport_replaceextension'};
        $prefs->set( 'sc_mipexport_replaceextension', "$sc_mipexport_replaceextension" );
        my $sc_mipexport_rating_threshold = $params->{'sc_mipexport_rating_threshold'};
        $prefs->set( 'sc_mipexport_rating_threshold', "$sc_mipexport_rating_threshold" );

        if ( $params->{'exportnow'} ) {
            eval { Slim::Utils::Scheduler::add_task( \&Plugins::SugarCube::Plugin::ExportStatsToMIP ); };
            $log->error("SC MIP Export - manual export failed to start; $@\n") if $@;
        }
        if ( $params->{'abortexport'} ) {
            Plugins::SugarCube::Plugin::scMIPExportAbort();
        }



    }    # LOAD
    $params->{'prefs'}->{'sugarport'}        = $prefs->get('sugarport');
    $params->{'prefs'}->{'miphosturl'}       = $prefs->get('miphosturl');
    $params->{'prefs'}->{'sugardelay'}       = $prefs->get('sugardelay');
    $params->{'prefs'}->{'sugarlvTS'}        = $prefs->get('sugarlvTS');
    $params->{'prefs'}->{'rating_10scale'}   = $prefs->get('rating_10scale');
    $params->{'prefs'}->{'useapcvalues'}     = $prefs->get('useapcvalues');
    $params->{'prefs'}->{'sugarxmas'}        = $prefs->get('sugarxmas');
    $params->{'prefs'}->{'sqlitetimeout'}    = $prefs->get('sqlitetimeout');
    $params->{'prefs'}->{'nasconvertpath'}   = $prefs->get('nasconvertpath');
    $params->{'prefs'}->{'localmediapath'}   = $prefs->get('localmediapath');

    # MIP Export
    $params->{'prefs'}->{'sc_mipexport_enabled'} = $prefs->get('sc_mipexport_enabled');
    $params->{'prefs'}->{'sc_mipexport_time'} = $prefs->get('sc_mipexport_time');
    $params->{'prefs'}->{'sc_mipexport_replaceextension'} = $prefs->get('sc_mipexport_replaceextension');
    $params->{'prefs'}->{'sc_mipexport_rating_threshold'} = $prefs->get('sc_mipexport_rating_threshold');
    $params->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';
    $params->{'activelmsscan'} = Slim::Music::Import->stillScanning ? 1 : 0;
    $params->{'activemipexport'} = $prefs->get('sc_mipexport_inprogress') ? 1 : 0;

    return $class->SUPER::handler( $client, $params );
}
1;

__END__
