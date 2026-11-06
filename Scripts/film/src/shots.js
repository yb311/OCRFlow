// The film, shot by shot.
import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import {
  C, CLEAN, FONT, H, LANG, W, backdrop, canvas, cardMaterial, clamp, col, dust, glowSprite, inCubic, inOut, inOutQuint,
  lerp, outBack, outCubic, outExpo, outQuint, pulse, rng, roundedAlpha, rrect, scanSheetMaterial, seg, smooth,
  smoother, texture, words,
} from './core.js';
import { desktop, docAtlas, heroPage, slideAtlas, tallPage } from './docs.js';

export const DURATION = 48;
export const TRANSITIONS = [
  { at: 6.9, length: 0.9 },
  { at: 15.3, length: 0.8 },
  { at: 22.0, length: 0.8 },
  { at: 27.3, length: 0.8 },
  { at: 36.4, length: 0.8 },
  { at: 41.6, length: 0.9 },
];

// --- type -----------------------------------------------------------------------
const cjk = (s) => /[　-鿿]/.test(s);

/** A line whose words rise out of nothing, one after another, and leave together. */
function title(g, text, x, y, size, t, tIn, tOut, { align = 'center', weight = 600, color = C.paper, stagger = 0.07, font = FONT.ui, spacing = -0.012 } = {}) {
  if (CLEAN || t < tIn || t > tOut + 0.5) return;
  const parts = cjk(text) ? [...text] : text.split(/(?<= )/);
  const each = cjk(text) ? stagger * 0.45 : stagger;
  g.save();
  g.font = `${weight} ${size}px ${font}`;
  g.letterSpacing = `${size * spacing}px`;
  g.textBaseline = 'alphabetic';
  const total = g.measureText(text).width;
  let cx = align === 'center' ? x - total / 2 : align === 'right' ? x - total : x;
  const leave = 1 - smooth(seg(t, tOut, tOut + 0.45));
  g.textAlign = 'left';
  parts.forEach((part, i) => {
    const k = outQuint(seg(t, tIn + i * each, tIn + i * each + 0.75));
    const w = g.measureText(part).width;
    g.globalAlpha = k * leave;
    g.filter = k < 0.98 ? `blur(${(1 - k) * size * 0.14}px)` : 'none';
    g.fillStyle = color;
    g.fillText(part, cx, y + (1 - k) * size * 0.42 - (1 - leave) * size * 0.2);
    cx += w;
  });
  g.restore();
}

function pill(g, x, y, w, h, fill, stroke) {
  rrect(g, x, y, w, h, h / 2);
  g.fillStyle = fill;
  g.fill();
  if (stroke) { g.strokeStyle = stroke; g.lineWidth = 1.5; g.stroke(); }
}

function cursor(g, x, y, scale = 1, alpha = 1, press = 0) {
  if (alpha <= 0) return;
  g.save();
  g.globalAlpha = alpha;
  g.translate(x, y);
  g.scale(scale * (1 - press * 0.14), scale * (1 - press * 0.14));
  g.shadowColor = 'rgba(0,0,0,.5)';
  g.shadowBlur = 14;
  g.shadowOffsetY = 5;
  g.beginPath();
  g.moveTo(0, 0); g.lineTo(0, 36); g.lineTo(9, 28); g.lineTo(15.5, 42); g.lineTo(21.5, 39.5); g.lineTo(15, 25.5); g.lineTo(26, 25.5); g.closePath();
  g.fillStyle = '#111'; g.fill();
  g.shadowColor = 'transparent';
  g.strokeStyle = '#fff'; g.lineWidth = 2.6; g.stroke();
  g.restore();
}

function project(v, camera) {
  const p = v.clone().project(camera);
  return { x: (p.x * 0.5 + 0.5) * W, y: (-p.y * 0.5 + 0.5) * H };
}

function camera(fov = 32) {
  return new THREE.PerspectiveCamera(fov, W / H, 0.05, 400);
}

const uvQuad = (w, h, rect) => {
  const geo = new THREE.PlaneGeometry(w, h);
  if (rect) {
    const uv = geo.attributes.uv;
    for (let i = 0; i < uv.count; i++) uv.setXY(i, rect.u0 + uv.getX(i) * (rect.u1 - rect.u0), rect.v0 + uv.getY(i) * (rect.v1 - rect.v0));
  }
  return geo;
};

// --- 1. pages adrift --------------------------------------------------------------
function swarm() {
  const scene = new THREE.Scene();
  const cam = camera(38);
  const bg = backdrop(scene, { strength: 0.75 });
  const motes = dust(scene, { count: 900, spread: [36, 22, 100], size: 0.05 });
  motes.mat.uniforms.uA.value = 0.6;

  const atlas = docAtlas();
  const map = texture(atlas.canvas);
  const N = 340;
  const r = rng(7);
  const geo = new THREE.PlaneGeometry(1, 1.29);
  const cell = new Float32Array(N);
  const items = [];
  for (let i = 0; i < N; i++) {
    const angle = r() * Math.PI * 2;
    // A tunnel: the words of the film sit in its clear middle.
    const radius = 4.2 + r() ** 1.3 * 8;
    items.push({
      x: Math.cos(angle) * radius * 1.55,
      y: Math.sin(angle) * radius * 0.92,
      z: -r() * 92 + 8,
      rx: (r() - 0.5) * 1.3, ry: (r() - 0.5) * 1.8, rz: (r() - 0.5) * 1.6,
      vx: (r() - 0.5) * 0.14, vy: (r() - 0.5) * 0.14, vz: (r() - 0.5) * 0.1,
      phase: r() * 10,
      scale: 0.7 + r() * 0.95,
    });
    cell[i] = Math.floor(r() * atlas.cols * atlas.rows);
  }
  geo.setAttribute('aCell', new THREE.InstancedBufferAttribute(cell, 1));
  const mat = new THREE.ShaderMaterial({
    transparent: true, side: THREE.DoubleSide,
    uniforms: {
      map: { value: map }, uGrid: { value: new THREE.Vector2(atlas.cols, atlas.rows) },
      uVoid: { value: col(C.void) }, uMint: { value: col(C.mint) }, uT: { value: 0 }, uSweep: { value: 0 },
    },
    vertexShader: /* glsl */ `
      attribute float aCell; varying vec2 vUv; varying float vCell; varying vec3 vP; varying vec3 vN; varying vec3 vW;
      void main(){ vUv = uv; vCell = aCell;
        vec4 w = modelMatrix * instanceMatrix * vec4(position,1.0); vW = w.xyz;
        vec4 p = viewMatrix * w; vP = p.xyz;
        vN = normalize(mat3(viewMatrix) * mat3(modelMatrix) * mat3(instanceMatrix) * normal);
        gl_Position = projectionMatrix * p; }`,
    fragmentShader: /* glsl */ `
      ${roundedAlpha}
      uniform sampler2D map; uniform vec2 uGrid; uniform vec3 uVoid, uMint; uniform float uT, uSweep;
      varying vec2 vUv; varying float vCell; varying vec3 vP; varying vec3 vN; varying vec3 vW;
      void main(){
        float d = roundedBox(vUv, vec2(.775,1.0), .012); float aa = fwidth(d);
        float shape = 1.0 - smoothstep(-aa,aa,d);
        if (shape < .004) discard;
        vec2 cellUv = vec2((mod(vCell,uGrid.x)+vUv.x)/uGrid.x, 1.0-(floor(vCell/uGrid.x)+(1.0-vUv.y))/uGrid.y);
        vec3 tex = texture2D(map, cellUv).rgb;
        vec3 N = normalize(vN); if (!gl_FrontFacing) N = -N;
        vec3 V = normalize(-vP);
        vec3 L = normalize(vec3(-.35,.65,.6));
        float diff = .28 + .62*max(dot(N,L),0.0);
        float spec = pow(max(dot(N,normalize(L+V)),0.0),40.0)*.12;
        vec3 c = gl_FrontFacing ? tex*diff + spec : vec3(.72,.71,.66)*diff*.55;
        float depth = -vP.z;
        float fog = smoothstep(3.,44.,depth);
        float near = smoothstep(.2,3.5,depth);
        c = mix(c*vec3(.86,.94,.92), uVoid + vec3(.0,.03,.028), fog);
        gl_FragColor = vec4(c, shape*near);
      }`,
  });
  const mesh = new THREE.InstancedMesh(geo, mat, N);
  mesh.frustumCulled = false;
  scene.add(mesh);
  const dummy = new THREE.Object3D();

  return {
    name: 'swarm', start: 0, end: 7.8, scene, camera: cam,
    bloom: () => 0.35,
    update(t) {
      bg.uniforms.uT.value = t;
      motes.update(t);
      const k = seg(t, 0, 7.8);
      const z = 12 - 52 * (k * k * 0.35 + k * 0.65);
      cam.position.set(Math.sin(t * 0.3) * 0.5, Math.cos(t * 0.23) * 0.3, z);
      cam.lookAt(Math.sin(t * 0.22) * 0.8, Math.cos(t * 0.3) * 0.4, z - 12);
      cam.rotateZ(Math.sin(t * 0.16) * 0.09 + (t - 3) * 0.012);
      for (let i = 0; i < N; i++) {
        const it = items[i];
        dummy.position.set(it.x + Math.sin(t * 0.4 + it.phase) * 0.35, it.y + Math.cos(t * 0.33 + it.phase) * 0.35 - t * 0.06, it.z);
        dummy.rotation.set(it.rx + t * it.vx * 1.6, it.ry + t * it.vy * 1.6, it.rz + t * it.vz * 1.6);
        dummy.scale.setScalar(it.scale);
        dummy.updateMatrix();
        mesh.setMatrixAt(i, dummy.matrix);
      }
      mesh.instanceMatrix.needsUpdate = true;
    },
    overlay(g, t) {
      const veil = g.createRadialGradient(W / 2, H / 2, 40, W / 2, H / 2, 760);
      const v = CLEAN ? 0 : smooth(seg(t, 0.8, 1.6)) * (1 - smooth(seg(t, 6.3, 6.9)));
      veil.addColorStop(0, `rgba(3,10,9,${0.88 * v})`);
      veil.addColorStop(0.55, `rgba(3,10,9,${0.62 * v})`);
      veil.addColorStop(1, 'rgba(3,10,9,0)');
      g.save(); g.translate(0, 0); g.scale(1, 1); g.fillStyle = veil; g.fillRect(0, 0, W, H); g.restore();
      title(g, words.trapped1, W / 2, H / 2 - 24, 74, t, 1.1, 6.35, { weight: 500 });
      title(g, words.trapped2, W / 2, H / 2 + 74, 74, t, 2.5, 6.35, { weight: 700, color: C.mint });
    },
  };
}

