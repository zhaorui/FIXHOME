#!/bin/sh /usr/share/centrifydc/perl/run 

use strict;
use Getopt::Long;
use File::Spec;
use File::Find;
use English qw( -no_match_vars );

use constant {
    NAME    =>  0,
    PASSWD  =>  1,
    UID     =>  2,
    GID     =>  3,
    GECOS   =>  4,
    HOME    =>  5,
    SHELL   =>  6,
};

use constant {
    RED     => "\033[0;40;31m",
    GREEN   => "\033[0;40;92m",
    PURPLE  => "\033[1;40;94m",
    HIGHT   => "\033[1;40;39m",
    CEND    => "\033[0m",
};

#Global hash table contains the basic information of AD Users, initialized by function "GetAllUsers" 
my %aduser_info;

#Global hash table contains mapping relationship between former UID and current UID
my %uidmap;         

#user type classified by function "FilterUser", they're mobile user, conflict user
#local user, inexistent user, homeless user, legal AD user. Only mobile users and 
#legal AD users' home folder would be fixed in the script
my @mobileuser;
my @conflictuser;
my @localuser;
my @nouser;         #in-existent users
my @nohome;         #homeless users

#Global variables keeps options on command line
my $HomeRoot;       #the root directory of users' home specified by -d
my @include;        #users need to be fixed, -i
my @exclude;        #users should not be fixed, -e
my $uidonly = 0;    #only fix UID mode of files, -u
my $test = 0;       #do not commit any change -t
my $follow = 0;     #follow symbolic links, -L
my $help = 0;       #show help usage, -h

sub Usage
{
    print "usage: fixhome.pl [-ufth] [-i|-e user ...] [-d path]\n";
    print "option:\n";
    print "  -i, --include user[,...] only fix the home directory for specified users,\n";
    print "                           users must be separated by comma\n";
    print "  -e, --exclude user[,...] fix all the home directory except for the specified users,\n";
    print "                           users must be separated by comma\n";
    print "  -u, --uidonly            only fix the uid while fixing users home, keep gid as original\n";
    print "  -f, --follow             follow symbolic links\n";
    print "  -t, --test               list out the action without committing any changes\n";
    print "  -d, --dir directory      specify the root of home, like /User,/home...\n";
    print "  -h, --help               display this message\n";
    
    $help?exit 0:exit 1;
}

# Check whether a user is network user or not
# Function return 1 if user is AD user, otherwise return 0
#
# $_[0]: user's name
# ret:   1 or 0
sub IsADUser($)
{
    my $user = $_[0];
    my $result;

    #avoid the empty user name for command "adquery user"
    $user =~ s/^\s*//;
    if($user eq "")
    {
        return 0;
    }
    
    return 1 if exists $aduser_info{$user};
    my $result = `adquery user "$user" 2> /dev/null`;
    if($?==0)
    {
        #New AD user is found, update "aduser_info"
        my @data = split /:/,$result;
        $user = $data[0];
        $aduser_info{$user} = [@data];
        return 1;
    }

    #user is not AD user, or it shall be return at above blocks
    return 0;
}

# Check whether a user is Local user or not
# Function return 1 if user is Local user, otherwise return 0
# Notes: mobile users or conflict users are both network user and local user
#
# $_[0]: user's name
# ret: 1 or 0
sub IsLocalUser($)
{
    my $user = $_[0];
    `dscl /Local/Default -read /Users/\"$user\" UniqueID > /dev/null 2>&1`;
    return 1 if($? == 0);
    return 0;
}

# Check whether a user is  mobile user or not
# Function return 1 if user is a mobile user, else return 0
# This function is for Darwin only, because mobile user only exist in Mac
#
# $_[0]: user's name
# ret: 1 or 0
sub IsMobileUser($)
{
    my $user = $_[0];
    if($OSNAME ne "darwin")
    {
        return 0;
    }

    #First of all, Mobile User is an AD user.
    if(! IsADUser($user))
    {
        return 0;
    }

    #Check if it's a mobile user
    system "dscl /Local/Default -read /Users/\"$user\" AuthenticationAuthority ".
            " 2> /dev/null | grep LocalCachedUser > /dev/null";
    if($?!=0)
    {
        return 0;
    }

    #Pass all the check, mobile user it is
    return 1;
}

