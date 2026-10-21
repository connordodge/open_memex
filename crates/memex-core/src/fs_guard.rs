//! The network-drive guard (req 30, ruling D4).
//!
//! A vault's SQLite runs in WAL mode, which is unsafe on network filesystems,
//! so `memex` refuses to create or open a vault on one. [`classify`] holds
//! the whole decision as a pure function over a `statfs` description;
//! [`probe`] is the `cfg`-gated `statfs` call that produces it, and
//! [`check`] / [`check_with`] tie the two together for a path that may not
//! exist yet.

use std::io;
use std::path::Path;

use crate::error::MemexError;
use crate::Result;

/// What `statfs` says about the filesystem holding a path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FsInfo {
    /// macOS: `f_fstypename` and whether `f_flags` has `MNT_LOCAL`.
    MacOs { fstypename: String, local: bool },
    /// Linux: `f_type` and whether `/proc/self/mountinfo` reports the mount
    /// as `fuseblk` (a FUSE driver over a local block device).
    Linux { f_type: u32, fuseblk: bool },
}

/// Whether a filesystem is safe for a vault.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FsClass {
    Local,
    Network,
}

/// macOS `f_fstypename` values that are network filesystems even when the
/// mount reports `MNT_LOCAL` (req 30). Matched exactly.
const MACOS_NETWORK_TYPES: [&str; 8] = [
    "smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs", "macfuse", "osxfuse",
];

/// Linux `f_type` magics of network filesystems (req 30), FUSE aside.
const LINUX_NETWORK_MAGICS: [u32; 10] = [
    0x6969,      // NFS
    0x517B,      // SMB
    0xFF53_4D42, // CIFS
    0xFE53_4D42, // SMB2
    0x5346_414F, // AFS
    0x6B41_4653, // kAFS
    0x7375_7245, // Coda
    0x564C,      // NCP
    0x00C3_6400, // Ceph
    0x0102_1997, // 9P
];

/// Linux `FUSE_SUPER_MAGIC`: network unless the mount is `fuseblk`.
const LINUX_FUSE_MAGIC: u32 = 0x6573_5546;

/// Classifies a `statfs` description (req 30).
///
/// - macOS: network when the mount lacks `MNT_LOCAL`, or when its type name
///   is exactly one of [`MACOS_NETWORK_TYPES`].
/// - Linux: network when `f_type` is one of [`LINUX_NETWORK_MAGICS`], or is
///   FUSE and the mount is not `fuseblk`.
pub fn classify(info: &FsInfo) -> FsClass {
    let network = match info {
        FsInfo::MacOs { fstypename, local } => {
            !*local || MACOS_NETWORK_TYPES.contains(&fstypename.as_str())
        }
        FsInfo::Linux { f_type, fuseblk } => {
            LINUX_NETWORK_MAGICS.contains(f_type) || (*f_type == LINUX_FUSE_MAGIC && !*fuseblk)
        }
    };
    if network {
        FsClass::Network
    } else {
        FsClass::Local
    }
}

/// Refuses `path` when it is on a network filesystem, using the real
/// `statfs` [`probe`].
pub fn check(path: &Path) -> Result<()> {
    check_with(path, &probe)
}

/// Refuses `path` when it is on a network filesystem, asking `probe` about
/// it. A path that doesn't exist yet is judged by its nearest existing
/// ancestor, and exactly that one path is probed. Nothing is created.
///
/// A failing probe is returned as an I/O error carrying the probe's error
/// text: never as safe and never as `NetworkFilesystem`.
pub fn check_with(path: &Path, probe: &dyn Fn(&Path) -> io::Result<FsInfo>) -> Result<()> {
    let target = nearest_existing(path);
    let info = probe(target).map_err(|e| {
        MemexError::Io(io::Error::new(
            e.kind(),
            format!(
                "cannot tell which filesystem holds {}: statfs {}: {e}",
                path.display(),
                target.display()
            ),
        ))
    })?;
    match classify(&info) {
        FsClass::Local => Ok(()),
        FsClass::Network => Err(MemexError::NetworkFilesystem(format!(
            "{} ({})",
            path.display(),
            describe(&info)
        ))),
    }
}

/// `path` itself when it exists, else its nearest existing ancestor. A
/// relative path with no existing ancestor resolves to `.`.
fn nearest_existing(path: &Path) -> &Path {
    let mut current = path;
    loop {
        if current.exists() {
            return current;
        }
        match current.parent() {
            Some(parent) if !parent.as_os_str().is_empty() => current = parent,
            _ => return Path::new("."),
        }
    }
}

/// A short name for the filesystem in a refusal message.
fn describe(info: &FsInfo) -> String {
    match info {
        FsInfo::MacOs { fstypename, local } if *local => fstypename.clone(),
        FsInfo::MacOs { fstypename, .. } => format!("{fstypename}, not a local mount"),
        FsInfo::Linux { f_type, .. } if *f_type == LINUX_FUSE_MAGIC => "fuse".to_string(),
        FsInfo::Linux { f_type, .. } => format!("f_type {f_type:#x}"),
    }
}

/// `statfs` of `path` itself (which must exist).
#[cfg(target_os = "macos")]
pub fn probe(path: &Path) -> io::Result<FsInfo> {
    let st = statfs(path)?;
    // SAFETY: the kernel NUL-terminates `f_fstypename` within its 16 bytes.
    let name = unsafe { std::ffi::CStr::from_ptr(st.f_fstypename.as_ptr()) };
    Ok(FsInfo::MacOs {
        fstypename: name.to_string_lossy().into_owned(),
        local: st.f_flags & (libc::MNT_LOCAL as u32) != 0,
    })
}

