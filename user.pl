#!/usr/bin/perl -w
use strict;
my %user_info;
my @users = `adquery user`;

for(my $i=0;$i<@users;$i++)
{
    my @info = split(/:/,$users[$i]);
    $user_info{$info[0]} = $users[$i];
}

print $user_info{"apple2"};
print $user_info{"tom"};

#foreach my $line (@users)
#{
#    ${$inof[0]} = $users[]
#    print $info[0]." ".$info[5]."\n";
#}
