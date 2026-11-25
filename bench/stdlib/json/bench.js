// The JSON benchmark of Node.js: node bench.js MODE FILE.json
// Prints the best time of one run of MODE, in seconds, or "skip".
// SPDX-License-Identifier: BSD-2-Clause
const fs = require("fs");
const path = require("path");
const [mode, file] = process.argv.slice(2);
const text = fs.readFileSync(file, "utf8");
const paths = JSON.parse(fs.readFileSync(path.join(__dirname, "paths.json"), "utf8"))[path.basename(file, ".json")];
const get = (v, p) => { for (const k of p) v = v[k]; return v; };
function walk(v) {
  let n = 1;
  if (Array.isArray(v)) for (const x of v) n += walk(x);
  else if (v !== null && typeof v === "object") for (const k in v) n += walk(v[k]);
  return n;
}
let sink = 0;
const parsed = JSON.parse(text);
const ops = {
  parse: () => { sink += JSON.parse(text) !== null; },
  query: () => { sink += String(get(JSON.parse(text), paths.query)).length; },
  read3: () => { const d = JSON.parse(text); for (const p of paths.read) sink += String(get(d, p)).length; },
  walk: () => { sink += walk(JSON.parse(text)); },
  encode: () => { sink += JSON.stringify(parsed).length; },
};
if (!ops[mode]) { console.log("skip"); process.exit(0); }
let best = Infinity, total = 0, n = 0;
while (n < 3 || total < 0.5) {
  const t = process.hrtime.bigint();
  ops[mode]();
  const s = Number(process.hrtime.bigint() - t) / 1e9;
  best = Math.min(best, s); total += s; n++;
}
console.log(best.toPrecision(6));
