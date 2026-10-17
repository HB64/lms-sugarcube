# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

# MIP POWER SEARCH. Everything that knows about the expression lives here: the field table, the
# clause shapes, the two questions asked of MusicIP, and the per player storage. Plugin.pm calls in
# and never builds a clause itself.
#
# THE PAGE NEVER LETS THE USER TYPE AN OPERATOR. It posts a list of rows, this file turns them into
# an expression. So 'without', a bare &, unquoted punctuation and unbalanced brackets are unreachable
# by construction rather than merely detected.
#
# GRAMMAR, ALL MEASURED ON THE LIVE MIXER. Do not "tidy" any of it:
#   * Exclusion is 'and not (...)' or 'or not (...)'. NEVER 'without' - it silently loses clauses.
#   * 'not (...)' is legal as the first thing in an expression AND as the first thing inside a
#     bracketed set with clauses after it. Both verified against counts that add up.
#   * An empty include value is a harmless no-op; an empty EXCLUDE value wipes the result to zero.
#     So a row with no value is not turned into a clause at all.
#   * 'missing' on a TEXT field is field = "". Genre, Album and Artist are the exception: MusicIP
#     substitutes a placeholder name, so those three test for the placeholder instead.
#   * 'missing' on a NUMBER or DATE field is field = 0. field = "" answers HTTP 400 there.
#   * DATES ARE MILLISECONDS since 1970, not seconds. A seconds-scale number is smaller than every
#     stored value, so '> seconds' silently matches the whole library. This is the trap in the file.
#   * MusicIP has no range operator. A range row is built from two conditions.

package Plugins::SugarCube::PowerSearch;

use strict;
use warnings;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings;
use LWP::UserAgent;
use URI::Escape;
use Time::Local ();

my $prefs = preferences('plugin.SugarCube');
my $log = logger('plugin.sugarcube');

# The value stored in chainFilter when Power Search is the selection. Never shown; the dropdown
# shows the translated '(Power Search)' instead, exactly as '(None)' is shown for the stored 0.
# Henk, 2026-10-17 - NOT allowed to start with an underscore: Template Toolkit's stash treats
# any hash key starting with '_' as private and silently refuses to look it up, which is why
# this entry's label rendered blank in the Filter dropdown no matter what psLabel() returned.
use constant PS_KEY     => 'SugarCubePowerSearchFilter';
use constant PS_TIMEOUT => 2;    # seconds, both questions. A 500 track answer took 0.35s measured.
# The minimum yield has a floor as well as a ceiling. A pool smaller than the ask size leaves nothing to
# trim, so the chain would promote the same few tracks for ever.
use constant PS_MINMAX   => 500;  # the ceiling on the minimum yield
use constant PS_MINFLOOR => 10;   # and the floor. Anything below is raised to it, not refused.
                                  # Keep it above Reject Size: a filter with fewer tracks leaves nothing to play.
use constant PS_MINSTART => 50;   # what the box shows on a player with nothing saved
use constant PS_MAXROWS => 40;   # sanity ceiling on a posted search, not a designed limit

# THE FIELD TABLE. 'mip' is the word sent; the label is ours and need not match it. Text fields and
# number/date fields take different connectors, which is the only thing 'kind' decides.
my @FIELDS = (
	{ id => 'album',     mip => 'album',      kind => 'text', label => 'PLUGIN_SC_PS_F_ALBUM',     missing => '"Miscellaneous"'   },
	{ id => 'artist',    mip => 'artist',     kind => 'text', label => 'PLUGIN_SC_PS_F_ARTIST',    missing => '"Various Artists"' },
	{ id => 'composer',  mip => 'composer',   kind => 'text', label => 'PLUGIN_SC_PS_F_COMPOSER',  missing => '""'                },
	{ id => 'conductor', mip => 'conductor',  kind => 'text', label => 'PLUGIN_SC_PS_F_CONDUCTOR', missing => '""'                },
	{ id => 'file',      mip => 'file',       kind => 'text', label => 'PLUGIN_SC_PS_F_FILE',      missing => '""'                },
	{ id => 'genre',     mip => 'genre',      kind => 'text', label => 'PLUGIN_SC_PS_F_GENRE',     missing => '"Miscellaneous"'   },
	{ id => 'orchestra', mip => 'orchestra',  kind => 'text', label => 'PLUGIN_SC_PS_F_ORCHESTRA', missing => '""'                },

	{ id => 'bitrate',   mip => 'bitrate',    kind => 'num',  label => 'PLUGIN_SC_PS_F_BITRATE'   },
	{ id => 'added',     mip => 'dateadded',  kind => 'date', label => 'PLUGIN_SC_PS_F_ADDED'     },
	{ id => 'lastplay',  mip => 'lastplayed', kind => 'date', label => 'PLUGIN_SC_PS_F_LASTPLAY'  },
	{ id => 'playcount', mip => 'playcount',  kind => 'num',  label => 'PLUGIN_SC_PS_F_PLAYCOUNT' },
	{ id => 'rating',    mip => 'rating',     kind => 'num',  label => 'PLUGIN_SC_PS_F_RATING', lo => 0, hi => 5 },
	{ id => 'year',      mip => 'year',       kind => 'num',  label => 'PLUGIN_SC_PS_F_YEAR'      },
);

