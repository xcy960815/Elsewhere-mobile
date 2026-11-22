//! Stable C boundary for the mobile app's developer-service client.
/// cbindgen:ignore
mod credentials;
mod ddi;
mod engine;
mod error;
mod location;
mod pairing;
mod protocol;
mod receipt;

use std::{ffi::c_void, panic::{AssertUnwindSafe, catch_unwind}, path::Path, ptr, slice, str};

use idevice::lockdown::LockdownClient;
use serde_json::json;

pub use engine::EwEngine;
pub use error::EwErrorCode;
use error::Failure;

/// Increases when a caller and a binary can no longer interoperate.
#[unsafe(no_mangle)]
pub extern "C" fn ew_abi_version() -> u32 {
    catch_unwind(|| 3).unwrap_or(0)
}

#[unsafe(no_mangle)]
pub extern "C" fn ew_lockdown_port() -> u16 {
    catch_unwind(|| LockdownClient::LOCKDOWND_PORT).unwrap_or(0)
}

/// The transport a target version requires. Availability on a particular
/// device still depends on its pairing session and advertised services.
#[repr(C)]
pub enum EwTransport {
    EwTransportUnsupported = 0,
    EwTransportRemotePairing = 1,
    EwTransportCoreDeviceProxy = 2,
}

#[unsafe(no_mangle)]
pub extern "C" fn ew_target_transport(major: u32, minor: u32) -> EwTransport {
    catch_unwind(|| match (major, minor) {
        (0..=16, _) => EwTransport::EwTransportUnsupported,
        (17, 0..=3) => EwTransport::EwTransportRemotePairing,
        _ => EwTransport::EwTransportCoreDeviceProxy,
    }).unwrap_or(EwTransport::EwTransportUnsupported)
}

#[unsafe(no_mangle)]
pub extern "C" fn ew_coordinate_is_valid(latitude: f64, longitude: f64) -> bool {
    catch_unwind(|| (-90.0..=90.0).contains(&latitude) && (-180.0..=180.0).contains(&longitude))
        .unwrap_or(false)
}

#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum EwCommand {
    EwCommandProbe = 0,
    EwCommandCheckDdi,
    EwCommandMountDdi,
    EwCommandSetLocation,
    EwCommandClearLocation,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EwEventKind {
    EwEventStage = 0,
    EwEventSuccess,
    EwEventFailure,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EwStage {
    EwStageConnecting = 0,
    EwStageDownloadingDdi,
    EwStageVerifyingDdi,
    EwStageSigningDdi,
    EwStageUploadingDdi,
    EwStageMountingDdi,
    EwStageApplyingLocation,
    EwStageClearingLocation,
}

/// Text slices use UTF-8. Zero length omits the optional UDID or DDI directory.
#[repr(C)]
pub struct EwRequest {
    pub command: EwCommand,
    pub endpoint_host_ptr: *const u8,
    pub endpoint_host_len: usize,
    pub ipv6_scope_id: u32,
    pub pairing_ptr: *const u8,
    pub pairing_len: usize,
    pub expected_udid_ptr: *const u8,
    pub expected_udid_len: usize,
    pub ddi_dir_ptr: *const u8,
    pub ddi_dir_len: usize,
    pub latitude: f64,
    pub longitude: f64,
    pub timeout_ms: u32,
}

#[repr(C)]
pub struct EwJobEvent {
    pub job_id: u64,
    pub kind: EwEventKind,
    pub stage: EwStage,
    pub error_code: EwErrorCode,
    pub outcome_unknown: bool,
    pub payload_ptr: *const u8,
    pub payload_len: usize,
}

/// Copy the UTF-8 JSON or failure text before returning.
pub type EwSyncCallback = extern "C" fn(code: EwErrorCode, payload_ptr: *const u8, payload_len: usize, context: *mut c_void);
/// The event and its payload are borrowed for this call. Keep context alive through the terminal event.
pub type EwJobCallback = extern "C" fn(event: *const EwJobEvent, context: *mut c_void);

unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], Failure> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() || len > isize::MAX.unsigned_abs() {
        return Err(Failure::input("Invalid byte range."));
    }
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}

unsafe fn utf8<'a>(ptr: *const u8, len: usize) -> Result<&'a str, Failure> {
    str::from_utf8(unsafe { bytes(ptr, len) }?).map_err(|_| Failure::input("Expected UTF-8 text."))
}

