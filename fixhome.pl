#!/usr/bin/perl -w
use strict;
use Getopt::Long;
use File::Spec;
use File::Find;
use English qw( -no_match_vars );

my %uidmap;     #The hash table, maps old uid to new uid
my @nouser;     #list of users not found in system, and contain the result from FilterUsers, GetAllUsers
my @nohome;     #list of user who don't have home directory, and contain the result from FilterUsers,GetAllUsers
my $HomeRoot;   #The Root of User's home directory, could be specified by -d option
my @include=(); #list of include user by -i option
my @exclude=(); #list of exclude user by -e option
my $uidonly=0; #value for -u option
my $test=0;     #value for -t option
my $follow=0;     #value for -L option, traverse every symbolic link to a directory encounter
my $help=0;     #value for -h opiton, display the useage of this script.

sub Usage
{
    print "usage: fixhome.pl [-ufth] [-i|-e user ...] [-d path]\n";
    print "option:\n";
    print "  -i, --include user ... only fix the the specified users\n";
    print "  -e, --exclude user ... fix all the user except the specified users\n";
    print "  -u, --uidonly          only fix the uid while fixing users home, keep gid original\n";
    print "  -f, --follow           traverse the symlink directory when encounter one,\n";
    print "                         when it is disable, only modify the link itself\n";
    print "  -t, --test             list out the action without committing any changes\n";
    print "  -d, --dir directory    specify the root of home, like /User,/home...\n";
    print "  -h, --help             display this message\n";
    exit;
}

#This function would return legal users from the array we pass in , whose home directory could be fixed,
#and reset the global @nouser and @nohome;
sub FilterUsers
{
    @nouser=();
    @nohome=();
    my @legal_user=();
    foreach my $user (@_)
    {
        my $home_path = File::Spec->catfile($HomeRoot,$user);
        if(system "id $user >/dev/null 2>&1")
        {
            push(@nouser,$user);
        }
        elsif(system "ls -d $home_path > /dev/null 2>&1") #Home Prefix
        {
            push(@nohome,$user);
        }
        else
        {
            push(@legal_user,$user);
        }
    }
    sort @legal_user;
}


#This function would return all the legal user who have home directory,
#and empty the nohome/nouser array, and reset the nouser array.
#This function also would initialize the uidmap.
sub GetAllUsers
{
    my @all_user=();
    my $home_uid;
    my $new_uid;
    @nouser=();
    @nohome=();
    foreach my $user (`ls $HomeRoot/`)
    {
        my $home_path = File::Spec->catfile($HomeRoot,$user);
        chomp $home_path;
        chomp $user;
        if(system "id $user >/dev/null 2>&1")
        {
            push(@nouser,$user);
        }
        else
        {
            push(@all_user,$user);
            #initialize the uid hash table.
            $home_uid = (stat($home_path))[4];
            chomp ($new_uid=`id -u $user`);
            $uidmap{$home_uid}=$new_uid if($home_uid!=$new_uid);
        }
    }
    sort @all_user;
}


#This function would fix User's home directory.
sub FixHome
{
    my @files;      #Array to store all the files under the home directory
    my $new_uid;    #user's new uid
    my $new_gid;    #user's new gid
    my $prev_uid;   #user's previous uid, assume it's the same with user's home uid
    my $prev_gid;   #user's previous gid, assume it's the same with user's home gid
    my $home_path;
    print "Would Fix:",join(',',@_),"\n" if($test);
    #Display the uid map
    if($test)
    {
        print "\nThe uidmap:\n";
        while(my ($key,$value) = each %uidmap){
            print "$key => $value\n";
        }
        print "\n\n";
    }
    foreach my $user (@_)
    {
        $home_path = File::Spec->catfile($HomeRoot,$user);
        chomp ($new_uid=`id -u $user`);
        chomp ($new_gid=`id -g $user`);
        $prev_uid = (stat("$home_path"))[4];
        $prev_gid = (stat("$home_path"))[5];
        #Home's mode is correct, don't need to be fixed.
        next if($new_uid==$prev_uid && $new_gid==$prev_gid);
        print "Fix user's home: $home_path \n" if($test);
        #foreach my $file (`find $home_path`)   Cant's solve the space in filename issue
        my %options = (
            wanted      => sub { push(@files,$File::Find::name);},
            follow      => $follow,
            follow_skip => 2
        );
        #Search every files under the home, and keep them in array @files
        find(\%options,$home_path);
        FixFiles($new_uid,$new_gid,$prev_uid,$prev_gid,\@files);
        @files=();
        print "\n\n" if($test);
    }
}

