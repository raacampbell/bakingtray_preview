final changes


We can assume the image processing toolbox is installed. 

Some TODOs:

# one
e.g. we don't need shrinkToWidth
Replace it with imresize or whatever from that toolbox. 
Get rid of "shrinkToWidth" we don't need extra cruft like this. 


# two
In zipFolder.m you made the internal function deleteQuietly
This is used once at line 41. 
Just quietly put the contents of deleteQuietly at that location
to get rid of this function and simply have the guard in place in-line


# three
The magnifier is OK on a big screen but on a phone it's annoying. 
Can you suppress it on phones and ideally also tablets?

# MY JOBS
I will convert the section uploader to something that will integrate better into the existing StitchIt code. 
