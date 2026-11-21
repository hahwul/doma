/* The doma board, drawn as a tone field and ordered-dithered down to the
   five wood tones of the palette.

   One renderer, two consumers: the landing hero mounts it on a <canvas>
   (the pointer moves the light), and docs/tools/render-board.js runs the
   same `render` under Node to produce the static marks (header logo,
   favicons). Keep `render` free of DOM access so both keep working. */
(function (root) {
    "use strict";

    // 4x4 Bayer matrix — the classic ordered-dither threshold map.
    var BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];

    var TRANSPARENT = 255;
    var LEVELS = 5; // bark, walnut, husk, oak, sap — dark to light

    function roundBox(x, y, hx, hy, r) {
        var qx = Math.abs(x) - hx + r;
        var qy = Math.abs(y) - hy + r;
        var ox = Math.max(qx, 0);
        var oy = Math.max(qy, 0);
        return Math.sqrt(ox * ox + oy * oy) + Math.min(Math.max(qx, qy), 0) - r;
    }

    // Smooth union: blends body and handle into the curved neck.
    function smin(a, b, k) {
        var h = Math.max(k - Math.abs(a - b), 0) / k;
        return Math.min(a, b) - h * h * k * 0.25;
    }

    // Signed distance to the board outline in board-local units
    // (u along the long axis, handle at -u; negative = inside).
    function outline(u, v) {
        var body = roundBox(u - 18, v, 50, 35, 10);
        var handle = roundBox(u + 54, v, 27, 11.5, 11.5);
        return smin(body, handle, 16);
    }

    function board(u, v) {
        var du = u + 69;
        var hole = Math.sqrt(du * du + v * v) - 4.6;
        return Math.max(outline(u, v), -hole);
    }

    // Wood grain: warped rings around an off-centre knot, like the logo.
    function grain(u, v) {
        var qx = u - 44;
        var qy = (v - 9) * 1.9;
        var r = Math.sqrt(qx * qx + qy * qy);
        r += 7 * Math.sin(u * 0.045 + v * 0.07) + 3 * Math.sin(v * 0.16 - u * 0.02);
        var ring = (r / 15) % 1;
        // A dark line occupying the first fifth of each ring, soft-edged.
        var line = 1 - Math.min(Math.abs(ring - 0.1) / 0.1, 1);
        return line * line * (3 - 2 * line);
    }

    /* Renders into a Uint8Array of palette indices (TRANSPARENT = none).

       opts:
         w, h      output size in pixels
         scale     pixels per board unit
         angle     radians, counter-clockwise tilt
         light     {x, y} highlight centre in output pixels
         block     dither cell size in pixels (1 = finest; >1 = coarse)
         ground    "pool" (lit patch under the board, for dark pages),
                   "shadow" (checker drop shadow, for light pages), "none" */
    function render(opts) {
        var w = opts.w;
        var h = opts.h;
        var scale = opts.scale;
        var block = Math.max(1, opts.block | 0 || 1);
        var ground = opts.ground || "none";
        var cos = Math.cos(opts.angle);
        var sin = Math.sin(opts.angle);
        var cx = (opts.cx === undefined ? w / 2 : opts.cx) + 4 * scale;
        var cy = opts.cy === undefined ? h / 2 : opts.cy;
        var light = opts.light || { x: w * 0.3, y: h * 0.25 };
        var depth = 5; // slab thickness, in board units, straight down
        var out = new Uint8Array(w * h);
        // Icon sizes: once a pixel is wider than the ink outline, drawing the
        // outline and bevel just erodes the shape (the handle goes first),
        // and the grain turns to noise. Drop the first two, soften the third.
        var tiny = 1 / scale > 2.5;
        var edge = tiny ? 0 : 1.6;
        var bevel = tiny ? 0 : 4;
        var figure = tiny ? 0.2 : 0.42;

        // Output pixel -> board-local coordinates.
        function local(px, py) {
            var x = (px - cx) / scale;
            var y = (py - cy) / scale;
            return [x * cos - y * sin, x * sin + y * cos];
        }

        var lit = local(light.x, light.y);

        for (var y = 0; y < h; y++) {
            for (var x = 0; x < w; x++) {
                // Sample at the centre of the dither cell so coarse blocks
                // stay flat instead of smearing.
                var sx = Math.floor(x / block) * block + block / 2;
                var sy = Math.floor(y / block) * block + block / 2;
                var p = local(sx, sy);
                var d = board(p[0], p[1]);
                var tone = -1;

                if (d < 0) {
                    if (d > -edge) {
                        tone = 0; // ink outline
                    } else {
                        var dx = p[0] - lit[0];
                        var dy = p[1] - lit[1];
                        var glow = Math.exp(-(dx * dx + dy * dy) / 3600);
                        tone = 0.6 + 0.4 * glow - figure * grain(p[0], p[1]);
                        // Soft bevel just inside the outline.
                        if (d > -bevel) tone -= 0.14;
                    }
                } else {
                    // Side face: the same outline, pushed straight down.
                    var s = local(sx, sy - depth * scale);
                    var side = board(s[0], s[1]);
                    if (side < 0) {
                        tone = side > -edge ? 0 : 0.2;
                    } else if (ground === "shadow") {
                        var q = local(sx - 5 * scale, sy - (depth + 7) * scale);
                        if (outline(q[0], q[1]) < 0) tone = 0.5;
                    } else if (ground === "pool") {
                        var gx = (sx - cx) / (w * 0.5);
                        var gy = (sy - cy - h * 0.05) / (h * 0.44);
                        var fall = 1 - (gx * gx + gy * gy);
                        if (fall > 0) tone = 0.34 * fall * fall;
                    }
                }

                var i = y * w + x;
                if (tone < 0) {
                    out[i] = TRANSPARENT;
                    continue;
                }
                var bx = Math.floor(x / block) & 3;
                var by = Math.floor(y / block) & 3;
                var threshold = (BAYER[by * 4 + bx] + 0.5) / 16;
                var level = Math.floor(Math.min(Math.max(tone, 0), 1) * (LEVELS - 1) + threshold);
                if (level > LEVELS - 1) level = LEVELS - 1;
                // A drop shadow is ink on paper: either a dot or nothing.
                if (tone === 0.5 && ground === "shadow" && d >= 0) {
                    level = (x + y) & 1 ? 0 : TRANSPARENT;
                }
                // The pool fades into the page: its darkest level is the page.
                if (level === 0 && d >= 0 && tone > 0 && ground === "pool") level = TRANSPARENT;
                out[i] = level;
            }
        }
        return out;
    }

    var api = { render: render, BAYER: BAYER, TRANSPARENT: TRANSPARENT, LEVELS: LEVELS };

    if (typeof module !== "undefined" && module.exports) {
        module.exports = api;
        return;
    }
    root.DomaBoard = api;

    // ---- Browser: mount on every <canvas data-board> --------------------

    var TONES = ["--bark", "--walnut", "--husk", "--oak", "--sap"];

    // Reads the tones back through a canvas fill style, which normalizes
    // whatever notation the stylesheet uses (#rgb, rgb(), a name) to #rrggbb.
    function palette() {
        var style = getComputedStyle(document.documentElement);
        var probe = document.createElement("canvas").getContext("2d");
        return TONES.map(function (name) {
            probe.fillStyle = "#000";
            probe.fillStyle = style.getPropertyValue(name).trim();
            var hex = probe.fillStyle;
            return [1, 3, 5].map(function (i) {
                return parseInt(hex.substr(i, 2), 16) || 0;
            });
        });
    }

    var FULL_W = 192; // logical pixels at full size
    var FULL_H = 152;

    function mount(canvas) {
        var ctx = canvas.getContext("2d");
        var colors = palette();
        var W = 0;
        var H = 0;
        var zoom = 0;
        var image = null;
        var light = { x: 0, y: 0 };
        var target = { x: 0, y: 0 };
        var block = 1;
        var queued = false;

        function draw() {
            queued = false;
            var px = render({
                w: W,
                h: H,
                scale: (1.05 * W) / FULL_W,
                angle: 0.5,
                light: light,
                block: block,
                ground: canvas.dataset.board || "pool",
            });
            var data = image.data;
            for (var i = 0; i < px.length; i++) {
                var c = px[i] === TRANSPARENT ? null : colors[px[i]];
                var o = i * 4;
                data[o] = c ? c[0] : 0;
                data[o + 1] = c ? c[1] : 0;
                data[o + 2] = c ? c[2] : 0;
                data[o + 3] = c ? 255 : 0;
            }
            ctx.putImageData(image, 0, 0);
            // Ease the light toward the pointer; stop once it has arrived.
            var dx = target.x - light.x;
            var dy = target.y - light.y;
            if (Math.abs(dx) + Math.abs(dy) > 0.5) {
                light.x += dx * 0.18;
                light.y += dy * 0.18;
                schedule();
            }
        }

        function schedule() {
            if (queued) return;
            queued = true;
            requestAnimationFrame(draw);
        }

        /* Whole-number upscaling only, so every dither cell stays square:
           pick the zoom from the room available, then give the canvas as
           many logical pixels as fit at that zoom (a multiple of 4 keeps
           the Bayer tile whole). Narrow screens get a smaller drawing at
           2x rather than the full one at 1x. */
        function fit() {
            var room = canvas.parentElement.clientWidth;
            var z = room >= FULL_W * 3 ? 3 : room >= 300 ? 2 : 1;
            var w = Math.max(64, Math.min(FULL_W, Math.floor(room / z))) & ~3;
            if (w === W && z === zoom) return;
            zoom = z;
            W = w;
            H = Math.round((W * FULL_H) / FULL_W) & ~1;
            canvas.width = W;
            canvas.height = H;
            canvas.style.width = W * zoom + "px";
            canvas.style.height = H * zoom + "px";
            image = ctx.createImageData(W, H);
            light.x = target.x = W * 0.34;
            light.y = target.y = H * 0.3;
            schedule();
        }

        fit();
        window.addEventListener("resize", fit);

        // The pointer is the lamp. Listen on the whole hero so the light
        // follows before the cursor reaches the canvas itself.
        var stage = canvas.closest("[data-board-stage]") || canvas;
        stage.addEventListener("pointermove", function (e) {
            var box = canvas.getBoundingClientRect();
            target.x = ((e.clientX - box.left) / box.width) * W;
            target.y = ((e.clientY - box.top) / box.height) * H;
            schedule();
        });

        // One load moment: the board resolves from coarse cells to fine.
        // (fit() has already queued the plain, final frame.)
        if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
        var steps = [16, 12, 8, 6, 4, 3, 2, 1];
        (function develop(i) {
            block = steps[i];
            draw();
            if (i + 1 < steps.length) setTimeout(develop, 85, i + 1);
        })(0);
    }

    function init() {
        var nodes = document.querySelectorAll("canvas[data-board]");
        for (var i = 0; i < nodes.length; i++) mount(nodes[i]);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", init);
    } else {
        init();
    }
})(typeof window !== "undefined" ? window : this);