/// `statfs` of `path` itself (which must exist), plus whether its mount is
/// `fuseblk` when the filesystem is FUSE.
#[cfg(target_os = "linux")]
pub fn probe(path: &Path) -> io::Result<FsInfo> {
    let st = statfs(path)?;
    let f_type = st.f_type as u32;
    let fuseblk = f_type == LINUX_FUSE_MAGIC && {
        let canonical = std::fs::canonicalize(path)?;
        let mountinfo = std::fs::read_to_string("/proc/self/mountinfo")?;
        mountinfo_fstype(&mountinfo, &canonical).as_deref() == Some("fuseblk")
    };
    Ok(FsInfo::Linux { f_type, fuseblk })
}

/// No `statfs` classification exists for this platform, so every path is an
/// error rather than silently safe.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn probe(path: &Path) -> io::Result<FsInfo> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        format!(
            "network-drive detection is not supported on this platform: {}",
            path.display()
        ),
    ))
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn statfs(path: &Path) -> io::Result<libc::statfs> {
    use std::os::unix::ffi::OsStrExt;
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let mut st = std::mem::MaybeUninit::<libc::statfs>::zeroed();
    // SAFETY: `c_path` is NUL-terminated and `st` is a writable statfs.
    let rc = unsafe { libc::statfs(c_path.as_ptr(), st.as_mut_ptr()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: statfs returned 0, so it filled `st`.
    Ok(unsafe { st.assume_init() })
}

/// The filesystem type `/proc/self/mountinfo` lists for the mount holding
/// the canonical `path`: the mount whose mount point is the longest prefix
/// of it, the last one listed when several share that mount point.
#[cfg(any(target_os = "linux", test))]
fn mountinfo_fstype(mountinfo: &str, path: &Path) -> Option<String> {
    let mut best: Option<(usize, String)> = None;
    for line in mountinfo.lines() {
        let Some((left, right)) = line.split_once(" - ") else {
            continue;
        };
        let Some(mount_point) = left.split(' ').nth(4) else {
            continue;
        };
        let Some(fstype) = right.split(' ').next() else {
            continue;
        };
        let mount_point = unescape_mountinfo(mount_point);
        let mount_point = Path::new(&mount_point);
        if !path.starts_with(mount_point) {
            continue;
        }
        let depth = mount_point.components().count();
        if best.as_ref().is_none_or(|(d, _)| depth >= *d) {
            best = Some((depth, fstype.to_string()));
        }
    }
    best.map(|(_, fstype)| fstype)
}

/// Undoes mountinfo's octal escapes (`\040` for a space, and so on).
#[cfg(any(target_os = "linux", test))]
fn unescape_mountinfo(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 4 <= bytes.len() {
            let digits = &bytes[i + 1..i + 4];
            if digits.iter().all(|d| (b'0'..=b'7').contains(d)) {
                let value = digits
                    .iter()
                    .fold(0u32, |acc, d| acc * 8 + u32::from(d - b'0'));
                if let Ok(b) = u8::try_from(value) {
                    out.push(b);
                    i += 4;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOUNTINFO: &str = "\
22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw
40 22 0:35 / /mnt/usb rw,nosuid shared:20 - fuseblk /dev/sdb1 rw,user_id=0
41 22 0:36 / /mnt/remote rw,nosuid shared:21 - fuse.sshfs host:/ rw,user_id=1000
42 22 0:37 / /mnt/my\\040disk rw shared:22 - fuseblk /dev/sdc1 rw
43 41 0:38 / /mnt/remote/inner rw shared:23 - fuseblk /dev/sdd1 rw
44 22 0:39 / /mnt/usb rw shared:24 - fuse.sshfs host:/ rw
";

    #[test]
    fn mountinfo_picks_the_longest_mount_point_prefix() {
        let at = |p: &str| mountinfo_fstype(MOUNTINFO, Path::new(p));
        assert_eq!(at("/home/a").as_deref(), Some("ext4"));
        assert_eq!(at("/mnt/remote/x").as_deref(), Some("fuse.sshfs"));
        assert_eq!(at("/mnt/remote/inner/v").as_deref(), Some("fuseblk"));
        assert_eq!(at("/mnt/remotex").as_deref(), Some("ext4"));
    }

    #[test]
    fn mountinfo_later_mounts_shadow_earlier_ones() {
        let got = mountinfo_fstype(MOUNTINFO, Path::new("/mnt/usb/v"));
        assert_eq!(got.as_deref(), Some("fuse.sshfs"));
    }

    #[test]
    fn mountinfo_unescapes_octal_mount_points() {
        let got = mountinfo_fstype(MOUNTINFO, Path::new("/mnt/my disk/v"));
        assert_eq!(got.as_deref(), Some("fuseblk"));
        assert_eq!(unescape_mountinfo("a\\040b\\011c"), "a b\tc");
        assert_eq!(unescape_mountinfo("trail\\04"), "trail\\04");
    }

    #[test]
    fn mountinfo_without_a_match_is_none() {
        assert_eq!(mountinfo_fstype("", Path::new("/x")), None);
        assert_eq!(mountinfo_fstype("garbage line\n", Path::new("/x")), None);
    }
}