// --- 2. reading the page ------------------------------------------------------------
function reading() {
  const scene = new THREE.Scene();
  const cam = camera(30);
  const bg = backdrop(scene, { strength: 0.8 });
  const motes = dust(scene, { count: 300, spread: [26, 16, 18], size: 0.04 });
  const page = heroPage();
  const map = texture(page.canvas);
  const PH = 6.4;
  const PW = PH * page.w / page.h;
  const sheet = new THREE.Mesh(new THREE.PlaneGeometry(PW, PH), scanSheetMaterial(map, PW / PH));
  scene.add(sheet);
  const halo = glowSprite(C.accent, 13);
  halo.material.opacity = 0.09;
  halo.position.z = -2;
  scene.add(halo);

  // Blocks, in page space, then in the column of results they fly to.
  const colW = 5.1;
  const gap = 0.14;
  const padTop = 0.34;
  const info = page.blocks.map((b, i) => {
    const aspect = b.w / b.h;
    const scale = Math.min(colW * 0.92 / b.w, (b.w < page.w * 0.6 ? 0.0052 : 1));
    const fw = b.w * scale; const fh = b.h * scale;
    return { b, i, aspect, fw, fh, cardH: fh + padTop + 0.16 };
  });
  let totalH = info.reduce((s, x) => s + x.cardH + gap, -gap);
  // Keep the whole column inside the frame.
  const fit = Math.min(1, 7.15 / totalH);
  info.forEach((x) => { x.fw *= fit; x.fh *= fit; x.cardH = x.fh + padTop + 0.1; });
  totalH = info.reduce((s, x) => s + x.cardH + gap, -gap);
  let top = totalH / 2;
  info.forEach((x) => { x.cy = top - x.cardH / 2; top -= x.cardH + gap; });

  const label = (i) => {
    const c = canvas(1024, 64);
    const g = c.getContext('2d');
    g.font = `600 34px ${FONT.ui}`;
    g.fillStyle = C.accent;
    rrect(g, 0, 8, 48, 48, 12); g.fill();
    g.fillStyle = '#04201C'; g.textAlign = 'center';
    g.fillText(String(i + 1), 24, 44);
    g.textAlign = 'left';
    g.fillStyle = C.back;
    g.fillText(words.kinds[i], 66, 44);
    return texture(c);
  };

  const pieces = info.map((x) => {
    const b = x.b;
    const rect = { u0: b.x / page.w, u1: (b.x + b.w) / page.w, v0: 1 - (b.y + b.h) / page.h, v1: 1 - b.y / page.h };
    const pw = b.w / page.w * PW; const ph = b.h / page.h * PH;
    const mat = scanSheetMaterial(map, pw / ph, { uShine: { value: 1.42 } });
    mat.uniforms.uDark.value = col('#0C4A42'); mat.uniforms.uDark2.value = col('#0A4038');
    mat.uniforms.uScan.value = 2;
    mat.uniforms.uRadius.value = 0.012 / Math.max(ph, 0.2);
    mat.uniforms.uAspect.value = pw / ph;
    const mesh = new THREE.Mesh(uvQuad(1, 1, rect), mat);
    mesh.renderOrder = 10;
    // Frame the app draws around a block.
    const frame = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.ShaderMaterial({
      transparent: true, depthWrite: false,
      uniforms: { uP: { value: 0 }, uAspect: { value: pw / ph }, uH: { value: ph }, uC: { value: col(C.mint) }, uFill: { value: 0 } },
      vertexShader: `varying vec2 vUv; void main(){ vUv=uv; gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);} `,
      fragmentShader: /* glsl */ `${roundedAlpha}
        uniform float uP,uAspect,uH,uFill; uniform vec3 uC; varying vec2 vUv;
        void main(){ float t = 0.008/uH; float d = roundedBox(vUv, vec2(uAspect,1.0), .02/uH);
          float line = 1.0 - smoothstep(0.0, t, abs(d));
          float sweep = step(vUv.x, uP);
          float inside = (1.0 - smoothstep(-.001,.001,d)) * uFill;
          gl_FragColor = vec4(uC*(line*1.5 + inside*.4), max(line*sweep, inside*.18*sweep)); }`,
    }));
    frame.renderOrder = 11;
    scene.add(frame);
    // Card behind the piece, once it has left the page.
    const card = new THREE.Mesh(new THREE.PlaneGeometry(colW, x.cardH), new THREE.ShaderMaterial({
      transparent: true, depthWrite: false,
      uniforms: { uO: { value: 0 }, uAspect: { value: colW / x.cardH } },
      vertexShader: `varying vec2 vUv; void main(){ vUv=uv; gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);} `,
      fragmentShader: /* glsl */ `${roundedAlpha} uniform float uO,uAspect; varying vec2 vUv;
        void main(){ float d = roundedBox(vUv, vec2(uAspect,1.0), .09/${x.cardH.toFixed(3)}); float a = fwidth(d);
          float s = 1.0 - smoothstep(-a,a,d); if (s<.003) discard;
          vec3 c = mix(vec3(.018,.075,.066), vec3(.03,.11,.097), vUv.y);
          c += vec3(.25,.75,.62)*(1.0-smoothstep(.0,.006,abs(d+.004)))*.45;
          gl_FragColor = vec4(c, s*uO); }`,
    }));
    card.renderOrder = 9;
    scene.add(card);
    const tag = new THREE.Mesh(new THREE.PlaneGeometry(4.2, 0.2625), cardMaterial(label(x.i), 16, { radius: 0 }));
    tag.renderOrder = 12;
    scene.add(tag);
    scene.add(mesh);
    return { ...x, pw, ph, mesh, frame, card, tag, u: b.x + b.w / 2, v: b.y + b.h / 2 };
  });

  const start = 7.0;
  const pagePos = new THREE.Vector3();
  const home = new THREE.Vector3();
  const flown = new THREE.Vector3();
  const pageGroup = new THREE.Object3D();
  scene.add(pageGroup);

  return {
    name: 'reading', start: 6.9, end: 16.1, scene, camera: cam,
    bloom: (t) => 0.36 + pulse(t, 8.4, 1.0, 0.8) * 0.14,
    update(t) {
      bg.uniforms.uT.value = t;
      motes.update(t);
      const slide = inOutQuint(seg(t, 10.6, 12.1));
      cam.position.set(lerp(0.3, 0, slide) + Math.sin(t * 0.25) * 0.08, Math.sin(t * 0.2) * 0.05, lerp(14.6 - seg(t, start, 10.6) * 1.1, 15.6, slide));
      cam.lookAt(0, 0, 0);

      const px = lerp(3.05, -3.1, slide);
      const yaw = lerp(lerp(-0.18, -0.07, seg(t, start, 10)), 0.34, slide);
      sheet.position.set(px, 0, 0);
      sheet.rotation.set(Math.sin(t * 0.3) * 0.012, yaw, 0);
      sheet.updateMatrixWorld();
      halo.position.set(px, 0, -3);

      const scan = inOut(seg(t, 7.75, 9.45));
      sheet.material.uniforms.uScan.value = t < 7.75 ? 0 : scan * 1.08;

      pieces.forEach((p, i) => {
        // Page-space centre of the block.
        const lx = (p.u / page.w - 0.5) * PW; const ly = (0.5 - p.v / page.h) * PH;
        pagePos.set(lx, ly, 0.02).applyMatrix4(sheet.matrixWorld);

        const fIn = seg(t, 9.55 + i * 0.09, 10.05 + i * 0.09);
        p.frame.position.copy(pagePos);
        p.frame.quaternion.copy(sheet.quaternion);
        p.frame.scale.set(p.pw, p.ph, 1);
        p.frame.material.uniforms.uP.value = outCubic(fIn) * 1.02;
        p.frame.material.uniforms.uFill.value = pulse(t, 10.1 + i * 0.09, 0.3, 0.5);

        const at = 11.0 + i * 0.13;
        const fly = inOut(seg(t, at, at + 1.15));
        home.copy(pagePos);
        const tx = 2.55; const ty = p.cy;
        flown.set(tx - colW / 2 + p.fw / 2 + 0.16, ty - (p.cardH - p.fh) / 2 + 0.1 - 0.04, 0.8);
        const lift = Math.sin(fly * Math.PI) * 1.5;
        p.mesh.position.lerpVectors(home, flown, fly);
        p.mesh.position.z += lift + 0.02;
        p.mesh.quaternion.copy(sheet.quaternion).slerp(new THREE.Quaternion(), fly);
        p.mesh.rotateZ(Math.sin(fly * Math.PI) * (i % 2 ? -0.09 : 0.09));
        p.mesh.rotateX(Math.sin(fly * Math.PI) * 0.3);
        p.mesh.scale.set(lerp(p.pw, p.fw, fly), lerp(p.ph, p.fh, fly), 1);
        p.mesh.material.uniforms.uOpacity.value = seg(t, at - 0.02, at + 0.02);
        p.mesh.material.uniforms.uAspect.value = p.mesh.scale.x / p.mesh.scale.y;
        p.mesh.material.uniforms.uRadius.value = 0.014 / p.mesh.scale.y;
        p.frame.visible = fIn > 0;
        p.frame.material.opacity = 1;

        const shown = smooth(seg(t, at + 0.7, at + 1.15));
        p.card.position.set(tx, ty, 0.72);
        p.card.material.uniforms.uO.value = shown;
        p.card.scale.setScalar(lerp(0.965, 1, shown));
        const tagShown = outCubic(seg(t, at + 0.9, at + 1.3));
        p.tag.position.set(tx - colW / 2 + 2.1 + 0.15, ty + p.cardH / 2 - 0.2, 0.84);
        p.tag.material.uniforms.uOpacity.value = tagShown;
      });
    },
    overlay(g, t) {
      title(g, words.reads1, 118, H / 2 - 20, 66, t, 7.7, 10.4, { align: 'left', weight: 500 });
      title(g, words.reads2, 118, H / 2 + 66, 66, t, 8.4, 10.4, { align: 'left', weight: 700, color: C.mint });
    },
  };
}

