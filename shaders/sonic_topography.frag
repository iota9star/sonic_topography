// Sonic Topography — SINGLE-PASS GPU shader.
//
// The entire scene (audio-reactive terrain + ripples + meteors + particles) is
// rendered in ONE fragment shader with ZERO intermediate textures. Elevation is
// computed inline via simplex noise (pure ALU — faster than texture sampling on
// modern GPUs, and eliminates the bake pass + toImage stall entirely).
//
// Architecture:
//   CPU/frame: read bands, update ring buffers, ~30 setFloat calls. ~10µs total.
//   GPU/frame: Flutter rasterizes CustomPaint's drawRect with this shader.
//              DDA visits ~10 cells/ray (early-out after first hit), each cell
//              evaluates ~5 snoise = ~50 snoise/pixel avg. <1ms at 1080p.
//
// This is the reference's elevation model (vertex shader) + shading (fragment
// shader) merged into one pass, ray-traced via a stable DDA that visits every
// crossed cell (no angle-dependent bugs).

#include <flutter/runtime_effect.glsl>

precision highp float;

// Uniform layout — KEEP IN SYNC with sonic_shader_controller.dart.
// Metal limits MSL buffer bindings to 32 ([[buffer(0..30)]]); every declared
// uniform (dead or live) consumes a slot after GLSL→SPIR-V→MSL translation.
// This pass therefore declares ONLY what it reads: elevation/band data lives
// in the baked heightfield texture, so uSubBass/uBass/…/uDensity and the
// uRipples array must NOT be declared here (they once blew past the limit and
// Impeller failed the per-frame shader build, showing a blank screen).
uniform vec2  uResolution;
uniform float uTime;
uniform float uPresence, uBrilliance, uAir;
uniform float uWarmth, uBrightness, uSharpness;

uniform vec3  uBaseColor1, uBaseColor2;
uniform vec3  uCoolCore, uCoolEdge;
uniform vec3  uWarmCore, uWarmEdge;
uniform vec3  uRippleColor;
uniform float uGlowIntensity;

uniform vec4  uMeteors[20];   // x, z, currentY, strength
uniform vec4  uParticles[64]; // x, y, z, strength

uniform float uCamRadius, uCamHeight, uCamAngle, uMarchScale;
uniform float uPillarHalf;
uniform float uSpacing;
uniform vec3  uBgColor;  // Flutter background color (behind the terrain)
uniform vec3  uFogColor; // scene fog — reference themes 1.1.3 use a fog ≠ background
uniform vec4  uBlockA[32];  // floating crystal blocks: x, y, z, halfSize
uniform vec4  uBlockQ[32];  // per-block tumble quaternion (unit, xyzw)
uniform float uBlockPulse;  // reference uPulse — crystal brightness driver

// Baked per-cell heightfield (sampler 0). R=elevation/16, G=rippleN, B=rippleW,
// A=cellHash. Sampling is a cheap coherent memory access (vs 5 snoise/cell
// inline → warp divergence). The bake runs once per cell on the GPU (async).
uniform sampler2D uHeightfield;

out vec4 fragColor;

// ────────────── Heightfield texture lookup ──────────────
// One coherent texture() fetch per DDA cell — replaces the expensive inline
// elevation model (5 snoise/cell) that caused GPU warp divergence. The bake
// shader computes elevation once per cell; we just read it.
// Returns vec4(elevation, rippleNormal, rippleWhite, cellHash).
vec4 sampleCell(vec2 cellCenter){
  // Fixed world extent = 84 (matches bake shader). Changing spacing only
  // changes cell density, not world coverage.
  float gridExtent = 84.0;
  vec2 uv = (cellCenter / gridExtent) * 0.5 + 0.5;
  // Clamp to valid texture range — cells outside the bake return edge values
  // (flat ground at the boundary), which is correct for the dome edge.
  // NOTE: no IMPELLER_TARGET_OPENGLES Y-flip — engine PR #186556 made the GLES
  // backend's Y-axis consistent with the other Impeller backends (Flutter 3.47
  // removes the same workaround from its own Material shaders).
  uv = clamp(uv, vec2(0.0), vec2(1.0));
  vec4 raw = texture(uHeightfield, uv);
  return vec4(raw.r * 16.0, raw.g, raw.b, raw.a);
}

