

This is a project I started some time ago and want to do properly so I can deploy on the web now. 
Read everything in this folder and the sub-folders so you understand what's here.

What I am doing live in the world right now is here:
https://github.com/SWC-Advanced-Microscopy/StitchIt/tree/master/code/processDuringAcquistion

i.e. The StitchIt MATLAB package uses rsync to send text and images to a static site via a secure key. 
This shows users the state of their acquisition. 


What we will get working today is something a little different. We will modify what you see here. 
We will ultimately add a feature to https://github.com/SWC-Advanced-Microscopy/BakingTray that runs after each section is complete. 
This will send the last completed section preview image and the current state of the microscope.

## Scope
You **don't** need to read through all the BakingTray's code. 
You just need to have a MATLAB function that will accept a matrix to be uploaded. That will be the image.
It should also pull details from the current recipe file and acq log file as the current code does. 
You will find examples in a sub-folder in this dir. 
It should send those to the web using the same approach as that implemented so far here. 

## Constraints
The machines doing the upload are Windows. They have MATLAB. You can't assume anything else. So the setup file I see right now which is a Linux BASH script will not work. 

Create a folder called BakingTray in which you will write all the MATLAB scripts I will need to make this work on the local end. 
This should be a module I can later drop into BakingTray. e.g. `.webpreview/updateSectionImage.m` or whatever. It does not have to have that name. 
This must work on Mac too for testing. 

You should write MATLAB test function that will simulate an acquisition. Making test images and slowly adding to an acq log file every, say, 5 seconds and syncing to the website after I have created the site so I can test it.


## Other
You should feel free to go over the code and make it neater than before. 
