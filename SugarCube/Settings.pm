package Plugins::SugarCube::Settings;

use strict;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;

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
        my $sugarlvwidth = $params->{'sugarlvwidth'};
        $prefs->set( 'sugarlvwidth', "$sugarlvwidth" );
        my $sugarlviconsize = $params->{'sugarlviconsize'};
        $prefs->set( 'sugarlviconsize', "$sugarlviconsize" );
        my $sugarlvTS = $params->{'sugarlvTS'};
        $prefs->set( 'sugarlvTS', "$sugarlvTS" );
        my $rating_10scale = $params->{'rating_10scale'};
        $prefs->set( 'rating_10scale', "$rating_10scale" );
        my $useAPCvalues = $params->{'useapcvalues'};
        $prefs->set( 'useapcvalues', "$useAPCvalues" );
        my $sugarmipsize = $params->{'sugarmipsize'};
        $prefs->set( 'sugarmipsize', "$sugarmipsize" );
        my $sugarhisweight = $params->{'sugarhisweight'};
        $prefs->set( 'sugarhisweight', "$sugarhisweight" );
        my $sugarlvweight = $params->{'sugarlvweight'};
        $prefs->set( 'sugarlvweight', "$sugarlvweight" );
        my $sugarxmas = $params->{'sugarxmas'};
        $prefs->set( 'sugarxmas', "$sugarxmas" );
        my $sqlitetimeout = $params->{'sqlitetimeout'};
        $prefs->set( 'sqlitetimeout', "$sqlitetimeout" );
        my $nasconvertpath = $params->{'nasconvertpath'};
        $prefs->set( 'nasconvertpath', "$nasconvertpath" );
        my $localmediapath = $params->{'localmediapath'};
        $prefs->set( 'localmediapath', "$localmediapath" );
        my $nasconvertpath_2 = $params->{'nasconvertpath_2'};
        $prefs->set( 'nasconvertpath_2', "$nasconvertpath_2" );
        my $localmediapath_2 = $params->{'localmediapath_2'};
        $prefs->set( 'localmediapath_2', "$localmediapath_2" );
        my $sugardpc = $params->{'sugardpc'};
        $prefs->set( 'sugardpc', "$sugardpc" );






    }    # LOAD
    $params->{'prefs'}->{'sugarport'}        = $prefs->get('sugarport');
    $params->{'prefs'}->{'miphosturl'}       = $prefs->get('miphosturl');
    $params->{'prefs'}->{'sugardelay'}       = $prefs->get('sugardelay');
    $params->{'prefs'}->{'sugarlvwidth'}     = $prefs->get('sugarlvwidth');
    $params->{'prefs'}->{'sugarlviconsize'}  = $prefs->get('sugarlviconsize');
    $params->{'prefs'}->{'sugarlvTS'}        = $prefs->get('sugarlvTS');
    $params->{'prefs'}->{'rating_10scale'}   = $prefs->get('rating_10scale');
    $params->{'prefs'}->{'useapcvalues'}     = $prefs->get('useapcvalues');
    $params->{'prefs'}->{'sugarmipsize'}     = $prefs->get('sugarmipsize');
    $params->{'prefs'}->{'sugarhisweight'}   = $prefs->get('sugarhisweight');
    $params->{'prefs'}->{'sugarlvweight'}    = $prefs->get('sugarlvweight');
    $params->{'prefs'}->{'sugarxmas'}        = $prefs->get('sugarxmas');
    $params->{'prefs'}->{'sqlitetimeout'}    = $prefs->get('sqlitetimeout');
    $params->{'prefs'}->{'nasconvertpath'}   = $prefs->get('nasconvertpath');
    $params->{'prefs'}->{'localmediapath'}   = $prefs->get('localmediapath');
    $params->{'prefs'}->{'nasconvertpath_2'} = $prefs->get('nasconvertpath_2');
    $params->{'prefs'}->{'localmediapath_2'} = $prefs->get('localmediapath_2');
    $params->{'prefs'}->{'sugardpc'}         = $prefs->get('sugardpc');




    return $class->SUPER::handler( $client, $params );
}
1;

__END__