#Used for Travserse the direcory recursively
sub FixFiles
{
    my ($new_uid,$new_gid,$prev_uid,$prev_gid) = @_;
    my @files = @{$_[4]};
    foreach my $file (@files)
    {
        chomp $file;
        my $filename = $file;
        $filename=~s/([ \$\@!^&*()=\[\]\\;',:{}|"<>?])/\\$1/g; # to fix the special character in file name
        my $file_uid = (stat($file))[4];
        my $file_gid = (stat($file))[5];

        if( -l $file and !$follow)
        {
            #print "<symlink found> $file\n";
            # Fix the link itself and no traverse.
            $file_uid = (lstat($file))[4];
            $file_gid = (lstat($file))[5];
            if($prev_uid==$file_uid && $prev_gid==$file_gid)
            {
                $test?print "chown -h $new_uid:$new_gid $file\n"
                     :system "chown -h $new_uid:$new_gid $filename";
            }
            else
            {
                if(exists $uidmap{$file_uid})
                {
                    $test?print "chown -h $uidmap{$file_uid} $file\n"
                         :system "chown -h $uidmap{$file_uid} $filename";
                }
                if($prev_gid==$file_gid)
                {
                    $test?print "chown -h :$new_gid $file\n"
                         :system "chown -h :$new_gid $filename";
                }
            }
        }
        else
        {
           if($prev_uid==$file_uid && $prev_gid==$file_gid)
            {
                $test?print "chown $new_uid:$new_gid $file\n"
                     :system "chown $new_uid:$new_gid $filename";
            }
            else
            {
                if(exists $uidmap{$file_uid})
                {
                    $test?print "chown $uidmap{$file_uid} $file\n"
                         :system "chown $uidmap{$file_uid} $filename";
                }
                if($prev_gid==$file_gid)
                {
                    $test?print "chown :$new_gid $file\n"
                         :system "chown :$new_gid $filename";
                }
            } 
        }
    }
}

my $HomePath; # Temp variable to store the root directory of Home.
GetOptions ('include=s{1,}' => \@include,
            'exclude=s{1,}' => \@exclude,
            'uidonly' => \$uidonly,
            'test' => \$test,
            'dir=s' => \$HomePath,
            'follow' => \$follow,
            'help' => \$help)
or die();

Usage() if $help;

# Test if we have root permission
if ($> != 0)
{
    die "This Script Need Root Permission, Please run with \"sudo\" ";
}

# Detect the running platform and initilize
print "Detect running on $OSNAME...\n\n" if $test;
if($OSNAME eq "darwin")
{
    $HomeRoot="/Users";
}
elsif($OSNAME eq "linux")
{
    $HomeRoot="/home";
}
elsif($OSNAME eq "solaris")
{
    $HomeRoot="/export/home";
}
elsif($OSNAME eq "aix")
{
    $HomeRoot="/home";
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

unless (-d $HomeRoot)
{
    print "Directory $HomeRoot doesn't exist...\n\n";
    Usage();
}


if(@include && @exclude)
{
    print "-i and -e couldn't appear at the same time\n\n";
    Usage();
}

if(@include)
{
    #initilize the the uidmap;
    GetAllUsers();
    my @targets = FilterUsers(@include);
    print "<Error> Users:\t".join("\n\t\t",@nouser)."\ncould not found in the system, ".
          "Please check if you type the right name.\n\n" if(@nouser);
    print "<Warning> Users:\t".join("\n\t\t",@nohome)." got no home under $HomeRoot, ".
          "will skip this user while fixing.\n\n" if(@nohome);
    exit 1 if(@nouser);
    FixHome(@targets);
}
elsif(@exclude)
{
    my @extarget = FilterUsers(@exclude);
    print "<Warning> User:\t".join("\n\t\t",@nouser)."\ncould not found in the system, ".
          "will skip this user while fixing.\n\n" if(@nouser);
    print "<Warning> User:\t".join("\n\t\t",@nohome)."\ngot no home under $HomeRoot, ".
          "will skip this user while fixing.\n\n" if(@nohome);

    my @alltargets = GetAllUsers();
    foreach my $user (@exclude){
        @nouser = grep !/$user/,@nouser;
    }
    print "<Warning> Home:\t".join("\n\t\t",@nouser)."\nwill not be fixed, could not ".
          "find their owner.\n\n";

    print "Exclude Users: ",join(',',@extarget),"\n" if($test);
    print "All Users: ",join(',',@alltargets),"\n" if($test);
    
    my @targets = ();
    my $i = 0;
    my $j = 0;
    while($i<@alltargets && $j<@extarget)
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