// ────────────── Volumetric point glow ──────────────
float pointGlow(vec3 ro, vec3 rd, vec3 c, float radius, float intensity){
  float t = dot(c - ro, rd);
  if (t < 0.0) return 0.0;
  vec3 pc = ro + rd * t;
  return exp(-distance(pc, c) * distance(pc, c) / (radius*radius)) * intensity;
}

// Rotate v by the conjugate (inverse) of a unit quaternion — block-local
// space for the ray-box test. ~15 ALU, no transcendentals.
vec3 qrotInv(vec4 q, vec3 v){
  vec3 u = -q.xyz;
  return v + 2.0 * cross(u, cross(u, v) + q.w * v);
}

// ────────────── DDA ray-grid traversal ──────────────
// Stable Amanatides–Woo 2D DDA entering at the grid bbox. Visits every cell the
// ray crosses (no misses). All params in camera-ray space. Early-out after the
// first solid hit (every cell has ≥1-tall pillar → first hit occludes rest).
struct Hit {
  bool found;
  vec3 pos;
  vec2 cellCenter;
  float elevation;
  vec2 rippleAnim; // (normal, white) from the baked heightfield
  bool isTop;
  vec2 cellUv;
  float cellHash;
};

Hit traceGrid(vec3 ro, vec3 rd){
  Hit h;
  h.found = false;

  // DDA step budget. Sized for the reference's default camera (distance ~103,
  // low angle): rays cross the flat outer ring for ~60+ cells before reaching
  // the tall center, so the trip cap must cover a full diagonal walk. The
  // altitude clamp below skips the high-altitude approach segment, keeping the
  // average well under the cap; uMarchScale (0.5..1, driven by AdaptiveQuality)
  // dynamically truncates traversal for weak GPUs.
  float maxCells = 128.0 * clamp(uMarchScale, 0.5, 1.0);
  float sp = uSpacing;
  float halfBox = uPillarHalf;
  float gridExtent = 84.0;

  if (rd.y > -0.0001) return h; // only downward rays hit terrain
  vec3 invD = 1.0 / rd;

  // Ray vs xz bounding box (±gridExtent), parameterized by 3D ray t.
  float tx0 = (rd.x >= 0.0 ? -gridExtent - ro.x : gridExtent - ro.x) * invD.x;
  float tx1 = (rd.x >= 0.0 ?  gridExtent - ro.x : -gridExtent - ro.x) * invD.x;
  float tz0 = (rd.z >= 0.0 ? -gridExtent - ro.z : gridExtent - ro.z) * invD.z;
  float tz1 = (rd.z >= 0.0 ?  gridExtent - ro.z : -gridExtent - ro.z) * invD.z;
  float tEnter = max(max(min(tx0,tx1), min(tz0,tz1)), 0.0);
  float tExit  = min(max(tx0,tx1), max(tz0,tz1));

  // Altitude clamp: no pillar can be taller than ~13 world units (the bake
  // clamps elevation at 16 but audio lifts stay ≤ ~12), so a ray above that
  // height cannot hit anything. Advancing the entry to where the ray descends
  // below it skips the long high-altitude approach segment for free.
  float maxTerrainH = 13.0;
  float tAlt = (maxTerrainH - ro.y) / rd.y; // rd.y < 0 here
  tEnter = max(tEnter, tAlt);
  if (tEnter >= tExit) return h;

  vec2 p = (ro + rd * tEnter).xz;
  vec2 cell = floor((p + gridExtent) / sp);
  vec2 stepd = sign(rd.xz);
  vec2 tDelta = abs(invD.xz) * sp;
  vec2 tMax;
  tMax.x = (stepd.x >= 0.0)
      ? ((cell.x+1.0)*sp - (p.x+gridExtent)) * invD.x + tEnter
      : ((p.x+gridExtent) - cell.x*sp) * (-invD.x) + tEnter;
  tMax.y = (stepd.y >= 0.0)
      ? ((cell.y+1.0)*sp - (p.y+gridExtent)) * invD.z + tEnter
      : ((p.y+gridExtent) - cell.y*sp) * (-invD.z) + tEnter;

  float bestT = 1e9;
  for (int i = 0; i < 128; i++){
    if (float(i) >= maxCells) break;
    if (tMax.x > tExit && tMax.y > tExit) break;

    vec2 cc = cell * sp - gridExtent + sp * 0.5;
    // Allow one extra cell of margin so pillars at the grid edge are always
    // tested (prevents jagged holes at the boundary for any spacing value).
    if (abs(cc.x) <= gridExtent + sp && abs(cc.y) <= gridExtent + sp){
      vec4 cd = sampleCell(cc); // elevation, rippleN, rippleW, hash
      float elev = cd.x;
      float totalH = 1.0 + elev;
      vec3 mn = vec3(cc.x - halfBox, 0.0, cc.y - halfBox);
      vec3 mx = vec3(cc.x + halfBox, totalH, cc.y + halfBox);
      vec3 t0b = (mn - ro) * invD;
      vec3 t1b = (mx - ro) * invD;
      vec3 tsb = min(t0b, t1b);
      vec3 tpb = max(t0b, t1b);
      float tEnterB = max(max(tsb.x, tsb.y), tsb.z);
      float tExitB  = min(min(tpb.x, tpb.y), tpb.z);
      if (tEnterB <= tExitB && tEnterB > 0.0 && tEnterB < bestT){
        bestT = tEnterB;
        h.found = true;
        h.pos = ro + rd * tEnterB;
        h.cellCenter = cc;
        h.elevation = elev;
        h.rippleAnim = cd.yz;
        h.cellHash = cd.w;
        h.isTop = (rd.y < 0.0 && abs(tsb.y - tEnterB) < 1e-3);
        h.cellUv = (h.pos.xz - (cc - halfBox)) / (2.0 * halfBox);
      }
    }

    if (tMax.x < tMax.y){
      if (tMax.x > bestT && h.found) break;
      tMax.x += tDelta.x; cell.x += stepd.x;
    } else {
      if (tMax.y > bestT && h.found) break;
      tMax.y += tDelta.y; cell.y += stepd.y;
    }
  }
  return h;
}