# Get user's local UID/GID and network UID/GID
# This function require global hash_table "aduser_info" is initlized.
# If the UID/GID exist, function returns non-negative integer, their value, or
# else empty string would be returned.
#
# $_[0]: user's name
# ret: $local_uid, $local_gid, $net_uid, $net_gid
#
sub GetUGID($)
{
    my $user = $_[0];
    my ($local_uid, $local_gid, $net_uid, $net_gid);

    if(IsLocalUser($user))
    {
        chomp($local_uid = `dscl /Local/Default -read /Users/"$user" UniqueID`);
        chomp($local_gid = `dscl /Local/Default -read /Users/"$user" PrimaryGroupID`);
        $local_uid=~ s/^UniqueID: //;
        $local_gid=~ s/^PrimaryGroupID: //;
    }

    if ( IsADUser($user) )
    {
        ($net_uid,$net_gid) = @{$aduser_info{$user}}[UID,GID];
    }
    
    return ($local_uid, $local_gid, $net_uid, $net_gid);
}

# Change mobile user's local UID/GID 
# This function is for Darwin only
# 
# $_[0]:    user's name
# $_[1]:    user's new uid
# $_[2]:    user's new gid
#
sub ChangeMobileAccountID($$$)
{
    my ($user,$uid,$gid) = @_;
    if($OSNAME ne "darwin")
    {
        return;
    }

    $user =~ s/^\s*//;
    # validate the inputs
    if(!($uid =~ /^[0-9]+$/) || !($gid =~ /^[0-9]+$/) || ($user eq ""))
    {
        print "Could not change UID/GID($uid/$gid) for $user\n";
        return;
    }

    system "dscl /Local/Default -create /Users/\"$user\" UniqueID $uid";
    system "dscl /Local/Default -create /Users/\"$user\" PrimaryGroupID $gid";
}

# Obtain home folder name from the user's name, this function require the "aduser_info",
# please make sure it's initialized first. Normally, the hash table would be initlialized
# in function "FilterUsers" at the very begin of this script.
#
# Usually, home folder name is same with user's name, unless user's name have one of these
# character "/\[]:;|=,+*?<>@". These character would be instead by "_" in their folder name.
# If the user is no AD user, function would return empty string.
# 
# $_[0]:    user'name
# ret:      full path of user's home folder
sub GetHomeName($)
{
    my $user = $_[0];
    my $home_path;

    #We're not concerned about the local user or non-exist user
    if (! IsADUser($user))
    {
        return $home_path;
    }

    #For AD user
    $home_path = $aduser_info{$user}[HOME];

    if(IsMobileUser($user))
    {
        chomp($home_path = `dscl /Local/Default -read /Users/"$user" NFSHomeDirectory`);
        $home_path =~ s/NFSHomeDirectory: //;
    }

    return $home_path;
}


# added for Bug 59022 - Should not change local user's UID and GID when local user and AD user have a conflict
# Check if user is a conflict account or not
#
# $_[0]: user's name
# ret:   if user is not conflict account return 0, else return 1;
sub IsConflictUser($)
{
    my $user = $_[0];
    if(!IsMobileUser($user))
    {
        my ($local_uid, $local_gid, $net_uid, $net_gid) = GetUGID($user);
        if($local_uid ne "" && $local_gid ne "" &&
           $net_uid ne "" && $net_gid ne "")
        {
            if(($local_uid != $net_uid) || ($local_gid != $net_gid))
            {
                return 1;
            }
        }
    }
    return 0;
}

