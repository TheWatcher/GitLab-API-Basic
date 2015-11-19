#!/usr/bin/perl -w

# Given the path to the gitlab API documentation directory,
# generate the hash that describes the API operations.

use strict;
use Data::Dumper;
use JSON;

## @fn void superchomp($line)
# Remove any white space or newlines from the end of the specified line. This
# performs a similar task to chomp(), except that it will remove <i>any</i> OS
# newline from the line (unix, dos, or mac newlines) regardless of the OS it
# is running on. It does not remove unicode newlines (U0085, U2028, U2029 etc)
# because they are made of spiders.
#
# @param line A reference to the line to remove any newline from.
sub superchomp(\$) {
    my $line = shift;

    $$line =~ s/(?:[\s\x{0d}\x{0a}\x{0c}]+)$//o;
}


## @fn $ load_file($name)
# Load the contents of the specified file into memory. This will attempt to
# open the specified file and read the contents into a string. This should be
# used for all file reads whenever possible to ensure there are no internal
# problems with UTF-8 encoding screwups.
#
# @param name The name of the file to load into memory.
# @return The string containing the file contents, or undef on error. If this
#         returns undef, $! should contain the reason why.
sub load_file {
    my $name = shift;

    if(open(INFILE, "<:utf8", $name)) {
        undef $/;
        my $lines = <INFILE>;
        $/ = "\n";
        close(INFILE)
            or return undef;

        return $lines;
    }
    return undef;
}


## @fn void parse_file($filename, $api)
# Parse the API information in the specified file into the api hash.
#
# @param filename The name of the file to read from
# @param api      A reference to a hash containing the API information.
sub parse_file {
    my $filename = shift;
    my $api      = shift;

    my $content = load_file($filename)
        or die "Unable to load $filename: $!\n";

    # Operations are documented following ##s
    my @ops = split(/###?/, $content);

    foreach my $op (@ops) {
        next if($op =~ /^# /); # Skip level 1 headers

        my ($title)        = $op =~ /^\s*(.*?)\r?\n/;
        my ($method, $url) = $op =~ /```\s*\n(\w+)\s+(.*?)\r?\n/;
        my @params         = $op =~ /^- (`\w+`\s+\(.*?\)(?:\s+- .*)?)$/gm;

        next unless($method && ($method eq "POST" || $method eq "GET" || $method eq "PUT" || $method eq "DELETE"));

        $api -> {"api"} -> {$url} -> {$method} = { "title"  => $title };

        if(scalar(@params)) {
            foreach my $line (@params) {
                superchomp($line);

                my ($name, $type, $desc) = $line =~ /^`(\w+)`\s+\(\**(.*?)\**\)(?:\s+- (.*))?$/;
                $api -> {"api"} -> {$url} -> {$method} -> {"params"} -> {$type} -> {$name} = $desc;
            }
        } else {
            print STDERR "No parameters in $filename section $title:\n$op.\n";
        }
    }
}


my $dirname = $ARGV[0]
    or die "Usage: build_api_from_docs.pl <API doc directory>\n";

# mak sure there's a trailing /...
$dirname .= "/" unless($dirname =~ /\/$/);

my @mdfiles = glob("$dirname*.md");

my $api = { "api" => {} };
foreach my $file (@mdfiles) {
    next if($file =~ /README\.md$/);

    parse_file($file, $api);
}

my $json = JSON -> new();
$json -> pretty(1);
$json -> canonical(1);
print $json -> encode($api);