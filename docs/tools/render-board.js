#!/usr/bin/env node
/* Regenerates the static board marks from the same renderer the landing
   page runs live (static/assets/js/board.js). No packages to install, but
   it needs Node 22 or newer (zlib.crc32):

     node docs/tools/render-board.js

   Run it after changing the board drawing or the five wood tones in
   static/assets/css/01-variables.css — the palette is read from there. */
"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const board = require("../static/assets/js/board.js");

const STATIC = path.join(__dirname, "..", "static");

if (typeof zlib.crc32 !== "function") {
    throw new Error("render-board.js needs Node 22 or newer (zlib.crc32 is missing)");
}

// The five tones, dark to light, straight from the stylesheet.
const css = fs.readFileSync(path.join(STATIC, "assets/css/01-variables.css"), "utf8");
const PALETTE = ["bark", "walnut", "husk", "oak", "sap"].map((name) => {
    const hex = css.match(new RegExp(`--${name}:\\s*#([0-9a-f]{6})`, "i"));
    if (!hex) throw new Error(`--${name} is not a #rrggbb value in 01-variables.css`);
    return [0, 2, 4].map((i) => parseInt(hex[1].slice(i, i + 2), 16));
});

// ---- PNG ------------------------------------------------------------------

function chunk(type, data) {
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const out = Buffer.alloc(body.length + 8);
    out.writeUInt32BE(data.length, 0);
    body.copy(out, 4);
    out.writeUInt32BE(zlib.crc32(body) >>> 0, body.length + 4);
    return out;
}

// RGBA pixels -> PNG file bytes.
function png(w, h, rgba) {
    const raw = Buffer.alloc((w * 4 + 1) * h);
    for (let y = 0; y < h; y++) {
        raw[y * (w * 4 + 1)] = 0; // filter: none
        rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
    }
    const head = Buffer.alloc(13);
    head.writeUInt32BE(w, 0);
    head.writeUInt32BE(h, 4);
    head.set([8, 6, 0, 0, 0], 8); // 8-bit RGBA
    return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        chunk("IHDR", head),
        chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
        chunk("IEND", Buffer.alloc(0)),
    ]);
}

// ---- Board -> pixels --------------------------------------------------------

/* Draws the board on a `size` square of logical pixels, then enlarges each
   one `zoom` times (nearest neighbour, so dither cells stay square).
   `bg` is a palette index for an opaque tile, or null for transparency. */
function mark(size, zoom, { bg = null, ground = "none", fill = 0.82 } = {}) {
    const px = board.render({
        w: size,
        h: size,
        // The board is ~150 units long; `fill` is how much of the tile it spans.
        scale: (size * fill) / 150,
        angle: 0.5,
        light: { x: size * 0.38, y: size * 0.3 },
        ground,
    });
    const out = Buffer.alloc(size * zoom * size * zoom * 4);
    for (let y = 0; y < size * zoom; y++) {
        for (let x = 0; x < size * zoom; x++) {
            let level = px[Math.floor(y / zoom) * size + Math.floor(x / zoom)];
            if (level === board.TRANSPARENT) level = bg;
            if (level === null) continue;
            out.set([...PALETTE[level], 255], (y * size * zoom + x) * 4);
        }
    }
    return { w: size * zoom, h: size * zoom, rgba: out, px, size };
}

function writePng(file, m) {
    fs.writeFileSync(path.join(STATIC, file), png(m.w, m.h, m.rgba));
    console.log(`${file}  ${m.w}x${m.h}`);
}