# In Mac, mobile user have a network UID/GID and a local UID/GID, normally they should
# be the same number. However, when we generate UID/GID in a new scheme, only the network
# UID/GID would be changed to the new one. This would cause a conlict UID/GID issue.
# Before fixing the home folder of a mobile user, this issue must be solved first.
#
# Mobile account only exist on Mac, this function would NOT affect any other platfroms.
#
#  @_:      users
#
sub FixMobileAccount
{
    my $found = 0; #flag set to 1, when there's mobile account need to be fixed.
    if($OSNAME ne "darwin")
    {
        return;
    }

    foreach my $user (@_)
    {
        if(!IsMobileUser($user))
        {
            next;
        }

        #Confirm that it's a mobile user, now get its local UID/GID and network UID/GID
        my ($local_uid,$local_gid,$net_uid,$net_gid) = GetUGID($user);

        if(($local_uid != $net_uid) || ($local_gid != $net_gid))
        {
            if($found == 0)
            {
                print "\n";
                print ("   (mobile users' local UID/GID would change to their network UID/GID, before the fixing of homes)\n");
                print PURPLE."###   Table of Strategies for Fixing Mobile Account   ###\n".CEND;
                printf(HIGHT."%-20s %-20s %-10s %-8s %-12s %-12s\n".CEND,
                    'LocalUID(Name/Map)','ZoneUID(Name/Map)','LocalGID','ZoneGID','Resolution','ID Map');
                $found = 1;
            }
            printf("%-20s %-20s %-10s %-8s %-12s %-12s\n", 
                    $local_uid."($user)",$net_uid."($user)",$local_gid,$net_gid,'Use Zone ID',$net_uid);

            if(!$test)
            {
                ChangeMobileAccountID($user, $net_uid, $net_gid);
            }
        }
    }

    if( scalar(@_) != 0)
    {
        print "\n";
    }
}

#
# Validate specified users, and filter out the illegal users.
# Illegal users would be triaged by error (User not exist, Home not exist, local user, conflict users)
# They would be put into respective array. This function would initialize the global hash table - uidmap
#
#   @_:     users
#   ret:    sorted legal user array
#
sub FilterUsers
{
    @localuser = ();
    @nouser    = ();
    @conflictuser = ();
    @nohome    = ();
    @mobileuser = ();

    my @legal_user = ();
    my ($new_uid,$new_gid,$prev_uid,$prev_gid,$home_path);

    foreach my $user (@_)
    {
        #Bug 58524 - Should support UPN format when run fixhome.pl to fix cross forest user's home owner
        #Account with UPN(probably a cross froest user) may be overlooked at function GetAllUsers, 
        #so update aduser_info for UPN is necessary.
        if($user =~ /@/)
        {
            my $result = `adquery user "$user" 2> /dev/null`;
            if($? == 0)
            {
                my @data = split /:/,$result;
                $user = $data[0];
                $aduser_info{$user} = [@data];
                push(@legal_user, $user);
                next;
            }
        }

        $home_path = GetHomeName($user);

        #script only fix AD user now, we'll skip those local user.
        if(!defined getpwnam($user))
        {
            push(@nouser,$user);
        }
        elsif(!IsADUser($user))
        {
            push(@localuser,$user);
        }
        elsif(! -d $home_path) 
        {
            push(@nohome,$user);
        }
        elsif(IsConflictUser($user))
        {
            #Bug 59022 - Should not change local user's UID and GID when local user and AD user have a conflict
            #When conflict accout appear, we should use adfixid to fix them first, it's not the job of fixhome.pl
            push(@conflictuser, $user);
        }
        else
        {
            if(IsMobileUser($user))
            {
                push(@mobileuser, $user);
            }
            push(@legal_user,$user);

            #initialize the "uidmap" to  which the fucntioin "FixFiles" would refer 
            ($prev_uid,$prev_gid) = (stat($home_path))[4,5];
            ($new_uid,$new_gid) = (@{$aduser_info{$user}})[UID,GID];
            $uidmap{$prev_uid} = $new_uid if($prev_uid != $new_uid);
        }
    }

    #Display the warning message for those user we won't fix
    if(@nouser)
    {
        print "Nonexistent users:\n   (homes of below users would be skipped during fixing)\n\t".
              RED.join("\n\t",@nouser)."\n\n".CEND;
    }
    if(@localuser)
    {
        print "Local users:\n   (homes of below users would be skipped during fixing)\n\t".
              RED.join("\n\t",@localuser)."\n\n".CEND;
    }
    if(@nohome)
    {
        print "Homeless users:\n   (homes of below user cannot be found under the $HomeRoot)\n".
              "   (try to use \"-D\" option to specify Home Root Folder, otherwise they would be skipped)\n\t".
              RED.join("\n\t",@nohome)."\n\n".CEND;
    }
    if(@conflictuser)
    {
        print "\n";
        print "   (Conlicting users founded, please use \"adfixid\" or \"Account Migration Tool\" which is for Mac OSX only\n".
              "to fix these accounts first, otherwise they would be ignored while fixing)\n";
        print PURPLE."###   Information of Conflict Account   ###\n".CEND;
        printf(HIGHT."%-10s %-10s %-10s %-10s %-10s %s\n".CEND,
            'Name','LocalUID','ZoneUID','LocalGID','ZoneGID','Home');

        foreach my $user (@conflictuser)
        {
            my ($local_uid,$local_gid,$net_uid,$net_gid) = GetUGID($user);
            printf(RED."%-10s %-10s %-10s %-10s %-10s %s\n".CEND,
                $user,$local_uid,$net_uid,$local_gid,$net_gid,$aduser_info{$user}[HOME]);
        }
        print "\n";
    }

    return sort @legal_user;
}