// --- 3. capture from any app ---------------------------------------------------------
function capture() {
  const scene = new THREE.Scene();
  scene.background = col(C.void);
  const cam = camera(30);
  const light = new THREE.DirectionalLight('#ffffff', 1.0);
  light.position.set(-3, 6, 7);
  scene.add(light);
  const fill = new THREE.PointLight(C.mint, 14, 30);
  fill.position.set(3, -2, 5);
  scene.add(fill);

  const d = desktop();
  const map = texture(d.canvas);
  const SW = 14.2; const SH = SW * 9 / 16;
  const screen = new THREE.Mesh(new THREE.PlaneGeometry(SW, SH), new THREE.ShaderMaterial({
    uniforms: {
      map: { value: map }, uDim: { value: 0 }, uRect: { value: new THREE.Vector4(0, 0, 0, 0) }, uBlur: { value: 0 }, uLight: { value: 1 },
    },
    vertexShader: `varying vec2 vUv; void main(){ vUv=uv; gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);} `,
    fragmentShader: /* glsl */ `
      uniform sampler2D map; uniform float uDim, uBlur, uLight; uniform vec4 uRect; varying vec2 vUv;
      void main(){
        vec3 c = textureLod(map, vUv, uBlur).rgb * uLight;
        float inside = step(uRect.x,vUv.x)*step(vUv.x,uRect.z)*step(uRect.y,vUv.y)*step(vUv.y,uRect.w);
        c *= mix(1.0 - uDim, 1.0, inside);
        gl_FragColor = vec4(c,1.0);
      }`,
  }));
  scene.add(screen);

  // Keys.
  const keys = (LANG === 'zh' ? ['⌥', '⇧', '⌘', '2'] : ['⌥', '⇧', '⌘', '2']).map((label, i) => {
    const group = new THREE.Group();
    const cap = new THREE.Mesh(new RoundedBoxGeometry(1.5, 1.5, 0.55, 8, 0.2), new THREE.MeshPhysicalMaterial({
      color: '#0E211E', roughness: 0.46, metalness: 0, clearcoat: 0.25, clearcoatRoughness: 0.5, envMapIntensity: 0.1,
    }));
    group.add(cap);
    const c = canvas(256, 256);
    const g = c.getContext('2d');
    g.fillStyle = '#fff'; g.font = `500 136px ${FONT.ui}`; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText(label, 128, 136);
    const glyph = new THREE.Mesh(new THREE.PlaneGeometry(1.15, 1.15), new THREE.ShaderMaterial({
      transparent: true, depthWrite: false,
      uniforms: { map: { value: texture(c) }, uC: { value: col(C.mint) }, uG: { value: 0.8 } },
      vertexShader: `varying vec2 vUv; void main(){ vUv=uv; gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);} `,
      fragmentShader: `uniform sampler2D map; uniform vec3 uC; uniform float uG; varying vec2 vUv; void main(){ float a = texture2D(map,vUv).a; gl_FragColor = vec4(uC*uG, a); }`,
    }));
    glyph.position.z = 0.285;
    group.add(glyph);
    scene.add(group);
    return { group, cap, glyph, i };
  });
  const keyGlow = glowSprite(C.accent, 13);
  scene.add(keyGlow);

  // The picked piece, leaving the screen.
  const px = d.pick;
  const rect = { u0: px.x / d.w, u1: (px.x + px.w) / d.w, v0: 1 - (px.y + px.h) / d.h, v1: 1 - px.y / d.h };
  const pw = (rect.u1 - rect.u0) * SW; const ph = (rect.v1 - rect.v0) * SH;
  const pieceMat = scanSheetMaterial(map, pw / ph, { uShine: { value: 1.45 } });
  pieceMat.uniforms.uRadius.value = 0.03;
  const piece = new THREE.Mesh(uvQuad(pw, ph, rect), pieceMat);
  piece.renderOrder = 5;
  scene.add(piece);
  const pieceHome = new THREE.Vector3(((rect.u0 + rect.u1) / 2 - 0.5) * SW, ((rect.v0 + rect.v1) / 2 - 0.5) * SH, 0.01);
  piece.position.copy(pieceHome);

  const selStart = 16.95; const selEnd = 17.85;
  const barAt = 18.0;
  const clickAt = 18.85;

  const a = { x: rect.u0, y: rect.v1 };
  const b = { x: rect.u1, y: rect.v0 };
  const selection = (t) => {
    const k = inOut(seg(t, selStart, selEnd));
    return { x0: a.x, y1: a.y, x1: lerp(a.x, b.x, k), y0: lerp(a.y, b.y, k) };
  };
  const toWorld = (u, v, z = 0) => new THREE.Vector3((u - 0.5) * SW, (v - 0.5) * SH, z);

  return {
    name: 'capture', start: 15.3, end: 22.8, scene, camera: cam,
    bloom: (t) => 0.36,
    update(t) {
      const push = inOut(seg(t, 19.1, 21.6));
      const follow = pieceHome.clone().multiplyScalar(push);
      cam.position.set(Math.sin(t * 0.3) * 0.06 + follow.x, 0.03 + follow.y, lerp(14.5, 10.4, push));
      cam.lookAt(follow.x, follow.y, 0);

      const keysOut = inOutQuint(seg(t, 16.55, 17.05));
      const appear = outCubic(seg(t, 15.5, 16.0));
      screen.material.uniforms.uLight.value = lerp(0.1, 1, keysOut) * appear;
      screen.material.uniforms.uBlur.value = lerp(3.4, 0, keysOut);
      keyGlow.material.opacity = 0.1 * (1 - keysOut) * appear;
      keyGlow.position.set(0, 0, 2);

      keys.forEach((key) => {
        const pressAt = 15.75 + key.i * 0.13;
        const down = pulse(t, pressAt + 0.05, 0.05, 2) * (1 - seg(t, 16.35, 16.55));
        const inK = outBack(seg(t, 15.4 + key.i * 0.06, 15.95 + key.i * 0.06));
        key.group.position.set((key.i - 1.5) * 1.82, lerp(-6, 0, inK) - keysOut * 11 * (1 + key.i * 0.1), 1.2 - down * 0.32);
        key.group.rotation.set(-0.34 + keysOut * 0.8, Math.sin(t * 0.7) * 0.03 + 0.04 * (key.i - 1.5) * -1, 0);
        key.glyph.material.uniforms.uG.value = lerp(0.75, 2.2, seg(t, pressAt, pressAt + 0.05) * (1 - seg(t, 16.35, 16.6)));
        key.group.visible = keysOut < 1;
      });

      const dim = smooth(seg(t, 16.6, 16.95));
      const s = selection(t);
      const lifted = inOut(seg(t, clickAt + 0.1, clickAt + 0.8));
      screen.material.uniforms.uDim.value = dim * lerp(0.56, 0.72, lifted);
      if (t >= selStart) screen.material.uniforms.uRect.value.set(s.x0, s.y0, s.x1, s.y1);
      else screen.material.uniforms.uRect.value.set(0, 0, 0, 0);

      piece.visible = t > clickAt;
      const toText = seg(t, 19.15, 20.4);
      piece.position.copy(pieceHome);
      piece.position.z = 0.01 + lifted * 0.9;
      piece.rotation.set(-lifted * 0.05 + Math.sin(t * 0.8) * 0.012 * lifted, lifted * 0.05, 0);
      piece.scale.setScalar(1 + lifted * 0.04);
      pieceMat.uniforms.uScan.value = t < 19.15 ? 0 : inOut(toText) * 1.1;
    },
    overlay(g, t) {
      if (t < 15.3) return;
      title(g, words.capture1, W / 2, 250, 72, t, 15.5, 16.45, { weight: 700 });
      const s = selection(t);
      const p0 = project(toWorld(s.x0, s.y1), cam);
      const p1 = project(toWorld(s.x1, s.y0), cam);
      const fadeSel = 1 - seg(t, clickAt, clickAt + 0.2);
      if (t > selStart - 0.1 && fadeSel > 0) {
        g.save();
        g.globalAlpha = fadeSel;
        if (t >= selStart) {
          g.strokeStyle = C.mint; g.lineWidth = 2.5;
          g.strokeRect(p0.x, p0.y, p1.x - p0.x, p1.y - p0.y);
          g.fillStyle = '#fff';
          [[p0.x, p0.y], [p1.x, p0.y], [p0.x, p1.y], [p1.x, p1.y]].forEach(([x, y]) => { g.beginPath(); g.arc(x, y, 6.5, 0, 7); g.fill(); g.strokeStyle = C.accent; g.lineWidth = 2.5; g.stroke(); });
        }
        g.restore();
      }

      // The bar beside what is chosen.
      const barIn = outBack(seg(t, barAt, barAt + 0.34), 1.3);
      const barOut = seg(t, clickAt + 0.05, clickAt + 0.3);
      const end = project(toWorld(b.x, b.y), cam);
      const bw = 610; const bh = 74;
      const bx = end.x - bw; const by = end.y + 24;
      if (barIn > 0 && barOut < 1) {
        g.save();
        g.globalAlpha = clamp(barIn) * (1 - barOut);
        g.translate(bx + bw / 2, by + bh / 2);
        g.scale(lerp(0.9, 1, barIn), lerp(0.9, 1, barIn));
        g.translate(-bx - bw / 2, -by - bh / 2);
        g.shadowColor = 'rgba(0,0,0,.55)'; g.shadowBlur = 40; g.shadowOffsetY = 14;
        pill(g, bx, by, bw, bh, 'rgba(18,30,28,.96)');
        g.shadowColor = 'transparent';
        const items = [words.barRead, words.barLong, words.barSave, words.barCopy];
        const widths = [190, 140, 130, 130];
        let cx = bx + 10;
        const hovering = seg(t, clickAt - 0.5, clickAt - 0.25);
        items.forEach((label, i) => {
          if (i === 0) {
            rrect(g, cx, by + 9, widths[i], bh - 18, (bh - 18) / 2);
            g.fillStyle = hovering > 0 ? C.accent : 'rgba(21,184,153,.75)'; g.fill();
          }
          g.fillStyle = i === 0 ? '#04201C' : C.paper;
          g.font = `600 27px ${FONT.ui}`;
          g.textAlign = 'center';
          g.fillText(label, cx + widths[i] / 2, by + 47);
          cx += widths[i];
        });
        g.textAlign = 'left';
        g.restore();
      }

      // The pointer: drags out the area, then goes to the bar.
      let cx; let cy; let press = 0;
      const startPoint = project(toWorld(a.x, a.y), cam);
      if (t < selEnd) {
        const k = inOut(seg(t, selStart, selEnd));
        const entry = outCubic(seg(t, 16.55, selStart));
        cx = lerp(lerp(W * 0.25, startPoint.x, entry), end.x, k);
        cy = lerp(lerp(H * 0.2, startPoint.y, entry), end.y, k);
        press = t > selStart - 0.05 ? 1 : 0;
      } else {
        const k = inOut(seg(t, barAt + 0.05, clickAt - 0.15));
        cx = lerp(end.x, bx + 100, k);
        cy = lerp(end.y, by + 42, k);
        press = pulse(t, clickAt, 0.05, 0.12);
      }
      const shown = seg(t, 16.55, 16.75) * (1 - seg(t, clickAt + 0.25, clickAt + 0.5));
      cursor(g, cx, cy, 1.05, shown, press);

      {
        const v = CLEAN ? 0 : smooth(seg(t, 19.4, 19.9)) * (1 - smooth(seg(t, 21.8, 22.2)));
        const grad = g.createLinearGradient(0, H - 300, 0, H);
        grad.addColorStop(0, 'rgba(3,10,9,0)'); grad.addColorStop(1, `rgba(3,10,9,${0.85 * v})`);
        g.fillStyle = grad; g.fillRect(0, H - 300, W, 300);
      }
      title(g, words.capture2, W / 2, H - 88, 66, t, 19.5, 21.8, { weight: 700, color: C.paper });
    },
  };
}

