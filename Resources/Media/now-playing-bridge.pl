#!/usr/bin/perl
# Host the optional Now Playing bridge in Apple's system Perl process. This is
# needed on macOS 15.4+, where ordinary clients cannot read system Now Playing.
use strict;
use warnings;
use DynaLoader;
my ($library, $command) = @ARGV;
die "Invalid media command\n" unless defined($library) && defined($command)
    && $command =~ /\A(?:stream|2|4|5)\z/;
$ENV{AGENTNOTCH_MEDIA_COMMAND} = $command;
my $handle = DynaLoader::dl_load_file($library, 0)
    or die "Could not load Now Playing bridge: " . DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($handle, 'agentnotch_media_main')
    or die "Incompatible Now Playing bridge\n";
DynaLoader::dl_install_xsub('main::run_bridge', $symbol);
run_bridge();
