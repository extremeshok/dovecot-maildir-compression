#!/bin/sh

# Find the mails you want to compress in a single maildir.
#
#     Skip files that don't have ,S=<size> in the filename. 
#
# Compress the mails to tmp/
#
#     Update the compressed files' mtimes to be the same as they were in the original files (e.g. touch command) 
#
# Run maildirlock <path> <timeout>. It writes PID to stdout, save it.
#
#     <path> is path to the directory containing Maildir's dovecot-uidlist (the control directory, if it's separate)
# 
#     <timeout> specifies how long to wait for the lock before failing. 
#
# If maildirlock grabbed the lock successfully (exit code 0) you can continue.
# For each mail you compressed:
#
#     Verify that it still exists where you last saw it.
#     If it doesn't exist, delete the compressed file. Its flags may have been changed or it may have been expunged. This happens rarely, so just let the next run handle it.
#
#     If the file does exist, rename() (mv) the compressed file over the original file.
#
#         Dovecot can now read the file, but to avoid compressing it again on the next run, you'll probably want to rename it again to include e.g. a "Z" flag in the file name to mark that it was compressed (e.g. 1223212411.M907959P17184.host,S=3271:2,SZ). Remember that the Maildir specifications require that the flags are sorted by their ASCII value, although Dovecot itself doesn't care about that. 
#
# Unlock the maildir by sending a TERM signal to the maildirlock process (killing the PID it wrote to stdout). 

## Based on: https://gist.github.com/cs278/1490556
## <http://ivaldi.nl/blog/2011/12/06/compressed-mail-in-dovecot/>
##

store=/tmp/mail/srv/mail
compress=gzip
#compress=bzip2

find "$store" -type d -name "cur" | while read maildir;
do
	tmpdir=$(cd "$maildir/../tmp" &>/dev/null && pwd) || exit 1

	find=$(find "$maildir" -type f -name "*,S=*" -mtime +30 ! -name "*,*:2,*,*Z*" -printf "%f\n")

	if [ -z "$find" ];
	then
		continue
	fi

	echo "$find" | while read filename;
	do
		srcfile="$maildir/$filename"
		tmpfile="$tmpdir/$filename"

		$compress --best --stdout "$srcfile" > "$tmpfile" &&

		# Copy over some things
		chown --reference="$srcfile" "$tmpfile" &&
		chmod --reference="$srcfile" "$tmpfile" &&
		touch --reference="$srcfile" "$tmpfile"
	done

	# Should really check dovecot-uidlist is in $maildir/..
	if lock=$(/usr/lib/dovecot/maildirlock "$maildir/.." 10);
	then
		# The directory is locked now

		echo "$find" | while read filename;
		do
			flags=$(echo $filename | awk -F:2, '{print $2}')

			if echo $flags | grep ',';
			then
				newname=$filename"Z"
			else
				newname=$filename",Z"
			fi

			srcfile=$maildir/$filename
			tmpfile=$tmpdir/$filename
			dstfile=$maildir/$newname

			if [ -f "$srcfile" ] && [ -f "$tmpfile" ];
			then
				#echo "$srcfile -> $dstfile"

				mv "$tmpfile" "$srcfile" &&
				mv "$srcfile" "$dstfile"
			else
				rm -f "$tmpfile"
			fi
		done

		kill -SIGTERM $lock
	else
		echo "Failed to lock: $maildir" >&2

		echo "$find" | while read filename;
		do
			rm -f "$tmpdir/$filename"
		done
	fi
done