// --- 4. the ribbon ----------------------------------------------------------------
function ribbon() {
  const scene = new THREE.Scene();
  const cam = camera(36);
  const bg = backdrop(scene, { strength: 1.1 });
  const motes = dust(scene, { count: 450, spread: [40, 24, 50], size: 0.05 });
  const page = tallPage();
  const map = texture(page.canvas);
  map.wrapT = THREE.MirroredRepeatWrapping;

  const L = 64;
  const RW = 3.9;
  const pathGLSL = /* glsl */ `
    vec3 path(float s){
      return vec3(
        sin(s*.105)*13.5 + sin(s*.041+1.0)*4.5,
        s*.5 - 15.5,
        cos(s*.13)*5.0 + sin(s*.07)*2.2 );
    }`;
  const path = (s) => new THREE.Vector3(
    Math.sin(s * 0.105) * 13.5 + Math.sin(s * 0.041 + 1) * 4.5,
    s * 0.5 - 15.5,
    Math.cos(s * 0.13) * 5 + Math.sin(s * 0.07) * 2.2,
  );
  const geo = new THREE.PlaneGeometry(1, 1, 8, 1400);
  const mat = new THREE.ShaderMaterial({
    side: THREE.DoubleSide, transparent: true,
    uniforms: {
      map: { value: map }, uGrow: { value: 1 }, uL: { value: L }, uW: { value: RW }, uMint: { value: col(C.mint) },
      uDark: { value: col('#0A3D37') }, uT: { value: 0 },
    },
    vertexShader: /* glsl */ `
      ${pathGLSL}
      uniform float uL, uW; varying vec2 vUv; varying float vS; varying vec3 vN; varying vec3 vP;
      void main(){
        float s = (1.0-uv.y) * uL;
        vec3 P = path(s);
        vec3 T = normalize(path(s+.05)-P);
        vec3 side = normalize(cross(T, vec3(0.,0.,1.)));
        float twist = sin(s*.12)*.55;
        vec3 up = cross(side,T);
        vec3 S = side*cos(twist)+up*sin(twist);
        vec3 N = normalize(cross(S,T));
        vec3 w = P + S*(uv.x-.5)*uW;
        vUv = vec2(uv.x, s*(uW/ (1024./8192. * uW * 8.)) );
        vS = s;
        vec4 mv = viewMatrix*vec4(w,1.0);
        vN = normalize(mat3(viewMatrix)*N); vP = mv.xyz;
        gl_Position = projectionMatrix*mv;
      }`,
    fragmentShader: /* glsl */ `
      uniform sampler2D map; uniform float uGrow, uL, uW, uT; uniform vec3 uMint, uDark;
      varying vec2 vUv; varying float vS; varying vec3 vN; varying vec3 vP;
      void main(){
        float head = uGrow - vS;              // >0: already joined on
        if (head < 0.0) discard;
        vec2 uv = vec2(vUv.x, 1.0 - fract(vS / (uW*8.0)));
        vec3 tex = texture2D(map, uv).rgb;
        float ink = smoothstep(.08,.75,1.0-dot(tex,vec3(.299,.587,.114)));
        vec3 N = normalize(vN); if (!gl_FrontFacing) N = -N;
        float facing = abs(dot(N,normalize(-vP)));
        float lit = .38 + .55*facing;
        float t = smoothstep(2.2, 9.5, head);
        vec3 fresh = tex*lit;
        vec3 old = mix(vec3(.012,.1,.09),uDark,facing) + uMint*ink*(.75 + .62*facing);
        vec3 c = mix(fresh, old, t);
        float seam = 1.0 - smoothstep(0.0,.03,abs(fract(vS/2.4)-.5)-.47);
        c += uMint * exp(-head*2.6) * 1.6;
        c += uMint * smoothstep(.487,.5,abs(vUv.x-.5)) * (.3+1.0*exp(-head*.12));
        float depth = -vP.z;
        float fog = smoothstep(42.,86.,depth);
        c = mix(c, vec3(.012,.036,.033), fog);
        gl_FragColor = vec4(c, 1.0);
      }`,
  });
  const mesh = new THREE.Mesh(geo, mat);
  mesh.frustumCulled = false;
  scene.add(mesh);

  const start = 22.0;
  return {
    name: 'ribbon', start, end: 28.1, scene, camera: cam,
    bloom: () => 0.4,
    update(t) {
      bg.uniforms.uT.value = t;
      motes.update(t);
      const k = seg(t, start, 28.1);
      const grow = lerp(7, L - 1, k * k * 0.6 + k * 0.4);
      mat.uniforms.uGrow.value = grow;
      const head = path(grow);
      const back = smoother(seg(t, 22.4, 27.6));
      const dir = path(grow + 0.1).sub(head).normalize();
      const near = head.clone().add(new THREE.Vector3(0.4, -1.8, 7.2));
      const far = new THREE.Vector3(3, 1, 48);
      cam.position.lerpVectors(near, far, back);
      const nearLook = head.clone().addScaledVector(dir, -1.4);
      const look = nearLook.lerp(new THREE.Vector3(1.5, 0.5, 0), back);
      cam.up.set(Math.sin(t * 0.2) * 0.1, 1, 0).normalize();
      cam.lookAt(look);
    },
    overlay(g, t) {
      title(g, words.long1, 118, H - 196, 58, t, 22.7, 27.0, { align: 'left', weight: 500 });
      title(g, words.long2, 118, H - 120, 58, t, 23.6, 27.0, { align: 'left', weight: 700, color: C.mint });
    },
  };
}

