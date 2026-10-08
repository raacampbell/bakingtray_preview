
# Currently
Currently the StitchIt package sends data to the web via SSH. It just uploads the last completed section. 
It runs on the analysis PC.
https://github.com/SWC-Advanced-Microscopy/StitchIt/tree/master/code/processDuringAcquistion
It runs in a loop with three threads:
1. A thread that copies data from the acquisition PC to the analysis PC. 
2. A thread that runs some pre-processing to get rid of vignetting and make nicer images.
3. A thread that makes a downsampled version of the last imaged section and it sends it to the web. 

It's using rsync and a shared key. 

It works well for a few reasons. For one, it doesn't burden the acquisition PC with calculating these average images. 
However, sometimes users forget to start it. Or sometimes syncAndCrunch (which coordinates the above) crashes or fails and the update to the web stops. 
Also the existing website is shit and the constraint of having the SSH keys is a problem. 

# The general plan
The work done so far on this project fixes many of the above issues. But we need to decide where to deploy it and how. 

## Deploying on the acquisition PC
If BakingTray on the acquisition PC runs the function, it can do so cheaply because after each section it has access to a low-res preview image that it generates from one channel during its normal acquisition. So it can easily send this. 
With suitable guards in place to avoid the operation crashing the acquisition, this is a good option. 
If the acquisition starts then the web preview will start also. The user will get a preview even if they forget syncAndCrunch or it crashes. 
However, the images will look rubbish as they are low res and full of tiling artifacts. 
To get this to work people have to upgrade BakingTray. This should be easy, but there is always inertia to upgrading acquisition software. 


## Deploying on the analysis PC
This will give better images but it requires the user to run syncAndCrunch and sometimes (about once a month, perhaps) it stops during acquisition. 
It's easier to get users to upgrade this. 


# How to deploy?
The path of least resistance is, frankly, to simply upgrade StitchIt to the new system we have been making. 
However, this ignores the benefits of having it run on BakingTray. 
So I am wondering about a dual approach. 
Briefly, BakingTray is the ground truth and StitchIt adds the icing in terms of nicer images as it goes. 

## My vague plan for code layout
Place the core upload functions that we have spent so much time debugging into StitchIt. 
Ask users to install StichIt alongside BakingTray when they upgrade. 
This BakingTray access to the web upload core, without creating a third package. 
We may need to refactor the web core such that there is a module that just handles upload and then BakingTray functions that handle upload of its last section and StitchIt functions that handle upload of its nicer section. 

## What the user would see
They start the acquisition. Right after they start the website indicates acquisition has started. 
The recipe file is uploaded so the sample name and resolution appear online. 
During slicing of the section, which is slow, BakingTray uploads it section preview image and log files are sent. 
This keeps going. Even if syncAndCrunch is never started the above continues.
Then the acquisition finishes, BakingTray sends that information and it's marked as finished online. 

If the user then also syncAndCrunch, when they navigate to the microscope page they now see a larger pretty image that is RGB. That is from syncAndCrunch. Beneath it are largish thumbnails of the last BakingTray image and the last montage image. Clicking on them enlarges them. 
The thumbnail image on the tile can remain that from BakingTray for now. 


## Implementing that
### Why it could be tricky
Implementing the above is tricky because we have two systems sending data and now have edge cases to consider. 
e.g. what happens if the user stops the acquisition at the microscope but syncAndCrunch is still running and tries to send an image?
What happens if the user then starts a new acquisition with a new sample name, whilst the old syncAndCrunch is still running and tries to send an image?

Other things:
We can't assume that all acquisitions will end gracefully and be marked as ended on the web. 
Sometimes users stop and restart an acquisition. It could be a restart of the same acquisition in the same folder with the same name. 
It could be under a new folder with a new name. The latter would just count as a new acquisition. 

One analysis PC can serve many acquisition PCs. It has to have the token config files for all and choose the correct one. 


### How I think this should work on the back-end
BakingTray is the ground truth. When it starts a new acquisition it should:
1. We need to simplify the token JSON file. I think this is a must. 
The microscope ID leaves the JSON. It is, instead, pulled from the recipe file. 
The server will have access to the recipe file and can find that line and it will know what to do with it. 
No need to specify it twice (JSON and recipe). 
The token should be shared across all microscopes from the same site. That will make life much easier and is no less safe. 
Thus, all acq PCs and all analysis PCs on a site share the same JSON. The analysis PC needs one JSON. 


2. It send the recipe and acquisition log files and last image. It does that every time it finishes a section. 
Presumably data will be landing in a site_id/microscope_id folder
BrainSaw will append the string "acq" to the zip file. That will tell the server to place the data in site_id/microscope_id/acquisition_pc
It will treat those data as ground truth

2. The analysis PC starts its stuff. 
It has a copy of the JSON file with the token and site details. 
It uploads a zip with the string "stitchit" appended to the zip file name. 
This ends up in site_id/microscope_id/analysis_pc on the server
We send not only the images but also the recipe file and the acquisition log file. 

3. The server uses the images in site_id/microscope_id/analysis_pc only if the sample name in the recipe file matches that of the sample name in site_id/microscope_id/acquisition_pc

4. For the above to work well, I think we need to send the recipe and acquisition log files as generic names always. So always have it land and be called "raw_recipe" and "raw_acqlog". That way they will just over-write whatever was there before. 
If we do things this way, then even if StitchIt is pushing old acquisition files to the server they will never be displayed because the server will refuse to plot anything with a sample name that does not match. 

