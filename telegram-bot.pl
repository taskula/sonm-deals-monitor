#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use JSON;
use Getopt::Long;
use List::Util qw( any );
use Pod::Usage;
use Scalar::Util qw( looks_like_number );

my $token       = '';
my $verbose     = 0;
my $man         = 0;
my $help        = 0;
my $dwh_deals   = 'https://dwh.livenet.sonm.com:15022/DWHServer/GetDeals/';
my $deals_db    = 'data/deals.db';

GetOptions(
    'token|t=s'     => \$token,
    'verbose|v'     => \$verbose,
    'help|h'        => \$help,
    'man'           => \$man,
) or pod2usage(2);
pod2usage(1) if $help;
pod2usage(-exitval => 0, -verbose => 2) if $man;

my $dbh = DBI->connect('DBI:SQLite:dbname=data/deals.db', 'sonm', 'sonm',
    { RaiseError => 1 }
) or die $DBI::errstr;

my $latest = 0;

while (1) {
    # Get updates
    my $tg_url = "https://api.telegram.org/bot$token/getUpdates?offset=$latest";
    my $data = `curl -s $tg_url`;
    my $updates = eval { JSON->new->utf8->decode($data); };
    next if $@;

    if ($updates->{result}) {
        unless ($latest) {
            $latest = $updates->{result}->[@{$updates->{result}}-1]
                ->{update_id};
        }
        foreach my $upd (@{$updates->{result}}) {
            if ($upd->{update_id} <= $latest) {
                next;
            }
            $latest = $upd->{update_id};
            my $cmd = $upd->{message}->{text};
            next unless $cmd && $cmd =~ /^\/\w+(\@{0,1}(.*))?$/;
            eval { command($cmd, $upd); };
        }
    }

    sleep(1);
}

sub command {
    my ($cmd, $upd) = @_;

    $cmd =~ /^\/(\w+)(\@{0,1}(.*))?$/;
    $cmd = $1;
    my @valid_commands = (
        'dm', 'sc'
    );

    # Check if $cmd is a valid command
    unless (any { /^$cmd$/ } @valid_commands) {
        return;
    }

    if ($cmd eq 'dm') {
        return respond_stats($upd);
    }
    elsif ($cmd eq 'sc') {
        return respond_sidechain($upd);
    }
}

sub respond_sidechain {
    my ($upd) = @_;

    # Get SNM tokens deposited to the side chain
    my $result = `curl -s 'https://api.etherscan.io/api?module=account&action=tokenbalance&contractaddress=0x983f6d60db79ea8ca4eb9968c6aff8cfa04b3c63&address=0x125f1e37a45abf9b9894aefcb03d14d170d1489b'`;
    my $deposited = JSON->new->decode($result)->{result};
    my $deposited_tokens = $deposited / 1000000000000000000;
    my $total = `curl -s 'https://api.etherscan.io/api?module=stats&action=tokensupply&contractaddress=0x983f6d60db79ea8ca4eb9968c6aff8cfa04b3c63'`;
       $total = JSON->new->utf8->decode($total)->{result};
    my $percent_of_total_supply = ($deposited/$total)*100 . "%";
    my $msg = qq(
     Currently $deposited_tokens SNM are in the side chain, which are $percent_of_total_supply of the total supply.
    );

    send_response($upd, $msg);
}