// --- 5. show it once ----------------------------------------------------------------
function deck() {
  const scene = new THREE.Scene();
  const cam = camera(30);
  const bg = backdrop(scene, { strength: 1.1, hue: '#0A4A42' });
  const motes = dust(scene, { count: 500, spread: [34, 20, 36], size: 0.05 });
  const atlas = slideAtlas();
  const map = texture(atlas.canvas);
  const N = 64;
  const SW = 8.4; const SH = SW * 9 / 16;
  const geo = new THREE.PlaneGeometry(SW, SH);
  const cell = new Float32Array(N);
  const flash = new Float32Array(N);
  for (let i = 0; i < N; i++) cell[i] = i % (atlas.cols * atlas.rows);
  geo.setAttribute('aCell', new THREE.InstancedBufferAttribute(cell, 1));
  geo.setAttribute('aFlash', new THREE.InstancedBufferAttribute(flash, 1));
  const mat = new THREE.ShaderMaterial({
    transparent: true, side: THREE.DoubleSide,
    uniforms: { map: { value: map }, uGrid: { value: new THREE.Vector2(atlas.cols, atlas.rows) }, uMint: { value: col(C.mint) }, uRead: { value: 0 } },
    vertexShader: /* glsl */ `attribute float aCell, aFlash; varying vec2 vUv; varying float vCell, vFlash; varying vec3 vP;
      void main(){ vUv=uv; vCell=aCell; vFlash=aFlash; vec4 p = viewMatrix*modelMatrix*instanceMatrix*vec4(position,1.0); vP=p.xyz; gl_Position=projectionMatrix*p; }`,
    fragmentShader: /* glsl */ `
      ${roundedAlpha}
      uniform sampler2D map; uniform vec2 uGrid; uniform vec3 uMint; uniform float uRead;
      varying vec2 vUv; varying float vCell, vFlash; varying vec3 vP;
      void main(){
        float d = roundedBox(vUv, vec2(1.778,1.0), .02); float a = fwidth(d);
        float s = 1.0 - smoothstep(-a,a,d); if (s<.004) discard;
        float ux = gl_FrontFacing ? vUv.x : 1.0 - vUv.x;
        vec2 cu = vec2((mod(vCell,uGrid.x)+ux)/uGrid.x, 1.0-(floor(vCell/uGrid.x)+(1.0-vUv.y))/uGrid.y);
        vec3 c = texture2D(map,cu).rgb;
        c += vec3(.85,1.,.95)*vFlash*.22;
        c += uMint*(1.0-smoothstep(.0,.006,abs(d+.003)))*(.2+vFlash*1.2);
        float fog = smoothstep(32.,72.,-vP.z);
        c = mix(c*.94, vec3(.012,.036,.033), fog*.92);
        gl_FragColor = vec4(c,s);
      }`,
  });
  const mesh = new THREE.InstancedMesh(geo, mat, N);
  mesh.frustumCulled = false;
  scene.add(mesh);

  // The finished document: the icon's front sheet.
  const docC = canvas(1024, 1320);
  const g0 = docC.getContext('2d');
  const grad = g0.createLinearGradient(0, 0, 0, 1320);
  grad.addColorStop(0, C.front); grad.addColorStop(1, C.deep);
  g0.fillStyle = grad; g0.fillRect(0, 0, 1024, 1320);
  [[160, 240, 704, 1], [160, 420, 550, 0.85], [160, 600, 704, 0.7], [160, 780, 366, 0.5]].forEach(([x, y, w, a]) => {
    g0.globalAlpha = a; g0.fillStyle = C.mint; rrect(g0, x, y, w, 70, 35); g0.fill();
  });
  g0.globalAlpha = 1;
  const docMat = cardMaterial(texture(docC), 0.775, { radius: 0.05, gain: 1.08, glow: C.mint });
  const doc = new THREE.Mesh(new THREE.PlaneGeometry(4.3, 5.55), docMat);
  doc.renderOrder = 20;
  scene.add(doc);
  const docGlow = glowSprite(C.accent, 16);
  scene.add(docGlow);

  const dummy = new THREE.Object3D();
  const demoEnd = 30.6;
  const runEnd = 34.3;
  const captureTime = (i) => {
    if (i === 0) return 28.45;
    return demoEnd + (runEnd - demoEnd) * ((i - 1) / (N - 2)) ** 0.62;
  };

  return {
    name: 'deck', start: 27.3, end: 37.2, scene, camera: cam,
    bloom: (t) => 0.36,
    update(t) {
      bg.uniforms.uT.value = t;
      motes.update(t);
      const orbit = smoother(seg(t, demoEnd - 0.3, 33.2)) * (1 - smoother(seg(t, 34.4, 36)));
      const yaw = smoother(seg(t, demoEnd, runEnd)) * 1.1 + t * 0.02;
      const dist = lerp(17, 39, orbit);
      cam.position.set(Math.sin(yaw * orbit) * dist, lerp(0, 9, orbit), Math.cos(yaw * orbit) * dist);
      cam.lookAt(0, 0, 0);

      const collect = inOutQuint(seg(t, 34.25, 35.3));
      for (let i = 0; i < N; i++) {
        const at = captureTime(i);
        const next = i === N - 1 ? at + 1 : captureTime(i + 1);
        const hold = t < at;
        const k = seg(t, at, at + 1.05);
        const e = outExpo(k);
        // Which slide is on the "screen" now: until this one is taken, it waits.
        const onScreen = t >= (i === 0 ? 0 : captureTime(i - 1)) - 0.001;
        const angle = i * 0.62 + t * 0.34;
        const radius = 12 + Math.sin(i * 1.7) * 3.2;
        const helixY = (i / N - 0.5) * 13 + Math.sin(t * 0.4 + i) * 0.3;
        const orbitX = Math.cos(angle) * radius; const orbitZ = Math.sin(angle) * radius;
        let x = lerp(0, orbitX, e);
        let y = lerp(0, helixY, e);
        let z = lerp(0, orbitZ, e);
        let scale = lerp(1, 0.5, e);
        let ry = lerp(0, -angle + Math.PI / 2, e);
        let rz = lerp(0, Math.sin(i) * 0.2, e);
        if (hold) {
          // Next slide comes in from the right when its turn arrives.
          const slideIn = i === 0 ? outCubic(seg(t, 27.4, 27.9)) : outCubic(seg(t, captureTime(i - 1) + (i === 1 ? -0.9 : 0), captureTime(i - 1) + (i === 1 ? -0.35 : 0.08)));
          x = lerp(i === 0 ? 0 : 12, 0, slideIn);
          z = i === 0 ? lerp(-4, 0, slideIn) : lerp(-1, -0.02, slideIn);
          scale = i === 0 ? lerp(0.9, 1, slideIn) : 1;
          ry = 0; rz = 0; y = 0;
        }
        // All of them gather into one stack.
        const gx = 0; const gy = 0 - i * 0.002; const gz = -0.4 - i * 0.05;
        x = lerp(x, gx, collect); y = lerp(y, gy, collect); z = lerp(z, gz + 0.8, collect);
        scale = lerp(scale, 0.8, collect); ry = lerp(ry, 0, collect); rz = lerp(rz, 0, collect);
        dummy.position.set(x, y, z);
        dummy.rotation.set(0, ry, rz);
        dummy.scale.setScalar(onScreen || collect > 0 ? scale : 0.0001);
        dummy.updateMatrix();
        mesh.setMatrixAt(i, dummy.matrix);
        flash[i] = pulse(t, at, 0.02, i < 2 ? 0.26 : 0.1);
      }
      mesh.instanceMatrix.needsUpdate = true;
      geo.attributes.aFlash.needsUpdate = true;
      mesh.visible = t < 35.9;

      // The stack becomes one sheet.
      const become = inOut(seg(t, 35.0, 35.8));
      docMat.uniforms.uOpacity.value = become;
      doc.scale.setScalar(lerp(0.82, 1, outCubic(seg(t, 35.0, 36.2))));
      doc.position.set(0, 0.5, 1.0);
      doc.rotation.set(Math.sin(t * 0.5) * 0.04, Math.sin(t * 0.7) * 0.07, 0);
      docGlow.material.opacity = become * 0.14;
      docGlow.position.set(0, 0, -1);
    },
    overlay(g, t) {
      title(g, words.show1, W / 2, 138, 68, t, 27.65, 30.25, { weight: 700 });
      title(g, words.show2, W / 2, 138, 68, t, 30.55, 34.1, { weight: 700, color: C.mint });

      // Recording panel: what was done, as steps.
      const panelIn = outQuint(seg(t, 27.8, 28.2)) * (1 - seg(t, 33.9, 34.3));
      if (panelIn > 0) {
        g.save();
        g.globalAlpha = panelIn;
        const x = 120 - (1 - panelIn) * 60;
        const y = 780;
        rrect(g, x, y, 640, 196, 26);
        g.fillStyle = 'rgba(8,24,22,.86)'; g.fill();
        g.strokeStyle = 'rgba(143,240,216,.25)'; g.lineWidth = 1.5; g.stroke();
        const running = t >= demoEnd;
        g.fillStyle = running ? C.accent : '#FF5F57';
        g.beginPath(); g.arc(x + 36, y + 42, 9, 0, 7); g.fill();
        g.fillStyle = C.paper; g.font = `600 25px ${FONT.ui}`;
        g.fillText(running ? words.repeat : words.recording, x + 58, y + 51);
        const steps = [[words.step1, 28.45], [words.step2, 29.45]];
        steps.forEach(([label, at], i) => {
          const on = outCubic(seg(t, at - 0.05, at + 0.2));
          const active = running ? (Math.floor(t * lerp(2, 16, seg(t, demoEnd, runEnd))) % 2 === i ? 1 : 0.35) : 1;
          const yy = y + 78 + i * 52;
          g.globalAlpha = panelIn * on;
          rrect(g, x + 22, yy, 596, 44, 12);
          g.fillStyle = `rgba(21,184,153,${0.2 + 0.5 * (running ? active - 0.35 : pulse(t, at, 0.05, 0.6))})`; g.fill();
          g.fillStyle = C.mint; g.font = `600 22px ${FONT.ui}`;
          g.fillText(String(i + 1), x + 40, yy + 30);
          g.fillStyle = C.paper; g.font = `500 23px ${FONT.ui}`;
          g.fillText(label, x + 72, yy + 30);
        });
        g.restore();
      }

      // The → key.
      const keyIn = outBack(seg(t, 28.95, 29.25)) * (1 - seg(t, 30.3, 30.55));
      if (keyIn > 0) {
        const press = pulse(t, 29.5, 0.06, 0.2);
        const x = W - 340; const y = 806 + press * 9;
        g.save();
        g.globalAlpha = clamp(keyIn);
        g.shadowColor = 'rgba(0,0,0,.6)'; g.shadowBlur = 26; g.shadowOffsetY = 12 - press * 8;
        rrect(g, x, y, 136, 136, 28);
        const kg = g.createLinearGradient(0, y, 0, y + 136);
        kg.addColorStop(0, '#223733'); kg.addColorStop(1, '#0C1C1A');
        g.fillStyle = kg; g.fill();
        g.shadowColor = 'transparent';
        g.strokeStyle = `rgba(143,240,216,${0.25 + press * 0.7})`; g.lineWidth = 2; g.stroke();
        g.fillStyle = press > 0.2 ? '#fff' : C.mint; g.font = `500 74px ${FONT.ui}`; g.textAlign = 'center';
        g.fillText('→', x + 68, y + 92);
        g.textAlign = 'left';
        g.restore();
      }

      // Count.
      const countIn = outCubic(seg(t, demoEnd + 0.1, demoEnd + 0.5)) * (1 - seg(t, 34.3, 34.7));
      if (countIn > 0) {
        let n = 2;
        for (let i = 2; i < N; i++) if (t >= captureTime(i)) n = i + 1;
        g.save();
        g.globalAlpha = countIn;
        g.textAlign = 'right';
        g.fillStyle = C.paper; g.font = `700 148px ${FONT.ui}`;
        g.letterSpacing = '-4px';
        g.fontVariantNumeric = 'tabular-nums';
        g.fillText(String(n), W - 248, 960);
        g.letterSpacing = '0px';
        g.fillStyle = C.mint; g.font = `600 36px ${FONT.ui}`;
        g.fillText(words.pages, W - 130, 960);
        g.restore();
      }

      title(g, words.one, W / 2, H - 100, 62, t, 35.2, 36.5, { weight: 700 });
    },
  };
}

