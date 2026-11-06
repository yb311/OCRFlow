// What every shot shares: the palette from the app icon, timing, and textures.
import * as THREE from 'three';

export const params = new URLSearchParams(location.search);
export const LANG = params.get('lang') ?? 'en';
export const W = Number(params.get('w') ?? 1920);
export const H = Number(params.get('h') ?? 1080);
/** Without the film's words: for loops on the website. */
export const CLEAN = params.has('clean');

// Sheet-Front.svg, Sheet-Middle.svg, Sheet-Back.svg, and icon.json's paper.
export const C = {
  void: '#030A09',
  deep: '#07423B',
  front: '#14665D',
  middle: '#3C8578',
  back: '#6FA79C',
  mint: '#8FF0D8',
  accent: '#15B899',
  paper: '#F6F4EE',
  paperDim: '#E2E0D6',
  ink: '#1A1F1E',
};
export const col = (hex) => new THREE.Color(hex);

export const FONT = {
  ui: '-apple-system, "SF Pro Display", "PingFang SC", sans-serif',
  serif: '"Times New Roman", "Songti SC", serif',
  mono: '"SF Mono", Menlo, monospace',
};

// --- timing ---------------------------------------------------------------
export const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
export const seg = (t, a, b) => clamp((t - a) / (b - a));
export const lerp = (a, b, x) => a + (b - a) * x;
export const smooth = (x) => x * x * (3 - 2 * x);
export const smoother = (x) => x * x * x * (x * (x * 6 - 15) + 10);
export const outCubic = (x) => 1 - (1 - x) ** 3;
export const outQuint = (x) => 1 - (1 - x) ** 5;
export const outExpo = (x) => (x >= 1 ? 1 : 1 - 2 ** (-10 * x));
export const inCubic = (x) => x * x * x;
export const inOut = (x) => (x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2);
export const inOutQuint = (x) => (x < 0.5 ? 16 * x ** 5 : 1 - (-2 * x + 2) ** 5 / 2);
export const outBack = (x, s = 1.70158) => 1 + (s + 1) * (x - 1) ** 3 + s * (x - 1) ** 2;
export const pulse = (t, at, up, down) => (t < at ? seg(t, at - up, at) : 1 - seg(t, at, at + down));

export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let z = a;
    z = Math.imul(z ^ (z >>> 15), z | 1);
    z ^= z + Math.imul(z ^ (z >>> 7), z | 61);
    return ((z ^ (z >>> 14)) >>> 0) / 4294967296;
  };
}

// --- canvas -----------------------------------------------------------------
export function canvas(w, h) {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return c;
}

export function texture(source, { srgb = true, repeat = false } = {}) {
  const t = new THREE.CanvasTexture(source);
  if (srgb) t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 16;
  t.generateMipmaps = true;
  t.minFilter = THREE.LinearMipmapLinearFilter;
  if (repeat) t.wrapS = t.wrapT = THREE.RepeatWrapping;
  return t;
}

export function rrect(g, x, y, w, h, r) {
  g.beginPath();
  g.roundRect(x, y, w, h, r);
}

/** Wraps to lines; handles Chinese, which has no spaces, a character at a time. */
export function wrap(g, text, width) {
  const cjk = /[　-鿿]/.test(text);
  const parts = cjk ? [...text] : text.split(' ');
  const lines = [];
  let line = '';
  for (const part of parts) {
    const next = line ? line + (cjk ? '' : ' ') + part : part;
    if (g.measureText(next).width > width && line) {
      lines.push(line);
      line = part;
    } else line = next;
  }
  if (line) lines.push(line);
  return lines;
}

export function paragraph(g, text, x, y, width, leading) {
  const lines = wrap(g, text, width);
  lines.forEach((l, i) => g.fillText(l, x, y + i * leading));
  return y + lines.length * leading;
}

