use std::{
    borrow::Cow,
    fs::File,
    io::{BufReader, Read, Seek},
    path::Path,
    sync::{Arc, atomic::{AtomicBool, Ordering}},
    time::Duration,
};

use idevice::{Idevice, IdeviceError, IdeviceService, ReadWrite, lockdown::LockdownClient, mobile_image_mounter::ImageMounter, provider::TcpProvider};
use plist::{Dictionary, Value};
use sha2::{Digest, Sha384, digest::Output};
use tokio::sync::oneshot;

use crate::{EwErrorCode::*, EwStage::*, engine::Job, error::Failure, protocol::identity, receipt::ReceiptStream};

pub(crate) struct VerifiedDdi {
    manifest: Dictionary,
    pub digest: Output<Sha384>,
    image: File,
    trust_cache: File,
}

pub(crate) fn verify_ddi_dir(dir: &Path, cancelled: impl Fn() -> bool) -> Result<VerifiedDdi, Failure> {
    if dir.as_os_str().is_empty() {
        return Err(Failure::ddi("A developer disk image directory is required."));
    }
    let open = |name, reason| {
        let path = dir.join(name);
        if !path.metadata().is_ok_and(|m| m.is_file() && m.len() != 0) {
            return Err(Failure::ddi(reason));
        }
        File::open(path).map_err(|_| Failure::ddi(reason))
    };
    let manifest = open("BuildManifest.plist", "BuildManifest.plist is missing, empty or unreadable.")?;
    let manifest: Dictionary = plist::from_reader(BufReader::new(manifest))
        .map_err(|_| Failure::ddi("BuildManifest.plist is not a valid manifest dictionary."))?;
    let mut image = open("Image.dmg", "Image.dmg is missing, empty or unreadable.")?;
    let trust_cache = open("Image.dmg.trustcache", "Image.dmg.trustcache is missing, empty or unreadable.")?;
    let mut hash = Sha384::new();
    let mut chunk = [0; 64 * 1024];
    loop {
        if cancelled() {
            return Err(Failure::CANCELLED);
        }
        let n = image.read(&mut chunk).map_err(|_| Failure::ddi("Cannot read Image.dmg."))?;
        if n == 0 {
            break;
        }
        hash.update(&chunk[..n]);
    }
    let digest = hash.finalize();
    let matches = manifest.get("BuildIdentities").and_then(Value::as_array).into_iter().flatten()
        .filter_map(|id| id.as_dictionary()?.get("Manifest")?.as_dictionary()?
            .get("PersonalizedDMG")?.as_dictionary()?.get("Digest")?.as_data())
        .any(|expected| expected == &digest[..]);
    if !matches {
        return Err(Failure::ddi("Image.dmg SHA-384 does not match any PersonalizedDMG digest in BuildManifest.plist."));
    }
    image.rewind().map_err(|_| Failure::ddi("Cannot rewind Image.dmg."))?;
    Ok(VerifiedDdi { manifest, digest, image, trust_cache })
}

pub(crate) async fn verify(dir: Option<&Path>, job: &Job) -> Result<VerifiedDdi, Failure> {
    let dir = dir.ok_or(Failure::ddi("A developer disk image directory is required."))?.to_owned();
    job.stage(EwStageVerifyingDdi)?;
    let (tx, rx) = oneshot::channel();
    tokio::task::spawn_blocking(move || {
        let result = verify_ddi_dir(&dir, || tx.is_closed());
        let _ = tx.send(result);
    });
    rx.await.map_err(|_| Failure::PANIC)?
}

fn developer_image(entries: &[Value]) -> Option<bool> {
    let mut known = Some(false);
    for value in entries {
        let Some(entry) = value.as_dictionary() else { known = None; continue };
        if entry.get("IsMounted").and_then(Value::as_boolean) == Some(false) {
            continue;
        }
        let kind = ["PersonalizedImageType", "DiskImageType", "ImageType"].iter()
            .find_map(|k| entry.get(*k).and_then(Value::as_string));
        let path = entry.get("MountPath").and_then(Value::as_string);
        if matches!(kind, Some("Personalized" | "Developer" | "DeveloperDiskImage")) ||
            matches!(path, Some("/Developer" | "/System/Developer")) {
            return Some(true);
        }
        if kind.is_none() && path.is_none() {
            known = None;
        }
    }
    known
}

