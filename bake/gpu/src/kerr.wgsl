// Kerr geodesics as a compute shader (NULL.md §3.3, §5.5).
//
// FP32 only: both adapters here have weak double precision. Three
// consequences are designed in rather than discovered --
//   * the null-condition tolerance is 1e-5, not 1e-8;
//   * p is re-projected onto the null cone periodically rather than trusting
//     drift to stay bounded;
//   * the finite-difference step SCALES WITH POSITION, because a fixed
//     absolute step adequate near the horizon falls below f32 epsilon at large
//     radius and the difference degenerates into rounding noise.

struct Params {
    cols: u32,
    rows: u32,
    max_steps: u32,
    n_bands: u32,
    a: f32,
    inclination: f32,
    half_width: f32,
    distance: f32,
    r_in: f32,
    r_out: f32,
    t_frac: f32,
    t_inner: f32,
};

struct Band { m: f32, n: f32, r: f32, amp: f32, width: f32, phase: f32, _p0: f32, _p1: f32 };

@group(0) @binding(0) var<uniform> P: Params;
@group(0) @binding(1) var<storage, read> bands: array<Band>;
@group(0) @binding(2) var<storage, read_write> out_rgbt: array<vec4<f32>>;

const PI: f32 = 3.14159265359;
const ESCAPE_R: f32 = 400.0;

fn ks_radius(p: vec3<f32>, a: f32) -> f32 {
    let rho2 = dot(p, p);
    let t = rho2 - a * a;
    return sqrt(0.5 * (t + sqrt(t * t + 4.0 * a * a * p.z * p.z)));
}

// g^{mu nu} = eta^{mu nu} - f k^mu k^nu, with k^0 = -1.
// Returned as (f, kx, ky, kz); the caller forms what it needs.
fn ks_fk(p: vec3<f32>, a: f32) -> vec4<f32> {
    let r = ks_radius(p, a);
    let r2 = r * r;
    let denom = r2 * r2 + a * a * p.z * p.z;
    let f = 2.0 * r2 * r / max(denom, 1e-20);
    let d = r2 + a * a;
    return vec4<f32>(f, (r * p.x + a * p.y) / d, (r * p.y - a * p.x) / d, p.z / max(r, 1e-20));
}

// H = 1/2 g^{mu nu} p_mu p_nu
fn hamiltonian(x: vec3<f32>, pt: f32, pv: vec3<f32>, a: f32) -> f32 {
    let fk = ks_fk(x, a);
    let f = fk.x;
    let k = vec3<f32>(fk.y, fk.z, fk.w);
    // eta part: -pt^2 + |pv|^2
    let flat = -pt * pt + dot(pv, pv);
    // k^mu p_mu = (-1)*pt + k.pv
    let kp = -pt + dot(k, pv);
    return 0.5 * (flat - f * kp * kp);
}

fn dx_dl(x: vec3<f32>, pt: f32, pv: vec3<f32>, a: f32) -> vec4<f32> {
    let fk = ks_fk(x, a);
    let f = fk.x;
    let k = vec3<f32>(fk.y, fk.z, fk.w);
    let kp = -pt + dot(k, pv);
    // dx^mu/dl = g^{mu nu} p_nu
    let dt = -pt - f * (-1.0) * kp;
    let dv = pv - f * k * kp;
    return vec4<f32>(dt, dv.x, dv.y, dv.z);
}

fn dp_dl(x: vec3<f32>, pt: f32, pv: vec3<f32>, a: f32) -> vec3<f32> {
    // Central differences on the cheap scalars, with a step that scales with
    // position (§5.5).
    let scale = max(max(abs(x.x), abs(x.y)), max(abs(x.z), 1.0));
    let h = 1e-3 * scale;
    var g: vec3<f32>;
    let ex = vec3<f32>(h, 0.0, 0.0);
    let ey = vec3<f32>(0.0, h, 0.0);
    let ez = vec3<f32>(0.0, 0.0, h);
    g.x = (hamiltonian(x + ex, pt, pv, a) - hamiltonian(x - ex, pt, pv, a)) / (2.0 * h);
    g.y = (hamiltonian(x + ey, pt, pv, a) - hamiltonian(x - ey, pt, pv, a)) / (2.0 * h);
    g.z = (hamiltonian(x + ez, pt, pv, a) - hamiltonian(x - ez, pt, pv, a)) / (2.0 * h);
    return -g;
}

