.pragma library

// =============================================================================
// TrayMockSpecs.js -- the items TrayMock starts with, as specs for TrayMock.add().
//
//   blueman, nmApplet   the two REAL items of the session, captured:
//                       their SNI properties, the methods they implement, their whole dbusmenu layout -- the entries
//                       Quickshell hides (visible: false) left out, labels as the apps write
//                       them ("_Exit": the mock's TrayMenuModel strips the mnemonics, as
//                       Quickshell does for a real menu), Wi-Fi rows' pixmaps replaced by a
//                       theme icon.
//   chat                a chat app: Activate-capable, a short menu with a checkbox, a
//                       submenu of radio rows, and a status the tooltip says.
//
// spec: { id, title, icon (a URL), status ("Passive"|"Active"|"NeedsAttention"), category,
//         tooltipTitle, tooltipDescription, hasMenu, onlyMenu,
//         methods (of "Activate", "SecondaryActivate", "Scroll"),
//         menu: [{ text, icon, isSeparator, enabled, buttonType (1 check, 2 radio),
//                  checkState (2 checked), children: [...] }] }
// =============================================================================

var blueman = {
    "id": "blueman",
    "title": "blueman",
    "icon": "image://icon/blueman-disabled",
    "status": "Active",
    "category": "Hardware",
    "tooltipTitle": "Bluetooth Disabled",
    "tooltipDescription": "",
    "hasMenu": true,
    "onlyMenu": false,
    "methods": [
        "Activate"
    ],
    "menu": [
        {
            "text": "Turn Bluetooth _On",
            "icon": "image://icon/bluetooth-symbolic"
        },
        {
            "isSeparator": true
        },
        {
            "isSeparator": true
        },
        {
            "text": "Send _Files to Device…",
            "icon": "image://icon/blueman-send-symbolic",
            "enabled": false
        },
        {
            "isSeparator": true
        },
        {
            "text": "Reconnect to…",
            "icon": "image://icon/document-open-recent-symbolic",
            "enabled": false
        },
        {
            "isSeparator": true
        },
        {
            "text": "_Devices…",
            "icon": "image://icon/bluetooth-symbolic",
            "enabled": false
        },
        {
            "text": "Adap_ters…",
            "icon": "image://icon/bluetooth-symbolic",
            "enabled": false
        },
        {
            "text": "_Local Services…",
            "icon": "image://icon/document-properties-symbolic"
        },
        {
            "isSeparator": true
        },
        {
            "text": "_Plugins",
            "icon": "image://icon/application-x-addon-symbolic"
        },
        {
            "text": "_Help",
            "icon": "image://icon/help-about-symbolic"
        },
        {
            "text": "_Exit",
            "icon": "image://icon/application-exit-symbolic"
        }
    ]
};

var nmApplet = {
    "id": "nm-applet",
    "title": "Network",
    "icon": "image://icon/nm-signal-50",
    "status": "Active",
    "category": "SystemServices",
    "tooltipTitle": "",
    "tooltipDescription": "",
    "hasMenu": true,
    "onlyMenu": false,
    "methods": [
        "Scroll",
        "SecondaryActivate",
        "XAyatanaSecondaryActivate"
    ],
    "menu": [
        {
            "text": "Ethernet Network",
            "enabled": false
        },
        {
            "text": "disconnected",
            "enabled": false
        },
        {
            "isSeparator": true
        },
        {
            "text": "Wi-Fi Networks",
            "enabled": false
        },
        {
            "text": "Network 1",
            "icon": "image://icon/network-wireless-signal-good-symbolic"
        },
        {
            "text": "Disconnect"
        },
        {
            "text": "_Available networks",
            "children": [
                {
                    "text": "Network 2",
                    "icon": "image://icon/network-wireless-signal-good-symbolic"
                },
                {
                    "text": "Network 3",
                    "icon": "image://icon/network-wireless-signal-good-symbolic"
                },
                {
                    "text": "Network 4",
                    "icon": "image://icon/network-wireless-signal-good-symbolic"
                }
            ]
        },
        {
            "isSeparator": true
        },
        {
            "text": "_Connect to Hidden Wi-Fi Network…"
        },
        {
            "text": "Create _New Wi-Fi Network…"
        },
        {
            "isSeparator": true
        },
        {
            "text": "_VPN Connections",
            "children": [
                {
                    "text": "_Add a VPN connection…"
                }
            ]
        },
        {
            "isSeparator": true
        },
        {
            "text": "Enable _Networking",
            "buttonType": 1,
            "checkState": 2
        },
        {
            "text": "Enable _Wi-Fi",
            "buttonType": 1,
            "checkState": 2
        },
        {
            "isSeparator": true
        },
        {
            "text": "Connection _Information"
        },
        {
            "text": "Edit Connections…"
        },
        {
            "isSeparator": true
        }
    ]
};

var chat = {
    "id": "chat",
    "title": "Chat",
    "icon": "image://icon/internet-chat",
    "status": "Active",
    "category": "ApplicationStatus",
    "tooltipTitle": "Chat",
    "tooltipDescription": "2 unread",
    "hasMenu": true,
    "onlyMenu": false,
    "methods": [
        "Activate",
        "SecondaryActivate",
        "Scroll"
    ],
    "menu": [
        {
            "text": "_Open Chat"
        },
        {
            "isSeparator": true
        },
        {
            "text": "Do _not disturb",
            "buttonType": 1
        },
        {
            "text": "_Status",
            "children": [
                {
                    "text": "_Online",
                    "buttonType": 2,
                    "checkState": 2
                },
                {
                    "text": "_Away",
                    "buttonType": 2
                },
                {
                    "text": "_Busy",
                    "buttonType": 2
                }
            ]
        },
        {
            "isSeparator": true
        },
        {
            "text": "_Quit"
        }
    ]
};
