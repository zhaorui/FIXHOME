#!/usr/bin/perl -w
use strict;

my @some_array3 = qw/Name3 Email3 Age3/;

my %new_hash;
my $some_key1 = 1234;
my @some_array1 = qw/Name1 Email1 Age1/;
$new_hash{$some_key1} = [@some_array1];

my $some_key2 = 1235;
my @some_array2 = qw/Name2 Email2 Age2/;
$new_hash{$some_key2} = [@some_array2];

my $aref = [1,3,4,"Promiscuous"];
my $arrref = [@some_array3,@some_array2,@some_array1];

print "aref: \n";
for (@$aref){
    print $_." ";
}print "\n";

print "arrref: \n";
for (@$arrref){
    print $_."\n";
}

for ( keys %new_hash ) {
    my @value_array = @{$new_hash{$_}};
    print "Key is $_ and Second element of array is $value_array[1]\n";
}

my $cool;

sub createArray()
{
    $cool = ["I want to ","Love","U !"];
}

sub main()
{
    createArray();
    print @$cool."\n";
}

main;
