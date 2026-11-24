.pragma library

// =============================================================================
// PanoramaScenarios.js -- the mock's world: realistic outputs (the case table's fixtures, tools/dev/panorama_cases.json) and the
// saved setups a scenario starts from. Pure data and two builders; PanoramaMockEngine.js runs the rules on it.
//
//   scenarios()          [{ id, label }] for the mockup's picker
//   build(id)            { outs, data, drm, gpuMode, quiet, failNext, engineState, engineWhy, noApply }
//   fixture(key)         a copy of one plug-able output: lg | tv | proj | port4k (and edp)
// =============================================================================

var FX_EDP = {
 "name": "eDP-1",
 "description": "Samsung Display Corp. 0x4180",
 "make": "Samsung Display Corp.",
 "model": "0x4180",
 "serial": "",
 "id": 0,
 "enabled": true,
 "width": 2880,
 "height": 1620,
 "refresh": 120.002,
 "x": 0,
 "y": 0,
 "scale": 1.25,
 "transform": 0,
 "mirrorOf": "",
 "physW": 340,
 "physH": 190,
 "modes": [
  {
   "w": 2880,
   "h": 1620,
   "r": 120.0,
   "preferred": true
  },
  {
   "w": 2880,
   "h": 1620,
   "r": 60.0,
   "preferred": false
  }
 ],
 "backend": "drm",
 "hdr": true,
 "bt2020": true,
 "vrrCapable": false,
 "vrr": 0,
 "bitdepth": 10,
 "cm": "srgb",
 "sdrbrightness": 1,
 "sdrsaturation": 1,
 "driver": "i915"
};

var FX_LG = {
 "name": "DVI-I-1",
 "description": "Acme Displays ACME ULTRAWIDE 0x0000C0DE",
 "make": "Acme Displays",
 "model": "ACME ULTRAWIDE",
 "serial": "0x0000C0DE",
 "id": 1,
 "enabled": true,
 "width": 3440,
 "height": 1440,
 "refresh": 59.973,
 "x": 2304,
 "y": 0,
 "scale": 1,
 "transform": 0,
 "mirrorOf": "",
 "physW": 800,
 "physH": 335,
 "modes": [
  {
   "w": 3440,
   "h": 1440,
   "r": 59.973,
   "preferred": true
  },
  {
   "w": 2560,
   "h": 1080,
   "r": 60.0,
   "preferred": false
  }
 ],
 "backend": "drm",
 "hdr": false,
 "bt2020": false,
 "vrrCapable": false,
 "vrr": 0,
 "bitdepth": 8,
 "cm": "srgb",
 "sdrbrightness": 1,
 "sdrsaturation": 1,
 "driver": "evdi"
};

var FX_TV = {
 "name": "HDMI-A-1",
 "description": "Sony SONY TV  *00",
 "make": "Sony",
 "model": "SONY TV  *00",
 "serial": "",
 "id": 2,
 "enabled": true,
 "width": 1920,
 "height": 1080,
 "refresh": 60.0,
 "x": 5744,
 "y": 0,
 "scale": 1,
 "transform": 0,
 "mirrorOf": "",
 "physW": 1210,
 "physH": 680,
 "modes": [
  {
   "w": 1920,
   "h": 1080,
   "r": 60.0,
   "preferred": true
  },
  {
   "w": 3840,
   "h": 2160,
   "r": 30.0,
   "preferred": false
  }
 ],
 "backend": "drm",
 "hdr": true,
 "bt2020": true,
 "vrrCapable": true,
 "vrr": 0,
 "bitdepth": 8,
 "cm": "srgb",
 "sdrbrightness": 1,
 "sdrsaturation": 1,
 "driver": "nvidia"
};

