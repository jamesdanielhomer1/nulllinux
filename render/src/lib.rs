//! Shared by every surface this system draws.
//!
//! One renderer draws every surface (NULL.md §6.1). That is the reason the
//! surfaces cannot disagree with each other about what the hero looks like,
//! what a rule looks like, or what a colour means -- so the shared parts live
//! here rather than being reimplemented per binary.

pub mod atlas;
pub mod cells;
pub mod grid;
pub mod ipc;
pub mod outputs;
pub mod palette;
pub mod panel;
pub mod pty;
pub mod raster;
pub mod spectrum;
pub mod sysinfo;
pub mod vt;