fn sync_reply(result: std::thread::Result<Result<String, Failure>>, callback: EwSyncCallback, context: *mut c_void) {
    match result.unwrap_or(Err(Failure::PANIC)) {
        Ok(json) => callback(EwErrorCode::EwErrorOk, json.as_ptr(), json.len(), context),
        Err(e) => callback(e.code, e.message.as_ptr(), e.message.len(), context),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ew_pairing_inspect(
    bytes_ptr: *const u8, len: usize, callback: EwSyncCallback, context: *mut c_void,
) {
    sync_reply(catch_unwind(|| {
        Ok(pairing::Record::parse(unsafe { bytes(bytes_ptr, len) }?)?.metadata().to_string())
    }), callback, context);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ew_ddi_verify(
    dir_ptr: *const u8, dir_len: usize, callback: EwSyncCallback, context: *mut c_void,
) {
    sync_reply(catch_unwind(|| {
        let dir = Path::new(unsafe { utf8(dir_ptr, dir_len) }?);
        let ddi = ddi::verify_ddi_dir(dir, || false)?;
        Ok(json!({ "valid": true, "digestHex": format!("{:x}", ddi.digest) }).to_string())
    }), callback, context);
}

#[unsafe(no_mangle)]
pub extern "C" fn ew_engine_create() -> *mut EwEngine {
    catch_unwind(|| EwEngine::new().map_or(ptr::null_mut(), |e| Box::into_raw(Box::new(e))))
        .unwrap_or(ptr::null_mut())
}

/// The owner destroys the handle after other ABI calls return, outside its own callbacks.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ew_engine_destroy(engine: *mut EwEngine) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !engine.is_null() {
            unsafe { Box::from_raw(engine) }.shutdown();
        }
    }));
}

/// On acceptance the worker owns its request copy and delivers one terminal event, including on cancellation.
/// A false return leaves ownership of the callback context entirely with the caller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ew_submit(
    engine: *mut EwEngine, job_id: u64, request: *const EwRequest, callback: EwJobCallback, context: *mut c_void,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(engine), Some(request)) = (unsafe { engine.as_ref() }, unsafe { request.as_ref() }) else {
            return false;
        };
        let Ok(input) = (unsafe { protocol::Request::copy(request) }) else { return false };
        engine.submit(job_id, input, callback, context)
    })).unwrap_or(false)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ew_cancel(engine: *mut EwEngine, job_id: u64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(engine) = unsafe { engine.as_ref() } {
            engine.cancel(job_id);
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) fn sync_result(call: impl FnOnce(EwSyncCallback, *mut c_void)) -> (EwErrorCode, String) {
        extern "C" fn copy(code: EwErrorCode, data: *const u8, len: usize, ctx: *mut c_void) {
            let result = unsafe { &mut *ctx.cast::<Option<(EwErrorCode, Vec<u8>)>>() };
            *result = Some((code, unsafe { slice::from_raw_parts(data, len) }.to_vec()));
        }
        let mut result: Option<(EwErrorCode, Vec<u8>)> = None;
        call(copy, ptr::from_mut(&mut result).cast());
        let (code, bytes) = result.unwrap();
        (code, String::from_utf8(bytes).unwrap())
    }

    #[test]
    fn advertises_the_expected_abi_and_lockdown_port() {
        assert_eq!(ew_abi_version(), 3);
        assert_eq!(ew_lockdown_port(), 62078);
    }

    #[test]
    fn accepts_both_closed_coordinate_ranges() {
        for (lat, lon) in [(-90., -180.), (90., 180.), (0., 0.), (-12.3, 4.5)] {
            assert!(ew_coordinate_is_valid(lat, lon));
        }
    }

    #[test]
    fn rejects_nan_infinity_and_out_of_range_coordinates() {
        for (lat, lon) in [(91., 0.), (0., -180.0001), (f64::INFINITY, 0.),
                            (0., f64::NEG_INFINITY), (f64::NAN, 0.), (0., f64::NAN)] {
            assert!(!ew_coordinate_is_valid(lat, lon));
        }
    }

    #[test]
    fn distinguishes_early_17_from_core_device_proxy_candidates() {
        use EwTransport::*;
        assert!(matches!(ew_target_transport(16, 9), EwTransportUnsupported));
        assert!(matches!(ew_target_transport(17, 0), EwTransportRemotePairing));
        assert!(matches!(ew_target_transport(17, 3), EwTransportRemotePairing));
        assert!(matches!(ew_target_transport(17, 4), EwTransportCoreDeviceProxy));
        assert!(matches!(ew_target_transport(18, 0), EwTransportCoreDeviceProxy));
    }
}
