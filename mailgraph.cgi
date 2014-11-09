#!/usr/bin/perl -w

# mailgraph -- postfix mail traffic statistics
# copyright (c) 2000-2007 ETH Zurich
# copyright (c) 2000-2007 David Schweikert <david@schweikert.ch>
# released under the GNU General Public License

use RRDs;
use POSIX qw(uname);

my $VERSION = "1.15+g+d";

my $host = (POSIX::uname())[1];
my $scriptname = 'mailgraph.cgi';
my $xpoints = 540;
my $points_per_sample = 3;
my $ypoints = 160;
my $ypoints_err = 96;
my $ypoints_grey = 96;
my $ypoints_dane = 96;
my $rrd = '/var/lib/mailgraph/mailgraph.rrd'; # path to where the RRD database is
my $rrd_virus = '/var/lib/mailgraph/mailgraph_virus.rrd'; # path to where the Virus RRD database is
my $rrd_greylist = '/var/lib/mailgraph/mailgraph_greylist.rrd'; # path to where the Greylist RRD database is
my $rrd_dane = '/var/lib/mailgraph/mailgraph_dane.rrd'; # path to where the DANE RRD database is
my $tmp_dir = '/var/lib/mailgraph'; # temporary directory where to store the images

# note: the following ranges must match with the RRA ranges
# created in mailgraph.pl, otherwise the totals won't match.
my @graphs = (
	{ title => 'Last Day',   seconds => 3600*24,        },
	{ title => 'Last Week',  seconds => 3600*24*7,      },
	{ title => 'Last Month', seconds => 3600*24*7*5,     },
	{ title => 'Last Year',  seconds => 3600*24*7*5*12, },
);

my %color = (
	sent		=> '000099', # rrggbb in hex
	received	=> '009900',
	rejected	=> 'AA0000',
	bounced		=> '000000',
	virus		=> 'DDBB00',
	spam		=> '999999',
	greylisted	=> '999999',
	delayed		=> '006400',
	anonymoustls	=> '000099',
	trustedtls	=> '009900',
	untrustedtls	=> 'AA0000',
	verifiedtls	=> '000000',
);

sub rrd_graph(@)
{
	my ($range, $file, $ypoints, @rrdargs) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	# choose carefully the end otherwise rrd will maybe pick the wrong RRA:
	my $end  = time; $end -= $end % $step;
	my $date = localtime(time);
	$date =~ s|:|\\:|g unless $RRDs::VERSION < 1.199908;

	my ($graphret,$xs,$ys) = RRDs::graph($file,
		'--imgformat', 'PNG',
		'--width', $xpoints,
		'--height', $ypoints,
		'--start', "-$range",
		'--end', $end,
		'--vertical-label', 'msgs/min',
		'--lower-limit', 0,
		'--units-exponent', 0, # don't show milli-messages/s
		'--lazy',
		'--color', 'SHADEA#ffffff',
		'--color', 'SHADEB#ffffff',
		'--color', 'BACK#ffffff',

		$RRDs::VERSION < 1.2002 ? () : ( '--slope-mode'),

		@rrdargs,

		'COMMENT:['.$date.']\r',
	);

	my $ERR=RRDs::error;
	die "ERROR: $ERR\n" if $ERR;
}

sub graph($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints,
		"DEF:sent=$rrd:sent:AVERAGE",
		"DEF:msent=$rrd:sent:MAX",
		"CDEF:rsent=sent,60,*",
		"CDEF:rmsent=msent,60,*",
		"CDEF:dsent=sent,UN,0,sent,IF,$step,*",
		"CDEF:ssent=PREV,UN,dsent,PREV,IF,dsent,+",
		"AREA:rsent#$color{sent}:Sent    ",
		'GPRINT:ssent:MAX:total\: %8.0lf msgs',
		'GPRINT:rsent:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmsent:MAX:max\: %4.0lf msgs/min\l',

		"DEF:recv=$rrd:recv:AVERAGE",
		"DEF:mrecv=$rrd:recv:MAX",
		"CDEF:rrecv=recv,60,*",
		"CDEF:rmrecv=mrecv,60,*",
		"CDEF:drecv=recv,UN,0,recv,IF,$step,*",
		"CDEF:srecv=PREV,UN,drecv,PREV,IF,drecv,+",
		"LINE2:rrecv#$color{received}:Received",
		'GPRINT:srecv:MAX:total\: %8.0lf msgs',
		'GPRINT:rrecv:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmrecv:MAX:max\: %4.0lf msgs/min\l',
	);
}

