# Oled screencare

My laptop has an oled screen. These are prone to image retention and burn-in. I have already adapted a solution for this by nearly always having the hyprland shader called `hyproled` running to cover static elements with a per pixel checkerboard pattern. I even have had another agent once modify the shader script to allow for rounded corners and anti-aliasing on those corners. This solution has worked great for the desktop elements I had up until now, but for the quickshell implementation, we might need to rethink how we handle this.

This module is not a "I tell you what to design, you refine by planning, you implement, I let you iterate" case. Rather it is more of a call for information on what approach we best take.

In the final shell we might have one thick bar, and three slim bars. These bars are static elements, never changing their dimensions, or their contents all that much. That means my forked hyproled script would still work perfectly for this final shell.

Yet there are still some concerns I have, that might make me opt for a quickshell native solution:

- opening a popup will create a harch cuttoff line on the hyprland shader
- maybe performance of this technique could be better if it is quickshell shell native
- if qs native, it might be more context aware and react accordingly. I would not know what to do with this context aware feature, but I could see it being helpful.
- other oled care thechniques like pixel shift could perhaps be implemented in some way, be it bars or icons shifting about, or the entire shell shifting about an unnoticeable amount. Though perhaps the hyproled shader script could also pixel shift the entire hyprland session around.

Now that you know this, I want you to tell me what you think on this. And maybe you can even spawn lets say 10 subagents that also asses this situation, so that the results can be averaged and any non-deterministic drifts LLMs are prone to are eliminated while also all pros and cons are present.

After your conclusion I will take action and we can go into plan mode if needed. I might already initiate this conversation before the biggest parts of the shell are created, but when implementing anything, it might be best to wait untill all is nearly completed to asses where the oledcare could be helpfull, if at all.
