// Reusable signature pad (Phase 8b). Extracted from the close modal's inline
// canvas logic so the close modal + the Reports single/batch sign modals share
// one implementation.
//
//   const pad = SignaturePad.mount(canvasEl, { onChange(hasInk) {...} });
//   pad.resize();        // size the canvas — call when it becomes visible
//   pad.clear();         // wipe + reset has-ink (fires onChange(false))
//   pad.isEmpty();       // true until the first stroke
//   pad.toDataUrl();     // PNG data URL (matches the close pad's output)
//
// onChange(hasInk) fires on the first stroke (true) and on clear (false) so the
// host can gate its confirm button + toggle a "signed" class.
(function () {
    'use strict';

    function mount(canvas, opts) {
        opts = opts || {};
        var onChange = typeof opts.onChange === 'function' ? opts.onChange : function () {};
        var ctx = canvas.getContext('2d');
        var drawing = false, hasInk = false;

        function resize() {
            var ratio = window.devicePixelRatio || 1;
            var rect = canvas.getBoundingClientRect();
            canvas.width = rect.width * ratio;
            canvas.height = rect.height * ratio;
            ctx.scale(ratio, ratio);
            ctx.strokeStyle = '#1a1d20';
            ctx.lineWidth = 2;
            ctx.lineCap = 'round';
            ctx.lineJoin = 'round';
        }

        function pos(e) {
            var rect = canvas.getBoundingClientRect();
            var t = e.touches ? e.touches[0] : e;
            return { x: t.clientX - rect.left, y: t.clientY - rect.top };
        }

        function start(e) {
            e.preventDefault();
            drawing = true;
            var p = pos(e);
            ctx.beginPath();
            ctx.moveTo(p.x, p.y);
        }
        function move(e) {
            if (!drawing) return;
            e.preventDefault();
            var p = pos(e);
            ctx.lineTo(p.x, p.y);
            ctx.stroke();
            if (!hasInk) { hasInk = true; onChange(true); }
        }
        function end() { drawing = false; }

        canvas.addEventListener('mousedown', start);
        canvas.addEventListener('mousemove', move);
        canvas.addEventListener('mouseup', end);
        canvas.addEventListener('mouseleave', end);
        canvas.addEventListener('touchstart', start);
        canvas.addEventListener('touchmove', move);
        canvas.addEventListener('touchend', end);

        function clear() {
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            hasInk = false;
            onChange(false);
        }

        return {
            resize: resize,
            clear: clear,
            isEmpty: function () { return !hasInk; },
            toDataUrl: function () { return canvas.toDataURL('image/png'); }
        };
    }

    window.SignaturePad = { mount: mount };
})();
