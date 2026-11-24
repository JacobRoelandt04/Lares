# Workspace Particle Presets

Here are 10 unique, refined presets you can copy and paste directly into your `Workspaces { ... }` component. These have been tuned to remain grounded, respecting the physics of the default configuration while still providing distinct visual flavors.

### 1. Heavy Metal Grinding
*Thick, aggressive sparks that brake slightly faster. Looks like an angle grinder hitting steel.*
```qml
Workspaces {
    sparksAmountMultiplier: 45.0
    sparksBaseVelocity: 0.4
    sparksScatter: 500.0
    sparksLifetimeBase: 250.0
    sparksLifetimeVariance: 150.0
    sparksMaxHistory: 3
    sparksSizeStart: 3.5
    sparksSizeEnd: 1.0
    sparksColorStart: "#ffcc00"
    sparksColorEnd: "transparent"
    sparksDrag: 3.8
    sparksSwirlStr: 15.0
    sparksSwirlProb: 0.35
    sparksBloomBlur: 28.0
    sparksBloomStrength: 0.35
}
```

### 2. Fairy Dust
*Magical pink and purple motes that gently float with a soft, natural curve at the end of their lives.*
```qml
Workspaces {
    sparksAmountMultiplier: 25.0
    sparksBaseVelocity: 0.15
    sparksScatter: 250.0
    sparksLifetimeBase: 400.0
    sparksLifetimeVariance: 250.0
    sparksMaxHistory: 2
    sparksSizeStart: 2.5
    sparksSizeEnd: 0.5
    sparksColorStart: "#ff77ff"
    sparksColorEnd: "#5500ff"
    sparksDrag: 2.5
    sparksSwirlStr: 12.0
    sparksSwirlProb: 0.6
    sparksBloomBlur: 32.0
    sparksBloomStrength: 0.4
    sparksBloomBrightness: 1.3
}
```

### 3. Plasma Drive
*A highly focused, straight-line jet of blue energy. Very fast, very short-lived, with longer trails.*
```qml
Workspaces {
    sparksAmountMultiplier: 50.0
    sparksBaseVelocity: 0.6
    sparksScatter: 150.0
    sparksLifetimeBase: 200.0
    sparksLifetimeVariance: 100.0
    sparksMaxHistory: 6
    sparksSizeStart: 2.5
    sparksSizeEnd: 0.0
    sparksColorStart: "#00ffff"
    sparksColorEnd: "transparent"
    sparksDrag: 2.0
    sparksSwirlStr: 5.0
    sparksSwirlProb: 0.2
    sparksBloomBlur: 24.0
    sparksBloomStrength: 0.4
}
```

### 4. Campfire Embers
*Floaty, warm orange embers with slightly lower air resistance, allowing them to drift a bit further before a gentle swirl.*
```qml
Workspaces {
    sparksAmountMultiplier: 20.0
    sparksBaseVelocity: 0.25
    sparksScatter: 350.0
    sparksLifetimeBase: 450.0
    sparksLifetimeVariance: 300.0
    sparksMaxHistory: 3
    sparksSizeStart: 3.5
    sparksSizeEnd: 2.0
    sparksColorStart: "#ff6600"
    sparksColorEnd: "#ff0000"
    sparksDrag: 2.2
    sparksSwirlStr: 18.0
    sparksSwirlProb: 0.4
    sparksBloomBlur: 20.0
    sparksBloomStrength: 0.3
}
```

### 5. Laser Beams
*Elongated, perfectly straight green laser lines that shoot out and vanish with almost no chaotic swirl.*
```qml
Workspaces {
    sparksAmountMultiplier: 25.0
    sparksBaseVelocity: 0.7
    sparksScatter: 100.0
    sparksLifetimeBase: 250.0
    sparksLifetimeVariance: 50.0
    sparksMaxHistory: 8
    sparksSizeStart: 2.0
    sparksSizeEnd: 1.5
    sparksColorStart: "#00ff00"
    sparksColorEnd: "#00ff00"
    sparksDrag: 1.5
    sparksSwirlStr: 0.0
    sparksSwirlProb: 0.0
    sparksBloomBlur: 24.0
    sparksBloomStrength: 0.4
}
```

