#!/usr/bin/perl

use strict;

chomp (my $ret = `datsse`);
print "ret: $ret, $?\n";

my $name = "adhfu#ihjnrbkdbfgsdjfhgnjbehg";
if($name =~ /[#@%]/)
{
    print "we have special character \n";
}
else
{
    print "we don't have any special character\n";
}

my @table = (  [1,2,3],
            [4,5,6],
            [7,8,9],);
print @{$table[2]},"\n";

my %user_info;
my %user_data;
my @result = `getent passwd`;

for (@result){
    chomp;
    my @line = split/:/;
    $user_data{$line[0]} = {
        "name" => $line[0],
        "passwd" => $line[1],
        "uid" => $line[2],
        "gid" => $line[3],
        "gecos" => $line[4],
        "home" => $line[5],
        "shell" => $line[6],};
    $user_info{$line[0]} = [@line];
}
if (!exists $user_info{"xuser"})
{
    print "xuser is NOT exist\n";
}
print "Not exist user, the xuser's home:    ",$user_info{"xuser"}[5],"....\n";
if (exists $user_info{"xuser"})
{
    print "xuser now is exist \n";
}


#for my $name (sort keys %user_data)
#{
#    print $name,":",$user_data{$name}{"uid"},":",$user_data{$name}{"gid"},"\n";
#}
#
#for my $name (sort keys %user_info){
#    #print  $name,"   ",${$user_info{$name}}[5],"   ",${$user_info{$name}}[2];
#    #print  $name,"   ",$$user_info{$name}[5],"   ",$$user_info{$name}[2];
#    #print $name,"   ",$user_info{$name}->[5],"   ",$user_info{$name}->[2];
#    print $name,"   ",$user_info{$name}[5],"   ",$user_info{$name}[2];
#    print "\n";
#}

