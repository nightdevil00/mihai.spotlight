A simple spot-like search tool built for Omarchy
Install using omarchy plugin add https://github.com/nightdevil00/mihai.spotlight.git --enable
Edit your .config/hypr/bindings.lua and add a keybind for the plugin : 
o.bind("ALT + SPACE", "Spotlight launcher", "omarchy-shell shell summon mihai.spotlight '{}'")
You can change the keys as you like.

What can it do:
-Display and launch apps
-Run commands like btop, htop, cd, fastfetch etc.
-Seach and open files by name and extensions
-By appending https://website.example your website is opened in the default browser
-Do simple math calculations

Remove:
omarchy plugin remove mihai.spotlight
remove or comment -- line added in .config/hyrp/binding.lua

Enjoy, feedback or PRs appreciated

