#!/usr/bin/perl -w

use strict;

sub read_module($)
{
    my $file = shift;
    open(FILE, "<$file") or die "ERROR: can't open $file: $!\n";
    my $code = '';
    my ($name, $version);
    my $in_pod = 0;
    local $_;
    while(<FILE>) {
        # strip POD
        if(/^=(head|item|back)/) { $in_pod = 1; next; }
        if(/^=cut/)              { $in_pod = 0; next; }
        next if $in_pod;
        # strip vim mode-lines
        next if /^# vim?:/;
        # strip empty lines
        next if /^\s*$/;
        # strip 1;
        next if /^\s*1\s*;$/;
        # strip __END__
        next if /^__END__/;
        # strip $VERSION
        if(/\$VERSION\s*=\s*['"]?([^\s'"]+)/) {
            $version = $1;
            next;
        }
        # find out package name
        if(/^package\s+([^\s;]*)/) {
            $name = $1;
        }

        $code .= $_;
    }
    return ($name, $version, $code);
}

sub main
{
    my $src = shift @ARGV;
    defined $src > 0 or die "usage: embed.pl src\n";
    open(SRC, "<$src") or die "ERROR: can't open $src: $!\n";
    my %embedded = ();
    while(<SRC>) {
        if(/^## EMBED\((.*?)\)/) {
            my ($name,$version,$code) =  read_module($1);
            print "######## $name $version (automatically embedded) ########\n";
            print $code;
            $embedded{$name}=1;
        }
        else {
            next if /^use\s+([^\s;]+)/ and defined $embedded{$1};
            print;
        }
    }
}

main;

# vi: sw=4 et
