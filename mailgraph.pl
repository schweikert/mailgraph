#!/usr/bin/perl -w

# mailgraph -- an rrdtool frontend for mail statistics
# copyright (c) 2000-2007 ETH Zurich
# copyright (c) 2000-2007 David Schweikert <david@schweikert.ch>
# released under the GNU General Public License

## EMBED(/home/dws/checkouts/dws/sw/Parse-Syslog/lib/Parse/Syslog.pm)

#####################################################################
#####################################################################
#####################################################################

use RRDs;

use strict;
use File::Tail;
use Getopt::Long;
use POSIX 'setsid';
use Parse::Syslog;

my $VERSION = "1.15+g+d";

# config
my $rrdstep = 60;
my $xpoints = 540;
my $points_per_sample = 3;

my $daemon_logfile = '/var/log/mailgraph.log';
my $daemon_pidfile = '/var/run/mailgraph.pid';
my $daemon_rrd_dir = '/var/log';

# global variables
my $logfile;
my $rrd = "mailgraph.rrd";
my $rrd_virus = "mailgraph_virus.rrd";
my $rrd_greylist = "mailgraph_greylist.rrd";
my $rrd_dane = "mailgraph_dane.rrd";
my $year;
my $this_minute;
my %sum = ( sent => 0, received => 0, bounced => 0, rejected => 0, virus => 0, spam => 0, greylisted => 0, delayed => 0, anonymoustls => 0, trustedtls => 0, untrustedtls => 0, verifiedtls => 0, anonymoustlsin => 0, trustedtlsin => 0, untrustedtlsin => 0, verifiedtlsin => 0 );
my $rrd_inited=0;

my %opt = ();

# prototypes
sub daemonize();
sub process_line($);
sub event_sent($);
sub event_received($);
sub event_bounced($);
sub event_rejected($);
sub event_virus($);
sub event_spam($);
sub event_greylisted($);
sub event_delayed($);
sub event_anonymoustls($);
sub event_trustedtls($);
sub event_untrustedtls($);
sub event_verifiedtls($);
sub event_anonymoustlsin($);
sub event_trustedtlsin($);
sub event_untrustedtlsin($);
sub event_verifiedtlsin($);
sub init_rrd($);
sub update($);

sub usage
{
	print "usage: mailgraph [*options*]\n\n";
	print "  -h, --help         display this help and exit\n";
	print "  -v, --verbose      be verbose about what you do\n";
	print "  -V, --version      output version information and exit\n";
	print "  -c, --cat          causes the logfile to be only read and not monitored\n";
	print "  -l, --logfile f    monitor logfile f instead of /var/log/syslog\n";
	print "  -t, --logtype t    set logfile's type (default: syslog)\n";
	print "  -y, --year         starting year of the log file (default: current year)\n";
	print "      --host=HOST    use only entries for HOST (regexp) in syslog\n";
	print "  -d, --daemon       start in the background\n";
	print "  --daemon-pid=FILE  write PID to FILE instead of /var/run/mailgraph.pid\n";
	print "  --daemon-rrd=DIR   write RRDs to DIR instead of /var/log\n";
	print "  --daemon-log=FILE  write verbose-log to FILE instead of /var/log/mailgraph.log\n";
	print "  --ignore-localhost ignore mail to/from localhost (used for virus scanner)\n";
	print "  --ignore-host=HOST ignore mail to/from HOST regexp (used for virus scanner)\n";
	print "  --no-mail-rrd      no update mail rrd\n";
	print "  --no-virus-rrd     no update virus rrd\n";
	print "  --no-greylist-rrd  no update greylist rrd\n";
	print "  --no-dane-rrd  no update dane rrd\n";
	print "  --rrd-name=NAME    use NAME.rrd and NAME_virus.rrd for the rrd files\n";
	print "  --lmtp-is-smtp     treat LMTP as SMTP\n";
	print "  --rbl-is-spam      count rbl rejects as spam\n";
	print "  --virbl-is-virus   count virbl rejects as viruses\n";

	exit;
}