// ────────────── Fragment shading (reference fragment shader) ──────────────
// Returns vec4(linear color, alphaFade). The caller composites in display
// space like three.js does: ACES+sRGB per fragment, alpha-blended over the
// page background (which never passes through tone mapping).
vec4 shadePillar(Hit h, vec3 ro){
  vec2 pos2D = h.cellCenter;
  float centerDist = length(pos2D);
  float rnd = h.cellHash;
  float elevation = h.elevation;
  float normElevation = clamp(elevation / 8.0, 0.0, 1.0);

  float totalH = 1.0 + elevation;
  float relY = clamp(h.pos.y / totalH, 0.0, 1.0);
  float distFromTop = 1.0 - relY;

  vec3 c1 = uBaseColor1, c2 = uBaseColor2;
  float warmBlend = smoothstep(0.0, 1.0, uWarmth*1.5 + (0.5 - centerDist/80.0));
  vec3 zoneCore = mix(uCoolCore, uWarmCore, warmBlend);
  vec3 zoneEdge = mix(uCoolEdge, uWarmEdge, warmBlend);
  vec3 targetGlow = mix(zoneCore, zoneEdge, fract(rnd * 11.0));
  float distFade = 1.0 - smoothstep(40.0, 75.0, centerDist);
  vec3 brightCool = mix(uCoolCore, vec3(1.0), 0.24);
  targetGlow = mix(targetGlow, brightCool, uBrightness * 0.6);
  vec3 currentGlow = mix(c2, targetGlow, normElevation) * uGlowIntensity * distFade;

  // Ripples at the hit cell (from the baked heightfield — no recompute).
  vec2 ripAnim = h.rippleAnim;
  currentGlow = mix(currentGlow, uRippleColor, ripAnim.x);
  currentGlow = mix(currentGlow, vec3(1.0), ripAnim.y);

  vec3 bodyColor = mix(c1, c2, relY * distFade);
  vec3 col;

  if (h.isTop){
    float topIntensity = smoothstep(0.0, 0.4, normElevation);
    float twinkleFalloff = smoothstep(60.0, 30.0, centerDist);
    float twinkleMul = mix(twinkleFalloff, 1.0, smoothstep(0.01, 0.1, normElevation));
    if (fract(rnd*31.0) > 0.95 && normElevation < 0.1)
      topIntensity += uAir * 2.0 * twinkleMul;

    col = mix(c2, currentGlow, clamp(topIntensity, 0.0, 1.0));

    // Edge rim (reference 4-edge sum).
    float eX = smoothstep(0.05,0.01,h.cellUv.x) + smoothstep(0.95,0.99,h.cellUv.x);
    float eY = smoothstep(0.05,0.01,h.cellUv.y) + smoothstep(0.95,0.99,h.cellUv.y);
    float edge = min(eX + eY, 1.0);
    col += currentGlow * edge * 0.8 * (topIntensity + 0.3);

    // Presence flickers.
    float flashChance = smoothstep(0.3, 1.0, uPresence);
    if (fract(rnd*53.0) > 0.98 - flashChance*0.1){
      float flash = sin(uTime*40.0 + rnd*100.0)*0.5 + 0.5;
      col += mix(vec3(1.0), vec3(0.5,1.0,1.0), rnd) * flash * uPresence
             * (1.0 + uSharpness*2.0) * twinkleMul;
    }
    if (edge > 0.5 && fract(rnd*89.0 + uTime*2.0) > 0.98)
      col += vec3(1.0) * uBrilliance * 3.0 * twinkleMul;
  } else {
    float vFall = mix(1.0, 3.0, uSharpness);
    float sideGlow = smoothstep(0.5/vFall, 0.0, distFromTop) * normElevation;
    if (normElevation < 0.02) sideGlow = 0.0;
    col = mix(bodyColor, currentGlow, sideGlow * 1.5);
    float rim = smoothstep(0.03, 0.0, distFromTop) * normElevation;
    col += currentGlow * rim;
  }

  col += uRippleColor * ripAnim.x * 0.6;
  col += vec3(1.0) * ripAnim.y * 1.2;

  // ── Edge blend (matching reference) ──
  // The reference's pillars are a custom ShaderMaterial with fog DISABLED —
  // three.js's <fog> never touches them. All distance blending is RADIAL
  // (centerDist from the origin), not camera depth:
  //   1. aerial perspective toward the atmospheric color
  //   2. alpha fade of the outer ring toward the fog/backdrop color
  // (A camera-depth fog here wiped the whole scene once the camera moved to
  // the reference's default distance ~103 — everything sat beyond far=95.)

  // 1. Aerial perspective (radial)
  float aerialFog = smoothstep(30.0, 65.0, centerDist);
  vec3 atmosphericColor = mix(c1, c2, 0.4);
  col = mix(col, atmosphericColor, aerialFog * 0.35);

  // 2. Backdrop blend (radial)
  float alphaFade = 1.0 - smoothstep(55.0, 78.0, centerDist);
  float alphaBlend = 1.0 - alphaFade;
  col = mix(col, uFogColor, alphaBlend * 0.45);

  return vec4(col, alphaFade);
}

