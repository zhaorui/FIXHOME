#!/bin/sh /usr/share/centrifydc/perl/run
use strict;
use Getopt::Long;
use File::Spec;
use File::Find;
use English qw( -no_match_vars );

my %uidmap;         #The hash table, maps old uid to new uid
my @nouser;         #list of users not found in system, and contain the result from FilterUsers, GetAllUsers
my @nohome;         #list of user who don't have home directory, and contain the result from FilterUsers,GetAllUsers
my $HomeRoot;       #The Root of User's home directory, could be specified by -d option
my @include;        #list of include user by -i option
my @exclude;        #list of exclude user by -e option
my $uidonly = 0;    #value for -u option
my $test = 0;       #value for -t option
my $follow = 0;     #value for -L option, traverse every symbolic link to a directory encounter
my $help = 0;       #value for -h opiton, display the useage of this script.

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

# This function is used to get the history and future UID/GID of the home folder, which
# are the basic information needed by fixing.
#
# $_[0]     Owner of the home
# $_[1]     Home folder location
# $_[2]     Reference of previous home UID
# $_[3]     Reference of previous home GID
# $_[4]     Reference of future home UID
# $_[5]     Reference of future home GID
#
sub GetCurSituation($$$$$$)
{
    my ($user,$home_path,$prev_uid_ref,$prev_gid_ref,$new_uid_ref,$new_gid_ref) = @_;
    my $local_uid;
    my $local_gid;
    my $network_uid;
    my $network_gid;

    ($$prev_uid_ref,$$prev_gid_ref) = (stat("$home_path"))[4,5];
   
    #Standard Local User
    if(!IsADUser($user))
    {
        ($$new_uid_ref,$$new_gid_ref) = (getpwnam($user))[2,3];
    }
    else
    {
        chomp($network_uid = `adquery user $user --attribute _Uid`);
        chomp($network_gid = `adquery user $user --attribute _Gid`);

        #In Mac, once if conflict account appear, only the local account could login 
        #to the system. It's exactly the opposite behavior compared with UNIX/LINUX.
        #So when in such situation, we should use local UID/GID as the future home ownership.
        if($OSNAME eq "darwin")
        {
            system "dscl /Local/Default -read /Users/$user UniqueID > /dev/null 2>&1";
            if($? == 0)
            {
                chomp($local_uid = `dscl /Local/Default -read /Users/$user UniqueID`);
                chomp($local_gid = `dscl /Local/Default -read /Users/$user PrimaryGroupID`);
                $local_uid=~ s/^UniqueID: //;
                $local_gid=~ s/^PrimaryGroupID: //;
                #UID/GID conflict detected and it's not a mobile user,
                #because mobile user's account would be fixed in function "FixMobileAccount"
                if(($local_uid != $network_gid) || ($local_gid != $network_gid))
                {
                    $$new_uid_ref = $local_uid;
                    $$new_gid_ref = $local_gid;
                    return;
                }
            }
        }

        $$new_uid_ref = $network_uid;
        $$new_gid_ref = $network_gid;
    }
}

# Detect if a user is a network user
# if it's network user reutrn 1, else return 0
#
# $_[0]: user's name
# ret:   1 or 0
sub IsADUser($)
{
    my $user = $_[0];
    $user =~ s/^\s*//;
    if($user eq "")
    {
        return 0;
    }
    system "adquery user $user > /dev/null 2>&1";
    return !$?;
}