sub main
{
	Getopt::Long::Configure('no_ignore_case');
	GetOptions(\%opt, 'help|h', 'cat|c', 'logfile|l=s', 'logtype|t=s', 'version|V',
		'year|y=i', 'host=s', 'verbose|v', 'daemon|d!',
		'daemon_pid|daemon-pid=s', 'daemon_rrd|daemon-rrd=s',
		'daemon_log|daemon-log=s', 'ignore-localhost!', 'ignore-host=s@',
		'no-mail-rrd', 'no-virus-rrd', 'no-greylist-rrd', 'no-dane-rrd', 'rrd_name|rrd-name=s',
		'lmtp-is-smtp', 'rbl-is-spam', 'virbl-is-virus'
		) or exit(1);
	usage if $opt{help};

	if($opt{version}) {
		print "mailgraph $VERSION by david\@schweikert.ch\n";
		exit;
	}

	$daemon_pidfile = $opt{daemon_pid} if defined $opt{daemon_pid};
	$daemon_logfile = $opt{daemon_log} if defined $opt{daemon_log};
	$daemon_rrd_dir = $opt{daemon_rrd} if defined $opt{daemon_rrd};
	$rrd		= $opt{rrd_name}.".rrd" if defined $opt{rrd_name};
	$rrd_virus	= $opt{rrd_name}."_virus.rrd" if defined $opt{rrd_name};
	$rrd_greylist	= $opt{rrd_name}."_greylist.rrd" if defined $opt{rrd_name};
	$rrd_dane	= $opt{rrd_name}."_dane.rrd" if defined $opt{rrd_name};

	# compile --ignore-host regexps
	if(defined $opt{'ignore-host'}) {
		for my $ih (@{$opt{'ignore-host'}}) {
			push @{$opt{'ignore-host-re'}}, qr{\brelay=[^\s,]*$ih}i;
		}
	}

	if($opt{daemon} or $opt{daemon_rrd}) {
		chdir $daemon_rrd_dir or die "mailgraph: can't chdir to $daemon_rrd_dir: $!";
		-w $daemon_rrd_dir or die "mailgraph: can't write to $daemon_rrd_dir\n";
	}

	daemonize if $opt{daemon};

	my $logfile = defined $opt{logfile} ? $opt{logfile} : '/var/log/syslog';
	my $file;
	if($opt{cat}) {
		$file = $logfile;
	}
	else {
		$file = File::Tail->new(name=>$logfile, tail=>-1);
	}
	my $parser = new Parse::Syslog($file, year => $opt{year}, arrayref => 1,
		type => defined $opt{logtype} ? $opt{logtype} : 'syslog');

	if(not defined $opt{host}) {
		while(my $sl = $parser->next) {
			process_line($sl);
		}
	}
	else {
		my $host = qr/^$opt{host}$/i;
		while(my $sl = $parser->next) {
			process_line($sl) if $sl->[1] =~ $host;
		}
	}
}

sub daemonize()
{
	open STDIN, '/dev/null' or die "mailgraph: can't read /dev/null: $!";
	if($opt{verbose}) {
		open STDOUT, ">>$daemon_logfile"
			or die "mailgraph: can't write to $daemon_logfile: $!";
	}
	else {
		open STDOUT, '>/dev/null'
			or die "mailgraph: can't write to /dev/null: $!";
	}
	defined(my $pid = fork) or die "mailgraph: can't fork: $!";
	if($pid) {
		# parent
		open PIDFILE, ">$daemon_pidfile"
			or die "mailgraph: can't write to $daemon_pidfile: $!\n";
		print PIDFILE "$pid\n";
		close(PIDFILE);
		exit;
	}
	# child
	setsid			or die "mailgraph: can't start a new session: $!";
	open STDERR, '>&STDOUT' or die "mailgraph: can't dup stdout: $!";
}

