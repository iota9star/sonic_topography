// Sonic Topography — heightfield BAKE pass.
//
// Renders the grid into a small texture where each texel is one cell. Evaluates
// the elevation model ONCE PER CELL (parity with the reference vertex shader:
// ~25.6k snoise total). Packs: R=elevation/16, G=rippleNormal, B=rippleWhite,
// A=cellHash. The display pass samples this with a cheap texture() lookup per
// DDA cell (no per-pixel noise → no warp divergence → fast).
//
// Compact contiguous uniform layout — KEEP IN SYNC with controller._pushBake:
//   0,1 uResolution  2 uTime  3..15 audio  16 density  17 spacing
//   18 amplitude  19..58 ripples

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2  uResolution;
uniform float uTime;
uniform float uSubBass, uBass, uLowMid, uMid, uHighMid;
uniform float uPresence, uBrilliance, uAir;
uniform float uEnergy, uWarmth, uBrightness, uSharpness, uSmoothness;
uniform float uDensity;
uniform float uSpacing;
uniform float uAmplitude;   // master terrain gain (default 1.0)
uniform vec4  uRipples[10];

out vec4 fragColor;

vec3 mod289(vec3 x){ return x - floor(x*(1.0/289.0))*289.0; }
vec2 mod289(vec2 x){ return x - floor(x*(1.0/289.0))*289.0; }
vec3 permute(vec3 x){ return mod289(((x*34.0)+1.0)*x); }
float snoise(vec2 v){
  const vec4 C = vec4(0.211324865405187, 0.366025403784439,
                     -0.577350269189626, 0.024390243902439);
  vec2 i  = floor(v + dot(v, C.yy));
  vec2 x0 = v -   i + dot(i, C.xx);
  vec2 i1 = (x0.x > x0.y) ? vec2(1.0,0.0) : vec2(0.0,1.0);
  vec4 x12 = x0.xyxy + C.xxzz; x12.xy -= i1;
  i = mod289(i);
  vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
  vec3 m = max(0.5 - vec3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
  m = m*m; m = m*m;
  vec3 x = 2.0*fract(p*C.www)-1.0;
  vec3 h = abs(x)-0.5;
  vec3 ox = floor(x+0.5);
  vec3 a0 = x-ox;
  m *= 1.79284291400159 - 0.85373472095314*(a0*a0+h*h);
  vec3 g;
  g.x  = a0.x*x0.x + h.x*x0.y;
  g.yz = a0.yz*x12.xz + h.yz*x12.yw;
  return 130.0*dot(m,g);
}

float hash21(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233))) * 43758.5453123); }

vec2 rippleField(vec2 pos2D, out float elev){
  elev = 0.0;
  float intenN = 0.0, intenW = 0.0;
  for (int i = 0; i < 10; i++){
    vec4 r = uRipples[i];
    float strength = r.w;
    if (abs(strength) <= 0.001) continue;
    bool isWhite = strength < 0.0;
    float s = abs(strength);
    float dist = length(pos2D - r.xy);
    float speed    = isWhite ? 20.0 : 15.0;
    float width    = isWhite ? 1.0  : 3.0;
    float fadeDist = isWhite ? 8.0  : 15.0;
    float elevScl  = isWhite ? 1.0  : 4.0;
    float waveRadius = r.z * speed;
    float d = dist - waveRadius;
    float rw = exp(-d*d / width);
    float fade = exp(-waveRadius / fadeDist);
    float pulse = rw * fade * s;
    elev += pulse * elevScl;
    if (isWhite) intenW += pulse; else intenN += pulse;
  }
  return vec2(clamp(intenN, 0.0, 1.0), clamp(intenW, 0.0, 1.0));
}

float elevationAt(vec2 pos2D, float ripElev){
  float centerDist = length(pos2D);
  float rnd = hash21(pos2D);
  vec2 movingPos = pos2D * 0.05 + vec2(uTime*0.1, uTime*0.05);
  float baseNoise = (snoise(movingPos) + 1.0) * 0.5;
  float wave = sin(pos2D.x*0.15 + pos2D.y*0.1 - uTime*0.6) * 0.5 + 0.5;
  float globalFalloff = smoothstep(60.0, 30.0, centerDist);
  float idleElevation = mix(baseNoise, wave, uSmoothness*0.5 + 0.2) * 0.8 * globalFalloff;
  float subLift = uSubBass * smoothstep(25.0, 0.0, centerDist) * 5.0;
  float bassNoise = snoise(pos2D*0.1 - vec2(0.0, uTime*0.2));
  float bassLift = uBass * smoothstep(35.0, 5.0, centerDist + bassNoise*5.0)
                   * smoothstep(0.0, 1.0, rnd + uDensity*0.5) * 4.0;
  float lowMidNoise = snoise(pos2D*0.05 + vec2(uTime*0.1, 0.0));
  float lowMidLift = uLowMid * (lowMidNoise*0.5 + 0.5) * 2.5;
  float riverFlow = sin(pos2D.x*0.2 + pos2D.y*0.2 + snoise(pos2D*0.1)*2.0 - uTime*2.0);
  float midLift = uMid * max(0.0, riverFlow) * 3.0;
  float highMidLift = 0.0;
  if (fract(rnd*13.3) > 0.8)
    highMidLift = uHighMid * smoothstep(10.0, 45.0, centerDist) * fract(rnd*7.7) * 2.5;
  float audioElevation = subLift + bassLift + lowMidLift + midLift + highMidLift;
  if (rnd > 0.99) audioElevation += uEnergy * 5.0;
  audioElevation *= globalFalloff;

  // NOISE GATE (reference 1.1.3): subtract a small threshold so the analyzer
  // noise floor can't lift the whole terrain base — near-silence stays flat,
  // music punches harder.
  audioElevation = max(0.0, audioElevation - 0.2);
  audioElevation *= uAmplitude;

  return idleElevation + audioElevation + ripElev;
}

void main(){
  // Fixed world extent = 84 (matches display shader). Changing spacing only
  // changes cell density, not world coverage.
  float gridExtent = 84.0;
  vec2 uv = (FlutterFragCoord().xy + 0.5) / uResolution.xy;
  vec2 pos2D = (uv * 2.0 - 1.0) * gridExtent;
  // Evaluate the ripple field ONCE per texel — it feeds both the G/B intensity
  // channels and the elevation (via ripElev). Recomputing it inside
  // elevationAt doubled the bake cost for nothing.
  float ripElev;
  vec2 rip = rippleField(pos2D, ripElev);
  float elevation = elevationAt(pos2D, ripElev);
  fragColor = vec4(clamp(elevation/16.0, 0.0, 1.0), rip.x, rip.y, hash21(pos2D));
}
