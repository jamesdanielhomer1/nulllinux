//! Kerr raytracer on the GPU (NULL.md §5.5).
//!
//! Vulkan compute through wgpu, so the same code runs on both adapters in this
//! machine: develop and correctness-test against the INTEGRATED GPU at proxy
//! resolution -- slow but present and needing no driver decision -- and run the
//! real bake on the DISCRETE one.

use std::io::Write;
use wgpu::util::DeviceExt;

#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct Params {
    cols: u32, rows: u32, max_steps: u32, n_bands: u32,
    a: f32, inclination: f32, half_width: f32, distance: f32,
    r_in: f32, r_out: f32, t_frac: f32, t_inner: f32,
}

#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct Band { m: f32, n: f32, r: f32, amp: f32, width: f32, phase: f32, _p0: f32, _p1: f32 }

fn arg(a: &[String], k: &str) -> Option<String> {
    a.iter().position(|x| x == k).and_then(|i| a.get(i + 1)).cloned()
}
fn argf(a: &[String], k: &str, d: f32) -> f32 { arg(a, k).and_then(|s| s.parse().ok()).unwrap_or(d) }

/// A scene parameter, with NO default.
///
/// Defaults here were a silent second source of truth for the scene: the
/// cross-validation passed none of these flags, got a=0.9 while the reference
/// used a=0.6, and reported the shader broken. A missing flag must be an
/// error, not a plausible number (§10.3).
fn scene_arg(a: &[String], k: &str) -> f32 {
    match arg(a, k) {
        Some(s) => s.parse().unwrap_or_else(|_| panic!("{k}: not a number: {s}")),
        None => panic!("{k} is required -- scene parameters have no defaults, \
                        because a default here is a second source of truth for \
                        the scene (see bake/scene.py)"),
    }
}
fn argu(a: &[String], k: &str, d: u32) -> u32 { arg(a, k).and_then(|s| s.parse().ok()).unwrap_or(d) }

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cols = argu(&args, "--cols", 160);
    let rows = argu(&args, "--rows", 45);
    let frames = argu(&args, "--frames", 1);
    // A frame RANGE, so the driver can work in chunks without the loop phase
    // drifting: t_frac must be (start + i) / total, not i / chunk.
    let frame_start = argu(&args, "--frame-start", 0);
    let frame_total = argu(&args, "--frame-total", frames);
    let max_steps = argu(&args, "--max-steps", 3000);
    let a = scene_arg(&args, "--spin");
    let inclination = scene_arg(&args, "--inclination");
    let half_width = scene_arg(&args, "--half-width");
    let r_in = scene_arg(&args, "--r-in");
    let r_out = scene_arg(&args, "--r-out");
    let t_inner = scene_arg(&args, "--t-inner");
    let outdir = arg(&args, "--out").unwrap_or_else(|| "out".into());
    let want_igpu = args.iter().any(|x| x == "--igpu");
    let bands_json = arg(&args, "--bands").expect("--bands <file> required");

    // The mode ladder comes from the ONE generator (§10.3); three copies of a
    // table drift and only one of them is the physics.
    let text = std::fs::read_to_string(&bands_json).expect("read bands");
    let mut bands: Vec<Band> = Vec::new();
    for line in text.lines() {
        let f: Vec<f32> = line.split_whitespace().filter_map(|t| t.parse().ok()).collect();
        if f.len() >= 6 {
            bands.push(Band { m: f[0], n: f[1], r: f[2], amp: f[3], width: f[4], phase: f[5],
                              _p0: 0.0, _p1: 0.0 });
        }
    }
    assert!(!bands.is_empty(), "no bands parsed");

    pollster::block_on(run(cols, rows, frames, frame_start, frame_total, max_steps, a,
                           inclination, half_width, r_in, r_out, t_inner, &outdir,
                           want_igpu, bands));
}