// --- 6. every language, nothing leaves ---------------------------------------------------
function particles() {
  const scene = new THREE.Scene();
  const cam = camera(32);
  const bg = backdrop(scene, { strength: 0.8 });
  const N = 90000;
  const r = rng(101);

  const sample = (draw) => {
    const w = 1600; const h = 700;
    const c = canvas(w, h);
    const g = c.getContext('2d', { willReadFrequently: true });
    g.fillStyle = '#fff';
    draw(g, w, h);
    const data = g.getImageData(0, 0, w, h).data;
    const pts = [];
    for (let y = 0; y < h; y += 1) for (let x = 0; x < w; x += 1) if (data[(y * w + x) * 4 + 3] > 120) pts.push(x, y);
    const out = new Float32Array(N * 2);
    const count = pts.length / 2;
    for (let i = 0; i < N; i++) {
      const k = Math.floor(r() * count) * 2;
      out[i * 2] = ((pts[k] + r()) / w - 0.5) * 16;
      out[i * 2 + 1] = (0.5 - (pts[k + 1] + r()) / h) * 7;
    }
    return out;
  };
  const word = (text, weight = 700, font = FONT.ui) => (g, w, h) => {
    g.font = `${weight} 290px ${font}`;
    g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText(text, w / 2, h / 2 + 10);
  };
  const lock = (g, w, h) => {
    const cx = w / 2; const cy = h / 2 + 70;
    g.strokeStyle = '#fff'; g.lineWidth = 46; g.lineCap = 'round';
    g.beginPath(); g.arc(cx, cy - 90, 94, Math.PI, 0); g.lineTo(cx + 94, cy - 40); g.moveTo(cx - 94, cy - 40); g.lineTo(cx - 94, cy - 90); g.stroke();
    rrect(g, cx - 170, cy - 70, 340, 280, 56); g.fill();
    g.globalCompositeOperation = 'destination-out';
    g.beginPath(); g.arc(cx, cy + 45, 34, 0, 7); g.fill();
    g.fillRect(cx - 13, cy + 45, 26, 80);
    g.globalCompositeOperation = 'source-over';
  };
  const targets = [
    { t: sample(word('中文')), at: 36.9 },
    { t: sample(word('English')), at: 37.55 },
    { t: sample(word('日本語')), at: 38.2 },
    { t: sample(word('Français', 700)), at: 38.8 },
    { t: sample(word('Español', 700)), at: 39.35 },
    { t: sample(lock), at: 39.95 },
  ];

  const position = new Float32Array(N * 3);
  const seeds = new Float32Array(N);
  const start = new Float32Array(N * 3);
  for (let i = 0; i < N; i++) {
    seeds[i] = r();
    const a = r() * 6.283; const rr = 3 + r() * 13;
    start[i * 3] = Math.cos(a) * rr * 1.5;
    start[i * 3 + 1] = Math.sin(a) * rr;
    start[i * 3 + 2] = (r() - 0.5) * 16;
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(position, 3));
  geo.setAttribute('aSeed', new THREE.BufferAttribute(seeds, 1));
  const mat = new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    uniforms: { uC: { value: col(C.mint) }, uD: { value: col(C.accent) }, uH: { value: H }, uE: { value: 1 } },
    vertexShader: /* glsl */ `attribute float aSeed; varying float vS; uniform float uH;
      void main(){ vec4 p = modelViewMatrix*vec4(position,1.0); vS = aSeed;
        gl_PointSize = (0.022 + aSeed*aSeed*0.03) * uH / -p.z; gl_Position = projectionMatrix*p; }`,
    fragmentShader: /* glsl */ `uniform vec3 uC, uD; uniform float uE; varying float vS;
      void main(){ float d = length(gl_PointCoord-.5); float a = smoothstep(.5,.05,d);
        gl_FragColor = vec4(mix(uD,uC,vS)*(0.5+vS*1.2)*uE, a*.75); }`,
  });
  const points = new THREE.Points(geo, mat);
  points.frustumCulled = false;
  scene.add(points);
  const noise = (x, y, tt, s) => Math.sin(x * 0.7 + tt * 1.1 + s * 6.283) + Math.sin(y * 0.9 - tt * 0.8 + s * 12.7);

  return {
    name: 'particles', start: 36.4, end: 42.5, scene, camera: cam,
    bloom: (t) => 0.6,
    update(t) {
      bg.uniforms.uT.value = t;
      cam.position.set(Math.sin(t * 0.4) * 0.5, Math.cos(t * 0.34) * 0.3, lerp(17.5, 15.5, seg(t, 36.4, 42.5)));
      cam.lookAt(0, 0, 0);
      let index = -1;
      for (let i = 0; i < targets.length; i++) if (t >= targets[i].at) index = i;
      const prev = index >= 0 ? targets[index].t : null;
      const next = index + 1 < targets.length ? targets[index + 1] : null;
      for (let i = 0; i < N; i++) {
        const s = seeds[i];
        let x; let y; let z = (s - 0.5) * 0.35;
        const delay = s * 0.14;
        if (index < 0) {
          const k = outExpo(seg(t, 36.45 + delay, targets[0].at));
          x = lerp(start[i * 3], 0, 0); y = start[i * 3 + 1]; z = start[i * 3 + 2];
          x = lerp(x, targets[0].t[i * 2], k); y = lerp(y, targets[0].t[i * 2 + 1], k); z = lerp(z, 0, k);
        } else {
          x = prev[i * 2]; y = prev[i * 2 + 1];
          if (next) {
            const window = next.at - targets[index].at;
            const k = inOutQuint(seg(t, next.at - window * 0.34 + delay * 0.6, next.at + delay * 0.6));
            const lift = Math.sin(k * Math.PI);
            x = lerp(x, next.t[i * 2], k) + noise(y, x, t, s) * lift * 1.0;
            y = lerp(y, next.t[i * 2 + 1], k) + noise(x, y, t + 3, s) * lift * 1.0;
            z += lift * (s - 0.5) * 4.5;
          }
        }
        const shimmer = Math.sin(t * 2.4 + s * 90) * 0.012;
        position[i * 3] = x + shimmer;
        position[i * 3 + 1] = y - shimmer;
        position[i * 3 + 2] = z;
      }
      geo.attributes.position.needsUpdate = true;
    },
    overlay(g, t) {
      title(g, words.lang1, W / 2, H - 110, 54, t, 37.0, 39.55, { weight: 600 });
      title(g, words.lock1, W / 2, H - 110, 54, t, 40.1, 41.6, { weight: 600, color: C.mint });
    },
  };
}