var FX_PORT4K = {
 "name": "DP-1",
 "description": "ASUS MB16AH 4K L1LMTF012345",
 "make": "ASUS",
 "model": "MB16AH 4K",
 "serial": "L1LMTF012345",
 "id": 3,
 "enabled": true,
 "width": 3840,
 "height": 2160,
 "refresh": 60.0,
 "x": 2304,
 "y": 0,
 "scale": 2,
 "transform": 0,
 "mirrorOf": "",
 "physW": 344,
 "physH": 194,
 "modes": [
  {
   "w": 3840,
   "h": 2160,
   "r": 60.0,
   "preferred": true
  }
 ],
 "backend": "drm",
 "hdr": false,
 "bt2020": false,
 "vrrCapable": false,
 "vrr": 0,
 "bitdepth": 8,
 "cm": "srgb",
 "sdrbrightness": 1,
 "sdrsaturation": 1,
 "driver": "i915"
};

var FX_PROJ = {
 "name": "HDMI-A-1",
 "description": "",
 "make": "",
 "model": "",
 "serial": "",
 "id": 2,
 "enabled": true,
 "width": 1280,
 "height": 800,
 "refresh": 60.0,
 "x": 2304,
 "y": 0,
 "scale": 1,
 "transform": 0,
 "mirrorOf": "",
 "physW": 0,
 "physH": 0,
 "modes": [
  {
   "w": 1280,
   "h": 800,
   "r": 60.0,
   "preferred": true
  }
 ],
 "backend": "drm",
 "hdr": false,
 "bt2020": false,
 "vrrCapable": false,
 "vrr": 0,
 "bitdepth": 8,
 "cm": "srgb",
 "sdrbrightness": 1,
 "sdrsaturation": 1,
 "driver": "nvidia"
};

var DATA_LAPTOP = {
 "v": 1,
 "displays": {
  "Samsung Display Corp. 0x4180": {
   "label": "Laptop",
   "custom": false,
   "internal": true,
   "port": "eDP-1",
   "placeholder": false
  }
 },
 "setups": {
  "Samsung Display Corp. 0x4180": {
   "name": "Laptop",
   "custom": false,
   "used": 100,
   "outputs": {
    "Samsung Display Corp. 0x4180": {
     "enabled": true,
     "mode": "2880x1620@120",
     "position": [
      0,
      0
     ],
     "scale": 1.25,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 10,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    }
   }
  }
 },
 "split": {}
};

var DATA_DESK = {
 "v": 1,
 "displays": {
  "Samsung Display Corp. 0x4180": {
   "label": "Laptop",
   "custom": false,
   "internal": true,
   "port": "eDP-1",
   "placeholder": false
  },
  "Acme Displays ACME ULTRAWIDE 0x0000C0DE": {
   "label": "DisplayLink · ACME ULTRAWIDE",
   "custom": false,
   "internal": false,
   "port": "DVI-I-1",
   "placeholder": false
  }
 },
 "setups": {
  "Samsung Display Corp. 0x4180": {
   "name": "Laptop",
   "custom": false,
   "used": 100,
   "outputs": {
    "Samsung Display Corp. 0x4180": {
     "enabled": true,
     "mode": "2880x1620@120",
     "position": [
      0,
      0
     ],
     "scale": 1.25,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 10,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    }
   }
  },
  "Acme Displays ACME ULTRAWIDE 0x0000C0DE + Samsung Display Corp. 0x4180": {
   "name": "Desk",
   "custom": true,
   "used": 200,
   "outputs": {
    "Samsung Display Corp. 0x4180": {
     "enabled": true,
     "mode": "2880x1620@120",
     "position": [
      0,
      0
     ],
     "scale": 1.25,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 10,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    },
    "Acme Displays ACME ULTRAWIDE 0x0000C0DE": {
     "enabled": true,
     "mode": "3440x1440@59.97",
     "position": [
      -280,
      -1440
     ],
     "scale": 1,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 8,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    }
   }
  }
 },
 "split": {
  "1": "Samsung Display Corp. 0x4180",
  "2": "Samsung Display Corp. 0x4180",
  "3": "Acme Displays ACME ULTRAWIDE 0x0000C0DE"
 }
};

