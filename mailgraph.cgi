#!/usr/bin/perl -w

# mailgraph -- postfix mail traffic statistics
# copyright (c) 2000-2007 ETH Zurich
# copyright (c) 2000-2007 David Schweikert <david@schweikert.ch>
# released under the GNU General Public License
# with dkim-, dmarc, spf-patch Sebastian van de Meer <kernel-error@kernel-error.de>

use RRDs;
use POSIX qw(uname);

my $VERSION = "1.14";

my $host = (POSIX::uname())[1];
my $scriptname = 'mailgraph.cgi';
my $xpoints = 540;
my $points_per_sample = 3;
my $ypoints = 160;
my $ypoints_spf = 96;
my $ypoints_dmarc = 96;
my $ypoints_err = 96;
my $ypoints_dkim = 96;
my $rrd = 'mailgraph.rrd'; # path to where the RRD database is
my $rrd_virus = 'mailgraph_virus.rrd'; # path to where the Virus RRD database is
my $tmp_dir = '/tmp/mailgraph'; # temporary directory where to store the images

# note: the following ranges must match with the RRA ranges
# created in mailgraph.pl, otherwise the totals won't match.
my @graphs = (
	{ title => 'Last Day',   seconds => 3600*24,        },
	{ title => 'Last Week',  seconds => 3600*24*7,      },
	{ title => 'Last Month', seconds => 3600*24*7*5,     },
	{ title => 'Last Year',  seconds => 3600*24*7*5*12, },
);

my %color = (
	sent     => '000099', # rrggbb in hex
	received => '009900',
	rejected => 'AA0000',
	spfnone    => '000AAA',
	spffail    => '12FF0A',
	spfpass    => 'D15400',
	dmarcnone  => 'FFFF00',
	dmarcfail  => 'FF00EA',
	dmarcpass  => '00FFD5',
	dkimnone   => '3013EC',
	dkimfail   => '006B3A',
	dkimpass   => '491503', 
	bounced  => '000000',
	virus    => 'DDBB00',
	spam     => '999999',
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

sub graph_spf($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints_spf,
		"DEF:spfpass=$rrd:spfpass:AVERAGE",
		"DEF:mspfpass=$rrd:spfpass:MAX",
		"CDEF:rspfpass=spfpass,60,*",
		"CDEF:dspfpass=spfpass,UN,0,spfpass,IF,$step,*",
		"CDEF:sspfpass=PREV,UN,dspfpass,PREV,IF,dspfpass,+",
		"CDEF:rmspfpass=mspfpass,60,*",
		"AREA:rspfpass#$color{spfpass}:SPF pass",
		'GPRINT:sspfpass:MAX:total\: %8.0lf msgs',
		'GPRINT:rspfpass:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmspfpass:MAX:max\: %4.0lf msgs/min\l',
	
		"DEF:spfnone=$rrd:spfnone:AVERAGE",
		"DEF:mspfnone=$rrd:spfnone:MAX",
		"CDEF:rspfnone=spfnone,60,*",
		"CDEF:dspfnone=spfnone,UN,0,spfnone,IF,$step,*",
		"CDEF:sspfnone=PREV,UN,dspfnone,PREV,IF,dspfnone,+",
		"CDEF:rmspfnone=mspfnone,60,*",
		"STACK:rspfnone#$color{spfnone}:SPF none",
		'GPRINT:sspfnone:MAX:total\: %8.0lf msgs',
		'GPRINT:rspfnone:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmspfnone:MAX:max\: %4.0lf msgs/min\l',

		"DEF:spffail=$rrd:spffail:AVERAGE",
		"DEF:mspffail=$rrd:spffail:MAX",
		"CDEF:rspffail=spffail,60,*",
		"CDEF:dspffail=spffail,UN,0,spffail,IF,$step,*",
		"CDEF:sspffail=PREV,UN,dspffail,PREV,IF,dspffail,+",
		"CDEF:rmspffail=mspffail,60,*",
		"LINE2:rspffail#$color{spffail}:SPF fail",
		'GPRINT:sspffail:MAX:total\: %8.0lf msgs',
		'GPRINT:rspffail:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmspffail:MAX:max\: %4.0lf msgs/min\l',
	);
}

