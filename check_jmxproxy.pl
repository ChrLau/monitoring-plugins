#! /usr/bin/perl -wT

#
# check_jmxproxy.pl - Version 1.1.0
# Java 8 ready! (TM)
#
# Notice:
# This is check_jmxproxy.pl originally from Oliver Faenger and modified by Christian Lauf
# The original can be found on, for example: https://exchange.icinga.org/exchange/check_jmxproxy/
# My modified versions is available at:
# https://github.com/ChrLau/monitoring-plugins/blob/master/check_jmxproxy.pl
#
# There is a second plugin with the same name from Christopher Schultz, that can be found on:
# http://wiki.apache.org/tomcat/tools/check_jmxproxy.pl
# But that plugin has no performance data output. So don't get confused ;-)
# 
# Description:
# A Nagios plugin (script) that queries mbean information through tomcats
# JMXProxyServlet, parses the result and returns name-value pairs for
# values of type integer (values of type integer inside of type
# CompositeDataSupport will also be parsed).
# Returned performance data can be used by PNP.
# For each returned name-value pair a warning and/or critical threshold
# can be defined.
# 
# There are also plugins for monitoring jmx directly (e.g. check_jmx), but
# sometimes it is easier to make HTTP requests from nagios to tomcat servers
# than to enable jmx communication through firewalls.
#
# See manager-howto.html
# (http://tomcat.apache.org/tomcat-6.0-doc/manager-howto.html) from tomcat
# documentation for how to enable and use jmxproxy.
#
# One should always keep in mind, that enabling read access to jmxproxy
# allows also write access to the beans.
#
# Installation: Expand lib path to directory where utils.pm resides
# (mostly plugin dir, see below).
#
# Copyright (c) 2009 Oliver Faenger
#
# April 2016: Christian Lauf <contact AT christian-lauf.info>
#
# Modified RegEx for memory to handle negative and 0 values.
# Starting with Java8 the PermGen is obsolete in favour of the metaspace.
# Metaspace has the default value of -1 which means: unlimited and an init value of 0.
#
# Additionally change "use lib" to /usr/lib/nagios/plugins for debian systems
#
#
# License GPL

use strict;
use Getopt::Long;
use LWP::UserAgent;

# Nagios specific
# Installation: Expand lib path to directory where utils.pm resides.
use lib "/usr/lib/nagios/plugins";

use utils qw (%ERRORS &print_revision &support);

sub print_help ();
sub print_usage ();

my ($result, $message, $age, $size, $st);

# my vars
use vars qw(%select @enabled $verbose @critical @warning $ua $response);
use vars qw($webcontent $numQryResult @lines $i $compname $compDataContent);
use vars qw(@compData $perfdata $key);
use vars qw($host $port $qryurl %qryResult $qryname $qryvalue);
use vars qw($PROGNAME);

# $PROGNAME=$0;
$PROGNAME="check_jmxproxy";

# Options
use vars qw($opt_v $opt_c $opt_w $opt_h $opt_V $opt_p);
use vars qw($opt_u $opt_r $opt_U $opt_e);

Getopt::Long::Configure('bundling');
GetOptions(
        "U=s" => \$opt_U, "URL=s"         => \$opt_U,
        "r=s" => \$opt_r, "realm=s"       => \$opt_r,
        "u=s" => \$opt_u, "username=s"    => \$opt_u,
        "p=s" => \$opt_p, "password=s"    => \$opt_p,
        "e=s" => \$opt_e, "enable=s"      => \$opt_e,
        "w=s" => \$opt_w, "warning=s"     => \$opt_w,
        "c=s" => \$opt_c, "critical=s"    => \$opt_c,
	"v"   => \$opt_v, "verbose"	  => \$opt_v,
	"V"   => \$opt_V, "version"	  => \$opt_V,
	"h"   => \$opt_h, "help"	  => \$opt_h,
);

if ( $opt_v ) {
  $verbose=1;
}
if ($opt_h) {
	print_help();
	exit $ERRORS{'OK'};
}

if (! $opt_U) {
	print_help();
	exit $ERRORS{'OK'};
}

if ( $opt_e ) {
  @enabled=split ",", $opt_e;
  foreach (@enabled){
    $select{$_}=1;
  }
}

if ( $opt_c ) {
  @critical=split ",", $opt_c;
}

if ( $opt_w ) {
  @warning=split ",", $opt_w;
}

if ($opt_V) {
	print_revision($PROGNAME, '$Id:$');
	exit $ERRORS{'OK'};
}
 
if (! $opt_U) {
	print_help();
	exit $ERRORS{'OK'};
}

$qryurl = $opt_U;
# need host and port for LWP request
($host, $port) = ($qryurl =~ /http:\/\/(.*?):(.*?)\/.*/g);

$result = 'OK';

$SIG{'ALRM'} = sub {
  print ("ERROR: Alarm signal (Nagios time-out)\n");
  exit $ERRORS{"CRITICAL"};
};


# Query tomcat

$ua = LWP::UserAgent->new();
$ua->credentials("$host:$port", $opt_r, $opt_u, $opt_p);
$response = $ua->get($qryurl);
print "verbose: <BEGIN HTTP response>\n" if $verbose;
print "verbose: response: ". $response->content. "\n" if $verbose;
print "verbose: <END HTTP response>\n" if $verbose;