sub init_rrd($)
{
	my $m = shift;
	my $rows = $xpoints/$points_per_sample;
	my $realrows = int($rows*1.1); # ensure that the full range is covered
	my $day_steps = int(3600*24 / ($rrdstep*$rows));
	# use multiples, otherwise rrdtool could choose the wrong RRA
	my $week_steps = $day_steps*7;
	my $month_steps = $week_steps*5;
	my $year_steps = $month_steps*12;

	# mail rrd
	if(! -f $rrd and ! $opt{'no-mail-rrd'}) {
		RRDs::create($rrd, '--start', $m, '--step', $rrdstep,
				'DS:sent:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:recv:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:bounced:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:rejected:ABSOLUTE:'.($rrdstep*2).':0:U',
				"RRA:AVERAGE:0.5:$day_steps:$realrows",   # day
				"RRA:AVERAGE:0.5:$week_steps:$realrows",  # week
				"RRA:AVERAGE:0.5:$month_steps:$realrows", # month
				"RRA:AVERAGE:0.5:$year_steps:$realrows",  # year
				"RRA:MAX:0.5:$day_steps:$realrows",   # day
				"RRA:MAX:0.5:$week_steps:$realrows",  # week
				"RRA:MAX:0.5:$month_steps:$realrows", # month
				"RRA:MAX:0.5:$year_steps:$realrows",  # year
				);
		$this_minute = $m;
	}
	elsif(-f $rrd) {
		$this_minute = RRDs::last($rrd) + $rrdstep;
	}

	# dane rrd
	if(! -f $rrd_dane and ! $opt{'no-dane-rrd'}) {
		RRDs::create($rrd_dane, '--start', $m, '--step', $rrdstep,
				'DS:anonymoustls:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:trustedtls:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:untrustedtls:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:verifiedtls:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:anonymoustlsin:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:trustedtlsin:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:untrustedtlsin:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:verifiedtlsin:ABSOLUTE:'.($rrdstep*2).':0:U',
				"RRA:AVERAGE:0.5:$day_steps:$realrows",   # day
				"RRA:AVERAGE:0.5:$week_steps:$realrows",  # week
				"RRA:AVERAGE:0.5:$month_steps:$realrows", # month
				"RRA:AVERAGE:0.5:$year_steps:$realrows",  # year
				"RRA:MAX:0.5:$day_steps:$realrows",   # day
				"RRA:MAX:0.5:$week_steps:$realrows",  # week
				"RRA:MAX:0.5:$month_steps:$realrows", # month
				"RRA:MAX:0.5:$year_steps:$realrows",  # year
				);
			$this_minute = $m;
	}
	elsif(-f $rrd_dane and ! defined $rrd_dane) {
		$this_minute = RRDs::last($rrd_dane) + $rrdstep;
	}

	# virus rrd
	if(! -f $rrd_virus and ! $opt{'no-virus-rrd'}) {
		RRDs::create($rrd_virus, '--start', $m, '--step', $rrdstep,
				'DS:virus:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:spam:ABSOLUTE:'.($rrdstep*2).':0:U',
				"RRA:AVERAGE:0.5:$day_steps:$realrows",   # day
				"RRA:AVERAGE:0.5:$week_steps:$realrows",  # week
				"RRA:AVERAGE:0.5:$month_steps:$realrows", # month
				"RRA:AVERAGE:0.5:$year_steps:$realrows",  # year
				"RRA:MAX:0.5:$day_steps:$realrows",   # day
				"RRA:MAX:0.5:$week_steps:$realrows",  # week
				"RRA:MAX:0.5:$month_steps:$realrows", # month
				"RRA:MAX:0.5:$year_steps:$realrows",  # year
				);
	}
	elsif(-f $rrd_virus and ! defined $rrd_virus) {
		$this_minute = RRDs::last($rrd_virus) + $rrdstep;
	}
        # greylist rrd
        if(! -f $rrd_greylist and ! $opt{'no-greylist-rrd'}) {
                        RRDs::create($rrd_greylist, '--start', $m, '--step', $rrdstep,
                                'DS:greylisted:ABSOLUTE:'.($rrdstep*2).':0:U',
                                'DS:delayed:ABSOLUTE:'.($rrdstep*2).':0:U',
                                "RRA:AVERAGE:0.5:$day_steps:$realrows",   # day
                                "RRA:AVERAGE:0.5:$week_steps:$realrows",  # week
                                "RRA:AVERAGE:0.5:$month_steps:$realrows", # month
                                "RRA:AVERAGE:0.5:$year_steps:$realrows",  # year
                                "RRA:MAX:0.5:$day_steps:$realrows",   # day
                                "RRA:MAX:0.5:$week_steps:$realrows",  # week
                                "RRA:MAX:0.5:$month_steps:$realrows", # month
                                "RRA:MAX:0.5:$year_steps:$realrows",  # year
                                );
                $this_minute = $m;
        }
        elsif(-f $rrd_greylist and ! defined $rrd_greylist) {
                $this_minute = RRDs::last($rrd_greylist) + $rrdstep;
        }

	$rrd_inited=1;
}