var DATA_ONLY_EXTERNAL = {
 "v": 1,
 "displays": {
  "Samsung Display Corp. 0x4180": {
   "label": "Laptop",
   "custom": false,
   "internal": true,
   "port": "eDP-1",
   "placeholder": false
  },
  "Acme Displays ACME ULTRAWIDE 0x0000C0DE": {
   "label": "DisplayLink · ACME ULTRAWIDE",
   "custom": false,
   "internal": false,
   "port": "DVI-I-1",
   "placeholder": false
  }
 },
 "setups": {
  "Acme Displays ACME ULTRAWIDE 0x0000C0DE + Samsung Display Corp. 0x4180": {
   "name": "Desk",
   "custom": false,
   "used": 5,
   "outputs": {
    "Samsung Display Corp. 0x4180": {
     "enabled": false,
     "mode": "2880x1620@120",
     "position": [
      0,
      0
     ],
     "scale": 1.25,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 10,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    },
    "Acme Displays ACME ULTRAWIDE 0x0000C0DE": {
     "enabled": true,
     "mode": "3440x1440@59.97",
     "position": [
      0,
      0
     ],
     "scale": 1,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 8,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    }
   }
  }
 },
 "split": {}
};

var DATA_MIRROR = {
 "v": 1,
 "displays": {
  "Samsung Display Corp. 0x4180": {
   "label": "Laptop",
   "custom": false,
   "internal": true,
   "port": "eDP-1",
   "placeholder": false
  },
  "Sony SONY TV *00": {
   "label": "HDMI · SONY TV  *00",
   "custom": false,
   "internal": false,
   "port": "HDMI-A-1",
   "placeholder": false
  }
 },
 "setups": {
  "Samsung Display Corp. 0x4180 + Sony SONY TV *00": {
   "name": "Talk",
   "custom": true,
   "used": 9,
   "outputs": {
    "Samsung Display Corp. 0x4180": {
     "enabled": true,
     "mode": "2880x1620@120",
     "position": [
      0,
      0
     ],
     "scale": 1.25,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 10,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    },
    "Sony SONY TV *00": {
     "enabled": true,
     "mode": "1920x1080@60",
     "position": [
      2304,
      0
     ],
     "scale": 1,
     "transform": 0,
     "mirror": true,
     "vrr": 0,
     "bitdepth": 8,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    }
   }
  }
 },
 "split": {}
};

var DATA_ALL_OFF = {
 "v": 1,
 "displays": {
  "Samsung Display Corp. 0x4180": {
   "label": "Laptop",
   "custom": false,
   "internal": true,
   "port": "eDP-1",
   "placeholder": false
  }
 },
 "setups": {
  "Samsung Display Corp. 0x4180": {
   "name": "Laptop",
   "custom": false,
   "used": 1,
   "outputs": {
    "Samsung Display Corp. 0x4180": {
     "enabled": false,
     "mode": "2880x1620@120",
     "position": [
      0,
      0
     ],
     "scale": 1.25,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 10,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    }
   }
  }
 },
 "split": {}
};

var DATA_IMPORTED = {
 "v": 1,
 "displays": {
  "Samsung Display Corp. 0x4180": {
   "label": "Laptop",
   "custom": false,
   "internal": true,
   "port": "eDP-1",
   "placeholder": false
  },
  "port:DVI-I-1": {
   "label": "DisplayLink",
   "custom": false,
   "internal": false,
   "port": "DVI-I-1",
   "placeholder": true
  }
 },
 "setups": {
  "Samsung Display Corp. 0x4180 + port:DVI-I-1": {
   "name": "",
   "custom": false,
   "used": 0,
   "outputs": {
    "Samsung Display Corp. 0x4180": {
     "enabled": true,
     "mode": "2880x1620@120",
     "position": [
      0,
      0
     ],
     "scale": 1.25,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 10,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    },
    "port:DVI-I-1": {
     "enabled": true,
     "mode": "3440x1440@60",
     "position": [
      -280,
      -1440
     ],
     "scale": 1,
     "transform": 0,
     "mirror": false,
     "vrr": 0,
     "bitdepth": 8,
     "cm": "srgb",
     "sdrbrightness": 1,
     "sdrsaturation": 1
    }
   }
  }
 },
 "split": {
  "3": "port:DVI-I-1"
 }
};