# Change mobile user's uid/gid. This function is only for Darwin
# 
# $_[0]:    user's name
# $_[1]:    user's new uid
# $_[2]:    user's new gid
#
sub ChangeID($$$)
{
    my ($user,$uid,$gid) = @_;
    if($OSNAME ne "darwin")
    {
        return;
    }

    # validate the inputs
    if(!($uid =~ /^[0-9]+$/) || !($gid =~ /^[0-9]+$/) || !defined($user))
    {
        print "Could not change UID/GID($uid/$gid) for $user";
        return;
    }

    system "dscl /Local/Default -create /Users/$user UniqueID $uid";
    system "dscl /Local/Default -create /Users/$user PrimaryGroupID $gid";
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
    my $local_uid;
    my $local_gid;
    my $net_uid;
    my $net_gid;

    # This funciton is only used to fix the "different value return from 'id' and 'adquery user'"
    # problem, this problem only happen on Mac when use mobile user account.
    if($OSNAME ne "darwin")
    {
        return;
    }

    if($test)
    {
        printf("%-20s %-20s %-10s %-8s %-12s %-12s\n",'LocalUID(Name/Map)','ZoneUID(Name/Map)','LocalGID','ZoneGID','Resolution','ID Map');
    }

    foreach my $user (@_)
    {
        #check if user is mobile user, if not skip it.
        my $ret = `dscl /Local/Default -mcxread /Users/$user com.apple.MCX com.apple.cachedaccounts.CreateAtLogin 2> /dev/null`;
        if(($?!=0)&&($ret ne ""))
        {
            next;
        }
        else
        {
            chomp(my $ret = `dscl /Local/Default -read /Users/$user OriginalAuthenticationAuthority 2> /dev/null`);
            $ret =~ s/OriginalAuthenticationAuthority: //;
            if($ret ne "CentrifyDC")
            {
                #print "NOKEY: $user  $ret\n";
                next;
            }
        }

        chomp($local_uid = `dscl /Local/Default -read /Users/$user UniqueID`);
        chomp($local_gid = `dscl /Local/Default -read /Users/$user PrimaryGroupID`);
        chomp($net_uid = `adquery user $user --attribute _Uid`);
        chomp($net_gid = `adquery user $user --attribute _Gid`);
        $local_uid =~ s/UniqueID: //;
        $local_gid =~ s/PrimaryGroupID: //;

        if(($local_uid != $net_uid) || ($local_gid != $net_gid))
        {
            if($test)
            {
                printf("%-20s %-20s %-10s %-8s %-12s %-12s\n", $local_uid."($user)",$net_uid."($user)",
                $local_gid,$net_gid,'Use Zone ID',$net_uid);
            }
            else
            {
                ChangeID($user, $net_uid, $net_gid);
            }
        }
    }

    if($test)
    {
        print "\n\n";
    }
}

#
# validate specified users, and filter out the illegal users.
# illegal users would be classified by errors (User not exist, Home not exist)
# and would be placed into @nouser or @nohome respectively.
#
#   @_:     users
#   ret:    sorted legal user array
#
sub FilterUsers
{
    @nouser = ();
    @nohome = ();
    my @legal_user = ();
    foreach my $user (@_)
    {
        my $home_path = File::Spec->catfile($HomeRoot,$user);
        if(! defined getpwnam($user))
        {
            push(@nouser,$user);
        }
        elsif(! -d $home_path) #Home Prefix
        {
            push(@nohome,$user);
        }
        else
        {
            push(@legal_user,$user);
        }
    }
    return sort @legal_user;
}


#
# Get all the legal users whose home is under the directory $HomeRoot
# it would also build uidmap for validated user. 
#
#   ret:    sorted legal user array.
#
sub GetAllUsers()
{
    my @all_user = ();
    my $new_uid;
    my $new_gid;
    my $prev_uid;
    my $prev_gid;
    my $home_path;
    @nouser = ();
    @nohome = ();
    foreach my $user (glob("$HomeRoot/*"))
    {
        if(!-d $user)
        {
            next;
        }

        $user =~ s#^$HomeRoot/##;
        $home_path = File::Spec->catfile($HomeRoot,$user);
        chomp $home_path;
        chomp $user;
        if(!defined getpwnam($user))
        {
            push(@nouser,$user);
        }
        else
        {
            push(@all_user,$user);
            #initialize the uid hash table.
            GetCurSituation($user,$home_path,\$prev_uid,\$prev_gid,\$new_uid,\$new_gid);
            $uidmap{$prev_uid} = $new_uid if($prev_uid != $new_uid);
        }
    }
    return sort @all_user;
}