sub graph_err($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints_err,
		"DEF:bounced=$rrd:bounced:AVERAGE",
		"DEF:mbounced=$rrd:bounced:MAX",
		"CDEF:rbounced=bounced,60,*",
		"CDEF:dbounced=bounced,UN,0,bounced,IF,$step,*",
		"CDEF:sbounced=PREV,UN,dbounced,PREV,IF,dbounced,+",
		"CDEF:rmbounced=mbounced,60,*",
		"AREA:rbounced#$color{bounced}:Bounced ",
		'GPRINT:sbounced:MAX:total\: %8.0lf msgs',
		'GPRINT:rbounced:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmbounced:MAX:max\: %4.0lf msgs/min\l',

		"DEF:virus=$rrd_virus:virus:AVERAGE",
		"DEF:mvirus=$rrd_virus:virus:MAX",
		"CDEF:rvirus=virus,60,*",
		"CDEF:dvirus=virus,UN,0,virus,IF,$step,*",
		"CDEF:svirus=PREV,UN,dvirus,PREV,IF,dvirus,+",
		"CDEF:rmvirus=mvirus,60,*",
		"STACK:rvirus#$color{virus}:Viruses ",
		'GPRINT:svirus:MAX:total\: %8.0lf msgs',
		'GPRINT:rvirus:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmvirus:MAX:max\: %4.0lf msgs/min\l',

		"DEF:spam=$rrd_virus:spam:AVERAGE",
		"DEF:mspam=$rrd_virus:spam:MAX",
		"CDEF:rspam=spam,60,*",
		"CDEF:dspam=spam,UN,0,spam,IF,$step,*",
		"CDEF:sspam=PREV,UN,dspam,PREV,IF,dspam,+",
		"CDEF:rmspam=mspam,60,*",
		"STACK:rspam#$color{spam}:Spam    ",
		'GPRINT:sspam:MAX:total\: %8.0lf msgs',
		'GPRINT:rspam:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmspam:MAX:max\: %4.0lf msgs/min\l',

		"DEF:rejected=$rrd:rejected:AVERAGE",
		"DEF:mrejected=$rrd:rejected:MAX",
		"CDEF:rrejected=rejected,60,*",
		"CDEF:drejected=rejected,UN,0,rejected,IF,$step,*",
		"CDEF:srejected=PREV,UN,drejected,PREV,IF,drejected,+",
		"CDEF:rmrejected=mrejected,60,*",
		"LINE2:rrejected#$color{rejected}:Rejected",
		'GPRINT:srejected:MAX:total\: %8.0lf msgs',
		'GPRINT:rrejected:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmrejected:MAX:max\: %4.0lf msgs/min\l',

	);
}