sub respond_stats {
    my ($upd) = @_;

    my $sth = $dbh->prepare('SELECT amount FROM deals WHERE ' .
        'timestamp < DATETIME("now", "-1 hour") ORDER BY timestamp DESC LIMIT 1');
    $sth->execute();
    my ($interval_1hour) = $sth->fetchrow_array();
    $sth = $dbh->prepare('SELECT amount FROM deals WHERE ' .
        'timestamp < DATETIME("now", "-1 day") ORDER BY timestamp DESC LIMIT 1');
    $sth->execute();
    my ($interval_1day) = $sth->fetchrow_array();
    $sth = $dbh->prepare('SELECT amount FROM deals WHERE ' .
        'timestamp < DATETIME("now", "-7 day") ORDER BY timestamp DESC LIMIT 1');
    $sth->execute();
    my ($interval_1week) = $sth->fetchrow_array();
    $sth = $dbh->prepare('SELECT amount FROM deals WHERE ' .
        'timestamp < DATETIME("now", "-1 month") ORDER BY timestamp DESC LIMIT 1');
    $sth->execute();
    my ($interval_1month) = $sth->fetchrow_array();
    $sth = $dbh->prepare('SELECT MAX(amount) FROM deals');
    $sth->execute();
    my ($ath) = $sth->fetchrow_array();

    # Get SNM price from Binance
    my $snm_ticker = `curl -s https://api.binance.com/api/v1/ticker/24hr?symbol=SNMBTC`;
       $snm_ticker = JSON->new->utf8->decode($snm_ticker);
    my $snm_last_price = $snm_ticker->{lastPrice}*100000000;
    my $snm_quote_volume = int($snm_ticker->{quoteVolume});

    # Get current eth-hashrate
    my $deals = `curl -s $dwh_deals -d '{"status":1}'`;
       $deals = eval { JSON->new->utf8->decode($deals)->{deals}; };
    my $hashrate = 0;
    foreach my $deal (@$deals) {
        $deal = $deal->{deal};
        $hashrate += $deal->{benchmarks}->{'values'}->[9];
    }
    $hashrate /= 1000000; # Convert to MH/s
    $hashrate = sprintf('%d', $hashrate);

    # Get basic stats from EtherChain
    my $eth_stats = `curl -s https://www.etherchain.org/api/basic_stats`;
       $eth_stats = eval { JSON->new->utf8->decode($eth_stats)->{currentStats}; };
    my $eth_hashrate = $eth_stats->{hashrate};
    my $percent_of_total_hashrate = sprintf("%.10f", ($hashrate*1000/$eth_hashrate));

    my $number_of_deals = @{$deals};
    my $msg  = "Current deals: $number_of_deals\n";
       $msg .= '1 hour: ' . _inc_dec($number_of_deals, $interval_1hour) . "\n";
       $msg .= '1 day: ' . _inc_dec($number_of_deals, $interval_1day) . "\n";
       $msg .= '1 week: ' . _inc_dec($number_of_deals, $interval_1week) . "\n";
       $msg .= '1 month: ' . _inc_dec($number_of_deals, $interval_1month) . "\n";
       $msg .= "From ATH ($ath): " . _inc_dec($number_of_deals, $ath) . "\n";
       $msg .= "\n";
       $msg .= "ETH-hashrate: $hashrate MH/s ($percent_of_total_hashrate% of total)\n";
       $msg .= "SNM Price: $snm_last_price sats\n";
       $msg .= "Vol: $snm_quote_volume BTC";

    send_response($upd, $msg);
}

sub send_response {
    my ($upd, $msg) = @_;

    my $chat_id = $upd->{message}->{chat}->{id};
    my $msg_id  = $upd->{message}->{message_id};

    my $tg_url = "https://api.telegram.org/bot$token/sendMessage";
    `curl -s -G $tg_url --data-urlencode "text=$msg" --data-urlencode "chat_id=$chat_id" --data-urlencode "reply_to_message_id=$msg_id"`;
    print "Sending message to chat id $chat_id\n" if $verbose;
}

sub _inc_dec {
    my ($latest, $old) = @_;

    return "---" unless defined $old;
    return "+0.00%" if $latest == $old;

    if ($latest > $old) {
        my $increase = $latest - $old;
        return '+' . sprintf("%.2f", ($increase / $old * 100)) . '%';
    } else {
        my $decrease = $old - $latest;
        return '-' . sprintf("%.2f", ($decrease / $old * 100)) . '%';
    }
}
__END__

=head1 NAME

telegram-bot.pl - Reports the number of deals and the change to Telegram Chat

=head1 SYNOPSIS

./telegram-bot.pl [options]

 Options:
    --help or -h        Prints help message
    --man               Full documentation
    --token or -t       Your Telegram Bot token
    --verbose or -v     Verbose output

=head1 OPTIONS

=over 8

=item B<--help> or B<-h>

Prints a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<--interval> or B<-i>

The secret token of your Telegram Bot.

=item B<--verbose> or B<-v>

A more verbose output.

=back

=head1 DESCRIPTION

B<telegram-bot.pl> reports the number of deals and the change to Telegram Chat.

=cut
