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

# Detect if a user is a network user
# if it's network user reutrn 1, else return 0
#
# $_[0]: user's name
# ret:   1 or 0
sub IsADUser($)
{
    my $user = $_[0];
    if(!defined($user))
    {
        return 0;
    }
    system "adquery user $user > /dev/null 2>&1";
    return !$?;
}

# Obtain home folder name from the user's name, this function support UPN format username.
# Usually, home folder name is same with user's name, unless user's name have one of these
# character "/\[]:;|=,+*?<>@". These character would be instead by "_" in their folder name.
# 
# $_[0]:    user'name
# ret:      full path of user's home folder
sub GetHomeName($)
{
    my $home_name = $_[0];
    my $upn_prefix;
    my $home_path;
    my $tmp_home_name = $home_name;
    $tmp_home_name =~ s/[\/\\\[\]:;|=,+*?<>@]/_/g;

    #Support UPN for user's name
    if ($home_name =~ /(.*)@.*$/)
    {
        my $upn_prefix=$1;
        #deal with cross-forest user
        if(!IsADUser($tmp_home_name))
        {
            $upn_prefix =~ s/[\/\\\[\]:;|=,+*?<>@]/_/g;
            $home_name=$upn_prefix;
            $home_path = File::Spec->catfile($HomeRoot,$home_name);
            return $home_path;
        }
    }

    #deal with current-forest user
    $home_name=$tmp_home_name;
    $home_path = File::Spec->catfile($HomeRoot,$home_name);
    return $home_path;
}

# Changing user's local uid/gid at all platform.
# This function is only Darwin platform
# 
# $_[0]:    user's name
# $_[1]:    user's new uid
# $_[2]:    user's new gid
#
sub ChangeID($$$)
{
    my $user = $_[0];
    my $uid  = $_[1];
    my $gid  = $_[2];

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

# Fix the user's conflict local uid and network uid.
# The conlict happens when mobile user use new uid/gid shceme.
# This funciton is only Darwin platform
#
#  @_:      users
#
sub FixConflictID
{
    my $localuid;
    my $netuid;
    my $netgid;

    # This funciton is only used to fix the "different value return from 'id' and 'adquery user'"
    # problem, this problem only happen on Mac when use mobile user account.
    if($OSNAME ne "darwin")
    {
        return;
    }

    if($test)
    {
        printf("%-23s %-23s %-12s %-12s\n",'LocalUid(Name/Map)','Zone UID(Name/Map)','Resolution','ID Map');
    }

    foreach my $user (@_)
    {
        # conflict uid only happend at network user, if it's not, skip it.
        if(!IsADUser($user))
        {
            next;
        }
        
        # skip the AD user who don't have a local uid.
        system "dscl /Local/Default -read /Users/$user UniqueID > /dev/null 2>&1";
        if($? != 0)
        {
            next;
        }

        chomp($localuid = `dscl /Local/Default -read /Users/$user UniqueID`);
        $localuid =~ s/UniqueID: //;
        chomp($netuid = `adquery user $user --attribute _Uid`);
        chomp($netgid = `adquery user $user --attribute _Gid`);

        if($localuid != $netuid)
        {
            if($test)
            {
                printf("%-23s %-23s %-12s %-12s", $localuid."($user)",$netuid."($user)",'Use Zone ID',$netuid);
                print "\n";
            }
            else
            {
                ChangeID($user, $netuid, $netgid);
            }
        }
    }

    if($test)
    {
        print "\n\n";
    }
}

#
# This function is mainly used to filter out illegal users which be specified after
# the -i or -e option. Illegal users would be classified by errors (User not exist, 
# Home not exist) and would be placed into @nouser or @nohome respectively.
#
#   @_:     users
#   ret:    sorted legal user array
#
sub FilterUsers
{
    @nouser = ();
    @nohome = ();
    my @legal_user = ();
    my $home_path;
    foreach my $user (@_)
    {
        $home_path = GetHomeName($user);
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
    my $home_uid;
    my $new_uid;
    @nouser = ();
    @nohome = ();
    foreach my $user (glob("$HomeRoot/*"))
    {
        if(!-d $user)
        {
            next;
        }

        $user =~ s#^$HomeRoot/##;
        my $home_path = File::Spec->catfile($HomeRoot,$user);
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
            $home_uid = (stat($home_path))[4];
            if(IsADUser($user))
            {
                chomp ($new_uid = `adquery user $user --attribute _Uid`);
            }
            else
            {
                chomp($new_uid = getpwnam($user));
            }
            $uidmap{$home_uid} = $new_uid if($home_uid != $new_uid);
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
   
    # Before fix user's home, fix the conlict uid/gid first.
    FixConflictID(@_);

    #Display the uid map
    if($test)
    {
        printf("%-11s %-18s %-30s %-30s\n",'User','Home','UID Map','GID Map');
        foreach my $user (@_)
        {
            $home_path = GetHomeName($user);
            if(IsADUser($user))
            {
                chomp($new_uid = `adquery user $user --attribute _Uid`);
                chomp($new_gid = `adquery user $user --attribute _Gid`);
            }
            else
            {
                ($new_uid,$new_gid) = (getpwnam($user))[2,3];
            }
            ($prev_uid,$prev_gid) = (stat("$home_path"))[4,5];
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
        $home_path = GetHomeName($user);

        if(IsADUser($user))
        {
            chomp($new_uid = `adquery user $user --attribute _Uid`);
            chomp($new_gid = `adquery user $user --attribute _Gid`);
        }
        else
        {
            ($new_uid,$new_gid) = (getpwnam($user))[2,3];
        }
        ($prev_uid,$prev_gid) = (stat("$home_path"))[4,5];
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