#
# Get all the legal users whose home is under the directory $HomeRoot
# This function would initialize the aduser_info map. 
#
#   ret:    sorted legal user array.
#
sub GetAllUsers()
{
    my @all_user = ();

    foreach my $user (glob("$HomeRoot/*"))
    {
        if(!-d $user)
        {
            next;
        }

        $user =~ s#^$HomeRoot/##;
        my $adquery_result = `adquery user "$user" 2> /dev/null`;
        if ($? == 0)
        {
            chomp $adquery_result;
            my @data = split (/:/, $adquery_result );
            $aduser_info{$data[NAME]} = [@data];
        }
        chomp $user;
        push (@all_user, $user);
    }
    return sort @all_user;
}

# Fix the home directory for specified legal users
# If illegal user been passed in, undef operation would happen.
# Use FilterUsers function make sure the users are all legal.
#
#   @_: specified legal users
#
sub FixHome
{
    my $new_uid;    #user's new uid
    my $new_gid;    #user's new gid
    my $prev_uid;   #user's previous uid, assume it's the same with user's home uid
    my $prev_gid;   #user's previous gid, assume it's the same with user's home gid
    my $home_path;
    my $found = 0;
   
    # Fix the mobile user's account, make their local UID/GID same with their network one.
    # Mobile account only exist in Mac. For other platform, This function
    # would be automatically skipped.
    FixMobileAccount(@mobileuser);

    #Display the table of strategies of fixing home folder
    foreach my $user (@_)
    {
        $home_path = GetHomeName($user);
        ($prev_uid,$prev_gid) = (stat($home_path))[4,5];
        ($new_uid,$new_gid) = (@{$aduser_info{$user}})[UID,GID];
        if($new_uid == $prev_uid && $new_gid == $prev_gid)
        {
            next;
        }
        if($found == 0)
        {
            $found = 1;
            print ("\n");
            print PURPLE."###   Table of Home Fixing Strategies   ###\n".CEND;
            printf(HIGHT."%-11s %-18s %-30s %-30s\n".CEND,'User','Home','UID Map','GID Map');
        }
        printf("%-11s %-18s ",$user,$home_path);
        printf("%-30s ",$prev_uid.'=>'.$new_uid);
        printf("%-30s",$prev_gid.'=>'.$new_gid) unless($uidonly);
        print "\n";
    }
    if($found == 0)
    {
        print GREEN."No user needs to be fixed\n".CEND;
    }
    print "\n" if $found != 0;

    #if user specify -t option, we shall not commit any change, return immediately.
    return if $test;

    #begin to execute the fix follows the uid map 
    foreach my $user (@_)
    {
        my @files;#Array to store all the files under the home directory
        $home_path = GetHomeName($user);
        ($prev_uid,$prev_gid) = (stat($home_path))[4,5];
        ($new_uid,$new_gid) = (@{$aduser_info{$user}})[UID,GID];
        #Home's mode is correct, don't need to be fixed.
        if($new_uid == $prev_uid && $new_gid == $prev_gid)
        {
            next;
        }
        my %options = (
            wanted          =>  sub { push(@files,$File::Find::name);},
            follow_fast     => $follow,
            follow_skip     => 2
        );
        #Search every files under the home, and keep them in array @files
        find(\%options,$home_path);
        FixFiles($new_uid,$new_gid,$prev_uid,$prev_gid,\@files);
        print GREEN."$user done.\n".CEND;
    }
}

