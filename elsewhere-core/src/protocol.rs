use std::{
    ffi::{CString, c_char},
    net::IpAddr,
    path::PathBuf,
    time::Duration,
};

use idevice::{IdeviceService, lockdown::LockdownClient, provider::TcpProvider};
use plist::{Dictionary, Value};
use serde_json::json;
use tokio::time::{Instant, timeout};

use crate::{
    EwCommand::{self, *}, EwErrorCode::*, EwRequest, EwStage::*, bytes, ddi,
    engine::Job, error::Failure, ew_coordinate_is_valid, location, pairing::Record, utf8,
};

pub(crate) struct Request {
    command: EwCommand,
    host: String,
    scope_id: u32,
    pairing: Vec<u8>,
    expected: Option<String>,
    ddi_dir: Option<PathBuf>,
    latitude: f64,
    longitude: f64,
    pub deadline: Instant,
}

fn endpoint(host: &str, scope_id: u32) -> Result<(IpAddr, Option<u32>), Failure> {
    unsafe extern "C" {
        fn if_nametoindex(name: *const c_char) -> u32;
    }
    let invalid = Failure::input("Expected an IP address with a valid, unambiguous IPv6 scope.");
    let host = if let Some(rest) = host.strip_prefix('[') {
        rest.strip_suffix(']').filter(|s| s.contains(':')).ok_or(invalid)?
    } else { host };
    let (address, zone) = host.split_once('%').map_or((host, None), |(ip, zone)| (ip, Some(zone)));
    let ip: IpAddr = address.parse().map_err(|_| invalid)?;
    let explicit = (scope_id != 0).then_some(scope_id);
    let Some(zone) = zone else {
        return if ip.is_ipv4() && explicit.is_some() { Err(invalid) } else { Ok((ip, explicit)) };
    };
    if !ip.is_ipv6() || zone.is_empty() {
        return Err(invalid);
    }
    let index = if zone.bytes().all(|b| b.is_ascii_digit()) {
        zone.parse().map_err(|_| invalid)?
    } else {
        let name = CString::new(zone).map_err(|_| invalid)?;
        unsafe { if_nametoindex(name.as_ptr()) }
    };
    if index == 0 || explicit.is_some_and(|e| e != index) {
        return Err(invalid);
    }
    Ok((ip, Some(index)))
}

pub(crate) fn identity<'a>(actual: Option<&'a str>, expected: Option<&str>) -> Result<&'a str, Failure> {
    let actual = actual.filter(|s| !s.is_empty());
    if expected.is_some() && expected != actual {
        return Err(Failure { code: EwErrorNotPaired, message: "The authenticated device does not match the expected UDID." });
    }
    actual.ok_or(Failure { code: EwErrorFailed, message: "Lockdown did not return UniqueDeviceID." })
}

impl Request {
    pub unsafe fn copy(raw: &EwRequest) -> Result<Self, Failure> {
        let expected = unsafe { utf8(raw.expected_udid_ptr, raw.expected_udid_len) }?;
        let dir = unsafe { utf8(raw.ddi_dir_ptr, raw.ddi_dir_len) }?;
        let timeout = match (raw.timeout_ms, raw.command) {
            (0, EwCommandSetLocation | EwCommandMountDdi) => Duration::from_secs(180),
            (0, _) => Duration::from_secs(15),
            (ms, _) => Duration::from_millis(u64::from(ms)),
        };
        Ok(Self {
            command: raw.command, host: unsafe { utf8(raw.endpoint_host_ptr, raw.endpoint_host_len) }?.to_owned(),
            scope_id: raw.ipv6_scope_id, pairing: unsafe { bytes(raw.pairing_ptr, raw.pairing_len) }?.to_vec(),
            expected: (!expected.is_empty()).then(|| expected.to_owned()), ddi_dir: (!dir.is_empty()).then(|| dir.into()),
            latitude: raw.latitude, longitude: raw.longitude, deadline: Instant::now() + timeout,
        })
    }

    async fn mount_status(&self, provider: &TcpProvider, job: &Job) -> Result<bool, Failure> {
        job.stage(EwStageConnecting)?;
        ddi::mounted(provider, self.expected.as_deref()).await
    }