// ────────────── Output color handling ──────────────
// NOTE on the reference pipeline (measured on the live app): the terrain and
// block materials are drei `shaderMaterial`s — fully custom fragment shaders
// WITHOUT three.js's tonemapping/colorspace chunks — so their linear colors
// land in the framebuffer raw (no ACES, no sRGB encode). Only two things are
// ever encoded: the page CSS background (= sRGB(fog), which our MISS rays and
// radial fades must match) and the meteor/particle colors (built-in
// meshBasicMaterial with toneMapped=false still runs the colorspace chunk).
vec3 linearToSrgb(vec3 c){
  c = max(c, vec3(0.0));
  return mix(pow(c, vec3(0.41666)) * 1.055 - 0.055, c * 12.92,
             vec3(lessThanEqual(c, vec3(0.0031308))));
}

void main(){
  vec2 uv = FlutterFragCoord().xy / uResolution.xy;
  vec2 p = uv * 2.0 - 1.0;
  p.y = -p.y;
  p.x *= uResolution.x / uResolution.y;

  // Camera — exact reference [35,25,35], fov 45, look at origin.
  float a = uCamAngle;
  vec3 ro = vec3(uCamRadius * cos(a), uCamHeight, uCamRadius * sin(a));
  vec3 fwd = normalize(vec3(0.0) - ro);
  vec3 right = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
  vec3 up = cross(right, fwd);
  float fov = 1.0 / tan(radians(45.0) * 0.5);
  vec3 rd = normalize(fwd * fov + right * p.x + up * p.y);

  Hit h = traceGrid(ro, rd);

  // ── Compositing, mirroring the reference's ACTUAL pipeline ──
  // Measured on the live reference: its custom shaderMaterial fragments have
  // no three.js tonemapping/colorspace chunks, so terrain + block colors are
  // RAW linear values displayed as sRGB (the dark, moody look). Only the page
  // CSS background (= sRGB(fog) via getHexString) is encoded — so MISS rays
  // output the sRGB background, and radial alpha blends canvas-raw over it
  // exactly like the GPU compositing a transparent WebGL canvas over CSS.
  vec3 srgbBg = linearToSrgb(uBgColor);
  vec3 col;
  if (h.found) {
    vec4 tc = shadePillar(h, ro); // raw linear color + radial alphaFade
    col = mix(srgbBg, tc.rgb, tc.a);
  } else {
    col = srgbBg;
  }

  // Floating crystal blocks (reference FloatingBlocks + block material).
  // Real box geometry: bounding-sphere cull → quaternion ray-box slab test,
  // nearest block in front of the terrain wins. Shading follows the reference
  // block fragment shader (zone glow by uPulse, white kick flash, edge rim,
  // twinkle, radial aerial + backdrop fades).
  float terrainT = h.found ? length(h.pos - ro) : 1e9;
  float bestBT = 1e9;
  vec4 bestBl = vec4(0.0);
  vec3 bestLp = vec3(0.0);
  vec3 bestLn = vec3(0.0);
  for (int i = 0; i < 32; i++){
    vec4 bl = uBlockA[i];
    if (!(bl.w > 0.001)) continue;
    vec3 oc = bl.xyz - ro;
    float tc = dot(oc, rd);
    if (tc < 0.0) continue;
    float br = bl.w * 1.7321; // bounding sphere of the cube
    if (dot(oc, oc) - tc * tc > br * br) continue;
    vec4 q = uBlockQ[i];
    vec3 lro = qrotInv(q, ro - bl.xyz); // ray origin in block-local space
    vec3 lrd = qrotInv(q, rd);
    vec3 t0 = (vec3(-bl.w) - lro) / lrd;
    vec3 t1 = (vec3( bl.w) - lro) / lrd;
    vec3 tsb = min(t0, t1);
    vec3 tpb = max(t0, t1);
    float tN = max(max(tsb.x, tsb.y), tsb.z);
    float tF = min(min(tpb.x, tpb.y), tpb.z);
    if (tN > tF || tF < 0.0) continue;
    float tB = max(tN, 0.0);
    if (tB >= bestBT || tB >= terrainT) continue;
    bestBT = tB;
    bestBl = bl;
    bestLp = lro + lrd * tB;
    bestLn = -sign(lrd) * vec3(equal(tsb, vec3(tN))); // entry face, local
  }
  if (bestBT < 1e8) {
    vec3 c = bestBl.xyz;
    float cd = length(c.xz);
    float rnd = fract(sin(dot(c.xz, vec2(12.9898, 78.233))) * 43758.5453123);
    // vElevation = uPulse*20 → /8: blocks are "always excited" on kicks.
    float normElev = clamp(uBlockPulse * 2.5, 0.0, 1.0);
    float warmBlend = smoothstep(0.0, 1.0, uWarmth*1.5 + (0.5 - cd/80.0));
    vec3 zoneCore = mix(uCoolCore, uWarmCore, warmBlend);
    vec3 zoneEdge = mix(uCoolEdge, uWarmEdge, warmBlend);
    vec3 targetGlow = mix(zoneCore, zoneEdge, fract(rnd * 11.0));
    float distFade = 1.0 - smoothstep(40.0, 75.0, cd);
    vec3 brightCool = mix(uCoolCore, vec3(1.0), 0.24);
    targetGlow = mix(targetGlow, brightCool, uBrightness * 0.6);
    vec3 currentGlow = mix(uBaseColor2, targetGlow, normElev) * uGlowIntensity * distFade;
    currentGlow = mix(currentGlow, uRippleColor, uBlockPulse * 0.8);
    currentGlow = mix(currentGlow, vec3(1.0), uBlockPulse * 0.3);
    float topIntensity = smoothstep(0.0, 0.4, normElev);
    vec3 bcol = mix(uBaseColor2, currentGlow, topIntensity);

    // Face-local UV (the two axes off the normal) → edge rim like the cube.
    vec3 an = abs(bestLn);
    vec2 uvB;
    if (an.x > an.y && an.x > an.z)      uvB = bestLp.zy;
    else if (an.y > an.z)                uvB = bestLp.xz;
    else                                 uvB = bestLp.xy;
    uvB = uvB / (2.0 * bestBl.w) + 0.5;
    float eX = smoothstep(0.05, 0.01, uvB.x) + smoothstep(0.95, 0.99, uvB.x);
    float eY = smoothstep(0.05, 0.01, uvB.y) + smoothstep(0.95, 0.99, uvB.y);
    float edge = min(eX + eY, 1.0);
    bcol += currentGlow * edge * 0.8 * (topIntensity + 0.3);

    float twinkleMul = mix(smoothstep(60.0, 30.0, cd), 1.0,
                           smoothstep(0.01, 0.1, normElev));
    float flashChance = smoothstep(0.3, 1.0, uPresence);
    if (fract(rnd * 53.0) > 0.98 - flashChance * 0.1){
      float flashSync = sin(uTime * 40.0 + rnd * 100.0) * 0.5 + 0.5;
      bcol += mix(vec3(1.0), vec3(0.5, 1.0, 1.0), rnd) * flashSync * uPresence
            * (1.0 + uSharpness * 2.0) * twinkleMul;
    }
    if (edge > 0.5 && fract(rnd * 89.0 + uTime * 2.0) > 0.98)
      bcol += vec3(1.0) * uBrilliance * 3.0 * twinkleMul;
    bcol += uRippleColor * uBlockPulse * 0.8 * 0.6;
    bcol += vec3(1.0) * uBlockPulse * 0.3 * 1.2;

    float aerialFog = smoothstep(30.0, 65.0, cd);
    bcol = mix(bcol, mix(uBaseColor1, uBaseColor2, 0.4), aerialFog * 0.35);
    float alphaFade = 1.0 - smoothstep(55.0, 78.0, cd);
    bcol = mix(bcol, uFogColor, (1.0 - alphaFade) * 0.45);
    col = mix(col, bcol, alphaFade); // raw canvas value over the display frame
  }

  // Meteors + impact particles — additive glow on top of the display-space
  // frame. The reference's meteor/particle materials set toneMapped=false:
  // they skip ACES and only pass the sRGB encode.
  vec3 meteorCol = linearToSrgb(clamp(mix(uWarmCore, vec3(1.0), 0.7), 0.0, 1.0));
  for (int i = 0; i < 20; i++){
    vec4 m = uMeteors[i];
    if (!(m.w > 0.001)) continue;
    vec3 head = vec3(m.x, max(m.z, 0.0), m.y);
    float g = pointGlow(ro,rd,head,2.2,m.w*4.0)
            + pointGlow(ro,rd,head,0.7,m.w*6.0)
            + pointGlow(ro,rd,head-vec3(0,1.6,0),1.6,m.w*2.0)
            + pointGlow(ro,rd,head-vec3(0,3.2,0),1.2,m.w*1.0);
    col += meteorCol * g;
  }
  vec3 particleCol = linearToSrgb(clamp(mix(uWarmCore, vec3(1.0), 0.85), 0.0, 1.0));
  for (int i = 0; i < 64; i++){
    vec4 pa = uParticles[i];
    if (!(pa.w > 0.001)) continue;
    col += particleCol * pointGlow(ro,rd,pa.xyz,0.9,pa.w*3.0);
  }

  fragColor = vec4(col, 1.0);
}