sub graph_dmarc($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints_dmarc,
		"DEF:dmarcpass=$rrd:dmarcpass:AVERAGE",
		"DEF:mdmarcpass=$rrd:dmarcpass:MAX",
		"CDEF:rdmarcpass=dmarcpass,60,*",
		"CDEF:ddmarcpass=dmarcpass,UN,0,dmarcpass,IF,$step,*",
		"CDEF:sdmarcpass=PREV,UN,ddmarcpass,PREV,IF,ddmarcpass,+",
		"CDEF:rmdmarcpass=mdmarcpass,60,*",
		"AREA:rdmarcpass#$color{dmarcpass}:DMARC pass",
		'GPRINT:sdmarcpass:MAX:total\: %8.0lf msgs',
		'GPRINT:rdmarcpass:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdmarcpass:MAX:max\: %4.0lf msgs/min\l',
		
		"DEF:dmarcnone=$rrd:dmarcnone:AVERAGE",
		"DEF:mdmarcnone=$rrd:dmarcnone:MAX",
		"CDEF:rdmarcnone=dmarcnone,60,*",
		"CDEF:ddmarcnone=dmarcnone,UN,0,dmarcnone,IF,$step,*",
		"CDEF:sdmarcnone=PREV,UN,ddmarcnone,PREV,IF,ddmarcnone,+",
		"CDEF:rmdmarcnone=mdmarcnone,60,*",
		"STACK:rdmarcnone#$color{dmarcnone}:DMARC none",
		'GPRINT:sdmarcnone:MAX:total\: %8.0lf msgs',
		'GPRINT:rdmarcnone:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdmarcnone:MAX:max\: %4.0lf msgs/min\l',

		"DEF:dmarcfail=$rrd:dmarcfail:AVERAGE",
		"DEF:mdmarcfail=$rrd:dmarcfail:MAX",
		"CDEF:rdmarcfail=dmarcfail,60,*",
		"CDEF:ddmarcfail=dmarcfail,UN,0,dmarcfail,IF,$step,*",
		"CDEF:sdmarcfail=PREV,UN,ddmarcfail,PREV,IF,ddmarcfail,+",
		"CDEF:rmdmarcfail=mdmarcfail,60,*",
		"LINE2:rdmarcfail#$color{dmarcfail}:DMARC fail",
		'GPRINT:sdmarcfail:MAX:total\: %8.0lf msgs',
		'GPRINT:rdmarcfail:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdmarcfail:MAX:max\: %4.0lf msgs/min\l',
	);
}

sub graph_dkim($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints_dkim,
		"DEF:dkimpass=$rrd:dkimpass:AVERAGE",
		"DEF:mdkimpass=$rrd:dkimpass:MAX",
		"CDEF:rdkimpass=dkimpass,60,*",
		"CDEF:ddkimpass=dkimpass,UN,0,dkimpass,IF,$step,*",
		"CDEF:sdkimpass=PREV,UN,ddkimpass,PREV,IF,ddkimpass,+",
		"CDEF:rmdkimpass=mdkimpass,60,*",
		"AREA:rdkimpass#$color{dkimpass}:DKIM pass",
		'GPRINT:sdkimpass:MAX:total\: %8.0lf msgs',
		'GPRINT:rdkimpass:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdkimpass:MAX:max\: %4.0lf msgs/min\l',
		
		"DEF:dkimnone=$rrd:dkimnone:AVERAGE",
		"DEF:mdkimnone=$rrd:dkimnone:MAX",
		"CDEF:rdkimnone=dkimnone,60,*",
		"CDEF:ddkimnone=dkimnone,UN,0,dkimnone,IF,$step,*",
		"CDEF:sdkimnone=PREV,UN,ddkimnone,PREV,IF,ddkimnone,+",
		"CDEF:rmdkimnone=mdkimnone,60,*",
		"STACK:rdkimnone#$color{dkimnone}:DKIM none",
		'GPRINT:sdkimnone:MAX:total\: %8.0lf msgs',
		'GPRINT:rdkimnone:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdkimnone:MAX:max\: %4.0lf msgs/min\l',

		"DEF:dkimfail=$rrd:dkimfail:AVERAGE",
		"DEF:mdkimfail=$rrd:dkimfail:MAX",
		"CDEF:rdkimfail=dkimfail,60,*",
		"CDEF:ddkimfail=dkimfail,UN,0,dkimfail,IF,$step,*",
		"CDEF:sdkimfail=PREV,UN,ddkimfail,PREV,IF,ddkimfail,+",
		"CDEF:rmdkimfail=mdkimfail,60,*",
		"LINE2:rdkimfail#$color{dkimfail}:DKIM fail",
		'GPRINT:sdkimfail:MAX:total\: %8.0lf msgs',
		'GPRINT:rdkimfail:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdkimfail:MAX:max\: %4.0lf msgs/min\l',
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
<link rel="stylesheet" href="mailgraph.css" type="text/css" />
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
		print "<img src=\"$scriptname?${n}-s\" alt=\"mailgraph\"/></p>\n";
		print "<img src=\"$scriptname?${n}-d\" alt=\"mailgraph\"/></p>\n";
		print "<img src=\"$scriptname?${n}-k\" alt=\"mailgraph\"/></p>\n";
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

	print "Content-type: image/png\n" unless $ARGV[0];
	print "Content-length: ".((stat($file))[7])."\n" unless $ARGV[0];
	print "\n" unless $ARGV[0];
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

	my $img = $ARGV[0] || $ENV{QUERY_STRING};
	if(defined $img and $img =~ /\S/) {
		if($img =~ /^(\d+)-n$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1.png";
			graph($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		elsif($img =~ /^(\d+)-e$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1_err.png";
			graph_err($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		elsif($img =~ /^(\d+)-s$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1_spf.png";
			graph_spf($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		elsif($img =~ /^(\d+)-d$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1_dmarc.png";
			graph_dmarc($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		elsif($img =~ /^(\d+)-k$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1_dkim.png";
			graph_dkim($graphs[$1]{seconds}, $file);
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