sub graph_grey($$)
{
        my ($range, $file) = @_;
        my $step = $range*$points_per_sample/$xpoints;
        rrd_graph($range, $file, $ypoints_grey,
                "DEF:greylisted=$rrd_greylist:greylisted:AVERAGE",
                "DEF:mgreylisted=$rrd_greylist:greylisted:MAX",
                "CDEF:rgreylisted=greylisted,60,*",
                "CDEF:dgreylisted=greylisted,UN,0,greylisted,IF,$step,*",
                "CDEF:sgreylisted=PREV,UN,dgreylisted,PREV,IF,dgreylisted,+",
                "CDEF:rmgreylisted=mgreylisted,60,*",
                "AREA:rgreylisted#$color{greylisted}:Greylisted",
                'GPRINT:sgreylisted:MAX:total\: %8.0lf msgs',
                'GPRINT:rgreylisted:AVERAGE:avg\: %5.2lf msgs/min',
                'GPRINT:rmgreylisted:MAX:max\: %4.0lf msgs/min\l',

                "DEF:delayed=$rrd_greylist:delayed:AVERAGE",
                "DEF:mdelayed=$rrd_greylist:delayed:MAX",
                "CDEF:rdelayed=delayed,60,*",
                "CDEF:ddelayed=delayed,UN,0,delayed,IF,$step,*",
                "CDEF:sdelayed=PREV,UN,ddelayed,PREV,IF,ddelayed,+",
                "CDEF:rmdelayed=mdelayed,60,*",
                "LINE2:rdelayed#$color{delayed}:Delayed   ",
                'GPRINT:sdelayed:MAX:total\: %8.0lf msgs',
                'GPRINT:rdelayed:AVERAGE:avg\: %5.2lf msgs/min',
                'GPRINT:rmdelayed:MAX:max\: %4.0lf msgs/min\l',
        );
}

sub graph_dane($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints_dane,
		"DEF:anonymoustls=$rrd_dane:anonymoustls:AVERAGE",
		"DEF:manonymoustls=$rrd_dane:anonymoustls:MAX",
		"CDEF:ranonymoustls=anonymoustls,60,*",
		"CDEF:danonymoustls=anonymoustls,UN,0,anonymoustls,IF,$step,*",
		"CDEF:sanonymoustls=PREV,UN,danonymoustls,PREV,IF,danonymoustls,+",
		"CDEF:rmanonymoustls=manonymoustls,60,*",
		"AREA:ranonymoustls#$color{anonymoustls}:Out Anonymous TLS",
		'GPRINT:sanonymoustls:MAX:total\: %8.0lf msgs',
		'GPRINT:ranonymoustls:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmanonymoustls:MAX:max\: %4.0lf msgs/min\l',

		"DEF:trustedtls=$rrd_dane:trustedtls:AVERAGE",
		"DEF:mtrustedtls=$rrd_dane:trustedtls:MAX",
		"CDEF:rtrustedtls=trustedtls,60,*",
		"CDEF:dtrustedtls=trustedtls,UN,0,trustedtls,IF,$step,*",
		"CDEF:strustedtls=PREV,UN,dtrustedtls,PREV,IF,dtrustedtls,+",
		"CDEF:rmtrustedtls=mtrustedtls,60,*",
		"STACK:rtrustedtls#$color{trustedtls}:Out Trusted TLS  ",
		'GPRINT:strustedtls:MAX:total\: %8.0lf msgs',
		'GPRINT:rtrustedtls:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmtrustedtls:MAX:max\: %4.0lf msgs/min\l',
		
		"DEF:untrustedtls=$rrd_dane:untrustedtls:AVERAGE",
		"DEF:muntrustedtls=$rrd_dane:untrustedtls:MAX",
		"CDEF:runtrustedtls=untrustedtls,60,*",
		"CDEF:duntrustedtls=untrustedtls,UN,0,untrustedtls,IF,$step,*",
		"CDEF:suntrustedtls=PREV,UN,duntrustedtls,PREV,IF,duntrustedtls,+",
		"CDEF:rmuntrustedtls=muntrustedtls,60,*",
		"STACK:runtrustedtls#$color{untrustedtls}:Out Untrusted TLS",
		'GPRINT:suntrustedtls:MAX:total\: %8.0lf msgs',
		'GPRINT:runtrustedtls:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmuntrustedtls:MAX:max\: %4.0lf msgs/min\l',
		
		"DEF:verifiedtls=$rrd_dane:verifiedtls:AVERAGE",
		"DEF:mverifiedtls=$rrd_dane:verifiedtls:MAX",
		"CDEF:rverifiedtls=verifiedtls,60,*",
		"CDEF:dverifiedtls=verifiedtls,UN,0,verifiedtls,IF,$step,*",
		"CDEF:sverifiedtls=PREV,UN,dverifiedtls,PREV,IF,dverifiedtls,+",
		"CDEF:rmverifiedtls=mverifiedtls,60,*",
		"LINE2:rverifiedtls#$color{verifiedtls}:Out Verified TLS ",
		'GPRINT:sverifiedtls:MAX:total\: %8.0lf msgs',
		'GPRINT:rverifiedtls:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmverifiedtls:MAX:max\: %4.0lf msgs/min\l',
	);
}