// One <rect> per horizontal run of same-coloured pixels.
function writeSvg(file, m, bg) {
    let rects = "";
    for (let y = 0; y < m.size; y++) {
        for (let x = 0; x < m.size; ) {
            const level = m.px[y * m.size + x];
            let run = 1;
            while (x + run < m.size && m.px[y * m.size + x + run] === level) run++;
            if (level !== board.TRANSPARENT) {
                const [r, g, b] = PALETTE[level];
                rects += `<rect x="${x}" y="${y}" width="${run}" height="1" fill="rgb(${r},${g},${b})"/>`;
            }
            x += run;
        }
    }
    const [r, g, b] = PALETTE[bg];
    const svg =
        `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${m.size} ${m.size}" shape-rendering="crispEdges">` +
        `<rect width="${m.size}" height="${m.size}" fill="rgb(${r},${g},${b})"/>${rects}</svg>\n`;
    fs.writeFileSync(path.join(STATIC, file), svg);
    console.log(`${file}  ${m.size}x${m.size} (svg)`);
}

// A .ico is a 22-byte directory in front of an ordinary PNG.
function writeIco(file, m) {
    const body = png(m.w, m.h, m.rgba);
    const head = Buffer.alloc(22);
    head.writeUInt16LE(1, 2); // type: icon
    head.writeUInt16LE(1, 4); // one image
    head[6] = m.w;
    head[7] = m.h;
    head.writeUInt16LE(1, 10); // colour planes
    head.writeUInt16LE(32, 12); // bits per pixel
    head.writeUInt32LE(body.length, 14);
    head.writeUInt32LE(22, 18); // offset of the PNG
    fs.writeFileSync(path.join(STATIC, file), Buffer.concat([head, body]));
    console.log(`${file}  ${m.w}x${m.h} (ico)`);
}

/* A vertical ordered-dither fade: solid bark at the top thinning to nothing
   at the bottom, one Bayer period (4 logical pixels) wide so it tiles along
   x. Drawn at `zoom` so CSS never has to rescale it. */
function ramp(rows, zoom) {
    const w = 4 * zoom;
    const h = rows * zoom;
    const rgba = Buffer.alloc(w * h * 4);
    for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
            const lx = Math.floor(x / zoom);
            const ly = Math.floor(y / zoom);
            // Squared, because a few light pixels already read as a much
            // lighter tone: a linear fade looks like it starts at mid-grey.
            const density = 1 - ((ly + 0.5) / rows) ** 2;
            if (density > (board.BAYER[(ly & 3) * 4 + (lx & 3)] + 0.5) / 16) {
                rgba.set([...PALETTE[0], 255], (y * w + x) * 4);
            }
        }
    }
    return { w, h, rgba };
}

// ---- Outputs ---------------------------------------------------------------

const BARK = 0;

// Header mark: transparent, sits on the dark header bar.
writePng("images/board-mark.png", mark(22, 2, { fill: 0.92 }));

// Dither fades: the tall one under the landing hero, the short one under
// the docs header.
writePng("images/dither-ramp.png", ramp(48, 2));
writePng("images/dither-edge.png", ramp(8, 2));

// Favicons: the board on a bark tile.
const tile = { bg: BARK, fill: 0.88 };
writeSvg("icons/favicon.svg", mark(24, 1, tile), BARK);
writeIco("icons/favicon.ico", mark(16, 2, tile));
writePng("icons/favicon-96x96.png", mark(24, 4, tile));
writePng("icons/apple-touch-icon.png", mark(30, 6, tile));
// Maskable icons get cropped to a circle: keep the board inside it.
const maskable = { bg: BARK, fill: 0.66 };
writePng("icons/web-app-manifest-192x192.png", mark(48, 4, maskable));
writePng("icons/web-app-manifest-512x512.png", mark(64, 8, maskable));

// Preview sheets for eyeballing the drawing (not shipped): pass a directory.
if (process.argv[2]) {
    const dir = process.argv[2];
    for (const [name, opts] of [
        ["dark", { bg: BARK, ground: "pool", fill: 0.8 }],
        ["light", { bg: 4, ground: "shadow", fill: 0.72 }],
    ]) {
        const m = mark(200, 3, opts);
        fs.writeFileSync(path.join(dir, `board-${name}.png`), png(m.w, m.h, m.rgba));
    }
    console.log(`previews -> ${dir}`);
}
