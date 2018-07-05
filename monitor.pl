#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use Getopt::Long;
use Pod::Usage;
use Scalar::Util qw( looks_like_number );

my $interval    = 60;
my $verbose     = 0;
my $man         = 0;
my $help        = 0;
my $dwh_deals   = 'https://dwh.livenet.sonm.com:15022/DWHServer/GetDeals/';
my $deals_db    = 'data/deals.db';

GetOptions(
    'interval|i=i'  => \$interval,
    'verbose|v'   => \$verbose,
    'dwh'           => \$dwh_deals,
    'help|h'        => \$help,
    'man'           => \$man,
) or pod2usage(2);
pod2usage(1) if $help;
pod2usage(-exitval => 0, -verbose => 2) if $man;

my $dbh = DBI->connect('DBI:SQLite:dbname=data/deals.db', 'sonm', 'sonm',
    { RaiseError => 1 }
) or die $DBI::errstr;

unless (-s $deals_db) {
    print "Creating database for storing the number of deals...\n" if $verbose;
    create_database($dbh);
}

while (1) {
    my $deals = `curl -s $dwh_deals -d '{}' | grep -o '"deal"' | wc -l`;
    print "Deals: $deals" if $verbose;

    unless (looks_like_number($deals)) {
        print "$deals does not appear to be a number. Skipping.\n" if $verbose;
        sleep($interval);
        next;
    }

    my $sth = $dbh->prepare('INSERT INTO deals (amount) VALUES (?)');
    $sth->execute($deals);
    print "Added deals to database\n" if $verbose;

    sleep($interval);
}

sub create_database {
    my $dbh = shift;

    my $sql = <<'END_SQL';
CREATE TABLE deals (
    id        INTEGER PRIMARY KEY,
    amount    INTEGER,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
)
END_SQL

    $dbh->do($sql);
}

__END__

=head1 NAME

monitor.pl - Monitor the number of SONM network deals

=head1 SYNOPSIS

./monitor.pl [options]

 Options:
    --help or -h        Prints help message
    --man               Full documentation
    --interval or -i    Interval between monitoring calls to SONM network in
                        seconds. Defaults to 60 seconds.
    --verbose or -v     Verbose output
    --dwh               A custom URL to DWH GetLinks

=head1 OPTIONS

=over 8

=item B<--help> or B<-h>

Prints a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<--interval> or B<-i>

Interval in seconds between the monitoring calls to SONM network. Defaults to
60 seconds.

=item B<--verbose> or B<-v>

A more verbose output.

=item B<--dwh>

A custom URL to DWH GetLinks. Defaults to:
https://dwh.livenet.sonm.com:15022/DWHServer/GetDeals/

=back

=head1 DESCRIPTION

B<monitor.pl> connects to SONM network and monitors the number of active deals,
and then stores this number into a SQLite database.

=cut
