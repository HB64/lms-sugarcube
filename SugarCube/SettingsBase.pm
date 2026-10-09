# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

# THE SUBPAGE MECHANISM. Ported from MIPster (guptaas), 2026-09-19 - LMS lists a plugin's settings
# ONCE in its menu whatever we do, so a second (or third) page has to be reached from within the
# first one rather than getting its own menu entry. Every subpage registers itself here by name; the
# handler collects them all into $params->{subpages} (name -> url) and $params->{subpage} (this
# page's own name) before handing off to the page's own handler, and subpage_chooser.html draws the
# dropdown from those two values. A subpage passing a true $default to new() is the one LMS's normal
# settings list shows (Settings.pm); anything else is reachable only through the chooser.

package Plugins::SugarCube::SettingsBase;

use strict;
use warnings;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

my %subPages = ();

sub new {
	my ($class, $plugin, $default) = @_;

	if (!defined($default) || !$default) {
		Slim::Web::Pages->addPageFunction($class->page, $class);
	} else {
		$class->SUPER::new();
	}
	$subPages{$class->name()} = $class;
	return $class;
}

sub handler {
	my ($class, $client, $params) = @_;

	my %currentSubPages = ();
	for my $key (keys %subPages) {
		my $pages = $subPages{$key}->pages($client, $params);
		for my $page (@{$pages}) {
			$currentSubPages{$page->{'name'}} = $page->{'page'};
		}
	}
	$params->{'subpages'} = \%currentSubPages;
	$params->{'subpage'} = $class->currentPage($client, $params);

	return $class->SUPER::handler($client, $params);
}

1;