# $webcontent = undef;
if ($response->is_success) {
  $webcontent=$response->content;

  # not more than 1 result?
  ($numQryResult) = ($webcontent =~ /^OK - Number of results: (\d+)/);
  if ($numQryResult > 1 ) {
    print "Got more ($numQryResult) than 1 result. Please redefine query.\n";
    exit $ERRORS{"UNKNOWN"};
  }
  elsif ($numQryResult == 0 ){
    print "Got no result. Please redefine query.\n";
    exit $ERRORS{"UNKNOWN"};
  }


  # get name-value pairs
  @lines = split "\n", $webcontent;
  for ($i=4 ; $i<$#lines ; $i++) {
    if ( ($qryname, $qryvalue) = ($lines[$i] =~ /^(.*): (\d+)/)) {
      $qryResult{$qryname}=$qryvalue;
    }
    # CompositeData?
    elsif ( $lines[$i] =~ /^(.*?): javax\.management\.openmbean\.CompositeDataSupport\(/ ) {
      ($compname, $compDataContent) = ($lines[$i] =~ /^(.*?): javax\.management\.openmbean\.CompositeDataSupport\(.*,contents=\{(.*)\}\)/);
      @compData = split ",", $compDataContent;
      # split it off
      foreach my $comp (@compData) {
      	# For reference, old RegEx:
      	# ($qryname, $qryvalue) = ($comp =~ /\s*(.*)=(\d+).*/);
        ($qryname, $qryvalue) = ($comp =~ /\s*(.*)=(-?\d+).*/);
        $qryResult{$compname. "_". $qryname}=$qryvalue;
      }
    }
  }
}
else {
  print ("ERROR: ");
  if ($response->content) {
    print $response->content;
  } 
  else {
    print "No repsponse.\n";
  }
  exit $ERRORS{"CRITICAL"};
}

$perfdata = "";
$message = "";

# check for thresholds and build perfdata
$i=0;
foreach $key (sort keys %qryResult) {

  next if ( ( $opt_e ) && ( not $select{$key} ) ) ;

  if ( (defined $critical[$i]) && ($critical[$i] ne "") && ( $qryResult{$key} >= $critical[$i] ) ) {
    print "verbose: critical threshold (#". ($i + 1). ") for ". $key. " = ". $critical[$i]. "\n" if $verbose;
    $result = 'CRITICAL';
    $message .= "critical threshold reached for $key ($qryResult{$key} > $critical[$i]), ";
  }
  elsif ( (defined $warning[$i]) && ($warning[$i] ne "") && ( $qryResult{$key} >= $warning[$i] ) ) {
    print "verbose: warning threshold (#". ($i + 1). ") for ". $key. " = ". $warning[$i]. "\n" if $verbose;
    $result = 'WARNING' if ($result ne 'CRITICAL');
    $message .= "warning threshold reached for $key ($qryResult{$key} > $warning[$i]), ";
  }

  $perfdata .= " $key=$qryResult{$key};;;;";

  $i++;
}

$message =~ s/,$//;
print ("$result $message|$perfdata\n");
exit $ERRORS{$result};


# functions

sub print_usage () {
  print "Usage:";
  print " $PROGNAME -U <jmxqryurl>";
  print " [-r realm]";
  print " [-u username]";
  print " [-p password]";
  print " [-e enable]";
  print " [-c critical list]";
  print " [-w warning list]";
  print " [-h]";
  print " [-V]";
  print " [-v]";
  print "\n";
}

sub print_help () {
  print_revision($PROGNAME, '$Id:$');
  print "Copyright (c) 2009 Oliver Faenger\n\n";
  print_usage();
  print "\n";
  print "\n";
  print "A Nagios plugin (script) that queries mbean information through tomcats JMXProxyServlet.\n";
  print "See http://tomcat.apache.org/tomcat-6.0-doc/manager-howto.html#Using%20the%20JMX%20Proxy%20Servlet\n";
  print "\n";
  print "Query URL:\n";
  print "  -U <jmxqryurl>                            URL of the form you would query\n";
  print "                                            the JMXProxyServlet\n";
  print "Thresholds:\n";
  print "  [-c | --critical                          [<threshold1],[threshold2],...>]\n";
  print "                                            comma-separated list of threshholds\n";
  print "                                            in order of results,\n";
  print "                                            fields may be empty\n";
  print "  [-w | --warning                           [<threshold1],[threshold2],...>]\n";
  print "                                            comma-separated list of threshholds\n";
  print "                                            in order of results,\n";
  print "                                            fields may be empty\n";
  print "Authentication:\n";
  print "  [-r | --realm]                            authentication realm\n";
  print "                                            normaly \"Tomcat Manager Application\"\n";
  print "  [-u | --username]                         the user defined in tomcat-users.xml\n"; 
  print "                                            for the manager app\n";
  print "  [-p | --password]\n";
  print "  [-e | --enable attribute1,attribute2,...] enables list of attributes\n";
  print "                                            if this option ist set, all not explicitly\n";
  print "                                            enabled attributes are disabled.\n";
  print "  [-V | --version]\n";
  print "  [-v | --verbose]\n";
  print "\n";
  print "Examples:\n";
  print "  Query all memory values from mbean java.lang:type=Memory:\n";
  print "  (tomcat has to be started with -Dcom.sun.management.jmxremote)\n";
  print "  ". $PROGNAME. " -U \"http://192.168.0.1:8080/manager/jmxproxy?qry=java.lang:type=Memory\" \\\n";
  print "   -r \"Tomcat Manager Application\" -u nagios -p \"geheim\"\n";
  print "\n";
  print "  Query the number of threads of a listener:\n";
  print "  $PROGNAME -U \"http://192.168.0.2:8080/manager/jmxproxy?qry=Catalina:type=ThreadPool,name=jk-8009\" \\\n";
  print "  -r \"Tomcat Manager Application\" -u nagios -p \"geheim\" \\\n";
  print "  -e currentThreadCount,currentThreadsBusy,minSpareThreads -w 200,100,, -c 300,200\n";
  print "\n";
  # support();
}
