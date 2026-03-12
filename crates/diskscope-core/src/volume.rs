use std::io;
use std::path::Path;

const MIN_COLLAPSE_THRESHOLD_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VolumeStats {
    pub total_bytes: u64,
    pub free_bytes: u64,
    pub available_bytes: u64,
    pub occupied_bytes: u64,
}

pub fn collapse_threshold_bytes(volume_size_bytes: u64) -> u64 {
    let percent_threshold = volume_size_bytes / 1000;
    percent_threshold.max(MIN_COLLAPSE_THRESHOLD_BYTES)
}

pub fn volume_size_bytes(path: &Path) -> io::Result<u64> {
    Ok(volume_stats(path)?.total_bytes)
}

pub fn volume_occupied_bytes(path: &Path) -> io::Result<u64> {
    Ok(volume_stats(path)?.occupied_bytes)
}

#[cfg(target_os = "macos")]
pub fn volume_stats(path: &Path) -> io::Result<VolumeStats> {
    use std::ffi::CString;
    use std::mem::MaybeUninit;
    use std::os::unix::ffi::OsStrExt;

    let c_path = CString::new(path.as_os_str().as_bytes()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "path contains interior null byte",
        )
    })?;

    let mut stat = MaybeUninit::<libc::statfs>::uninit();
    let rc = unsafe { libc::statfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }

    let stat = unsafe { stat.assume_init() };
    Ok(stats_from_block_counts(
        stat.f_blocks as u64,
        stat.f_bfree as u64,
        stat.f_bavail as u64,
        stat.f_bsize as u64,
    ))
}

#[cfg(all(unix, not(target_os = "macos")))]
pub fn volume_stats(path: &Path) -> io::Result<VolumeStats> {
    use std::ffi::CString;
    use std::mem::MaybeUninit;
    use std::os::unix::ffi::OsStrExt;

    let c_path = CString::new(path.as_os_str().as_bytes()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "path contains interior null byte",
        )
    })?;

    let mut stat = MaybeUninit::<libc::statvfs>::uninit();
    let rc = unsafe { libc::statvfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }

    let stat = unsafe { stat.assume_init() };
    Ok(stats_from_block_counts(
        stat.f_blocks as u64,
        stat.f_bfree as u64,
        stat.f_bavail as u64,
        stat.f_frsize as u64,
    ))
}

#[cfg(not(unix))]
pub fn volume_stats(_path: &Path) -> io::Result<VolumeStats> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "volume stats lookup is not implemented on this platform",
    ))
}

fn stats_from_block_counts(
    total_blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
    block_size: u64,
) -> VolumeStats {
    let total_bytes = total_blocks.saturating_mul(block_size);
    let free_bytes = free_blocks.saturating_mul(block_size).min(total_bytes);
    let available_bytes = available_blocks.saturating_mul(block_size).min(total_bytes);
    let occupied_bytes = total_bytes.saturating_sub(free_bytes);
    VolumeStats {
        total_bytes,
        free_bytes,
        available_bytes,
        occupied_bytes,
    }
}

#[cfg(test)]
mod tests {
    use super::{collapse_threshold_bytes, stats_from_block_counts};

    #[test]
    fn threshold_has_minimum_floor() {
        assert_eq!(
            collapse_threshold_bytes(20 * 1024 * 1024 * 1024),
            64 * 1024 * 1024
        );
    }

    #[test]
    fn threshold_scales_with_large_volume() {
        let ten_tb = 10_u64 * 1024 * 1024 * 1024 * 1024;
        assert_eq!(collapse_threshold_bytes(ten_tb), ten_tb / 1000);
    }

    #[test]
    fn occupied_space_uses_total_minus_free() {
        let stats = stats_from_block_counts(1_000, 400, 350, 512);
        assert_eq!(stats.total_bytes, 512_000);
        assert_eq!(stats.free_bytes, 204_800);
        assert_eq!(stats.available_bytes, 179_200);
        assert_eq!(stats.occupied_bytes, 307_200);
    }

    #[test]
    fn occupied_space_saturates_when_free_exceeds_total() {
        let stats = stats_from_block_counts(10, 50, 50, 1_024);
        assert_eq!(stats.total_bytes, 10_240);
        assert_eq!(stats.free_bytes, 10_240);
        assert_eq!(stats.available_bytes, 10_240);
        assert_eq!(stats.occupied_bytes, 0);
    }
}