#
# fix the home directory for specified legal users,
# if illegal user been passed in, undef operation would happen.
# use FilterUsers function make sure the users are all legal.
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
   
    # Fix the mobile user's account, make their local UID/GID same with their network one.
    # Mobile account only exist in Mac. For other platform, This function
    # would be automatically skipped.
    FixMobileAccount(@_);

    #Display the uid map
    if($test)
    {
        printf("%-11s %-18s %-30s %-30s\n",'User','Home','UID Map','GID Map');
        foreach my $user (@_)
        {
            $home_path = File::Spec->catfile($HomeRoot,$user);
            GetCurSituation($user,$home_path,\$prev_uid,\$prev_gid,\$new_uid,\$new_gid);
            if($new_uid == $prev_uid && $new_gid == $prev_gid)
            {
                next;
            }
            printf("%-11s %-18s ",$user,$home_path);
            printf("%-30s ",$prev_uid.'=>'.$new_uid);
            printf("%-30s",$prev_gid.'=>'.$new_gid) unless($uidonly);
            print "\n";
        }
        print "\n\n";
        return;
    }
    foreach my $user (@_)
    {
        my @files;#Array to store all the files under the home directory
        $home_path = File::Spec->catfile($HomeRoot,$user);
        GetCurSituation($user,$home_path,\$prev_uid,\$prev_gid,\$new_uid,\$new_gid);
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
        print "$user done.\n";
    }
}

#
# fix all the files in the files array. if file's mode is complete equal to
# the file's previous uid/gid, use the new uid/gid instead of the old one.
# if only uid or gid match, search the uidmap and use new id instead.
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
        
        # to fix the special character in file name
        #$filename =~ s/([ \$\@!^&*()=\[\]\\;',:{}|"<>?])/\\$1/g; 
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

        #print "<symlink found> $file\n" if( -l $file);
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
or die();
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
    print "Your OS: $OSNAME\n";
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

if(@include)
{
    #initilize the the uidmap;
    GetAllUsers();

    #validate included users
    my @targets = FilterUsers(@include);
    if(@nouser)
    {
        print "<Error>\nUsers list below were not found in the system.\n\t".
              join("\n\t",@nouser)."\n".
              "Please check if the user names are entered correctly.\n\n";
        exit 1;
    }
    if(@nohome)
    {
        print "<Warning>\nUsers list below did not have their home directories found under $HomeRoot.\n\t".
              join("\n\t",@nohome)."\n ".
              "These users will be skipped.\n\n";
    }


    #fix the directory
    FixHome(@targets);
}
elsif(@exclude)
{
    #get all the legal user whose home could be fixed
    my @alltargets = GetAllUsers();

    #exclude those home which belong to excluded user
    foreach my $user (@exclude)
    {
        @nouser = grep !/$user/,@nouser;
    }
    if(@nouser)
    {
        print "<Warning>\nOwners of the home directories list below were not found in the system.\n\t".
              join("\n\t",@nouser)."\nThese home directories will be skipped.\n\n";
    }

    #get exclude users and validate whether it is legal
    my @extarget = FilterUsers(@exclude);
    if(@nouser)
    {
        print "<Warning>\nUsers list below were not found in the system.\n\t".
              join("\n\t",@nouser)."\nPlease check if the user names are entered correctly.\n\n ";
    }
    if(@nohome)
    {
        print "<Warning>\nUsers list below did not have their home directories found under $HomeRoot.\n\t".
              join("\n\t",@nohome)."\n".
              "Please check if the user names are entered correctly.\n\n";
    }

    #Calculate the Home need to be fixed and fix them all
    #the @alltargets and @extarget below has to be sorted
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

    FixHome(@targets);
}
else
{
    my @targets = GetAllUsers();
    FixHome(@targets);
}

if($test)
{
    print "fixhome.pl input (or default) options:\n";
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