    async fn probe(&self, provider: &TcpProvider, job: &Job) -> Result<serde_json::Value, Failure> {
        job.stage(EwStageConnecting)?;
        let mut lockdown = LockdownClient::connect(provider).await?;
        let mut pretrust = Dictionary::new();
        for key in ["ProductType", "DeviceClass", "ProductVersion"] {
            if let Ok(value) = lockdown.get_value(Some(key), None).await {
                pretrust.insert(key.into(), value);
            }
        }
        lockdown.start_session(&provider.pairing_file).await?;
        let all = lockdown.get_value(None, None).await?.into_dictionary().ok_or(Failure {
            code: EwErrorFailed, message: "Lockdown returned invalid device properties.",
        })?;
        let text = |key: &str| all.get(key).or_else(|| pretrust.get(key)).and_then(Value::as_string);
        let udid = identity(text("UniqueDeviceID"), self.expected.as_deref())?;
        let developer = lockdown.get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi")).await
            .ok().and_then(|v| v.as_boolean());
        let wifi = lockdown.get_value(Some("EnableWifiConnections"), Some("com.apple.mobile.wireless_lockdown")).await
            .ok().and_then(|v| v.as_boolean());
        // An unresponsive optional service must still leave time to return authenticated device properties.
        let budget = self.deadline.saturating_duration_since(Instant::now()) / 2;
        let mounted = match timeout(budget, ddi::mounted(provider, self.expected.as_deref())).await {
            Ok(Ok(mounted)) => Some(mounted),
            Ok(Err(e)) if e.code == EwErrorNotPaired => return Err(e),
            _ => None,
        };
        Ok(json!({
            "udid": udid, "name": text("DeviceName"), "deviceClass": text("DeviceClass"),
            "productType": text("ProductType"), "osVersion": text("ProductVersion"), "paired": true,
            "developerMode": developer, "wifi": wifi, "timeZone": text("TimeZone"),
            "cellular": all.get("TelephonyCapability").and_then(Value::as_boolean), "ddiMounted": mounted,
        }))
    }

    pub async fn run(mut self, job: &Job) -> Result<serde_json::Value, Failure> {
        if self.command == EwCommandSetLocation && !ew_coordinate_is_valid(self.latitude, self.longitude) {
            return Err(Failure::input("Latitude or longitude is outside the WGS-84 coordinate range."));
        }
        let (addr, scope_id) = endpoint(&self.host, self.scope_id)?;
        let pairing = std::mem::take(&mut self.pairing);
        let record = tokio::task::spawn_blocking(move || Record::parse(&pairing)).await.map_err(|_| Failure::PANIC)??;
        let Record::Lockdown(pairing_file) = record else {
            return Err(Failure { code: EwErrorNotPaired, message: "A Lockdown pairing record is required for this transport." });
        };
        let provider = TcpProvider { addr, scope_id, pairing_file, label: "Elsewhere".into() };
        match self.command {
            EwCommandProbe => self.probe(&provider, job).await,
            EwCommandCheckDdi => Ok(json!({ "mounted": self.mount_status(&provider, job).await? })),
            EwCommandMountDdi => {
                let ddi = ddi::verify(self.ddi_dir.as_deref(), job).await?;
                if !self.mount_status(&provider, job).await? {
                    ddi::mount(&provider, ddi, self.expected.as_deref(), job, Some(&job.awaiting_receipt)).await?;
                }
                Ok(json!({ "mounted": true }))
            }
            EwCommandSetLocation => {
                let mounted_now = !self.mount_status(&provider, job).await?;
                if mounted_now {
                    let ddi = ddi::verify(self.ddi_dir.as_deref(), job).await?;
                    ddi::mount(&provider, ddi, self.expected.as_deref(), job, None).await?;
                }
                job.stage(EwStageApplyingLocation)?;
                let mut input = Dictionary::new();
                input.insert("latitude".into(), self.latitude.into());
                input.insert("longitude".into(), self.longitude.into());
                location::invoke(&provider, "com.apple.coredevice.action.setsimulatedlocation", input, self.expected.as_deref(), job).await?;
                Ok(json!({ "mountedDeveloperDiskImage": mounted_now }))
            }
            EwCommandClearLocation => {
                let mounted = self.mount_status(&provider, job).await?;
                if mounted {
                    job.stage(EwStageClearingLocation)?;
                    location::invoke(&provider, "com.apple.coredevice.action.clearsimulatedlocation", Dictionary::new(), self.expected.as_deref(), job).await?;
                }
                Ok(json!({ "cleared": mounted }))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_ip_literals_and_rejects_ambiguous_scopes() {
        for (host, scope, ip, index) in [("127.0.0.1", 0, "127.0.0.1", None), ("::1", 0, "::1", None),
            ("fe80::1", 4, "fe80::1", Some(4)), ("fe80::1%4", 4, "fe80::1", Some(4)),
            ("[fe80::1%4]", 0, "fe80::1", Some(4))] {
            assert_eq!(endpoint(host, scope).unwrap(), (ip.parse().unwrap(), index));
        }
        assert!(endpoint("fe80::1%lo0", 0).unwrap().1.is_some());
        for (host, scope) in [("", 0), ("localhost", 0), ("1.2.3.4:62078", 0), ("::1%", 0), ("::1%0", 0),
            ("127.0.0.1%4", 0), ("127.0.0.1", 4), ("fe80::1%4", 5), ("::1%no-such-interface", 0)] {
            assert_eq!(endpoint(host, scope).unwrap_err().code, EwErrorInvalidInput);
        }
    }

    #[test]
    fn requires_authenticated_identity_before_acting_on_a_bound_endpoint() {
        assert_eq!(identity(Some("phone"), Some("phone")).unwrap(), "phone");
        assert_eq!(identity(Some("pad"), Some("phone")).unwrap_err().code, EwErrorNotPaired);
        assert_eq!(identity(None, Some("phone")).unwrap_err().code, EwErrorNotPaired);
        assert_eq!(identity(None, None).unwrap_err().code, EwErrorFailed);
    }
}