my %FIELDBYID = map { $_->{id} => $_ } @FIELDS;

sub fields { return \@FIELDS; }
sub minFloor { return PS_MINFLOOR; }
sub minStart { return PS_MINSTART; }
sub fieldById { my $id = shift; return (defined $id && exists $FIELDBYID{$id}) ? $FIELDBYID{$id} : undef; }

sub psKey { return PS_KEY; }
sub psLabel { return sprintf('(%s)', Slim::Utils::Strings::string('PLUGIN_SC_PS_DROPDOWN')); }

# Accepts both spellings for the same reason scIsNone does: the web dropdown carries the stored key,
# the iPeng picker carries the text it drew.
sub isPowerSearch {
	my $value = shift;
	return 0 unless defined $value && length $value;
	return 1 if $value eq PS_KEY;
	return 1 if $value eq psLabel();
	return 0;
}

# ---------------------------------------------------------------------------------------------
# The search structure. { min => n, sets => [ { match => 'all'|'any', rows => [ {f,op,v,v2} ] } ] }
# ---------------------------------------------------------------------------------------------

# ONE WIRE FORMAT, written by the page and read here. Lines, tab separated. The page strips tabs and
# newlines out of a value before it builds this, and so does the reader, so a value can never open a
# new field or a new line.
#   M <tab> 500
#   S <tab> all
#   R <tab> genre <tab> contains <tab> ghazal <tab>
sub parseData {
	my $text = shift;
	$text = '' unless defined $text;

	my %search = ( min => PS_MINSTART, sets => [] );
	my $set;
	my $rows = 0;

	foreach my $line (split(/\r?\n/, $text)) {
		my @f = split(/\t/, $line, -1);
		my $tag = shift @f;
		next unless defined $tag;

		if ($tag eq 'M') {
			my $m = $f[0];
			$m = PS_MINSTART unless defined $m && $m =~ /^\d+$/;
			$m = PS_MINFLOOR if $m < PS_MINFLOOR;
			$m = PS_MINMAX if $m > PS_MINMAX;
			$search{min} = $m;
		}
		elsif ($tag eq 'S') {
			my $match = (defined $f[0] && $f[0] eq 'any') ? 'any' : 'all';
			$set = { match => $match, rows => [] };
			push @{ $search{sets} }, $set;
		}
		elsif ($tag eq 'R') {
			next unless $set;
			next if ++$rows > PS_MAXROWS;
			push @{ $set->{rows} }, {
				f  => (defined $f[0] ? $f[0] : ''),
				op => (defined $f[1] ? $f[1] : ''),
				v  => cleanValue($f[2]),
				v2 => cleanValue($f[3]),
			};
		}
	}

	return \%search;
}

sub cleanValue {
	my $v = shift;
	return '' unless defined $v;
	$v =~ s/[\t\r\n]/ /g;
	$v =~ s/^\s+|\s+$//g;
	return $v;
}

