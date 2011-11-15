#!/usr/bin/perl

use strict;
use Data::Dumper;
use Getopt::Long;
use Getopt::Std; 
use Sys::Hostname;
use LWP::UserAgent;
use Term::ANSIColor qw/:constants/;

my %_opt;
my $hostname = hostname();

$_opt{no_ssl} = 0;
$_opt{disable} = 0;
$_opt{force} = 0;
$_opt{myself} = 0;
#my $myself = $hostname;
my $myself = $hostname;

my $result = GetOptions(
    "--config|c=s" => \$_opt{config_file_name},
	"--domain|d=s" => \$_opt{domain},
	"--none-ssl" => \$_opt{no_ssl},
	"--disable" => \$_opt{disable},
	"--enable" => \$_opt{enable},
	"--group|g=s" => \$_opt{group},
	"--range|r=s" => \$_opt{host},
	"--hostname|H=s" => \$_opt{hostname},
	"--myself|m" => \$_opt{myself},
	"--force|f" => \$_opt{force},
	"--help" => \$_opt{help}
); 

$myself = $_opt{hostname} if($_opt{hostname});
$_opt{disable} = 0 if($_opt{enable});

main();

sub main{
	check_options();

	if($_opt{myself} or $_opt{hostname}){
    	my (@request) = get_change_requests();
    	request_param(@request);
	}elsif($_opt{host}){
		my $config_data = config2data();
		my $nonce = get_nonce($config_data);
		my @member_array = get_change_active_params($config_data);
#		print Dumper(@member_array) . "\n";
		confirm_params(@member_array) unless($_opt{force});
		my (@params) = create_get_url($nonce, @member_array);
		request_param(@params);
	}else{
		die 'Unknown option error';
	}
}

sub confirm_params{
	my(@menber) = @_;
	print RED BOLD "\nPlz. Check to the balancer config for change operation", RESET , "\n\n";
	print "balancer_domain: ", RED ,"$_opt{domain}", RESET,  "\n";
	print "balancer_group: ", RED ,  "$_opt{group}", RESET , "\n";
	print "active status: ", RED , $_opt{disable} ? 'Disable' : 'Enable' , RESET , "\n";
	print "target member: \n";
	foreach my $m (@menber){
		print "    ", RED, $m , RESET , "\n";
	}
	print "\nIs it really good? (Y/n) : ";
    my $yn = <STDIN>;
    chomp($yn);
	exit unless($yn eq 'Y');
	print "Running .... change active status\n";
}

sub create_get_url{
	my $nonce = shift;
	my(@member_array) = @_;
	my @params;
	foreach my $member (@member_array){
		push(@params, create_get_params($_opt{group}, $member, $nonce));
	}
	return @params;
}

sub request_param{
	my (@params) = @_;
    my $ua = LWP::UserAgent->new();
    $ua->timeout(30);
	foreach my $p (@params){
		#print sprintf('%s://%s%s', $_opt{no_ssl} ? 'http':'https', $_opt{domain}, $p) . "\n";
		my $res = $ua->get(sprintf('%s://%s%s', $_opt{no_ssl} ? 'http':'https', $_opt{domain}, $p));
		die 'Request http ERROR' unless($res->is_success);
		sleep(1);
	}
}

sub get_change_active_params{
	my $config_data = shift;
	
	$_opt{'host'} =~ /(\d+)-(\d+)/;
	my $s_host = $1;
	my $e_host = $2;
	if(!$s_host or !$e_host){
		die "Error range option format $1 and $2";
	}
	if($s_host > $e_host){
		die "Error range $s_host > $e_host";
	}
	my @member;

	die sprintf('No host number from %s group', $_opt{group}) unless($config_data->{$_opt{group}}->{member});

	foreach my $i ($s_host .. $e_host){
		push(@member, $config_data->{$_opt{group}}->{member}->{$i}) if ($config_data->{$_opt{group}}->{member}->{$i});
	}
	return @member;
}

sub create_get_params{
	my $bl_group = shift;
	my $bl_member = shift;
	my $nonce = shift;
	return sprintf('/LBMAN/?b=%s&w=%s&nonce=%s&dw=%s', $bl_group, $bl_member, $nonce, $_opt{disable} ? 'Disable' : 'Enable');
}

