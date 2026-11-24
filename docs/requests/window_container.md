# Wayland window container

This module will be a blank popup where any window of hyprland can be dragged into. The reason I want this is because the shell is always a WIP, and I can see myself in some cases lacking a functionality that is already offered by another gui application.

The way we implement this could be very simple, or complex, but more robust. Either we manipulate the hyprland window instance so that it feel as part of the popup, or we create a light wayland compositor capable of the basic wayland features like displaying the window, having input be reacted to and perhaps allowing X11 fallback with Xwayland (iirc the protocol name correctly?). The desicion we make toghether in planning mode, where you touch on the pros and cons of both ways of implementing this, or perhaps there is another way that combines the best of both worlds.

How to interact with this popup would work something like this: I have the blank popup open and drag a hyprland window into it (this window could both be tiled or floating). The hyprland window disappears and a window with the same content appears in the popup. How the dimensions are handled is still up for debate, but perhaps the already establishes resizeable popups like notes has could be used here.

From this point onwards I can interact with the window like it is any other hyprland window as long is it is visible by the popup being open.

The popup can also hold more than one window, but never display more than one at a time. To switch what window is visible, there will have to be a tabselector.

When this popup is not blank, control buttons appear that allow the following: closing the window, making it persistent across boots (launch at boot in that case, content/state I do not expect to be persistent), snap out of popup back to hyprland, a tab selector when more than one window is assigned to this popup, pinnig it (more on that later).

For styling of the window, the only two things I'd like are the corners being rounded and there being a slight dropshadow beneith it.

This popup should have a button, but since I will only use this on occasion, I dont want it to take up space on the bar all the time. That I why I want the button to only be visible when a window is inside it. Calling the popup when blank should then perhaps be bound to a keybind, or maybe some other method that you came up with.

When at least one window is present in the popup, hovering the button should open the popup, and when the cursor leaves the bounds of the popup, it will close again after a slight delay. When the pin button is toggled, it never closes.