// Restore H = 0 by scaling the spatial momentum at fixed p_t.
fn project_null(x: vec3<f32>, pt: f32, pv: vec3<f32>, a: f32) -> vec3<f32> {
    let fk = ks_fk(x, a);
    let f = fk.x;
    let k = vec3<f32>(fk.y, fk.z, fk.w);
    // H(s) = 1/2[ -pt^2 + s^2|pv|^2 - f(-pt + s k.pv)^2 ]
    let kv = dot(k, pv);
    let A = dot(pv, pv) - f * kv * kv;
    let B = 2.0 * f * pt * kv;
    let C = -pt * pt - f * pt * pt;
    let disc = B * B - 4.0 * A * C;
    if (abs(A) < 1e-12 || disc < 0.0) { return pv; }
    let s = (-B + sqrt(disc)) / (2.0 * A);
    if (s <= 0.0 || !(s == s)) { return pv; }
    return pv * s;
}

fn planckian_xy(t_in: f32) -> vec2<f32> {
    let t = clamp(t_in, 1667.0, 25000.0);
    let t2 = t * t;
    let t3 = t2 * t;
    var x: f32;
    if (t <= 4000.0) {
        x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910;
    } else {
        x = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390;
    }
    let x2 = x * x;
    let x3 = x2 * x;
    var y: f32;
    if (t <= 2222.0) {
        y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683;
    } else if (t <= 4000.0) {
        y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867;
    } else {
        y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483;
    }
    return vec2<f32>(x, y);
}