pub(crate) async fn mounted(provider: &TcpProvider, expected: Option<&str>) -> Result<bool, Failure> {
    let stream = MounterSocket::checked(provider, expected).await?;
    let mut mounter = ImageMounter::new(Idevice::new(stream, &provider.label));
    if let Some(mounted) = developer_image(&mounter.copy_devices().await?) {
        return Ok(mounted);
    }
    for kind in ["Personalized", "Developer"] {
        match mounter.lookup_image(kind).await {
            Ok(_) => return Ok(true),
            Err(IdeviceError::NotFound | IdeviceError::ImageNotMounted) => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(false)
}

// The authenticated service socket carries the UDID read by IdeviceService on this connection.
struct MounterSocket {
    stream: Box<dyn ReadWrite>,
    udid: Option<String>,
}

impl IdeviceService for MounterSocket {
    fn service_name() -> Cow<'static, str> {
        ImageMounter::service_name()
    }

    async fn from_stream(device: Idevice) -> Result<Self, IdeviceError> {
        let udid = device.udid().map(str::to_owned);
        Ok(Self { stream: device.get_socket().ok_or(IdeviceError::NoEstablishedConnection)?, udid })
    }
}

impl MounterSocket {
    async fn checked(provider: &TcpProvider, expected: Option<&str>) -> Result<Box<dyn ReadWrite>, Failure> {
        let socket = Self::connect(provider).await?;
        if expected.is_some() {
            identity(socket.udid.as_deref(), expected)?;
        }
        Ok(socket.stream)
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Recovery { Mounted, Retry }

fn recovery(error: IdeviceError, status: Result<bool, Failure>, retried: bool) -> Result<Recovery, Failure> {
    if matches!(status, Ok(true)) {
        return Ok(Recovery::Mounted);
    }
    let retry = !retried && matches!(error, IdeviceError::Socket(_));
    let failure = Failure::mount(error, "The target could not upload or mount the developer image.");
    if matches!(failure.code, EwErrorLocked | EwErrorNotPaired) {
        return Err(failure);
    }
    if let Err(check) = status {
        if matches!(check.code, EwErrorLocked | EwErrorNotPaired) {
            return Err(check);
        }
        if !retry {
            return Err(Failure { code: EwErrorDdiMount, message: "Could not confirm whether the developer image was mounted." });
        }
    }
    if retry { Ok(Recovery::Retry) } else { Err(failure) }
}

fn mount_stream(socket: Box<dyn ReadWrite>, pending: Option<&Arc<AtomicBool>>) -> Box<dyn ReadWrite> {
    match pending {
        Some(pending) => Box::new(ReceiptStream::any_write(socket, pending)),
        None => socket,
    }
}

pub(crate) async fn mount(
    provider: &TcpProvider, ddi: VerifiedDdi, expected: Option<&str>, job: &Job, pending: Option<&Arc<AtomicBool>>,
) -> Result<(), Failure> {
    let clear_receipt = || {
        if let Some(pending) = pending {
            pending.store(false, Ordering::Relaxed);
        }
    };
    let mut lockdown = LockdownClient::connect(provider).await?;
    lockdown.start_session(&provider.pairing_file).await?;
    let chip_id = lockdown.get_value(Some("UniqueChipID"), None).await?.as_unsigned_integer()
        .ok_or(Failure { code: EwErrorDdiMount, message: "Lockdown did not return UniqueChipID." })?;
    drop(lockdown);
    let cached = match ImageMounter::connect(provider).await?
        .query_personalization_manifest("DeveloperDiskImage", ddi.digest.to_vec()).await {
        Ok(ticket) if !ticket.is_empty() => Some(ticket),
        Ok(_) | Err(IdeviceError::NotFound | IdeviceError::ImageNotMounted) => None,
        // Some releases close this connection or return a device-specific error on a cache miss.
        Err(IdeviceError::Socket(e)) if matches!(e.kind(), std::io::ErrorKind::UnexpectedEof |
            std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted | std::io::ErrorKind::BrokenPipe) => None,
        Err(e @ (IdeviceError::InternalError(_) | IdeviceError::UnknownErrorType(_))) => {
            let failure = Failure::from(e);
            if failure.code != EwErrorFailed { return Err(failure) }
            None
        }
        Err(e) => return Err(e.into()),
    };
    let signature = match cached {
        Some(ticket) => ticket,
        None => {
            job.stage(EwStageSigningDdi)?;
            ImageMounter::connect(provider).await?.get_manifest_from_tss(&ddi.manifest, chip_id).await
                .map_err(|e| Failure::mount(e, "Apple TSS did not supply a personalization ticket."))?
        }
    };
    // upload_image borrows a contiguous slice. Keep the verified inode open until that single allocation.
    let mut image = Vec::new();
    let mut trust_cache = Vec::new();
    use tokio::io::AsyncReadExt;
    tokio::fs::File::from_std(ddi.image).read_to_end(&mut image).await
        .map_err(|_| Failure::ddi("Cannot read Image.dmg for upload."))?;
    let mut hash = Sha384::new();
    for chunk in image.chunks(1024 * 1024) {
        hash.update(chunk);
        tokio::task::yield_now().await;
    }
    if hash.finalize() != ddi.digest {
        return Err(Failure::ddi("Image.dmg changed after verification."));
    }
    tokio::fs::File::from_std(ddi.trust_cache).read_to_end(&mut trust_cache).await
        .map_err(|_| Failure::ddi("Cannot read Image.dmg.trustcache for mounting."))?;

    let mut retried = false;
    loop {
        let socket = MounterSocket::checked(provider, expected).await?;
        let mut mounter = ImageMounter::new(Idevice::new(mount_stream(socket, pending), &provider.label));
        job.stage(EwStageUploadingDdi)?;
        let result = match mounter.upload_image("Personalized", &image, signature.clone()).await {
            Ok(()) => {
                clear_receipt();
                job.stage(EwStageMountingDdi)?;
                mounter.mount_image("Personalized", signature.clone(), Some(trust_cache.clone()), None).await
            }
            Err(e) => Err(e),
        };
        drop(mounter);
        let error = match result {
            Ok(()) => {
                clear_receipt();
                return Ok(());
            }
            Err(e) => e,
        };
        if matches!(error, IdeviceError::DeviceLocked | IdeviceError::InvalidHostID | IdeviceError::InternalError(_) |
            IdeviceError::UnknownErrorType(_) | IdeviceError::DeveloperModeNotEnabled | IdeviceError::CanceledByUser) {
            clear_receipt();
        }
        let status = mounted(provider, expected).await;
        if status.is_ok() {
            clear_receipt();
        }
        if recovery(error, status, retried)? == Recovery::Mounted {
            return Ok(());
        }
        retried = true;
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::PathBuf, time::{SystemTime, UNIX_EPOCH}};
    use crate::{ew_ddi_verify, tests::sync_result};

    #[test]
    fn lost_mount_reply_only_marks_a_tracked_receipt() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt, duplex};

        tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(async {
            for tracked in [false, true] {
                let awaiting_receipt = Arc::new(AtomicBool::new(false));
                let (socket, peer) = duplex(64);
                let mut stream = mount_stream(Box::new(socket), tracked.then_some(&awaiting_receipt));
                stream.write_all(b"mount").await.unwrap();
                stream.flush().await.unwrap();
                drop(peer);
                assert_eq!(stream.read_u8().await.unwrap_err().kind(), std::io::ErrorKind::UnexpectedEof);
                assert_eq!(awaiting_receipt.load(Ordering::Relaxed), tracked);
            }
        });
    }

    #[test]
    fn verifies_the_entire_image_and_reports_missing_or_damaged_components() {
        struct Directory(PathBuf);
        impl Drop for Directory {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir().join(format!("elsewhere-ddi-{}-{nonce}", std::process::id()));
        fs::create_dir(&path).unwrap();
        let dir = Directory(path);
        let manifest = dir.0.join("BuildManifest.plist");
        let image = dir.0.join("Image.dmg");
        let trust = dir.0.join("Image.dmg.trustcache");
        fs::write(&manifest, b"<plist version=\"1.0\"><dict><key>BuildIdentities</key><array><dict/><dict>
            <key>Manifest</key><dict><key>PersonalizedDMG</key><dict><key>Digest</key>
            <data>2m/H5ngxlYGanils4mF/ccIPo1Nunvxr+gLESnSkxjdWMHKUN4jRQAhIzMvk3zHx</data>
            </dict></dict></dict></array></dict></plist>").unwrap();
        let mut data = vec![b'x'; 131_075];
        fs::write(&image, &data).unwrap();
        fs::write(&trust, b"trust cache").unwrap();
        let verify = || {
            let dir = dir.0.to_str().unwrap();
            sync_result(|callback, ctx| unsafe { ew_ddi_verify(dir.as_ptr(), dir.len(), callback, ctx) })
        };
        let (code, body) = verify();
        assert_eq!(code, EwErrorOk);
        assert_eq!(serde_json::from_str::<serde_json::Value>(&body).unwrap(), serde_json::json!({
            "valid": true, "digestHex": "da6fc7e6783195819a9e296ce2617f71c20fa3536e9efc6bfa02c44a74a4c637563072943788d1400848cccbe4df31f1",
        }));
        for file in [&image, &trust, &manifest] {
            let saved = dir.0.join("held");
            fs::rename(file, &saved).unwrap();
            let (code, message) = verify();
            assert_eq!(code, EwErrorDdiMissing);
            assert!(message.contains(file.file_name().unwrap().to_str().unwrap()));
            fs::rename(saved, file).unwrap();
        }
        *data.last_mut().unwrap() = b'y';
        fs::write(image, data).unwrap();
        let (code, reason) = verify();
        assert_eq!(code, EwErrorDdiMissing);
        assert!(reason.contains("SHA-384"));
        fs::write(manifest, b"broken manifest").unwrap();
        let (code, reason) = verify();
        assert_eq!(code, EwErrorDdiMissing);
        assert!(reason.contains("BuildManifest.plist"));
    }

    #[test]
    fn identifies_only_mounted_developer_images() {
        let entry = |key: &str, text: &str| {
            let mut d = Dictionary::new();
            d.insert(key.into(), text.into());
            Value::Dictionary(d)
        };
        let other = entry("DiskImageType", "Diagnostics");
        assert_eq!(developer_image(&[]), Some(false));
        assert_eq!(developer_image(std::slice::from_ref(&other)), Some(false));
        assert_eq!(developer_image(&[Value::Dictionary(Dictionary::new())]), None);
        for (key, text) in [("DiskImageType", "Personalized"), ("ImageType", "Developer"),
                            ("PersonalizedImageType", "DeveloperDiskImage"), ("MountPath", "/System/Developer")] {
            let mut developer = entry(key, text);
            assert_eq!(developer_image(&[other.clone(), developer.clone()]), Some(true));
            developer.as_dictionary_mut().unwrap().insert("IsMounted".into(), false.into());
            assert_eq!(developer_image(&[developer]), Some(false));
        }
    }

    #[test]
    fn resolves_a_lost_mount_reply_and_limits_socket_retries() {
        use IdeviceError::*;
        let lost = || Socket(std::io::ErrorKind::UnexpectedEof.into());
        assert_eq!(recovery(lost(), Ok(true), false).unwrap(), Recovery::Mounted);
        assert_eq!(recovery(lost(), Ok(false), false).unwrap(), Recovery::Retry);
        assert_eq!(recovery(lost(), Err(lost().into()), false).unwrap(), Recovery::Retry);
        assert_eq!(recovery(lost(), Ok(false), true).unwrap_err().code, EwErrorDdiMount);
        assert_eq!(recovery(lost(), Err(DeviceLocked.into()), false).unwrap_err().code, EwErrorLocked);
        assert_eq!(recovery(InvalidHostID, Err(lost().into()), false).unwrap_err().code, EwErrorNotPaired);
        assert_eq!(recovery(BadBuildManifest, Ok(false), false).unwrap_err().code, EwErrorDdiMount);
    }
}