### 6. Void Anomaly
*A dark, mysterious purple/black effect. The particles move slowly and get caught in a moderate, localized swirl.*
```qml
Workspaces {
    sparksAmountMultiplier: 35.0
    sparksBaseVelocity: 0.1
    sparksScatter: 200.0
    sparksLifetimeBase: 400.0
    sparksLifetimeVariance: 200.0
    sparksMaxHistory: 4
    sparksSizeStart: 4.0
    sparksSizeEnd: 1.0
    sparksColorStart: "#aa00ff"
    sparksColorEnd: "#000000"
    sparksDrag: 2.8
    sparksSwirlStr: 22.0
    sparksSwirlProb: 0.7
    sparksBloomBlur: 32.0
    sparksBloomStrength: 0.2
    sparksBloomBrightness: 0.9
}
```

### 7. Cherry Blossom Wind
*Soft pink petals that gently scatter and gracefully curve away on the wind.*
```qml
Workspaces {
    sparksAmountMultiplier: 15.0
    sparksBaseVelocity: 0.2
    sparksScatter: 300.0
    sparksLifetimeBase: 500.0
    sparksLifetimeVariance: 250.0
    sparksMaxHistory: 2
    sparksSizeStart: 4.5
    sparksSizeEnd: 2.5
    sparksColorStart: "#ffb7c5"
    sparksColorEnd: "transparent"
    sparksDrag: 2.4
    sparksSwirlStr: 16.0
    sparksSwirlProb: 0.65
    sparksBloomBlur: 16.0
    sparksBloomStrength: 0.2
}
```

### 8. Electric Arc
*High-friction cyan static. Emits in an erratic scatter but stops quickly due to higher drag, creating a "zap" look with a sharp tiny swirl.*
```qml
Workspaces {
    sparksAmountMultiplier: 40.0
    sparksBaseVelocity: 0.5
    sparksScatter: 600.0
    sparksLifetimeBase: 200.0
    sparksLifetimeVariance: 100.0
    sparksMaxHistory: 5
    sparksSizeStart: 2.5
    sparksSizeEnd: 0.5
    sparksColorStart: "#ffffff"
    sparksColorEnd: "#0088ff"
    sparksDrag: 4.0
    sparksSwirlStr: 25.0
    sparksSwirlProb: 0.4
    sparksBloomBlur: 28.0
    sparksBloomStrength: 0.5
    sparksBloomBrightness: 1.3
}
```

### 9. Toxic Sludge
*Thick, slow-moving green globs that barely inherit any velocity and just kind of "drip" with high drag.*
```qml
Workspaces {
    sparksAmountMultiplier: 20.0
    sparksBaseVelocity: 0.05
    sparksScatter: 150.0
    sparksLifetimeBase: 450.0
    sparksLifetimeVariance: 150.0
    sparksMaxHistory: 2
    sparksSizeStart: 5.0
    sparksSizeEnd: 3.0
    sparksColorStart: "#88ff00"
    sparksColorEnd: "transparent"
    sparksDrag: 3.5
    sparksSwirlStr: 8.0
    sparksSwirlProb: 0.2
    sparksBloomBlur: 16.0
    sparksBloomStrength: 0.25
}
```

### 10. Subtle Dust
*A highly minimal preset. Perfect if you just want a tiny hint of motion without it being distracting.*
```qml
Workspaces {
    sparksAmountMultiplier: 10.0
    sparksBaseVelocity: 0.15
    sparksScatter: 200.0
    sparksLifetimeBase: 250.0
    sparksLifetimeVariance: 150.0
    sparksMaxHistory: 2
    sparksSizeStart: 2.0
    sparksSizeEnd: 0.5
    sparksColorStart: "#ffffff"
    sparksColorEnd: "transparent"
    sparksDrag: 3.0
    sparksSwirlStr: 10.0
    sparksSwirlProb: 0.3
    sparksBloomBlur: 12.0
    sparksBloomStrength: 0.15
}
```