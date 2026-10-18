#!/usr/bin/env node
// Renders App/Resources/AppIcon.svg into the AppIcon.appiconset PNGs (all macOS sizes) and writes
// Contents.json. Needs @resvg/resvg-js, which is not a repo dependency; install it anywhere and
// point NODE_PATH at it, e.g.:
//   npm i --prefix /tmp/resvg @resvg/resvg-js@2.6.2
//   NODE_PATH=/tmp/resvg/node_modules node scripts/make-app-icon.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { Resvg } = require('@resvg/resvg-js');
const root = new URL('..', import.meta.url).pathname;
const svg = readFileSync(`${root}App/Resources/AppIcon.svg`, 'utf8');
const dir = `${root}App/Resources/Assets.xcassets/AppIcon.appiconset`;

const images = [];
for (const points of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const px = points * scale;
    const filename = `icon_${points}x${points}${scale === 2 ? '@2x' : ''}.png`;
    const png = new Resvg(svg, { fitTo: { mode: 'width', value: px } }).render().asPng();
    writeFileSync(`${dir}/${filename}`, png);
    images.push({ filename, idiom: 'mac', scale: `${scale}x`, size: `${points}x${points}` });
  }
}
writeFileSync(`${dir}/Contents.json`, `${JSON.stringify({ images, info: { author: 'xcode', version: 1 } }, null, 2)}\n`);
console.log(`wrote ${images.length} icons to ${dir}`);