var FIXTURES = { edp: FX_EDP, lg: FX_LG, tv: FX_TV, port4k: FX_PORT4K, proj: FX_PROJ };

function _c(o) {
    return JSON.parse(JSON.stringify(o));
}

function fixture(key) {
    return _c(FIXTURES[key]);
}

var LIST = [
    { id: "laptop", label: "Laptop alone" },
    { id: "desk", label: "Desk: laptop + ultrawide above" },
    { id: "projector", label: "Projector (never seen)" },
    { id: "three", label: "Three displays" },
    { id: "onlyExternal", label: "Only the external (laptop off)" },
    { id: "mirror", label: "Mirror the laptop on the TV" },
    { id: "integrated", label: "Integrated mode (HDMI is off)" },
    { id: "dlNoService", label: "DisplayLink dock, no service" },
    { id: "modeFails", label: "A mode that does not take" },
    { id: "connectedOff", label: "Connected but off" },
    { id: "notImported", label: "Not imported yet" }
];

function scenarios() {
    return _c(LIST);
}

function _usb(name, driver, status) {
    return { name: name, driver: driver, status: status };
}

function build(id) {
    var s = { id: id, outs: [], data: _c(DATA_LAPTOP), drm: null, gpuMode: "hybrid", quiet: false, failNext: false, engineState: "active",
              engineWhy: "", noApply: false };
    var edp = fixture("edp");
    s.outs = [edp];
    var conns = [_usb("eDP-1", "i915", "connected")];
    var dl = { connectors: conns, displayLinkUsb: false, displayLinkSince: 0, evdiLoaded: true, displayLinkActive: true };
    s.drm = dl;
    if (id === "desk" || id === "modeFails") {
        s.outs.push(fixture("lg")); s.data = _c(DATA_DESK); dl.displayLinkUsb = true;
        conns.push(_usb("DVI-I-1", "evdi", "connected"));
        s.failNext = id === "modeFails";
    } else if (id === "projector") {
        s.outs.push(fixture("proj"));
        conns.push(_usb("HDMI-A-1", "nvidia", "connected"));
    } else if (id === "three") {
        s.outs.push(fixture("lg"), fixture("tv")); s.data = _c(DATA_DESK); s.quiet = true; dl.displayLinkUsb = true;
        conns.push(_usb("DVI-I-1", "evdi", "connected"), _usb("HDMI-A-1", "nvidia", "connected"));
    } else if (id === "onlyExternal") {
        s.outs.push(fixture("lg")); s.data = _c(DATA_ONLY_EXTERNAL); dl.displayLinkUsb = true;
        conns.push(_usb("DVI-I-1", "evdi", "connected"));
    } else if (id === "mirror") {
        s.outs.push(fixture("tv")); s.data = _c(DATA_MIRROR);
        conns.push(_usb("HDMI-A-1", "nvidia", "connected"));
    } else if (id === "integrated") {
        s.gpuMode = "integrated";
    } else if (id === "dlNoService") {
        dl.displayLinkUsb = true; dl.displayLinkActive = false; dl.displayLinkSince = 1;
    } else if (id === "connectedOff") {
        var tv = fixture("tv"); tv.enabled = false;
        s.outs.push(tv); s.data = _c(DATA_MIRROR); s.noApply = true;
        conns.push(_usb("HDMI-A-1", "nvidia", "connected"));
    } else if (id === "notImported") {
        s.engineState = "missing";
        s.engineWhy = "Panorama is not set up yet: run `lares panorama-import`";
    }
    return s;
}
