# Sage QoL: Quest XP

A World of Warcraft: Forever addon that shades your XP bar with the XP you will have after you turn in the quests you have already completed. The faded gold fill runs from your current XP to current XP plus the XP reward of every quest in your log that is ready to turn in. A thin gold line marks where you will land. Hovering the bar lists each completed quest with its XP and the total.

It also records where each level's XP comes from. Kills, quest turn-ins, exploration, and anything else are each counted, along with the zone you were in. Click the XP bar or type  to open a small window with the split for the current level, such as "Kills 30%, Quests 70%", and the zones that gave the most XP. Drag the window to move it; it remembers where you left it. The arrows step through earlier levels. Tracking starts when the addon is first loaded, so levels before that are not covered.

Commands:

-  opens or closes the window.
-  prints the split for every recorded level to chat.
-  opens the settings, which has the same on/off checkbox.
-  clears the history for this character.
-  prints each XP event and how it was counted for 60 seconds.

It is part of Sage QoL, a personal set of small quality-of-life addons.

## Install

Copy this repository into `World of Warcraft/_forever_/Interface/AddOns/SageQoL_QuestXP`. The folder name must be `SageQoL_QuestXP`.

## Development

```sh
npm install
npm run check
```

`npm run check` confirms the TOC and the Lua files agree and that the Lua parses.
