#!/bin/sh /usr/share/centrifydc/perl/run
use strict;
use Getopt::Long;
use File::Spec;
use File::Find;
use English qw( -no_match_vars );

my %uidmap;         #The hash table, maps old uid to new uid
my %aduser_info;    #key is ad user's name, value is array which contains name, passwd,uid/gid,gecos,home path,and shell.
my @mobileuser;     #list of mobile user, mobile user is only exist in darwin, this array will be filled by subrotine FixMobileAccount
my @localuser;      #list of local user, also the result container of FilterUsers, GetAllUsers
my @nouser;         #list of non-exist user, and contain the result from FilterUsers, GetAllUsers
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
    $user =~ s/^\s*//;
    if($user eq "")
    {
        return 0;
    }

    
    return exists $aduser_info{$user};
}

# Detect if a user is a mobile user
# if it's mobile user return 1, else return 0
#
# $_[0]: user's name
# ret: 1 or 0
sub IsMobileUser($)
{
    my $user = $_[0];
    #Moblie User is only exist in Darwin
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
    system "dscl /Local/Default -mcxread /Users/$user com.apple.MCX 2> /dev/null | grep com.apple.cachedaccounts.CreateAtLogin > /dev/null";
    if($?!=0)
    {
        return 0;
    }

    #I don't think this is necessary, when it comes to mobile user who cross forest,
    #code below would bring trouble.
    #
    #else
    #{
    #    chomp(my $ret = `dscl /Local/Default -read /Users/$user OriginalAuthenticationAuthority 2> /dev/null`);
    #    $ret =~ s/OriginalAuthenticationAuthority: //;
    #    if($ret ne "CentrifyDC")
    #    {
    #        print "$user is Not Mobile user because OriginalAuthenticationAuthority is $ret\n";
    #        return 0;
    #    }
    #}

    #Pass all the check, it is a mobile user
    return 1;
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

    $user =~ s/^\s*//;
    # validate the inputs
    if(!($uid =~ /^[0-9]+$/) || !($gid =~ /^[0-9]+$/) || ($user eq ""))
    {
        print "Could not change UID/GID($uid/$gid) for $user\n";
        return;
    }

    system "dscl /Local/Default -create /Users/$user UniqueID $uid";
    system "dscl /Local/Default -create /Users/$user PrimaryGroupID $gid";
}

# Obtain home folder name from the user's name, this function support UPN format username.
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
    $home_path = $aduser_info{$user}[5];

    #Not just a AD user, it's probably a mobile user
    if($home_path =~ /^\/SMB\// or $home_path =~ /^\/AFP\//)
    {
        if(IsMobileUser($user))
        {
            chomp($home_path = `dscl /Local/Default -read /Users/$user NFSHomeDirectory`);
            $home_path =~ s/NFSHomeDirectory: //;
        }
    }

    return $home_path;
}


