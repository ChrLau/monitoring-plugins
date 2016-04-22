#!/usr/bin/perl -w
#
# Copyright (c) 2012-2014 Stéphane Urbanovski <stephane.urbanovski@ac-nancy-metz.fr>
#  (some code took from nagiosexchange by ??? )
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty
# of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# you should have received a copy of the GNU General Public License
# along with this program (or with Nagios);  if not, write to the
# Free Software Foundation, Inc., 59 Temple Place - Suite 330,
# Boston, MA 02111-1307, USA
#
## check_jk_status:
##
## Check the status for mod_jk's loadbalancers via XML download from status 
## URL.

use strict;
use warnings;

use Nagios::Plugin ;

use Locale::gettext;
use File::Basename;         # get basename()
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Status;
use XML::Simple;
use Data::Dumper;
use Getopt::Long;

my $VERSION = '1.1';
my $TIMEOUT = 9;
my $DEBUG = 0;


my $np = Nagios::Plugin->new(
	version => $VERSION,
	blurb => _gt('Plugin to check mod_jk status url'),
	usage => "Usage: %s [ -v|--verbose ]  -u <url> [-t <timeout>] [ -c|--critical=<threshold> ] [ -w|--warning=<threshold> ] [ -b|--balancer <balancer> ]",
	timeout => $TIMEOUT+1
);
$np->add_arg (
	spec => 'debug|d',
	help => _gt('Debug level'),
	default => 0,
);
$np->add_arg (
	spec => 'w=f',
	help => _gt('Warning request time threshold (in seconds)'),
	default => 2,
	label => 'FLOAT'
);
$np->add_arg (
	spec => 'c=f',
	help => _gt('Critical request time threshold (in seconds)'),
	default => 10,
	label => 'FLOAT'
);
$np->add_arg (
	spec => 'url|u=s',
	help => _gt('URL of the mod_jk status page.'),
	required => 1,
);
$np->add_arg (
	spec => 'balancer|b=s',
	help => _gt('balancer name.'),
	required => 0,
);

$np->getopts;

$DEBUG = $np->opts->get('debug');
my $verbose = $np->opts->verbose;

# Thresholds :
# time
my $warn_t = $np->opts->get('w');
my $crit_t = $np->opts->get('c');

my $url = $np->opts->get('url');
my $reqbalancer = $np->opts->get('balancer');



# Create a LWP user agent object:
my $ua = new LWP::UserAgent(
	'env_proxy' => 0,
	'timeout' => $TIMEOUT,
	);
$ua->agent(basename($0));

# Workaround for LWP bug :
$ua->parse_head(0);

if ( defined($ENV{'http_proxy'}) ) {
	# Normal http proxy :
	$ua->proxy(['http'], $ENV{'http_proxy'});
	# Https must use Crypt::SSLeay https proxy (to use CONNECT method instead of GET)
	$ENV{'HTTPS_PROXY'} = $ENV{'http_proxy'};
}

# Build and submit an http request :
$url .= '?mime=xml&opt=2';
if ( $reqbalancer ) {
	$url .= '&cmd=show&w='.$reqbalancer;
}

my $request = HTTP::Request->new('GET', $url);
my $timer = time();
logD("GET ".$request->uri());
my $http_response = $ua->request( $request );
$timer = time()-$timer;



my $status = $np->check_threshold(
	'check' => $timer,
	'warning' => $warn_t,
	'critical' => $crit_t,
);

$np->add_perfdata(
	'label' => 't',
	'value' => sprintf('%.6f',$timer),
	'min' => 0,
	'uom' => 's',
	'threshold' => $np->threshold()
);

if ( $status > OK ) {
	$np->add_message($status, sprintf(_gt("Response time degraded: %.6fs !"),$timer) );
}


my $message = 'msg';