// --- shaders shared by anything made of paper --------------------------------
export const roundedAlpha = /* glsl */ `
  float roundedBox(vec2 uv, vec2 size, float radius) {
    vec2 p = (uv - 0.5) * size;
    vec2 q = abs(p) - size * 0.5 + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
  }
`;

/**
 * A sheet that a line of light turns from printed paper into the icon's front
 * sheet: paper goes deep teal, ink starts to shine. `uScan` is how far down the
 * light has reached, 0 at the top, 1 past the bottom.
 */
export function scanSheetMaterial(map, aspect, extra = {}) {
  return new THREE.ShaderMaterial({
    transparent: true,
    side: THREE.DoubleSide,
    uniforms: {
      map: { value: map },
      uScan: { value: 0 },
      uShine: { value: 1.32 },
      uOpacity: { value: 1 },
      uAspect: { value: aspect },
      uLight: { value: 1 },
      uRadius: { value: 0.022 },
      uBand: { value: 0.045 },
      uPaper: { value: col(C.paper) },
      uDark: { value: col('#0A3D37') },
      uDark2: { value: col('#042A26') },
      uMint: { value: col(C.mint) },
      ...extra,
    },
    vertexShader: /* glsl */ `
      varying vec2 vUv; varying vec3 vN; varying vec3 vP;
      void main() {
        vUv = uv;
        vN = normalize(normalMatrix * normal);
        vec4 p = modelViewMatrix * vec4(position, 1.0);
        vP = p.xyz;
        gl_Position = projectionMatrix * p;
      }`,
    fragmentShader: /* glsl */ `
      ${roundedAlpha}
      uniform sampler2D map;
      uniform float uScan, uShine, uOpacity, uAspect, uLight, uRadius, uBand;
      uniform vec3 uPaper, uDark, uDark2, uMint;
      varying vec2 vUv; varying vec3 vN; varying vec3 vP;
      void main() {
        vec2 size = vec2(uAspect, 1.0);
        float d = roundedBox(vUv, size, uRadius);
        float aa = fwidth(d);
        float shape = 1.0 - smoothstep(-aa, aa, d);
        if (shape < 0.003) discard;

        vec3 tex = texture2D(map, vUv).rgb;
        float ink = 1.0 - dot(tex, vec3(0.299, 0.587, 0.114));
        ink = smoothstep(0.08, 0.75, ink);

        vec3 N = normalize(vN);
        if (!gl_FrontFacing) N = -N;
        vec3 V = normalize(-vP);
        float facing = clamp(dot(N, V), 0.0, 1.0);
        float diffuse = 0.62 + 0.38 * facing;

        float y = 1.0 - vUv.y;
        float done = smoothstep(uScan - 0.004, uScan + 0.004, y);   // 1: not yet read
        vec3 printed = tex * diffuse * uLight * 0.93;
        vec3 ground = mix(uDark2, uDark, vUv.y) * (0.8 + 0.5 * facing);
        vec3 read = ground + uMint * ink * uShine;
        vec3 color = mix(read, printed, done);

        float band = exp(-pow((y - uScan) / uBand, 2.0)) * step(0.0001, uScan) * step(uScan, 1.0 + uBand);
        color += uMint * band * (0.12 + ink * 0.9);
        float line = exp(-pow((y - uScan) / 0.0028, 2.0)) * step(0.0001, uScan) * step(uScan, 1.0);
        color += vec3(0.8, 1.0, 0.95) * line * 3.2;

        float rim = smoothstep(0.012, 0.0, abs(d + 0.004));
        color += uMint * rim * (1.0 - done) * 0.28;

        gl_FragColor = vec4(color, shape * uOpacity);
      }`,
  });
}