// --- 7. the mark -------------------------------------------------------------------------
function mark() {
  const scene = new THREE.Scene();
  const cam = camera(26);
  const bg = backdrop(scene, { strength: 1.0, hue: '#0A4A42' });
  const motes = dust(scene, { count: 280, spread: [22, 14, 14], size: 0.04 });

  // The icon's grid: 220 units, drawn as in the SVGs.
  const u = 1 / 40;
  const icon = new THREE.Group();
  scene.add(icon);

  const paperC = canvas(512, 512);
  const pg = paperC.getContext('2d');
  const grad = pg.createLinearGradient(0, 0, 0, 512);
  grad.addColorStop(0, '#F6F4EE'); grad.addColorStop(1, '#E2E0D6');
  pg.fillStyle = grad; pg.fillRect(0, 0, 512, 512);
  const plate = new THREE.Mesh(new THREE.PlaneGeometry(220 * u, 220 * u), cardMaterial(texture(paperC), 1, { radius: 0.225, gain: 0.96 }));
  plate.renderOrder = 1;
  plate.position.z = -0.4;
  icon.add(plate);

  const sheetMat = (hex, w, h, gradTop = null) => {
    const c = canvas(512, Math.round(512 * h / w));
    const g = c.getContext('2d');
    if (gradTop) {
      const gr = g.createLinearGradient(0, 0, 0, c.height);
      gr.addColorStop(0, gradTop); gr.addColorStop(1, hex);
      g.fillStyle = gr;
    } else g.fillStyle = hex;
    g.fillRect(0, 0, c.width, c.height);
    return cardMaterial(texture(c), w / h, { radius: 12 / h });
  };
  const s = 1.3;
  const make = (x, y, w, h, rot, dx, dy, hex, top, z) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w * s * u, h * s * u), sheetMat(hex, w, h, top));
    const cx = x + w / 2 + dx - 105.745; const cy = -(y + h / 2 + dy - 109.497);
    return { mesh: m, home: new THREE.Vector3(cx * s * u, cy * s * u, z), rot: THREE.MathUtils.degToRad(rot), z };
  };
  // Approximates each sheet's turn about its own centre, as the SVG does.
  const back = make(60, 44, 100, 126, 11, -9.8, 1.9, C.back, null, 0.1);
  const middle = make(60, 46, 100, 126, 4, -2, 0.14, C.middle, null, 0.2);
  const front = make(64, 48, 104, 130, -4, 0, 0, C.deep, C.front, 0.3);
  const sheets = [back, middle, front];
  sheets.forEach((sh, i) => { sh.mesh.renderOrder = 2 + i; icon.add(sh.mesh); });

  const bars = [[81, 72, 70, 1], [81, 90, 54.6, 0.85], [81, 108, 70, 0.7], [81, 126, 36.4, 0.5]].map(([x, y, w, a], i) => {
    const mat = new THREE.ShaderMaterial({
      transparent: true, depthWrite: false, uniforms: { uC: { value: col(C.mint) }, uG: { value: 1 }, uA: { value: a }, uAspect: { value: w / 7 } },
      vertexShader: `varying vec2 vUv; void main(){ vUv=uv; gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);} `,
      fragmentShader: /* glsl */ `${roundedAlpha} uniform vec3 uC; uniform float uG,uA,uAspect; varying vec2 vUv;
        void main(){ float d = roundedBox(vUv, vec2(uAspect,1.0), .5); float q=fwidth(d); float s=1.0-smoothstep(-q,q,d); if(s<.003) discard;
          gl_FragColor = vec4(uC*uG, s*uA); }`,
    });
    const m = new THREE.Mesh(new THREE.PlaneGeometry(1, 7 * s * u), mat);
    m.renderOrder = 6;
    icon.add(m);
    return { mesh: m, x, y, w, i, mat };
  });

  const sweepGlow = glowSprite(C.mint, 16);
  scene.add(sweepGlow);
  const start = 41.6;

  return {
    name: 'mark', start, end: DURATION + 1, scene, camera: cam,
    bloom: (t) => 0.38 + pulse(t, 43.7, 0.2, 1.2) * 0.3,
    update(t) {
      bg.uniforms.uT.value = t;
      motes.update(t);
      cam.position.set(Math.sin(t * 0.3) * 0.05, 0, 18);
      cam.lookAt(0, 0, 0);

      const settle = inOutQuint(seg(t, 44.75, 45.75));
      const iconScale = lerp(0.82, 0.48, settle);
      icon.position.set(0, lerp(0.05, 1.3, settle), 0);
      icon.scale.setScalar(iconScale);
      icon.rotation.set(Math.sin(t * 0.8) * 0.02 * (1 - settle * 0.6) + (1 - outCubic(seg(t, 41.8, 43.4))) * 0.5, Math.sin(t * 0.55) * 0.05 * (1 - settle * 0.6) - (1 - outCubic(seg(t, 41.8, 43.4))) * 0.7, 0);

      sheets.forEach((sh, i) => {
        const k = outExpo(seg(t, 41.95 + i * 0.16, 43.05 + i * 0.16));
        const a = i / 3 * 6.28 + 0.8;
        sh.mesh.position.set(lerp(Math.cos(a) * 8, sh.home.x, k), lerp(Math.sin(a) * 6, sh.home.y, k), lerp(5 - i, sh.z, k));
        sh.mesh.rotation.set(0, 0, lerp(sh.rot + (i - 1) * 2.2, sh.rot, k));
        sh.mesh.material.uniforms.uOpacity.value = seg(t, 41.95 + i * 0.16, 42.2 + i * 0.16);
      });

      const plateIn = outQuint(seg(t, 42.85, 43.65));
      plate.material.uniforms.uOpacity.value = plateIn;
      plate.scale.setScalar(lerp(0.72, 1, plateIn));

      bars.forEach((b) => {
        const k = outCubic(seg(t, 43.4 + b.i * 0.12, 43.95 + b.i * 0.12));
        const w = b.w * s * u * k;
        const cx = (b.x - 116) * s * u + w / 2; const cy = -(b.y + 3.5 - 113) * s * u;
        const pivot = new THREE.Vector2(cx, cy).rotateAround(new THREE.Vector2(0, 0), front.rot);
        b.mesh.position.set(front.home.x + pivot.x, front.home.y + pivot.y, 0.35);
        b.mesh.rotation.z = front.rot;
        b.mesh.scale.x = Math.max(w, 0.0001);
        b.mat.uniforms.uAspect.value = Math.max(w, 0.0001) / (7 * s * u);
        b.mat.uniforms.uG.value = lerp(2.6, 1.0, seg(t, 43.8 + b.i * 0.12, 44.9));
        b.mesh.visible = k > 0.001;
      });
      sweepGlow.material.opacity = pulse(t, 43.7, 0.2, 1.2) * 0.16;
      sweepGlow.position.set(0, 0, 0.5);
    },
    overlay(g, t) {
      const y = H / 2 + 188;
      const k = outQuint(seg(t, 45.2, 46));
      if (k <= 0) return;
      g.save();
      g.textAlign = 'center';
      g.globalAlpha = k;
      g.filter = k < 0.98 ? `blur(${(1 - k) * 12}px)` : 'none';
      g.fillStyle = C.paper;
      g.font = `700 112px ${FONT.ui}`;
      g.letterSpacing = `${lerp(14, -2.5, k)}px`;
      g.fillText('OCRFlow', W / 2, y);
      g.restore();
      title(g, words.tag, W / 2, y + 74, 38, t, 45.65, DURATION + 2, { weight: 500, color: C.mint, stagger: 0.035 });
      title(g, words.free, W / 2, y + 138, 28, t, 46.1, DURATION + 2, { weight: 500, color: C.back });
    },
  };
}

export function buildShots({ environment }) {
  const list = [swarm(), reading(), capture(), ribbon(), deck(), particles(), mark()];
  list.forEach((s) => { s.scene.environment = s.name === 'capture' ? null : environment; s.scene.environmentIntensity = 0.75; });
  return list;
}