# The page redraws itself from this, so it has to survive a round trip unchanged.
sub toData {
	my $search = shift;
	return '' unless ref $search eq 'HASH';

	my @lines = ( "M\t" . ($search->{min} // PS_MINSTART) );
	foreach my $set (@{ $search->{sets} || [] }) {
		push @lines, "S\t" . (($set->{match} || 'all') eq 'any' ? 'any' : 'all');
		foreach my $row (@{ $set->{rows} || [] }) {
			push @lines, join("\t", 'R', $row->{f} // '', $row->{op} // '', $row->{v} // '', $row->{v2} // '');
		}
	}
	return join("\n", @lines);
}

# ---------------------------------------------------------------------------------------------
# Expression building
# ---------------------------------------------------------------------------------------------

# A date box holds mm/dd/yyyy and MusicIP holds milliseconds. 'which' picks the end of the day that
# belongs on that side of the comparison.
sub dateToMs {
	my ($text, $which) = @_;
	return undef unless defined $text;
	$text =~ s/\s+//g;
	return undef unless $text =~ m{^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$};
	my ($mm, $dd, $yyyy) = ($1, $2, $3);
	return undef if ($mm < 1 || $mm > 12 || $dd < 1 || $dd > 31);

	my $secs = eval { Time::Local::timelocal(0, 0, 0, $dd, $mm - 1, $yyyy) };
	return undef unless defined $secs;

	my $ms = $secs * 1000;
	$ms += 86_399_999 if (defined $which && $which eq 'end');
	return $ms;
}

sub numberFor {
	my ($field, $text, $which) = @_;

	if ($field->{kind} eq 'date') {
		return dateToMs($text, $which);
	}

	return undef unless defined $text && $text =~ /^-?\d+$/;
	my $n = $text + 0;
	$n = $field->{lo} if (defined $field->{lo} && $n < $field->{lo});
	$n = $field->{hi} if (defined $field->{hi} && $n > $field->{hi});
	return $n;
}

# One row, one clause - or nothing at all. Returning nothing is how a half filled row disappears
# instead of becoming an empty clause, which on an exclusion would wipe the result to zero.
sub clauseFor {
	my $row = shift;

	my $field = fieldById($row->{f}) or return undef;
	my $op = defined $row->{op} ? $row->{op} : '';
	my $m  = $field->{mip};

	if ($field->{kind} eq 'text') {
		return "($m = $field->{missing})" if $op eq 'missing';

		my $v = defined $row->{v} ? $row->{v} : '';
		return undef unless length $v;

		return "($m contains \"$v\")"     if $op eq 'contains';
		return "not ($m contains \"$v\")" if $op eq 'omits';
		return undef;
	}

	return "($m = 0)" if $op eq 'missing';

	if ($op eq 'range') {
		my $lo = numberFor($field, $row->{v},  'start');
		my $hi = numberFor($field, $row->{v2}, 'end');
		return undef unless defined $lo && defined $hi;
		($lo, $hi) = ($hi, $lo) if $lo > $hi;
		return "(($m >= $lo) and ($m <= $hi))";
	}

	if ($op eq 'gt') {
		my $n = numberFor($field, $row->{v}, 'start');
		return defined $n ? "($m > $n)" : undef;
	}
	if ($op eq 'lt') {
		my $n = numberFor($field, $row->{v}, 'start');
		return defined $n ? "($m < $n)" : undef;
	}

	return undef;
}

# POSITIVES FIRST INSIDE A SET. 'and not' and 'or not' after a subject are measured in every shape;
# a leading 'not' is measured too, but putting the subject first means the common case never relies
# on the rarer one.
sub setExpression {
	my $set = shift;

	my (@pos, @neg);
	foreach my $row (@{ $set->{rows} || [] }) {
		my $c = clauseFor($row);
		next unless defined $c;
		if ($c =~ /^not /) { push @neg, $c } else { push @pos, $c }
	}

	my @clauses = (@pos, @neg);
	return undef unless @clauses;
	return $clauses[0] if @clauses == 1;

	my $join = (($set->{match} || 'all') eq 'any') ? ' or ' : ' and ';
	return '(' . join($join, @clauses) . ')';
}

# SETS ARE ALWAYS JOINED BY 'and'. Permanent, never offered as a choice - every set narrows further.
sub buildExpression {
	my $search = shift;
	return undef unless ref $search eq 'HASH';

	my @sets;
	foreach my $set (@{ $search->{sets} || [] }) {
		my $e = setExpression($set);
		push @sets, $e if defined $e;
	}

	return undef unless @sets;
	return '?' . join(' and ', @sets);
}

# The one character the design rejects at entry, plus the quote, which would close a value early.
# Both are refused rather than stripped: silently changing what was typed is worse than saying no.
sub badCharacter {
	my $search = shift;
	foreach my $set (@{ $search->{sets} || [] }) {
		foreach my $row (@{ $set->{rows} || [] }) {
			foreach my $v ($row->{v}, $row->{v2}) {
				next unless defined $v;
				return '&' if $v =~ /&/;
				return '"' if $v =~ /"/;
			}
		}
	}
	return undef;
}

# ---------------------------------------------------------------------------------------------
# Storage - per player, and only ever written by a search that passed its yield test
# ---------------------------------------------------------------------------------------------

sub savedSearch {
	my $client = shift;
	return undef unless $client;
	my $s = $prefs->client($client)->get('psSearch');
	return undef unless ref $s eq 'HASH' && ref $s->{sets} eq 'ARRAY' && @{ $s->{sets} };
	return $s;
}

sub saveSearch {
	my ($client, $search) = @_;
	return unless $client;
	$prefs->client($client)->set('psSearch', $search);
}

sub clearSaved {
	my $client = shift;
	return unless $client;
	$prefs->client($client)->set('psSearch', undef);
}

# What buildMIPReq sends. Undef means there is nothing usable, and the caller falls back to no
# filter at all rather than sending something MusicIP would ignore.
sub activeExpression {
	my $client = shift;
	my $search = savedSearch($client) or return undef;
	return undef if hostCapability() ne 'ok';
	return buildExpression($search);
}

# EVERYTHING THAT IS NOT A PLAIN ASCII LETTER OR DIGIT IS ESCAPED, as UTF-8.
#
# ⛔ uri_escape_utf8, NEVER plain uri_escape. Plain uri_escape DIES on any character above 255 - a
# curly quote off a phone keyboard is enough - and the whole page request dies with it, answering
# nothing at all. Measured in the server log: "Can't escape \x{201C}".
#
# ⛔ AND NEVER A GUARD THAT ONLY ENCODES WHEN PERL SAYS THE STRING IS UTF-8. A character between
# 128 and 255, such as the o-umlaut in Bjork, is often held without that flag, so a guarded version
# escaped it as a single Latin-1 byte and MusicIP - whose API is UTF-8 and has no encoding setting
# at all - would never match it. uri_escape_utf8 encodes unconditionally, which is correct here.
sub escapeExpression {
	my $expr = shift;
	return URI::Escape::uri_escape_utf8($expr, "^A-Za-z0-9\\-\\._~");
}

sub mipBase {
	return 'http://' . ($prefs->get('miphosturl') || 'localhost') . ':' . ($prefs->get('sugarport') || '10002');
}

# ---------------------------------------------------------------------------------------------
# The two questions asked of MusicIP
# ---------------------------------------------------------------------------------------------

my $capAnswer = '';
my $capFor    = '';
my $capAt     = 0;

# How long a 'none' answer is trusted, in seconds. 'ok' and 'headless' are facts about the host and
# are kept for as long as the host and port do not change; 'none' only means MusicIP did not answer
# this second, and the 04:00 script restarts the container - so it must expire, or a restart leaves
# Power Search switched off until the page is next opened.
use constant CAP_NONE_TTL => 60;

# CAN THIS HOST POWER SEARCH AT ALL. A nonsense expression: a mixer host answers 200 with nothing,
# a server host answers 400 'No such filter'. It must NOT be asked on /api/mix - there a server host
# quietly collapses the result to one track instead of erroring, which no reply can be tested for.
#
# Cached against the host and port it was measured on, so changing either asks again. Refreshed
# whenever the page is opened, which is the only place the answer changes anything the user sees.
sub hostCapability {
	my $force = shift;

	my $key = mipBase();
	if (!$force && $capFor eq $key && $capAnswer ne '') {
		return $capAnswer if $capAnswer ne 'none';
		return $capAnswer if (time() - $capAt) < CAP_NONE_TTL;
	}

	my $ua = LWP::UserAgent->new();
	$ua->timeout(PS_TIMEOUT);
	my $r = $ua->get($key . '/api/songs?filter=' . escapeExpression('?(artist contains "zzzqqqxnotreal")'));

	my $answer = 'none';
	if ($r && ($r->header('Client-Warning') || '') !~ /Internal response/) {
		if    ($r->code == 200) { $answer = 'ok' }
		elsif ($r->code == 400) { $answer = 'headless' }
	}

	$capFor = $key;
	$capAnswer = $answer;
	$capAt = time();
	$log->debug("Power Search host capability for $key: $answer\n");
	return $answer;
}

sub forgetCapability { $capAnswer = ''; $capFor = ''; $capAt = 0; }

# HOW MANY TRACKS DOES THIS LEAVE. Ask for the minimum and count what comes back: short means too
# narrow. A mix is used rather than a song list because a song list means fetching every path -
# 11MB on a loose search. Nothing matching at all answers HTTP 500, which is the only loud failure.
sub yieldTest {
	my ($expr, $min) = @_;

	my $ua = LWP::UserAgent->new();
	$ua->timeout(PS_TIMEOUT);
	my $r = $ua->get(mipBase() . '/api/mix?&sizetype=tracks&size=' . $min . '&filter=' . escapeExpression($expr));

	return (undef, 'noanswer') unless $r && ($r->header('Client-Warning') || '') !~ /Internal response/;
	return (0, 'ok') if $r->code == 500;
	return (undef, 'noanswer') unless $r->is_success;

	my @lines = grep { /\S/ } split(/\n/, $r->content);
	return (scalar @lines, 'ok');
}

1;