#
# Fix all the files in the files array. if file's mode is totally equal to
# the file's previous UID/GID, use the new UID/GID instead of the old one.
# If only UID or GID match, search the "uidmap" and use new id instead.
#
#   $_[0]:  Files new uid
#   $_[1]:  Files new gid
#   $_[2]:  Files previous uid
#   $_[3]:  Files previous gid
#   $_[4]:  Reference of the files array
#
sub FixFiles($$$$$)
{
    my ($new_uid,$new_gid,$prev_uid,$prev_gid,$files) = @_;
    foreach my $file (@{$files})
    {
        chomp $file;
        my $filename = $file;
        my ($file_uid,$file_gid) = (stat($file))[4,5];

        if(-l $file)
        {
            if($follow)
            {
                if(!-e $file)
                {
                    #ignore dangling symlink when -f option is enabled
                    next;
                }
            }
            else
            {
                #if not followd symbolic link, just skip the symbolic file
                next;
            }
        }

        if($prev_uid == $file_uid && $prev_gid == $file_gid)
        {
            $uidonly?chown($new_uid, -1, $filename)
                    :chown($new_uid, $new_gid, $filename);
        }
        else
        {
            if(exists $uidmap{$file_uid})
            {
                 chown $uidmap{$file_uid}, -1, $filename;
            }
            if($prev_gid == $file_gid)
            {
                 chown(-1, $new_gid, $filename) unless($uidonly);
            }
        } 
    }
}

# Temp variable to store the root directory of Home.
my $HomePath; 

GetOptions ('include=s' => \@include,
            'exclude=s' => \@exclude,
            'uidonly' => \$uidonly,
            'test' => \$test,
            'dir=s' => \$HomePath,
            'follow' => \$follow,
            'help' => \$help)
or Usage();

@include = split(/,/,join(',',@include));
@exclude = split(/,/,join(',',@exclude));

if($help)
{
    Usage();
}

# Test if we have root permission
if ($> != 0)
{
    print "This script needs root permission. Please run with \"sudo\".\n";
    exit 1;
}

# Detect the running platform and initilize
if($test)
{
    print "Platform: $OSNAME\n";
}

if($OSNAME eq "darwin")
{
    $HomeRoot = "/Users";
}
elsif($OSNAME eq "linux")
{
    $HomeRoot = "/home";
}
elsif($OSNAME eq "solaris")
{
    $HomeRoot = "/export/home";
}
elsif($OSNAME eq "aix")
{
    $HomeRoot = "/home";
}
elsif($OSNAME eq "hpux")
{
    $HomeRoot = "/home";
}
else
{
    print "This platform is not supported.\n";
    exit 1;
}

$HomePath?$HomeRoot=$HomePath
         :print "Default HomeRoot: \"$HomeRoot\"\n\n";

if (!-d $HomeRoot)
{
    print "Directory $HomeRoot does not exist.\n\n";
}


if(@include && @exclude)
{
    print "Option -i and -e could not be used at the same time.\n\n";
    Usage();
}

#get all the user we expect to fix, and initialize aduser_info map
my @alltargets = GetAllUsers();

if(@include)
{
    #validate included users, FilterUser would update the aduser_info map for UPN
    my @targets = FilterUsers(@include);
    FixHome(@targets);
}
elsif(@exclude)
{
    #Calculate the Home need to be fixed and fix them all
    #the @alltargets and @extarget below has to be sorted
    my @extarget = sort @exclude;
    my @targets = ();
    my $i = 0;
    my $j = 0;

    while($i < @alltargets && $j < @extarget)
    {
        if($alltargets[$i] eq $extarget[$j])
        {
            $i++;
            $j++;
        }
        elsif($alltargets[$i] gt $extarget[$j])
        {
            $j++;
        }
        else #$alltargets[$i] lt $extarget[$j]
        {
            push(@targets,$alltargets[$i]);
            $i++;
        }
    }
    while($i<@alltargets)
    {
        push(@targets,$alltargets[$i]);
        $i++;
    }
    
    @targets = FilterUsers(@targets);
    FixHome(@targets);
}
else
{
    my @targets = FilterUsers(@alltargets);
    FixHome(@targets);
}

if($test)
{
    print "Input (or default) options:\n";
    print "User included        (-i): ",join(',',@include),"\n";
    print "User excluded        (-e): ",join(',',@exclude),"\n";
    print "Follow option        (-f): ";
    $follow?print "Enable\n":print "Disable\n";
    print "UID only option      (-u): ";
    $uidonly?print "Enable\n":print "Disable\n";
    print "Test option          (-t): ";
    $test?print "Enable\n":print "Disable\n";
    print "Home directories root(-d): ",$HomeRoot."\n";
}