fn blackbody_rgb(t: f32) -> vec3<f32> {
    let xy = planckian_xy(t);
    if (xy.y <= 1e-9) { return vec3<f32>(0.0); }
    let X = xy.x / xy.y;
    let Y = 1.0;
    let Z = (1.0 - xy.x - xy.y) / xy.y;
    var r = 3.2406 * X - 1.5372 * Y - 0.4986 * Z;
    var g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z;
    var b = 0.0557 * X - 0.2040 * Y + 1.0570 * Z;
    // Lift toward the achromatic axis rather than clipping: clipping a
    // negative channel is a hue shift, and it would desaturate exactly the two
    // ends that carry the Doppler asymmetry (§4.5).
    let m = min(min(r, g), b);
    if (m < 0.0) { r = r - m; g = g - m; b = b - m; }
    let peak = max(max(r, g), b);
    if (peak <= 0.0) { return vec3<f32>(0.0); }
    return vec3<f32>(r, g, b) / peak;
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= P.cols || gid.y >= P.rows) { return; }
    let cell = gid.y * P.cols + gid.x;

    // --- camera ---
    let inc = radians(P.inclination);
    let cam = vec3<f32>(P.distance * sin(inc), 0.0, P.distance * cos(inc));
    let fwd = normalize(-cam);
    let up0 = vec3<f32>(0.0, 0.0, 1.0);
    let right = normalize(cross(fwd, up0));
    let up = cross(right, fwd);
    let aspect = (f32(P.rows) * 2.0) / f32(P.cols);
    let sx = (f32(gid.x) + 0.5) / f32(P.cols) * 2.0 - 1.0;
    let sy = (f32(gid.y) + 0.5) / f32(P.rows) * 2.0 - 1.0;
    var x = cam + right * (sx * P.half_width) - up * (sy * P.half_width * aspect);

    var pt: f32 = -1.0;
    var pv: vec3<f32> = fwd;
    pv = project_null(x, pt, pv, P.a);

    let rp = 1.0 + sqrt(max(1.0 - P.a * P.a, 0.0));

    var acc_rgb = vec3<f32>(0.0);
    var acc_t: f32 = 0.0;
    var acc_w: f32 = 0.0;

    var step: u32 = 0u;
    loop {
        if (step >= P.max_steps) { break; }
        let r = ks_radius(x, P.a);
        if (r < rp * 1.001 || r > ESCAPE_R) { break; }

        let dl = clamp(0.02 * max(r - rp, 0.05) + 0.01, 0.005, 2.0);
        let z0 = x.z;

        // RK4
        let a1x = dx_dl(x, pt, pv, P.a);      let a1p = dp_dl(x, pt, pv, P.a);
        let x2 = x + 0.5 * dl * a1x.yzw;      let v2 = pv + 0.5 * dl * a1p;
        let a2x = dx_dl(x2, pt, v2, P.a);     let a2p = dp_dl(x2, pt, v2, P.a);
        let x3 = x + 0.5 * dl * a2x.yzw;      let v3 = pv + 0.5 * dl * a2p;
        let a3x = dx_dl(x3, pt, v3, P.a);     let a3p = dp_dl(x3, pt, v3, P.a);
        let x4 = x + dl * a3x.yzw;            let v4 = pv + dl * a3p;
        let a4x = dx_dl(x4, pt, v4, P.a);     let a4p = dp_dl(x4, pt, v4, P.a);

        let xn = x + (dl / 6.0) * (a1x.yzw + 2.0 * a2x.yzw + 2.0 * a3x.yzw + a4x.yzw);
        var vn = pv + (dl / 6.0) * (a1p + 2.0 * a2p + 2.0 * a3p + a4p);
        if (step % 16u == 0u) { vn = project_null(xn, pt, vn, P.a); }

        // EVERY equatorial crossing, not just the first (§3.3).
        let z1 = xn.z;
        if (z0 * z1 < 0.0) {
            let tt = z0 / (z0 - z1);
            let xc = x + tt * (xn - x);
            let vc = pv + tt * (vn - pv);
            let rc = ks_radius(xc, P.a);
            if (rc >= P.r_in && rc <= P.r_out) {
                let phi = atan2(xc.y, xc.x);
                var modv: f32 = 0.0;
                for (var i: u32 = 0u; i < P.n_bands; i = i + 1u) {
                    let b = bands[i];
                    let e = (rc - b.r) / (b.width * b.r);
                    let env = b.amp * exp(-(e * e));
                    // fract(n*t) BEFORE scaling by 2*pi: cos(m*phi - n*2*pi*t)
                    // is not bit-exact at t=1 for large n in f32, and the loop
                    // then fails to close (§5.5).
                    let ph = b.m * phi - 2.0 * PI * fract(b.n * P.t_frac) + b.phase;
                    modv = modv + env * cos(ph);
                }
                // The depth is already folded into the band amplitudes (§3.4).
                let t_local = clamp(P.t_inner * pow(rc / P.r_in, -0.75) * (1.0 + modv),
                                    200.0, 1000000.0);
                // Prograde circular emitter.
                let den = sqrt(max(rc * rc * rc - 3.0 * rc * rc + 2.0 * P.a * pow(rc, 1.5), 1e-6));
                let ut = (pow(rc, 1.5) + P.a) / den;
                let uphi = 1.0 / den;
                let pu = pt * ut + uphi * (-xc.y * vc.x + xc.x * vc.y);
                let g = 1.0 / max(abs(pu), 1e-9);
                let t_obs = clamp(t_local * g, 1667.0, 25000.0);
                let w = pow(g, 4.0) * pow(t_local / P.t_inner, 4.0);
                if (w > 0.0 && w == w) {
                    acc_rgb = acc_rgb + blackbody_rgb(t_obs) * w;
                    acc_t = acc_t + t_obs * w;
                    acc_w = acc_w + w;
                }
            }
        }

        x = xn; pv = vn;
        step = step + 1u;
    }

    var res = vec4<f32>(0.0, 0.0, 0.0, 0.0);
    if (acc_w > 0.0) { res = vec4<f32>(acc_rgb, acc_t / acc_w); }
    out_rgbt[cell] = res;
}