sub print_html()
{
	print "Content-Type: text/html\n\n";

	print <<HEADER;
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<title>Mail statistics for $host</title>
<meta http-equiv="Refresh" content="300" />
<meta http-equiv="Pragma" content="no-cache" />
<link rel="stylesheet" href="/mailgraph.css" type="text/css" />
</head>
<body>
HEADER

	print "<h1>Mail statistics for $host</h1>\n";

	print "<ul id=\"jump\">\n";
	for my $n (0..$#graphs) {
		print "  <li><a href=\"#G$n\">$graphs[$n]{title}</a>&nbsp;</li>\n";
	}
	print "</ul>\n";

	for my $n (0..$#graphs) {
		print "<h2 id=\"G$n\">$graphs[$n]{title}</h2>\n";
		print "<p><img src=\"$scriptname?${n}-n\" alt=\"mailgraph\"/><br/>\n";
		print "<img src=\"$scriptname?${n}-e\" alt=\"mailgraph\"/></p>\n";
		print "<img src=\"$scriptname?${n}-g\" alt=\"mailgraph\"/></p>\n";
		print "<img src=\"$scriptname?${n}-d\" alt=\"mailgraph\"/></p>\n";
	}

	print <<FOOTER;
<hr/>
<table><tr><td>
<a href="http://mailgraph.schweikert.ch/">Mailgraph</a> $VERSION
by <a href="http://david.schweikert.ch/">David Schweikert</a></td>
<td align="right">
<a href="http://oss.oetiker.ch/rrdtool/"><img src="http://oss.oetiker.ch/rrdtool/.pics/rrdtool.gif" alt="" width="120" height="34"/></a>
</td></tr></table>
</body></html>
FOOTER
}

sub send_image($)
{
	my ($file)= @_;

	-r $file or do {
		print "Content-type: text/plain\n\nERROR: can't find $file\n";
		exit 1;
	};

	print "Content-type: image/png\n";
	print "Content-length: ".((stat($file))[7])."\n";
	print "\n";
	open(IMG, $file) or die;
	my $data;
	print $data while read(IMG, $data, 16384)>0;
}

sub main()
{
	my $uri = $ENV{REQUEST_URI} || '';
	$uri =~ s/\/[^\/]+$//;
	$uri =~ s/\//,/g;
	$uri =~ s/(\~|\%7E)/tilde,/g;
	mkdir $tmp_dir, 0777 unless -d $tmp_dir;
	mkdir "$tmp_dir/$uri", 0777 unless -d "$tmp_dir/$uri";

	my $img = $ENV{QUERY_STRING};
	if(defined $img and $img =~ /\S/) {
		if($img =~ /^(\d+)-n$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1.png";
			graph($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		elsif($img =~ /^(\d+)-g$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1_grey.png";
			graph_grey($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		elsif($img =~ /^(\d+)-e$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1_err.png";
			graph_err($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		elsif($img =~ /^(\d+)-d$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1_dane.png";
			graph_dane($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		else {
			die "ERROR: invalid argument\n";
		}
	}
	else {
		print_html;
	}
}

main;