/** A flat plane showing a canvas, unlit, with rounded corners and an HDR gain. */
export function cardMaterial(map, aspect, { radius = 0.03, gain = 1, glow = null, transparent = true } = {}) {
  return new THREE.ShaderMaterial({
    transparent,
    side: THREE.DoubleSide,
    depthWrite: false,
    uniforms: {
      map: { value: map },
      uAspect: { value: aspect },
      uRadius: { value: radius },
      uGain: { value: gain },
      uOpacity: { value: 1 },
      uGlow: { value: glow ? col(glow) : col('#000') },
      uGlowAmount: { value: glow ? 1 : 0 },
    },
    vertexShader: /* glsl */ `varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }`,
    fragmentShader: /* glsl */ `
      ${roundedAlpha}
      uniform sampler2D map; uniform float uAspect, uRadius, uGain, uOpacity, uGlowAmount; uniform vec3 uGlow;
      varying vec2 vUv;
      void main() {
        float d = roundedBox(vUv, vec2(uAspect, 1.0), uRadius);
        float aa = fwidth(d);
        float shape = 1.0 - smoothstep(-aa, aa, d);
        if (shape < 0.003) discard;
        vec4 tex = texture2D(map, vUv);
        vec3 color = tex.rgb * uGain;
        color += uGlow * uGlowAmount * smoothstep(0.012, 0.0, abs(d + 0.002)) * 1.1;
        gl_FragColor = vec4(color, tex.a * shape * uOpacity);
      }`,
  });
}

/** A soft round light on the floor of the frame, for depth. */
export function glowSprite(color, size) {
  const c = canvas(256, 256);
  const g = c.getContext('2d');
  const grad = g.createRadialGradient(128, 128, 0, 128, 128, 128);
  grad.addColorStop(0, 'rgba(255,255,255,1)');
  grad.addColorStop(0.25, 'rgba(255,255,255,.35)');
  grad.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = grad;
  g.fillRect(0, 0, 256, 256);
  const mat = new THREE.SpriteMaterial({
    map: new THREE.CanvasTexture(c), color: col(color), blending: THREE.AdditiveBlending,
    transparent: true, depthWrite: false,
  });
  const s = new THREE.Sprite(mat);
  s.scale.setScalar(size);
  return s;
}

