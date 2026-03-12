use std::io;
use std::path::Path;

const MIN_COLLAPSE_THRESHOLD_BYTES: u64 = 64 * 1024 * 1024;

pub fn collapse_threshold_bytes(volume_size_bytes: u64) -> u64 {
    let percent_threshold = volume_size_bytes / 1000;
    percent_threshold.max(MIN_COLLAPSE_THRESHOLD_BYTES)
}

#[cfg(target_os = "macos")]
pub fn volume_size_bytes(path: &Path) -> io::Result<u64> {
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
    let blocks = stat.f_blocks as u64;
    let block_size = stat.f_bsize as u64;
    Ok(blocks.saturating_mul(block_size))
}

#[cfg(all(unix, not(target_os = "macos")))]
pub fn volume_size_bytes(path: &Path) -> io::Result<u64> {
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
    let blocks = stat.f_blocks as u64;
    let block_size = stat.f_frsize as u64;
    Ok(blocks.saturating_mul(block_size))
}

#[cfg(not(unix))]
pub fn volume_size_bytes(_path: &Path) -> io::Result<u64> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "volume size lookup is not implemented on this platform",
    ))
}

#[cfg(test)]
mod tests {
    use super::collapse_threshold_bytes;

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
}