if ( $http_response->is_error() ) {
	my $err = $http_response->code." ".status_message($http_response->code)." (".$http_response->message.")";
	$np->add_message(CRITICAL, _gt("HTTP error: ").$err );

} elsif ( ! $http_response->is_success() ) {
	my $err = $http_response->code." ".status_message($http_response->code)." (".$http_response->message.")";
	$np->add_message(CRITICAL, _gt("Internal error: ").$err );
}





if ( $http_response->is_success() ) {

	# Get xml content ... 
	my $xml = $http_response->content;
	if ($DEBUG) {
		print "------------------===http output===------------------\n$xml\n-----------------------------------------------------\n";
		print "t=".$timer."s\n";
	};
	
	### Convert XML to hash
	
	my $statusData = eval { XMLin($xml, forcearray => ['jk:member']) };
	if ($@) {
		$np->nagios_exit(CRITICAL, _gt("Unparsable XML in jkstatus response: ").$@ );
	}
	# TODO: handle supplied balancer name
	
	
#   print Dumper($statusData);
	
	if ( defined($statusData->{'jk:result'}->{'type'}) ) {
		if ( $statusData->{'jk:result'}->{'type'} ne 'OK' ) {
			if ( defined($statusData->{'jk:result'}->{'message'}) ) {
				$np->nagios_exit(CRITICAL, sprintf(_gt("Jk result error : %s"),$statusData->{'jk:result'}->{'message'}) );
			} else {
				$np->nagios_exit(CRITICAL, _gt("Unknown jk result error") );
			}
		}
	}
	
	my $jkVersion = '';
	if ( defined($statusData->{'jk:software'}->{'web_server'}) ) {
		$jkVersion = $statusData->{'jk:software'}->{'web_server'};
	}
	if ( defined($statusData->{'jk:software'}->{'jk_version'}) ) {
		$jkVersion .= ' - '.$statusData->{'jk:software'}->{'jk_version'};
	}
	
	
	my @balancers = keys( %{$statusData->{'jk:balancers'}->{'jk:balancer'}} );
	
	if ( defined($reqbalancer) ) {
	
		my $balancer = $reqbalancer;
		my @good_members = ();
		my @bad_members = ();
		
		### Get number of members
		my $member_count = $statusData->{'jk:balancer'}->{'member_count'} || 0;
		
		if ( $member_count == 0 ) {
			$np->nagios_exit(WARNING, sprintf(_gt('No member found for worker \'%s\' !'),$reqbalancer) );
		}
		
		foreach my $member ( sort keys %{$statusData->{'jk:balancer'}->{'jk:member'}} ) {
			my %memberData = %{$statusData->{'jk:balancer'}->{'jk:member'}->{$member}};
		
			$np->add_perfdata(
				'label' => 'busy['.$member.']',
				'value' => $memberData{'busy'},
				'min' => 0,
			);
			$np->add_perfdata(
				'label' => 'errors['.$member.']',
				'value' => $memberData{'errors'},
				'min' => 0,
			);
			
			if ( defined($memberData{'connected'}) ) {
				$np->add_perfdata(
					'label' => 'connected['.$member.']',
					'value' => $memberData{'connected'},
					'min' => 0,
				);
			}
			$np->add_perfdata(
				'label' => 'client_errors['.$member.']',
				'value' => $memberData{'client_errors'},
				'min' => 0,
			);
			$np->add_perfdata(
				'label' => 'used['.$member.']',
				'value' => $memberData{'elected'},
				'min' => 0,
			);
			
			
			
			$np->add_perfdata(
				'label' => 'read['.$member.']',
				'value' => $memberData{'read'},
				'min' => 0,
				'uom' => 'B'
			);
			$np->add_perfdata(
				'label' => 'transferred['.$member.']',
				'value' => $memberData{'transferred'},
				'min' => 0,
				'uom' => 'B'
			);

			my $activation = $memberData{'activation'};
			my $state = $memberData{'state'};
			
			
			logD( "STATE for $member: $state / $activation");
			# clauf, changed to include disabled workers into good_members
			#Original: if ( $activation ne 'ACT' ) {
			# Add stoped workers to bad_members
			if ( $activation eq 'STP' ) {
				push (@bad_members, $member);
			# Only active or disabled balancer members with state OK are added to good_members
			} elsif ( ($activation eq 'ACT') || ($activation eq 'DIS') ) {
				if ( ($state !~ /^OK/) && ($state ne 'N/A') ) {
					push (@bad_members, $member);
				} else {
					push (@good_members, $member);
				}
			}
		}
			
		logD("balancer = $balancer : ".scalar(@good_members)."/".$member_count);

		### Calculate possible differences
		my $bad_count = scalar(@bad_members);
		my $good_count = $member_count - $bad_count;

		if ($good_count == 0) {
			$np->add_message(CRITICAL, sprintf(_gt("All members (%d/%d) of '%s' are down"),$bad_count,$member_count,$balancer) );
			
		} elsif ($member_count != $good_count) {
			$np->add_message(WARNING, sprintf(_gt("Some members (%d/%d) of '%s' are down : %s"),$bad_count,$member_count,$balancer, join(',',@bad_members)) );
			
		}
		# We are not interested in Version information here
		#$np->add_message(OK, sprintf(_gt("%s - All members (%d/%d) of '%s' are optimal : %s"),$jkVersion,$good_count,$member_count,$balancer,join(',',@good_members)) );
		$np->add_message(OK, sprintf(_gt("All members (%d/%d) of '%s' are OK: %s"),$good_count,$member_count,$balancer,join(',',@good_members)) );
		
	} else {
		foreach my $balancer ( @balancers ) {
			
			my @good_members = ();
			my @bad_members = ();
			
			### Get number of members
			my $member_count = $statusData->{'jk:balancers'}->{'jk:balancer'}->{$balancer}->{'member_count'};

			### Check all members
			foreach my $member ( sort keys %{$statusData->{'jk:balancers'}->{'jk:balancer'}->{$balancer}->{'jk:member'}} ) {
				### Check status for every node activation
				
				
				my %memberData = %{$statusData->{'jk:balancers'}->{'jk:balancer'}->{$balancer}->{'jk:member'}->{$member}};
				my $activation = $memberData{'activation'};
				my $state = $memberData{'state'};
				
				
				logD( "STATE for $member: $state / $activation");
				if ( $activation ne 'ACT' ) {
					push (@bad_members, $member);
				} elsif ( $activation eq 'ACT' ) {
					if ( ($state !~ /^OK/) && ($state ne 'N/A') ) {
						push (@bad_members, $member);
					} else {
						push (@good_members, $member);
					}
				}
			}
			
			logD("balancer = $balancer : ".scalar(@good_members)."/".$member_count);

			### Calculate possible differences
			my $good_count = $member_count - scalar(@bad_members);

			if ($good_count == 0) {
				$np->add_message(CRITICAL, sprintf(_gt("All members of '%s' are down"),$balancer) );
				
			} elsif ($member_count != $good_count) {
				$np->add_message(WARNING, sprintf(_gt("Some members of '%s' are down : %s"),$balancer, join(',',@bad_members)) );
				
			}
		}
		# We are not interested in version information here
		#$np->add_message(OK, sprintf(_gt("%s - All balancers are optimal : %s"),$jkVersion,join(',',@balancers)) );
		$np->add_message(OK, sprintf(_gt("%s - All balancers are OK: %s"),join(',',@balancers)) );
	}
	
	
}

($status, $message) = $np->check_messages();
#$np->nagios_exit($status, $message );
$np->nagios_exit($status, $message );



exit 0;

sub logD {
	print STDERR 'DEBUG:   '.$_[0]."\n" if ($DEBUG);
}
sub logW {
	print STDERR 'WARNING: '.$_[0]."\n" if ($DEBUG);
}
# Gettext wrapper
sub _gt {
	return gettext($_[0]);
}