/** Slow, deep background: a void with a teal bloom that drifts. */
export function backdrop(scene, { strength = 1, hue = C.deep } = {}) {
  const mat = new THREE.ShaderMaterial({
    depthWrite: false, depthTest: false,
    uniforms: { uT: { value: 0 }, uS: { value: strength }, uA: { value: col(hue) }, uVoid: { value: col(C.void) } },
    vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy, 0.9999, 1.0); }`,
    fragmentShader: /* glsl */ `
      uniform float uT, uS; uniform vec3 uA, uVoid; varying vec2 vUv;
      float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453); }
      float noise(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.-2.*f);
        return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y); }
      float fbm(vec2 p){ float a=.5, s=0.; for(int i=0;i<5;i++){ s+=a*noise(p); p=p*2.03+vec2(1.7,9.2); a*=.5; } return s; }
      void main(){
        vec2 p = vUv*vec2(1.78,1.0);
        float n = fbm(p*.9 + vec2(uT*.02, -uT*.014) + .6*fbm(p*1.4 - uT*.018));
        float v = smoothstep(.3,.8,n) * (1.0-smoothstep(.1,.95,distance(vUv,vec2(.5,.48))*1.2));
        vec3 c = uVoid + uA * v * .62 * uS;
        gl_FragColor = vec4(c,1.0);
      }`,
  });
  const mesh = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), mat);
  mesh.frustumCulled = false;
  mesh.renderOrder = -1000;
  scene.add(mesh);
  return mat;
}

/** Slowly falling dust, catching the light. */
export function dust(scene, { count = 500, spread = [30, 18, 30], color = C.mint, size = 0.05, seed = 3 } = {}) {
  const r = rng(seed);
  const pos = new Float32Array(count * 3);
  const home = new Float32Array(count * 4);
  for (let i = 0; i < count; i++) {
    home[i * 4] = (r() - 0.5) * spread[0];
    home[i * 4 + 1] = (r() - 0.5) * spread[1];
    home[i * 4 + 2] = (r() - 0.5) * spread[2];
    home[i * 4 + 3] = r();
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  geo.setAttribute('aSeed', new THREE.BufferAttribute(Float32Array.from({ length: count }, () => r()), 1));
  const mat = new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    uniforms: { uC: { value: col(color) }, uS: { value: size }, uA: { value: 1 }, uH: { value: H } },
    vertexShader: /* glsl */ `attribute float aSeed; varying float vA; uniform float uS, uH;
      void main(){ vec4 p = modelViewMatrix*vec4(position,1.0); vA = aSeed;
        gl_PointSize = uS * (0.5+aSeed) * uH / -p.z; gl_Position = projectionMatrix*p; }`,
    fragmentShader: /* glsl */ `uniform vec3 uC; uniform float uA; varying float vA;
      void main(){ float d = length(gl_PointCoord-.5); float a = smoothstep(.5,.0,d); gl_FragColor = vec4(uC*(.6+vA*1.6), a*a*uA*(.25+vA*.6)); }`,
  });
  const points = new THREE.Points(geo, mat);
  points.frustumCulled = false;
  scene.add(points);
  return {
    mat,
    update(t) {
      for (let i = 0; i < count; i++) {
        const s = home[i * 4 + 3];
        pos[i * 3] = home[i * 4] + Math.sin(t * 0.15 + s * 40) * 0.7;
        pos[i * 3 + 1] = home[i * 4 + 1] + ((t * (0.05 + s * 0.1) + s * 20) % 3) - 1.5;
        pos[i * 3 + 2] = home[i * 4 + 2] + Math.cos(t * 0.12 + s * 30) * 0.7;
      }
      geo.attributes.position.needsUpdate = true;
    },
  };
}

export const words = {
  en: {
    trapped1: 'So much of what you read',
    trapped2: 'is trapped in pictures.',
    reads1: 'OCRFlow reads the page',
    reads2: 'the way you do.',
    kinds: ['Heading', 'Paragraph', 'Heading', 'Table', 'Formula', 'Heading', 'Paragraph'],
    capture1: 'From any app.',
    capture2: 'Choose it. Read it.',
    long1: 'A page longer than your screen?',
    long2: 'It joins as you scroll.',
    show1: 'Show it once.',
    show2: 'It does the rest.',
    one: 'One searchable document.',
    pages: 'pages',
    lang1: 'Fifty languages, out of the box.',
    lock1: 'And nothing ever leaves your Mac.',
    tag: 'Everything on your screen is text.',
    free: 'Free for Mac',
    step1: 'Capture this area', step2: 'Press →', recording: 'Recording', repeat: 'Repeat until the screen stops changing',
    barRead: 'Recognize', barLong: 'Long', barSave: 'Save', barCopy: 'Copy',
    longLabel: 'Long Screenshot',
  },
  zh: {
    trapped1: '你读到的很多文字，',
    trapped2: '都被困在图片里。',
    reads1: 'OCRFlow 读一页文档，',
    reads2: '就像你读它一样。',
    kinds: ['标题', '正文', '标题', '表格', '公式', '标题', '正文'],
    capture1: '在任何应用里。',
    capture2: '选中，就能读。',
    long1: '页面比屏幕还长？',
    long2: '边滚动，边拼接。',
    show1: '演示一次。',
    show2: '剩下的交给它。',
    one: '一份可搜索的文档。',
    pages: '页',
    lang1: '50 种语言，开箱即用。',
    lock1: '而且，什么都不会离开你的 Mac。',
    tag: '屏幕上的一切，都是文字。',
    free: '免费 · Mac 版',
    step1: '截取此区域', step2: '按 →', recording: '正在录制', repeat: '重复，直到屏幕不再变化',
    barRead: '识别', barLong: '长截图', barSave: '保存', barCopy: '拷贝',
    longLabel: '长截图',
  },
}[LANG];
