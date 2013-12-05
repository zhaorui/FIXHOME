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
    my $home_uid;
    my $new_uid;
    @nouser = ();
    @nohome = ();
    foreach my $user (glob("$HomeRoot/*"))
    {
        if(-f $user)
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
            chomp ($new_uid = getpwnam($user));
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
    
    #Display the uid map
    if($test)
    {
        printf("%-15s %-30s %-30s %-30s\n",'User','Home','UID Map','GID Map');
        foreach my $user (@_)
        {
            $home_path = File::Spec->catfile($HomeRoot,$user);
            ($new_uid,$new_gid) = (getpwnam($user))[2,3];
            ($prev_uid,$prev_gid) = (stat("$home_path"))[4,5];
            if($new_uid == $prev_uid && $new_gid == $prev_gid)
            {
                next;
            }
            printf("%-15s %-30s ",$user,$home_path);
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
        ($new_uid,$new_gid) = (getpwnam($user))[2,3];
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
        $filename =~ s/([ \$\@!^&*()=\[\]\\;',:{}|"<>?])/\\$1/g; # to fix the special character in file name
        my ($file_uid,$file_gid) = (stat($file))[4,5];

        if(-l $file and !-e $files and $follow)
        {
            #ignore dangling symlink when -f option is enabled
            next;
        }

        if(-l $file and !$follow)
        {
            #if not followd symbolic link, just skip the symbolic file
            next;
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

my $HomePath; # Temp variable to store the root directory of Home.
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
    die "This Script Need Root Permission, Please run with \"sudo\" ";
}

# Detect the running platform and initilize
if($test)
{
    print "Detect running on $OSNAME...\n\n";
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
    die "This platform is not supported.";
}

$HomePath?$HomeRoot=$HomePath
         :print "Use default directory \"$HomeRoot\" as the HomeRoot\n\n";

if (!-d $HomeRoot)
{
    print "Directory $HomeRoot doesn't exist...\n\n";
    Usage();
}


if(@include && @exclude)
{
    print "-i and -e can not be used at the same time\n\n";
    Usage();
}

if(@include)
{
    #validate included users
    my @targets = FilterUsers(@include);
    if(@nouser)
    {
        print "<Error> Users:\t".join("\n\t\t",@nouser)."\ncould not found in the system, ".
              "Please check if you type the right name.\n\n";
    }
    if(@nohome)
    {
        print "<Warning> Users:\t".join("\n\t\t",@nohome)." got no home under $HomeRoot, ".
              "will skip this user while fixing.\n\n";
    }
    if(@nouser)
    {
        Usage();
    }

    #initilize the the uidmap;
    GetAllUsers();
    
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
        print "<Warning> Home:\t".join("\n\t\t",@nouser)."\nwill not be fixed, could not ".
              "find their owner.\n\n";
    }

    #get exclude users and validate whether it is legal
    my @extarget = FilterUsers(@exclude);
    if(@nouser)
    {
        print "<Warning> User:\t".join("\n\t\t",@nouser)."\ncould not found in the system, ".
              "will skip this user while fixing.\n\n";
    }
    if(@nohome)
    {
        print "<Warning> User:\t".join("\n\t\t",@nohome)."\ngot no home under $HomeRoot, ".
              "will skip this user while fixing.\n\n";
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
    print "HomeRoot: ",$HomeRoot."\n";
    print "Include: ",join(',',@include),"\n";
    print "Exclude:",join(',',@exclude),"\n";
    print "uidonly: $uidonly","\n";
    print "test: $test \n";
    print "follow: $follow\n";
}