#In Mac, once if conflict account appear, only the local account could login 
#to the system. It's exactly the opposite behavior compared with UNIX/LINUX.
#When fixing home with the AD UID, it would cause local user couldn't login to the system.
#So when in such situation, we need to tell customer the conflict account in darwin.
#
#  @_:      users
#
sub CheckAccountConflict
{
    my ($local_uid,$local_gid,$new_uid,$new_gid);
    my $found = 0;

    if($OSNAME ne "darwin")
    {
        return;
    }

    #turn array @mobileuser to a hash table %mobilemap, so we could check if a user is mobile account quickly.
    my %mobilemap = map {$_ => 1} @mobileuser;

    foreach my $user (@_)
    {
        #skip the mobile user account.
        if(exists $mobilemap{$user})
        {
            next;
        }

        system "dscl /Local/Default -read /Users/$user UniqueID > /dev/null 2>&1";
        if($? == 0)
        {
            chomp($local_uid = `dscl /Local/Default -read /Users/$user UniqueID`);
            chomp($local_gid = `dscl /Local/Default -read /Users/$user PrimaryGroupID`);
            $local_uid=~ s/^UniqueID: //;
            $local_gid=~ s/^PrimaryGroupID: //;
            ($new_uid,$new_gid) = @{$aduser_info{$user}}[2,3];
            
            #conflict account detected
            if(($local_uid != $new_uid) || ($local_gid != $new_gid))
            {
                if($found == 0)
                {
                    $found = 1;
                    print "Conflict account has been detected, this may cause problem for user login!\n";
                    printf("%-10s %-10s %-10s %-10s %-10s %s\n",'Name','LocalUID','ZoneUID','LocalGID','ZoneGID','Home');
                }
                printf("%-10s %-10s %-10s %-10s %-10s %s\n",$user,$local_uid,$new_uid,$local_gid,$new_gid,$aduser_info{$user}[5]);
            }
        }
    }
    print("\n") if $found != 0 ;
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
    my ($local_uid,$local_gid,$net_uid,$net_gid);
    my $found = 0;

    # This funciton is only used to fix the "different value return from 'id' and 'adquery user'"
    # problem, this problem only happen on Mac when use mobile user account.
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

        #It is mobile user, now get its local UID/GID and network UID/GID
        chomp($local_uid = `dscl /Local/Default -read /Users/$user UniqueID`);
        chomp($local_gid = `dscl /Local/Default -read /Users/$user PrimaryGroupID`);
        $net_uid = $aduser_info{$user}[2];
        $net_gid = $aduser_info{$user}[3];
        $local_uid =~ s/UniqueID: //;
        $local_gid =~ s/PrimaryGroupID: //;

        if(($local_uid != $net_uid) || ($local_gid != $net_gid))
        {
            if($test)
            {
                if($found == 0)
                {
                    $found = 1;
                    printf("%-20s %-20s %-10s %-8s %-12s %-12s\n",'LocalUID(Name/Map)','ZoneUID(Name/Map)','LocalGID','ZoneGID','Resolution','ID Map');
                }
                printf("%-20s %-20s %-10s %-8s %-12s %-12s\n", $local_uid."($user)",$net_uid."($user)",
                $local_gid,$net_gid,'Use Zone ID',$net_uid);
            }
            else
            {
                ChangeID($user, $net_uid, $net_gid);
            }
            push @mobileuser, $user;
        }
    }

    if($test && $found != 0)
    {
        print "\n";
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
    @localuser = ();
    @nouser    = ();
    @nohome    = ();
    my @legal_user = ();

    foreach my $user (@_)
    {
        #Probably UPN, use adquery directly 
        if($user =~ /@/)
        {
            my $result = `adquery user $user 2> /dev/null`;
            if($? == 0)
            {
                my @data = split /:/,$result;
                $user = $data[0];
                $aduser_info{$user} = [@data];
            }
        }

        my $home_path = GetHomeName($user);
        if(!defined getpwnam($user))
        {
            push(@nouser,$user);
        }
        elsif(!IsADUser($user))
        {
            push(@localuser,$user);
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
    my ($new_uid,$new_gid,$prev_uid,$prev_gid,$home_path);
    @localuser = ();
    @nouser = ();
    @nohome = ();

    foreach my $user (glob("$HomeRoot/*"))
    {
        if(!-d $user)
        {
            next;
        }

        $user =~ s#^$HomeRoot/##;
        $home_path = GetHomeName($user);
        chomp $home_path;
        chomp $user;

        #script only fix AD user now, we'll skip those local user.
        if(!defined getpwnam($user))
        {
            push(@nouser,$user);
        }
        elsif(!IsADUser($user))
        {
            push(@localuser,$user);
        }
        else
        {
            push(@all_user,$user);
            #initialize the uid hash table.
            ($prev_uid,$prev_gid) = (stat($home_path))[4,5];
            ($new_uid,$new_gid) = (@{$aduser_info{$user}})[2,3];
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
    my $found = 0;
   
    # Fix the mobile user's account, make their local UID/GID same with their network one.
    # Mobile account only exist in Mac. For other platform, This function
    # would be automatically skipped.
    FixMobileAccount(@_);

    #Before call this funciton, need to make sure there's no Moblie user in the list, to
    #avoid false alarm of conflict account.
    CheckAccountConflict(@_);

    #Display the uid map
    if($test)
    {
        foreach my $user (@_)
        {
            $home_path = GetHomeName($user);
            ($prev_uid,$prev_gid) = (stat($home_path))[4,5];
            ($new_uid,$new_gid) = (@{$aduser_info{$user}})[2,3];
            if($new_uid == $prev_uid && $new_gid == $prev_gid)
            {
                next;
            }
            if($found == 0)
            {
                $found = 1;
                printf("%-11s %-18s %-30s %-30s\n",'User','Home','UID Map','GID Map');
            }
            printf("%-11s %-18s ",$user,$home_path);
            printf("%-30s ",$prev_uid.'=>'.$new_uid);
            printf("%-30s",$prev_gid.'=>'.$new_gid) unless($uidonly);
            print "\n";
        }
        print "\n" if $found != 0;
        return;
    }

    foreach my $user (@_)
    {
        my @files;#Array to store all the files under the home directory
        $home_path = GetHomeName($user);
        ($prev_uid,$prev_gid) = (stat($home_path))[4,5];
        ($new_uid,$new_gid) = (@{$aduser_info{$user}})[2,3];
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

# initialize the aduser_info hash table.
# username: $aduser_info{"xxx"}[0]
# passwd:   $aduser_info{"xxx"}[1]
# uid:      $aduser_info{"xxx"}[2]
# gid:      $aduser_info{"xxx"}[3]
# gecos:    $aduser_info{"xxx"}[4]
# home:     $aduser_info{"xxx"}[5]
# shell:    $aduser_info{"xxx"}[6]
my @adquery_result = `adquery user`;
for (@adquery_result)
{
    chomp;
    my @data = split/:/;
    $aduser_info{$data[0]} = [@data];
}

if(@include)
{
    #initilize the the uidmap;
    GetAllUsers();

    #validate included users
    my @targets = FilterUsers(@include);
    if(@nouser)
    {
        print "<Warning>\nUsers list below DO NOT exist.\n\t".
              join("\n\t",@nouser)."\n".
              "Please check if the user names are entered correctly,and make sure it is Active Directory User\n\n";
    }
    if(@localuser)
    {
        print "<Warning>\nUsers list below is local user, which would be skipped.\n\t".
              join("\n\t",@localuser)."\n".
              "Only the Active Directory User's home folder could be fixed.\n\n";
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
        print "<Warning>\nOwners of the home directories list below were not found in the domain.\n\t".
              join("\n\t",@nouser)."\nThese home directories will be skipped.\n\n";
    }

    #get exclude users and validate whether it is legal
    my @extarget = FilterUsers(@exclude);
    if(@nouser)
    {
        print "<Warning>\nUsers which you specify below DO NOT exist.\n\t".
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
