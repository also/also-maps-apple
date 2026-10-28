// Snapshot of also-maps-site/site/index.html at 27273c5.
// Used by the SVG canvas recorder; refresh deliberately when updating branding.

      const params = new URLSearchParams(location.search);
      const icon = params.has('icon');
      const vision = params.get('icon') === 'vision';
      document.documentElement.classList.toggle('icon', icon);
      document.documentElement.classList.toggle('vision', vision);
      const canvas = document.querySelector('canvas');
      const ctx = canvas.getContext('2d');
      const dark = matchMedia('(prefers-color-scheme: dark)');
      const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

      // World coordinates: x/z lie on the ground; y is building height.
      // Rotate a little around the ground plane, then tilt toward the viewer.
      function project(x, y, z) {
        if (icon) { x += 1; z -= 1; }
        const turn = -0.16;
        const tilt = 0.60;
        const across = x * Math.cos(turn) - z * Math.sin(turn);
        const depth = x * Math.sin(turn) + z * Math.cos(turn);
        const cameraDepth = depth * Math.cos(tilt) + y * Math.sin(tilt);
        const scale = 71 / (1 - cameraDepth / 14);
        return [(icon ? 64 : 310) + across * scale,
          (icon ? 70 : 176) + (depth * Math.sin(tilt) - y * Math.cos(tilt)) * scale];
      }

      function path(points, closed = true) {
        ctx.beginPath();
        points.forEach(([x, y, z], index) => {
          const p = project(x, y, z);
          if (index === 0) ctx.moveTo(...p);
          else ctx.lineTo(...p);
        });
        if (closed) ctx.closePath();
      }

      // Each triangle is a building reduced to two feet and a single peak.
      const buildings = [
        [-1.20, -1.18, 0.26, 0.82],
        [-0.85, -1.05, 0.30, 1.28],
        [-1.05, -0.80, 0.24, 0.57],
        [0.80, 0.82, 0.26, 0.92],
        [1.15, 1.00, 0.30, 1.52],
        [1.00, 1.20, 0.24, 0.66],
        [-1.20, 0.85, 0.14, 0.13],
        [-0.85, 1.00, 0.19, 0.23],
        [-1.05, 1.20, 0.11, 0.17],
      ];

      function draw(time = 0) {
        const bounds = canvas.getBoundingClientRect();
        const ratio = window.devicePixelRatio || 1;
        const width = Math.round(bounds.width * ratio);
        const height = Math.round(bounds.height * ratio);
        if (canvas.width !== width || canvas.height !== height) {
          canvas.width = width;
          canvas.height = height;
        }
        const viewWidth = icon ? 128 : 620;
        const viewHeight = icon ? 128 : 330;
        ctx.setTransform(width / viewWidth, 0, 0, height / viewHeight, 0, 0);
        ctx.clearRect(0, 0, viewWidth, viewHeight);
        const styles = getComputedStyle(document.documentElement);
        ctx.strokeStyle = styles.color;
        ctx.fillStyle = styles.getPropertyValue('--tile').trim();
        ctx.lineWidth = icon ? 2.2 : 1.1;
        ctx.lineJoin = 'round';

        if (icon) {
          if (vision) {
            ctx.fillRect(0, 0, viewWidth, viewHeight);
          } else {
            const edge = 0.555;
            path([[-1 - edge, 0, 1 - edge], [-1 + edge, 0, 1 - edge],
              [-1 + edge, 0, 1 + edge], [-1 - edge, 0, 1 + edge]]);
            ctx.stroke();
            const tileEdge = 0.445;
            path([[-1 - tileEdge, 0, 1 - tileEdge], [-1 + tileEdge, 0, 1 - tileEdge],
              [-1 + tileEdge, 0, 1 + tileEdge], [-1 - tileEdge, 0, 1 + tileEdge]]);
            ctx.fill();
          }
          for (const [x, z, span, height] of buildings.slice(-3)) {
            path([[x - span / 2, 0, z], [x, height, z], [x + span / 2, 0, z]], false);
            ctx.stroke();
          }
          return;
        }

        // A quiet, short loading fault every eight seconds. Keep two holes
        // permanent so the mark also works as a still image.
        const phase = time % 8000;
        const glitch = !reducedMotion.matches && phase > 6400 && phase < 6620;
        const inset = 0.055;
        // Tile-to-tile gaps are twice the inset; leave that same gap
        // between the outermost tile edges and the enclosing outline.
        const edge = 2.5 + inset;
        path([[-edge, 0, -edge], [edge, 0, -edge],
          [edge, 0, edge], [-edge, 0, edge]]);
        ctx.stroke();
        for (let row = 0; row < 5; row++) {
          for (let col = 0; col < 5; col++) {
            if ((row === 1 && col === 3) || (row === 4 && col === 1)) continue;
            if (glitch && row === 2 && col === 0 && phase < 6520) continue;
            const x = col - 2.5;
            const z = row - 2.5;
            const lift = glitch && row === 3 && col === 3 ? 0.09 : 0;
            path([[x + inset, lift, z + inset], [x + 1 - inset, lift, z + inset],
              [x + 1 - inset, lift, z + 1 - inset], [x + inset, lift, z + 1 - inset]]);
            ctx.fill();
          }
        }
        for (const [x, z, span, height] of buildings) {
          const lift = glitch && x > 0 ? 0.09 : 0;
          path([[x - span / 2, lift, z], [x, height + lift, z], [x + span / 2, lift, z]], false);
          ctx.stroke();
        }
      }

      let frame;
      let lastState;
      function animate(time) {
        const phase = time % 8000;
        const state = phase > 6400 && phase < 6520 ? 1 : phase >= 6520 && phase < 6620 ? 2 : 0;
        if (state !== lastState) draw(time);
        lastState = state;
        frame = requestAnimationFrame(animate);
      }
      function start() {
        cancelAnimationFrame(frame);
        lastState = undefined;
        draw();
        if (!icon && !reducedMotion.matches && !document.hidden) frame = requestAnimationFrame(animate);
      }
      new ResizeObserver(() => draw()).observe(canvas);
      dark.addEventListener('change', () => draw());
      reducedMotion.addEventListener('change', start);
      document.addEventListener('visibilitychange', start);
      start();
