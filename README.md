FIXHOME
=======
Author: Bill Zhao

Platform: 
---------
All Platform except Windows.

Description: 
------------
Fixhome.pl is used to fix the broken home directory, which uid/gid is a mess. it would use the owner's uid and gid to fix all the files under the home directory and it assume the current home uid/gid is the previous uid/gid of user. So please be absolutely clear when you're using this script. Sorry,I won't promise it won't casue other problem.

Options: 
---------
    * -i --include [users,...]include the only user you want to fix.
    * -e --exclude [users,...]exclude the user you don't want to fix.
    * -d [dir] choose the directory as the Home Root.
    * -u only fix the Home directory's uid.
    * -f traverse the symlink directory when we encount one.
    * -h show this help message 
    
Bugs: 
------
not support network share file yet.