sub get_lbman_contents{
    my $ua = LWP::UserAgent->new();
    $ua->timeout(30);
    my $res = $ua->get(sprintf('%s://%s/LBMAN/', $_opt{no_ssl} ? 'http':'https', $_opt{domain}));
    if ($res->is_success) {
        my $contents = $res->content;
        return $contents;
    }else{
        die "Can't open LBMAN Status = " . $res->status_line;
    }
}

sub get_nonce{
	my $contents = get_lbman_contents();
    $contents =~ /nonce=((\w|-)+)/s;
    die "Don't get nonce param" unless($1);
    return $1;
}

sub get_change_requests{
	my $contents = get_lbman_contents();
	my (@href_array);
	foreach my $line (split("\n", $contents)){
 		if($line =~ /a href/ && $line =~ /$myself/){
			$line =~ /a href="(.*)"/;
			my $href = $1;
			my ($group) = $href =~ /\?b=(.+)\&w/;
			if ((not $_opt{'group'}) || ($group =~ /^$_opt{'group'}$/)){
				push(@href_array, sprintf('%s&dw=%s', $href, $_opt{disable} ? 'Disable' : 'Enable'));
			}
		}
	}
	return @href_array;
}

sub config2data{
		
	open(IN, "<$_opt{config_file_name}") or die "Can't open file $_opt{config_file_name}";
	my %config_data;
	my $bl_group;
	my $cnt = 0;
	
	while(<IN>){
		# create balancer group
		next if ($_ =~ /#/);
		if($_ =~ /^<Proxy balancer:\/\/(.*)>$/){
			$bl_group = $1;
		}
		if($_ =~ /BalancerMember\s+(http\S+)/gc){
			$cnt++;
			die "Don't find <Proxy balancer ... $_" if(!$bl_group);
			my $member = $1;
			$member =~ s/:80$//;
			{
				$member =~ /[a-zA-Z](\d+)\./;
				my $host_no = $1;
				die 'duplicate host no'if($config_data{$bl_group}->{member}->{$host_no});
				$config_data{$bl_group}->{member}->{$host_no} = $member;
			}
		}
		if($_ =~ /\s+loadfactor=(\d+)\s+/){
		    die "Don't find <Proxy balancer ... $_" if(!$bl_group);
		    $config_data{$bl_group}->{$cnt}->{loadfactor} = $1;
		}
		if($_ =~ /<\/Proxy>/){
			$cnt =0;
			undef($bl_group);
		}
	}
	close(IN);
	return \%config_data;
}

sub check_options{
	print_option() if($_opt{help});
	die 'Plz, Input host' if(!$_opt{hostname} and !$_opt{'myself'} and !$_opt{'host'});
	die 'Plz, Input LBMAN domain' unless($_opt{domain});
	die 'Plz, Select Enable or Diasble' if($_opt{disable} && $_opt{enable});
	die "None balancer group $_opt{group}" if(!$_opt{'hostname'} and !$_opt{'myself'} and !$_opt{group});
}

sub print_option{
	print "<ex> ./bl_changer.pl --config ./00balancer.conf --domain LBMAN-hostname --group proxy-groupname --range 1-8 --disable\n";
	print "<ex> ./bl_changer.pl --domain LBMAN-hostname --myself --disable\n";
	print "<ex> ./bl_changer.pl --domain LBMAN-hostname --hostname ap-server-hostname --disable\n\n";
	print "--config -c\t\tset 00balancer.conf\n";
	print "--domain -d\t\tset LBMAN domain or IP address\n";
	print "--group -g\t\tset balancer group name\n";
	print "--force -f\t\tif an existing destination\n";
	print "--none-ssl\t\tuse http request\n";
	print "--disable\t\tset disable status\n";
	print "--enable\t\tset enable status\n";
	print "--range -r\t\tset target serial number for host ex:(1-8)\n";
	print "--myself -m\t\tset target my hostname, change all grop (ex `hostname`)\n";
	print "--hostname -H\t\tset target hostname , change all group (ex --hostname ap-server-hostname)\n";
	print "--help\t\t\tdisplay help message\n";
	exit;
}

# vim:ts=4