sub process_line($)
{
	my $sl = shift;
	my $time = $sl->[0];
	my $prog = $sl->[2];
	my $text = $sl->[4];

	if($prog =~ /^postfix\/(.*)/) {
		my $prog = $1;
		if($prog eq 'smtp' or ($opt{'lmtp-is-smtp'} and $prog eq 'lmtp')) {
			if($text =~ /\bstatus=sent\b/) {
				return if $opt{'ignore-localhost'} and
					$text =~ /\brelay=[^\s\[]*\[127\.0\.0\.1\]/;
				if(defined $opt{'ignore-host-re'}) {
					for my $ih (@{$opt{'ignore-host-re'}}) {
						warn "Ignore receiving host! $text\n" if $text =~ $ih;
						return if $text =~ $ih;
					}
				}
				event($time, 'sent');
			}
			elsif($text =~ /\bstatus=bounced\b/) {
				event($time, 'bounced');
			}
			elsif($text =~ /Anonymous TLS connection established to/) {
				event($time, 'anonymoustls');
			}
			elsif($text =~ /Trusted TLS connection established to/) {
				event($time, 'trustedtls');
			}
			elsif($text =~ /Untrusted TLS connection established to/) {
				event($time, 'untrustedtls');
			}
			elsif($text =~ /Verified TLS connection established to/) {
				event($time, 'verifiedtls');
			}
		}
		
		elsif($prog eq 'local') {
			if($text =~ /\bstatus=bounced\b/) {
				event($time, 'bounced');
			}
		}
		elsif($prog eq 'smtpd') {
			if($text =~ /^[0-9A-Za-z]+: client=(\S+)/) {
				my $client = $1;
				return if $opt{'ignore-localhost'} and
					$client =~ /\[127\.0\.0\.1\]$/;
				if(defined $opt{'ignore-host'}) {
					#for my $ih (@{$opt{'ignore-host'}}) {
					#	warn "Ignore sending host! $client\n" if $client =~ /$ih/i;
					#	return if $client =~ /$ih/i;
					#}
					if( grep { $client =~ /$_/i } @{$opt{'ignore-host'}} ) {
						warn "Ignore sending host! $client\n";
						return;
					}
				}
				event($time, 'received');
			}
			elsif($opt{'virbl-is-virus'} and $text =~ /^(?:[0-9A-Za-z]+: |NOQUEUE: )?reject: .*: 554.* blocked using virbl.dnsbl.bit.nl/) {
				event($time, 'virus');
			}
			elsif($opt{'rbl-is-spam'} and $text    =~ /^(?:[0-9A-Za-z]+: |NOQUEUE: )?reject: .*: 554.* blocked using/) {
				event($time, 'spam');
			}
                        elsif($text =~ /Greylisted/) {
                                event($time, 'greylisted');
                        }
			elsif($text =~ /^(?:[0-9A-Za-z]+: |NOQUEUE: )?reject: /) {
				event($time, 'rejected');
			}
			elsif($text =~ /^(?:[0-9A-Za-z]+: |NOQUEUE: )?milter-reject: /) {
				if($text =~ /Blocked by SpamAssassin/) {
					event($time, 'spam');
				}
				else {
					event($time, 'rejected');
				}
			}
			# Note: the log line with TLS info comes first, followed by greylisting, filter etc.
			# Thus we probably count more TLC connections than received/sent mail 
			elsif($text =~ /Anonymous TLS connection established from/) {
				event($time, 'anonymoustlsin');
			}
			elsif($text =~ /Trusted TLS connection established from/) {
				event($time, 'trustedtlsin');
			}
			elsif($text =~ /Untrusted TLS connection established from/) {
				event($time, 'untrustedtlsin');
			}
			elsif($text =~ /Verified TLS connection established from/) {
				event($time, 'verifiedtlsin');
			}
		}
		elsif($prog eq 'error') {
			if($text =~ /\bstatus=bounced\b/) {
				event($time, 'bounced');
			}
		}
		elsif($prog eq 'cleanup') {
			if($text =~ /^[0-9A-Za-z]+: (?:reject|discard): /) {
				event($time, 'rejected');
			}
		}
		elsif($prog eq 'postscreen') {
			if($text =~ /NOQUEUE: reject: RCPT from .* /) {
				if($text =~ /Service unavailable; /) {
					event($time, 'rejected');
				}
				elsif($text =~ /Protocol error; /) {
					event($time, 'rejected');
				}
				elsif($text =~ /too many connections /) {
					event($time, 'rejected');
				}
			}
		}
	}
	elsif($prog eq 'sendmail' or $prog eq 'sm-mta') {
		if($text =~ /\bmailer=(?:local|cyrusv2)\b/ ) {
			event($time, 'received');
		}
                elsif($text =~ /\bmailer=relay\b/) {
                        event($time, 'received');
                }
		elsif($text =~ /\bstat=Sent\b/ &&
		      $text =~ /\bmailer=esmtp\b/) {
			event($time, 'sent');
		}
		elsif($text =~ /\bruleset=check_XS4ALL\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\blost input channel\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\bruleset=check_rcpt\b/ ) {
			event($time, 'rejected');
		}
                elsif($text =~ /\bstat=virus\b/ ) {
                        event($time, 'virus');
                }
		elsif($text =~ /\bruleset=check_relay\b/ ) {
			if (($opt{'virbl-is-virus'}) and ($text =~ /\bivirbl\b/ )) {
				event($time, 'virus');
			} elsif ($opt{'rbl-is-spam'}) {
				event($time, 'spam');
			} else {
				event($time, 'rejected');
			}
		}
		elsif($text =~ /\bsender blocked\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\bsender denied\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\brecipient denied\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\brecipient unknown\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\bUser unknown$/i ) {
			event($time, 'bounced');
		}
		elsif($text =~ /\bMilter:.*\breject=55/ ) {
			event($time, 'rejected');
		}
	}
	elsif($prog eq 'exim') {
		if($text =~ /^[0-9a-zA-Z]{6}-[0-9a-zA-Z]{6}-[0-9a-zA-Z]{2} <= \S+/) {
			event($time, 'received');
		}
		elsif($text =~ /^[0-9a-zA-Z]{6}-[0-9a-zA-Z]{6}-[0-9a-zA-Z]{2} => \S+/) {
			event($time, 'sent');
		}
		elsif($text =~ / rejected because \S+ is in a black list at \S+/) {
			if($opt{'rbl-is-spam'}) {
				event($time, 'spam');
			} else {
				event($time, 'rejected');
			}
		}
		elsif($text =~ / rejected RCPT \S+: (Sender verify failed|Unknown user)/) {
			event($time, 'rejected');
		}
	}
	elsif($prog eq 'amavis' || $prog eq 'amavisd') {
		if(   $text =~ /^\([\w-]+\) (Passed|Blocked) SPAM(?:MY)?\b/) {
			if($text !~ /\btag2=/) { # ignore new per-recipient log entry (2.2.0)
				event($time, 'spam'); # since amavisd-new-2004xxxx
			}
		}
		elsif($text =~ /^\([\w-]+\) (Passed|Not-Delivered)\b.*\bquarantine spam/) {
			event($time, 'spam'); # amavisd-new-20030616 and earlier
		}
		elsif($text =~ /^\([\w-]+\) (Passed |Blocked )?INFECTED\b/) {
			if($text !~ /\btag2=/) {
				event($time, 'virus');# Passed|Blocked inserted since 2004xxxx
			}
		}
		elsif($text =~ /^\([\w-]+\) (Passed |Blocked )?BANNED\b/) {
			if($text !~ /\btag2=/) {
			       event($time, 'virus');
			}
		}
		elsif($text =~ /^Virus found\b/) {
			event($time, 'virus');# AMaViS 0.3.12 and amavisd-0.1
		}
#		elsif($text =~ /^\([\w-]+\) Passed|Blocked BAD-HEADER\b/) {
#		       event($time, 'badh');
#		}
	}
	elsif($prog eq 'vagatefwd') {
		# Vexira antivirus (old)
		if($text =~ /^VIRUS/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'hook') {
		# Vexira antivirus
		if($text =~ /^\*+ Virus\b/) {
			event($time, 'virus');
		}
		# Vexira antispam
		elsif($text =~ /\bcontains spam\b/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'avgatefwd' or $prog eq 'avmailgate.bin') {
		# AntiVir MailGate
		if($text =~ /^Alert!/) {
			event($time, 'virus');
		}
		elsif($text =~ /blocked\.$/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'avcheck') {
		# avcheck
		if($text =~ /^infected/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'spamd') {
		if($text =~ /^(?:spamd: )?identified spam/) {
			event($time, 'spam');
		}
		# ClamAV SpamAssassin-plugin
		elsif($text =~ /(?:result: )?CLAMAV/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'dspam') {
		if($text =~ /spam detected from/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'spamproxyd' or $prog eq 'spampd') {
		if($text =~ /^\s*SPAM/ or $text =~ /^identified spam/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'drweb-postfix') {
		# DrWeb
		if($text =~ /infected/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'BlackHole') {
		if($text =~ /Virus/) {
			event($time, 'virus');
		}
		if($text =~ /(?:RBL|Razor|Spam)/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'MailScanner') {
		if($text =~ /(Virus Scanning: Found)/ ) {
			event($time, 'virus');
		}
		elsif($text =~ /Bounce to/ ) {
			event($time, 'bounced');
		}
		elsif($text =~ /^Spam Checks: Found ([0-9]+) spam messages/) {
			my $cnt = $1;
			for (my $i=0; $i<$cnt; $i++) {
				event($time, 'spam');
			}
		}
	}
	elsif($prog eq 'clamsmtpd') {
		if($text =~ /status=VIRUS/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'clamav-milter') {
		if($text =~ /Intercepted/) {
			event($time, 'virus');
		}
	}
	# uncommment for clamassassin:
	#elsif($prog eq 'clamd') {
	#	if($text =~ /^stream: .* FOUND$/) {
	#		event($time, 'virus');
	#	}
	#}
	elsif ($prog eq 'smtp-vilter') {
		if ($text =~ /clamd: found/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'avmilter') {
		# AntiVir Milter
		if($text =~ /^Alert!/) {
			event($time, 'virus');
		}
		elsif($text =~ /blocked\.$/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'bogofilter') {
		if($text =~ /Spam/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'filter-module') {
		if($text =~ /\bspam_status\=(?:yes|spam)/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'sta_scanner') {
		if($text =~ /^[0-9A-F]+: virus/) {
			event($time, 'virus');
		}
	}
        elsif($prog eq 'postgrey') {
                # Old versions (up to 1.27)
                if($text =~ /delayed [0-9]+ seconds: client/) {
                        event($time, 'delayed');
                }
                # New versions (from 1.28)
                if($text =~ /delay=[0-9]+/) {
                        event($time, 'delayed');
                }
        }
}

sub event($$)
{
	my ($t, $type) = @_;
	update($t) and $sum{$type}++;
}

# returns 1 if $sum should be updated
sub update($)
{
	my $t = shift;
	my $m = $t - $t%$rrdstep;
	init_rrd($m) unless $rrd_inited;
	return 1 if $m == $this_minute;
	return 0 if $m < $this_minute;

	print "update $this_minute:$sum{sent}:$sum{received}:$sum{bounced}:$sum{rejected}:$sum{virus}:$sum{spam}:$sum{greylisted}:$sum{delayed}:$sum{anonymoustls}:$sum{trustedtls}:$sum{untrustedtls}:$sum{verifiedtls}:$sum{anonymoustlsin}:$sum{trustedtlsin}:$sum{untrustedtlsin}:$sum{verifiedtlsin}\n" if $opt{verbose};
	RRDs::update $rrd, "$this_minute:$sum{sent}:$sum{received}:$sum{bounced}:$sum{rejected}" unless $opt{'no-mail-rrd'};
	RRDs::update $rrd_virus, "$this_minute:$sum{virus}:$sum{spam}" unless $opt{'no-virus-rrd'};
	RRDs::update $rrd_greylist, "$this_minute:$sum{greylisted}:$sum{delayed}" unless $opt{'no-greylist-rrd'};
	RRDs::update $rrd_dane, "$this_minute:$sum{anonymoustls}:$sum{trustedtls}:$sum{untrustedtls}:$sum{verifiedtls}:$sum{anonymoustlsin}:$sum{trustedtlsin}:$sum{untrustedtlsin}:$sum{verifiedtlsin}" unless $opt{'no-dane-rrd'};
	if($m > $this_minute+$rrdstep) {
		for(my $sm=$this_minute+$rrdstep;$sm<$m;$sm+=$rrdstep) {
			print "update $sm:0:0:0:0:0:0:0:0 (SKIP)\n" if $opt{verbose};
			RRDs::update $rrd, "$sm:0:0:0:0" unless $opt{'no-mail-rrd'};
			RRDs::update $rrd_virus, "$sm:0:0" unless $opt{'no-virus-rrd'};
			RRDs::update $rrd_greylist, "$sm:0:0" unless $opt{'no-greylist-rrd'};
			RRDs::update $rrd_dane, "$sm:0:0:0:0:0:0:0:0" unless $opt{'no-dane-rrd'};
		}
	}
	$this_minute = $m;
	$sum{sent}=0;
	$sum{received}=0;
	$sum{bounced}=0;
	$sum{rejected}=0;
	$sum{virus}=0;
	$sum{spam}=0;
	$sum{greylisted}=0;
	$sum{delayed}=0;
	$sum{anonymoustls}=0;
	$sum{trustedtls}=0;
	$sum{untrustedtls}=0;
	$sum{verifiedtls}=0;
	$sum{anonymoustlsin}=0;
	$sum{trustedtlsin}=0;
	$sum{untrustedtlsin}=0;
	$sum{verifiedtlsin}=0;
	return 1;
}

main;

__END__

=head1 NAME

mailgraph.pl - rrdtool frontend for mail statistics

=head1 SYNOPSIS

B<mailgraph> [I<options>...]

     --man          show man-page and exit
 -h, --help         display this help and exit
     --version      output version information and exit
 -h, --help         display this help and exit
 -v, --verbose      be verbose about what you do
 -V, --version      output version information and exit
 -c, --cat          causes the logfile to be only read and not monitored
 -l, --logfile f    monitor logfile f instead of /var/log/syslog
 -t, --logtype t    set logfile's type (default: syslog)
 -y, --year         starting year of the log file (default: current year)
     --host=HOST    use only entries for HOST (regexp) in syslog
 -d, --daemon       start in the background
 --daemon-pid=FILE  write PID to FILE instead of /var/run/mailgraph.pid
 --daemon-rrd=DIR   write RRDs to DIR instead of /var/log
 --daemon-log=FILE  write verbose-log to FILE instead of /var/log/mailgraph.log
 --ignore-localhost ignore mail to/from localhost (used for virus scanner)
 --ignore-host=HOST ignore mail to/from HOST regexp (used for virus scanner)
 --no-mail-rrd      do not update mail rrd
 --no-virus-rrd     do not update virus rrd
 --no-greylist-rrd  do not update greylist rrd
 --no-dane-rrd  do not update dane rrd
 --rrd-name=NAME    use NAME.rrd and NAME_virus.rrd for the rrd files
 --rbl-is-spam      count rbl rejects as spam
 --virbl-is-virus   count virbl rejects as viruses

=head1 DESCRIPTION

This script does parse syslog and updates the RRD database (mailgraph.rrd) in
the current directory.

=head2 Log-Types

The following types can be given to --logtype:

=over 10

=item syslog

Traditional "syslog" (default)

=item metalog

Metalog (see http://metalog.sourceforge.net/)

=back

=head1 COPYRIGHT

Copyright (c) 2000-2007 by ETH Zurich
Copyright (c) 2000-2007 by David Schweikert

=head1 LICENSE

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=head1 AUTHOR

S<David Schweikert E<lt>david@schweikert.chE<gt>>

=cut

# vi: sw=8
