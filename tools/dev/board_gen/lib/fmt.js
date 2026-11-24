"use strict";
// fmt.js -- the number and vector spellings every generated GLSL line uses (four decimals, always a point).
const f = (v) => {
    const s = (Math.round(v * 10000) / 10000).toString();
    return s.indexOf(".") < 0 && s.indexOf("e") < 0 ? s + ".0" : s;
};
const v3 = (a) => `vec3(${f(a[0])}, ${f(a[1])}, ${f(a[2])})`;
const v2 = (a, b) => `vec2(${f(a)}, ${f(b)})`;
const pascal = (name) => name.charAt(0).toUpperCase() + name.slice(1);
module.exports = { f, v3, v2, pascal };
