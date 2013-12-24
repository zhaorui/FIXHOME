#!/usr/bin/perl -w
use strict;

my %os_table;

if(! open CONFIG, "</etc/os-release")
{
    die "You don't have /etc/os-release on your system, are you sure you're using Ubuntu 13.04?\n";
}
while(<CONFIG>)
{
    chomp;
    my ($key,$value) = split/=/;
    $os_table{$key} = $value;
}

for (keys %os_table)
{
    print $_,"    ",$os_table{$_},"\n";
}
