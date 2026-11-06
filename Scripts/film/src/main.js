// The film's frame: shots rendered in HDR, joined by a line of light, then
// bloom, a little lens, and type on top. `filmFrame(t)` is the only clock.
import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { C, H, W, canvas, col, seg, smooth } from './core.js';
import { buildShots, DURATION, TRANSITIONS } from './shots.js';

const renderer = new THREE.WebGLRenderer({ antialias: false, preserveDrawingBuffer: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(1);
renderer.setSize(W, H);
renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
renderer.toneMapping = THREE.NoToneMapping;
renderer.autoClear = false;
document.body.appendChild(renderer.domElement);

const pmrem = new THREE.PMREMGenerator(renderer);
const environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;

const target = () => new THREE.WebGLRenderTarget(W, H, { type: THREE.HalfFloatType, samples: 4, colorSpace: THREE.NoColorSpace });
const rtA = target();
const rtB = target();

// --- type on top ------------------------------------------------------------
const typeCanvas = canvas(W, H);
const type = typeCanvas.getContext('2d');
const typeTexture = new THREE.CanvasTexture(typeCanvas);
typeTexture.colorSpace = THREE.NoColorSpace;
typeTexture.minFilter = THREE.LinearFilter;
typeTexture.generateMipmaps = false;
typeTexture.premultiplyAlpha = true;

// --- passes -------------------------------------------------------------------
const composer = new EffectComposer(renderer, new THREE.WebGLRenderTarget(W, H, { type: THREE.HalfFloatType }));

const join = new ShaderPass(new THREE.ShaderMaterial({
  uniforms: { tDiffuse: { value: null }, tA: { value: rtA.texture }, tB: { value: rtB.texture }, uMix: { value: -1 }, uLine: { value: col(C.mint) } },
  vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy,0.,1.); }`,
  fragmentShader: /* glsl */ `
    uniform sampler2D tA, tB; uniform float uMix; uniform vec3 uLine; varying vec2 vUv;
    void main(){
      vec3 a = texture2D(tA, vUv).rgb;
      if (uMix < 0.0) { gl_FragColor = vec4(a, 1.0); return; }
      vec3 b = texture2D(tB, vUv).rgb;
      float y = 1.0 - vUv.y;
      float m = uMix * 1.16 - 0.08;
      float wave = sin(vUv.x * 9.0 + uMix * 5.0) * 0.006;
      float d = y - m + wave;
      vec3 c = d < 0.0 ? b : a;
      c += uLine * exp(-pow(d / 0.0018, 2.0)) * 7.0 * step(0.0, uMix) * step(uMix, 1.0);
      c += uLine * exp(-pow(d / 0.04, 2.0)) * 0.22;
      gl_FragColor = vec4(c, 1.0);
    }`,
}));
composer.addPass(join);

const bloom = new UnrealBloomPass(new THREE.Vector2(W, H), 0.4, 0.6, 1.02);
composer.addPass(bloom);

const finish = new ShaderPass(new THREE.ShaderMaterial({
  uniforms: {
    tDiffuse: { value: null }, tType: { value: typeTexture }, uT: { value: 0 }, uFade: { value: 1 },
    uAberration: { value: 1 }, uRes: { value: new THREE.Vector2(W, H) },
  },
  vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy,0.,1.); }`,
  fragmentShader: /* glsl */ `
    uniform sampler2D tDiffuse, tType; uniform float uT, uFade, uAberration; uniform vec2 uRes; varying vec2 vUv;
    vec3 aces(vec3 x){ return clamp((x*(2.51*x+.03))/(x*(2.43*x+.59)+.14),0.,1.); }
    float hash(vec2 p){ vec3 q = fract(vec3(p.xyx)*.1031); q += dot(q,q.yzx+33.33); return fract((q.x+q.y)*q.z); }
    void main(){
      vec2 c = vUv - .5;
      float r2 = dot(c,c);
      vec2 off = c * r2 * .012 * uAberration;
      vec3 hdr = vec3(texture2D(tDiffuse, vUv + off).r, texture2D(tDiffuse, vUv).g, texture2D(tDiffuse, vUv - off).b);
      vec3 col = aces(hdr * .86); col = mix(col, col*col*(3.-2.*col), .35);
      col *= 1.0 - smoothstep(.16,.78,r2) * .62;
      col = pow(col, vec3(1./2.2));
      vec4 type = texture2D(tType, vUv);
      col = col * (1.0 - type.a) + type.rgb;
      float n = hash(gl_FragCoord.xy + fract(uT*7.13)*311.) - .5;
      col += n * .018;
      col *= uFade;
      gl_FragColor = vec4(col, 1.0);
    }`,
}));
composer.addPass(finish);

const shots = buildShots({ environment, renderer });

function active(t) {
  return shots.filter((s) => t >= s.start && t < s.end);
}

function draw(shot, rt, t) {
  shot.update(t);
  renderer.setRenderTarget(rt);
  renderer.setClearColor(C.void, 1);
  renderer.clear();
  renderer.render(shot.scene, shot.camera);
}

window.filmDuration = DURATION;
window.filmFrame = async (t) => {
  const on = active(t);
  draw(on[0], rtA, t);
  let mix = -1;
  const crossing = TRANSITIONS.find((x) => t >= x.at && t < x.at + x.length);
  if (crossing && on[1]) {
    draw(on[1], rtB, t);
    mix = smooth(seg(t, crossing.at, crossing.at + crossing.length));
  } else if (crossing && !on[1]) mix = -1;
  join.uniforms.uMix.value = mix;
  join.uniforms.tA.value = rtA.texture;
  join.uniforms.tB.value = rtB.texture;

  // Any shot's bright moments can ask for more or less bloom.
  const shot = on[on.length - 1];
  bloom.strength = shot.bloom ? shot.bloom(t) : 0.4;

  type.clearRect(0, 0, W, H);
  for (const s of on) if (s.overlay) s.overlay(type, t);
  typeTexture.needsUpdate = true;

  finish.uniforms.uT.value = t;
  finish.uniforms.uFade.value = smooth(seg(t, 0, 0.9)) * (1 - smooth(seg(t, DURATION - 0.9, DURATION - 0.05)));
  renderer.setRenderTarget(null);
  composer.render();
  return renderer.domElement.toDataURL('image/jpeg', 0.97).split(',')[1];
};

await document.fonts.ready;
window.filmReady = true;