async fn run(cols: u32, rows: u32, frames: u32, frame_start: u32, frame_total: u32,
             max_steps: u32, a: f32, inclination: f32,
             half_width: f32, r_in: f32, r_out: f32, t_inner: f32, outdir: &str,
             want_igpu: bool, bands: Vec<Band>) {
    let instance = wgpu::Instance::default();
    let adapters: Vec<_> = instance.enumerate_adapters(wgpu::Backends::all());
    eprintln!("adapters:");
    for ad in &adapters {
        let i = ad.get_info();
        eprintln!("  {:?}  {}  ({:?})", i.device_type, i.name, i.backend);
    }
    // Adapter selection is EXPLICIT: default ordering is not something to rely
    // on when one adapter is eighteen times the other (§5.5).
    let pick = adapters.iter().find(|ad| {
        let t = ad.get_info().device_type;
        if want_igpu { t == wgpu::DeviceType::IntegratedGpu }
        else { t == wgpu::DeviceType::DiscreteGpu }
    }).or_else(|| adapters.first()).expect("no adapter");
    eprintln!("using: {}", pick.get_info().name);

    let (device, queue) = pick.request_device(&wgpu::DeviceDescriptor {
        label: None,
        required_features: wgpu::Features::empty(),
        required_limits: wgpu::Limits::downlevel_defaults(),
        memory_hints: Default::default(),
    }, None).await.expect("device");

    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("kerr"),
        source: wgpu::ShaderSource::Wgsl(include_str!("kerr.wgsl").into()),
    });

    let n = (cols * rows) as u64;
    let out_size = n * 16;
    let out_buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: None, size: out_size,
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
        mapped_at_creation: false,
    });
    let read_buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: None, size: out_size,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let band_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: None, contents: bytemuck::cast_slice(&bands),
        usage: wgpu::BufferUsages::STORAGE,
    });

    let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: None,
        entries: &[
            wgpu::BindGroupLayoutEntry { binding: 0, visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false, min_binding_size: None }, count: None },
            wgpu::BindGroupLayoutEntry { binding: 1, visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Storage { read_only: true },
                    has_dynamic_offset: false, min_binding_size: None }, count: None },
            wgpu::BindGroupLayoutEntry { binding: 2, visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Storage { read_only: false },
                    has_dynamic_offset: false, min_binding_size: None }, count: None },
        ],
    });
    let pipe_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: None, bind_group_layouts: &[&layout], push_constant_ranges: &[] });
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: None, layout: Some(&pipe_layout), module: &shader,
        entry_point: "main", compilation_options: Default::default(), cache: None });

    std::fs::create_dir_all(outdir).expect("mkdir");
    let t_start = std::time::Instant::now();

    for f in 0..frames {
        let params = Params {
            cols, rows, max_steps, n_bands: bands.len() as u32,
            a, inclination, half_width, distance: 200.0,
            r_in, r_out,
            t_frac: (frame_start + f) as f32 / frame_total.max(1) as f32,
            t_inner,
        };
        let pbuf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: None, contents: bytemuck::bytes_of(&params),
            usage: wgpu::BufferUsages::UNIFORM });
        let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None, layout: &layout, entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: pbuf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: band_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: out_buf.as_entire_binding() },
            ]});

        let mut enc = device.create_command_encoder(&Default::default());
        {
            let mut cp = enc.begin_compute_pass(&Default::default());
            cp.set_pipeline(&pipeline);
            cp.set_bind_group(0, &bind, &[]);
            cp.dispatch_workgroups((cols + 7) / 8, (rows + 7) / 8, 1);
        }
        enc.copy_buffer_to_buffer(&out_buf, 0, &read_buf, 0, out_size);
        queue.submit(Some(enc.finish()));

        let slice = read_buf.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| { let _ = tx.send(r); });
        device.poll(wgpu::Maintain::Wait);
        rx.recv().unwrap().unwrap();
        let data = slice.get_mapped_range().to_vec();
        drop(slice);
        read_buf.unmap();

        // Same HDR intermediate the reference writes (§5.2).
        let path = format!("{outdir}/{:04}.hdr", frame_start + f);
        let mut fh = std::io::BufWriter::new(std::fs::File::create(&path).expect("create"));
        fh.write_all(b"RHDR").unwrap();
        fh.write_all(&1u16.to_le_bytes()).unwrap();
        fh.write_all(&(cols as u16).to_le_bytes()).unwrap();
        fh.write_all(&(rows as u16).to_le_bytes()).unwrap();
        fh.write_all(&data).unwrap();
        if frames > 1 && (f + 1) % 10 == 0 {
            eprintln!("  {}/{} frames, {:.1}s", f + 1, frames, t_start.elapsed().as_secs_f32());
        }
    }
    let el = t_start.elapsed().as_secs_f32();
    eprintln!("{frames} frame(s) of {cols}x{rows} in {el:.2}s ({:.2}s/frame)", el / frames as f32);
}
