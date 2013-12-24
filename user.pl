#!/usr/bin/perl -w
use strict;
my %user_info;
my $user_ref = \%user_info;
my @users = ("tom:x:/Users/tom","apple2:x:/home/apple2");

sub main()
{
    my @info;
#    for(my $i=0;$i<@users;$i++)
#    {
    @info = split(/:/,$users[0]);
    @{$user_info{$info[0]}} = @info;
#    }
    print @{$user_ref->{"tom"}}."\n";
}


my %Map;

sub begin()
{
    while(<>)
    {
        chomp;
        my ($city, $country) = split(/, /);
        push @{$Map{$country}}, $city;#How about a function ?
    }

    foreach my $country (sort keys %Map)
    {
#       sort @{$Map{$_}};
        my @citys = sort @{$Map{$country}};
        print $country,": ",@citys;
        print "\n";
    }
}

sub example()
{
    while (<>) {
     chomp;
      my ($city, $country) = split /, /;
      #$Map{$country} = [] unless exists $Map{$country};
      push @{$Map{$country}}, $city;
    }

    foreach my $country (sort keys %Map) {
      print "$country: ";
       my @cities = @{$Map{$country}};
       print join ', ', sort @cities;
       print ".\n";
    }
}

begin;
#example;

#main
#foreach my $line (@users)
#{
#    ${$inof[0]} = $users[]
#    print $info[0]." ".$info[5]."\n";
#}
