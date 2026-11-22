use idevice::pairing_file::PairingFile;
use serde_json::{Value, json};

use crate::{credentials, error::Failure};

pub(crate) enum Record {
    Lockdown(PairingFile),
    Remote,
}

impl Record {
    pub fn parse(bytes: &[u8]) -> Result<Self, Failure> {
        let dict: plist::Dictionary = plist::from_bytes(bytes)
            .map_err(|_| Failure::input("Pairing data is not a plist dictionary."))?;
        if dict.contains_key("public_key") && dict.contains_key("private_key") {
            if dict.get("identifier").and_then(plist::Value::as_string).is_some() &&
                ["private_key", "public_key"].iter().all(|k| dict.get(*k).and_then(plist::Value::as_data).is_some_and(|key| key.len() == 32)) {
                return Ok(Self::Remote);
            }
            return Err(Failure::input("Malformed RemotePairing record."));
        }
        drop(dict);
        let mut pair = PairingFile::from_bytes(bytes)
            .map_err(|_| Failure::input("The Lockdown record is missing required fields or has invalid credentials."))?;
        for value in [Some(&pair.host_id), Some(&pair.system_buid), Some(&pair.wifi_mac_address), pair.udid.as_ref()]
            .into_iter().flatten()
        {
            if value.contains("-----BEGIN") || value.chars().any(char::is_control) ||
                pair.escrow_bag.as_deref().is_some_and(|bag| !bag.is_empty() && value.as_bytes().windows(bag.len()).any(|w| w == bag))
            {
                return Err(Failure::input("The pairing record contains invalid display metadata."));
            }
        }
        if pair.host_id.is_empty() || pair.system_buid.is_empty() {
            return Err(Failure::input("The pairing record requires HostID and SystemBUID."));
        }
        credentials::validate(&mut pair).ok_or(Failure::input("Invalid or unsupported Lockdown certificate or private key."))?;
        Ok(Self::Lockdown(pair))
    }

    pub fn metadata(&self) -> Value {
        match self {
            Self::Remote => json!({ "format": "remote_pairing" }),
            Self::Lockdown(p) => json!({
                "format": "lockdown", "udid": p.udid, "hostId": p.host_id, "systemBuid": p.system_buid,
                "wifiMacAddress": p.wifi_mac_address, "hasEscrowBag": p.escrow_bag.is_some(),
            }),
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{EwErrorCode::{self, *}, ew_pairing_inspect, tests::sync_result};
    use plist::Dictionary;

    const RSA_CERT: &[u8] = b"-----BEGIN CERTIFICATE-----
MIICxDCCAawCCQCV6sAttdkD1DANBgkqhkiG9w0BAQsFADAkMSIwIAYDVQQDDBlF
bHNld2hlcmUgT2ZmbGluZSBGaXh0dXJlMB4XDTI2MTEyMjA0MzMzMFoXDTM2MTEx
OTA0MzMzMFowJDEiMCAGA1UEAwwZRWxzZXdoZXJlIE9mZmxpbmUgRml4dHVyZTCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKkZcmsl9mZwr4T3Rg3WaSlm
79CG/X71CF/ekH0JRYulW6//QoASY/zvwZbPT7YXqC+oH96NGS/30hvTfAxgw/pq
wprYMK/RUim83qVXxOa+il5PNuRWtrfVuwDfkQVdaYwstwvGyQo5OrGoP99tFhtZ
m4z+lrlJMBi0tN8culcjq+XxGczrWDAhcqEznTiUGPa1lw5QZTMF6r6SllgUcGc8
fu+X+QHlCAipnS2G0KDT13WwKbMkWXMy/e3voQ5QzK4PGWwYa82cT125u+wA5qyp
EUD6yfU5LZmXG+DPGwtyg1PA4I+vEksrn4FRiyp+Le+22MyEp1iemHf2bhgEW10C
AwEAATANBgkqhkiG9w0BAQsFAAOCAQEAo+/b2qRlhaMz+hbedxt4uH834vHAW75v
arIS0SwT6MySBth8NbTgGqers0c8kmEdxr+TMtBdJ439c6GWR0TwXaGXz4ftZBma
m5R7IFUOeYhmyoR0thZYR2cRv4akNv8te3/ivgnHNw7moHAz9jKAHx43OXkv3YGK
tc6gbBrN0SCH1t5+fxQJU8FZycNFmNcQ7r8jlAr9DTdq34T7IzKvbODGHZeWmNa6
1dQVreWL32UTZ1GBhEDTTa+B8QJfCOnMix3Vkpqt0uT/OzqLB8GECwxqx83Tg6Cj
7xD0cWuZb9eVa838wuW9iukM2dx9nCzSmkne5VJ8WIuE6MmZbNOjRw==
-----END CERTIFICATE-----
";
    const RSA_KEY: &[u8] = b"-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQCpGXJrJfZmcK+E
90YN1mkpZu/Qhv1+9Qhf3pB9CUWLpVuv/0KAEmP878GWz0+2F6gvqB/ejRkv99Ib
03wMYMP6asKa2DCv0VIpvN6lV8TmvopeTzbkVra31bsA35EFXWmMLLcLxskKOTqx
qD/fbRYbWZuM/pa5STAYtLTfHLpXI6vl8RnM61gwIXKhM504lBj2tZcOUGUzBeq+
kpZYFHBnPH7vl/kB5QgIqZ0thtCg09d1sCmzJFlzMv3t76EOUMyuDxlsGGvNnE9d
ubvsAOasqRFA+sn1OS2ZlxvgzxsLcoNTwOCPrxJLK5+BUYsqfi3vttjMhKdYnph3
9m4YBFtdAgMBAAECggEANO7dTUM17X1KxEGvcTdz9dzeJxWKlspXU8NU0X8sgPlD
SUWLaJHZMN1QaUf9+M9Q+5ISX9UlVEmsQL+j7jAASQxQXK5eFztcD+qqe3GNFnoA
0GLVmQa37bX+8tgJCnfiSVnZ9trEJeoiQGidjfAU4nzbX3h2cAvD/YfbspfIkOv8
JFG2TILTaDF6+Eu5MuSMcCZJqrp2DHYqy9JsL1g+okIyDH/42Trsx7QoJjKyZITZ
cIIrM9ZOxeWY35nX1GFax4tpzQ/xGrLB1A3Gnjno2Ao9gtG88QWbpC7ML9eBWB45
s/G8LH5yDvsJqM7/pZzFp6vEuqgZIw/BuOWYW5F61QKBgQDd7AzJ3NPWKaxkEo+6
Z/HE6YdIjSMWV6d3j9pMCG+evRky8I5jVlriQ1JHL3Rrbuu91C0T1IZapJw3mlHy
IvK4y/24ZQx4x05Z06ROoa/aLz5JHS4vXAb7orb3CZ1t/FPQpZnDsKjZ+AmQbHm7
+cCPHzy+QYkJKFt4W7vKjmp3SwKBgQDDEORRKHGnpe+lM9ljbMudurZ2uSE4DzCv
+o5paS6r0q7niMOpi8v1vr2gHIJfHXndMTV4wCNMIoDgpETnlRAL6RQYVVQftxqn
Gc43GGuXDcHDhaEBo0jSvgE4Yv8Y/eebWwOvMXnEAXV7vDLir9sRE3g9RznQcCq1
FcLaVE6G9wKBgQDNVvz+SzY3k5fPgN08vbEXYn2qw+0TX0e1eYWjlKqzVoVafPtD
L0Qo1+HpvB8cySWYIBsVnjAy7t0dFc19Hpk4JIg/dkB0APaeZxZBK5praAtZ24ZA
jAZqD8T8EAl7G17yUEhWqb+S787ps3VwWUezJlQuNrV1o8H/O+InKl+YwQKBgQCl
1yilr0Lhi3ww8eHyW77I/MLAMSkC5jc4hkapa9lYD6jQBECFVusypNXG2DYm84J2
Aa46WPApfHQhiMdkNCEOXzzMa084H44zXwcpZEOkivefaW63W8FAGnYjIFdNQiC0
vi5ltiSV9b+SUTDZ9TTEUc86GeIXSiWlCzk8Mc0JhQKBgQDX+2O45KDMU9jEE9i/
Z0nrMRzkRGOdtqy9fh52O5oxDJHh6kDMjOBOJzTakBUSI1z9gIeGjup6UX4MLu32
n15Wv3zo32Cl481LQvdEzL6y3kDOjz5Aw+6Mdb0m95Uh+60uhHbtIFxX53tHizZS
2YNmEx5kb1+18FvhCh2EFLO/Ug==
-----END PRIVATE KEY-----
";
    const EC_CERT: &[u8] = b"-----BEGIN CERTIFICATE-----
MIIBnDCCAUOgAwIBAgIUARtHevn3WSceKenp57gKZHlTBH8wCgYIKoZIzj0EAwIw
JDEiMCAGA1UEAwwZRWxzZXdoZXJlIE9mZmxpbmUgRml4dHVyZTAeFw0yNjExMjIw
NDMzNDRaFw0zNjExMTkwNDMzNDRaMCQxIjAgBgNVBAMMGUVsc2V3aGVyZSBPZmZs
aW5lIEZpeHR1cmUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATdXL19bGCBF1yg
8jgBg6GnQVIgiOBGDjrRpiXeG1h9Fv7vPZQzZQd5aUTZ1j1NJ7X5KnyHcSwpENHW
SZfMRXZBo1MwUTAdBgNVHQ4EFgQUA7d1wjIegiAPMzDyPAZnRQmqVkowHwYDVR0j
BBgwFoAUA7d1wjIegiAPMzDyPAZnRQmqVkowDwYDVR0TAQH/BAUwAwEB/zAKBggq
hkjOPQQDAgNHADBEAiBkyyYD0XZDLWbCcnVvAz/ndlIHl+sBTGfMpOFhxqrgCgIg
C+qyH/UnttrOzrJq/WixDTTktscsCY+exsYOAz5zgWU=
-----END CERTIFICATE-----
";
    const EC_KEY: &[u8] = b"-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgf6BtYyfyIC6wfsf7
zUpzshBdhQ7ReuNZePYHm1qPevihRANCAATdXL19bGCBF1yg8jgBg6GnQVIgiOBG
DjrRpiXeG1h9Fv7vPZQzZQd5aUTZ1j1NJ7X5KnyHcSwpENHWSZfMRXZB
-----END PRIVATE KEY-----
";

    fn dictionary(cert: &[u8], key: &[u8]) -> Dictionary {
        let mut d = Dictionary::new();
        for field in ["DeviceCertificate", "HostCertificate", "RootCertificate"] {
            d.insert(field.into(), plist::Value::Data(cert.to_vec()));
        }
        for field in ["HostPrivateKey", "RootPrivateKey"] {
            d.insert(field.into(), plist::Value::Data(key.to_vec()));
        }
        for (field, value) in [("HostID", "test-host"), ("SystemBUID", "test-system"), ("WiFiMACAddress", "02:00:00:00:00:01")] {
            d.insert(field.into(), value.into());
        }
        d.insert("EscrowBag".into(), plist::Value::Data(b"test escrow secret".to_vec()));
        d
    }

    pub(crate) fn xml_record() -> Vec<u8> {
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &dictionary(RSA_CERT, RSA_KEY)).unwrap();
        bytes
    }

    fn inspect(bytes: &[u8]) -> (EwErrorCode, String) {
        sync_result(|callback, context| unsafe { ew_pairing_inspect(bytes.as_ptr(), bytes.len(), callback, context) })
    }

    fn der(pem: &[u8]) -> Vec<u8> {
        let body = std::str::from_utf8(pem).unwrap().lines().filter(|s| !s.starts_with("-----")).collect::<String>();
        plist::Data::from_xml_format(&body).unwrap().into()
    }

    #[test]
    fn inspects_xml_and_binary_with_optional_udid_and_der_or_pem_keys() {
        for mut record in [dictionary(RSA_CERT, RSA_KEY), dictionary(&der(EC_CERT), &der(EC_KEY))] {
            for udid in [None, Some("test-device")] {
                if let Some(id) = udid {
                    record.insert("UDID".into(), id.into());
                }
                let mut xml = Vec::new();
                let mut binary = Vec::new();
                plist::to_writer_xml(&mut xml, &record).unwrap();
                plist::to_writer_binary(&mut binary, &record).unwrap();
                for bytes in [xml, binary] {
                    let (code, json) = inspect(&bytes);
                    assert_eq!(code, EwErrorOk);
                    assert_eq!(serde_json::from_str::<Value>(&json).unwrap(), json!({
                        "format": "lockdown", "udid": udid, "hostId": "test-host", "systemBuid": "test-system",
                        "wifiMacAddress": "02:00:00:00:00:01", "hasEscrowBag": true,
                    }));
                }
            }
        }
    }

    #[test]
    fn rejects_malformed_or_mismatched_credentials_without_echoing_them() {
        let mut base = dictionary(RSA_CERT, RSA_KEY);
        let mut cases = Vec::new();
        let mut damaged = der(RSA_CERT);
        *damaged.last_mut().unwrap() ^= 1;
        for (field, bad) in [("HostPrivateKey", b"-----BEGIN PRIVATE KEY----- invalid".as_slice()),
                             ("RootPrivateKey", EC_KEY), ("DeviceCertificate", b"not an X.509 certificate"),
                             ("DeviceCertificate", damaged.as_slice()),
                             ("HostCertificate", EC_CERT), ("RootCertificate", &der(RSA_CERT)[..20])] {
            let mut d = base.clone();
            d.insert(field.into(), plist::Value::Data(bad.to_vec()));
            cases.push(d);
        }
        let mut injected = base.clone();
        injected.insert("HostID".into(), std::str::from_utf8(RSA_KEY).unwrap().into());
        cases.push(injected);
        base.remove("SystemBUID");
        cases.push(base);
        for d in cases {
            let mut bytes = Vec::new();
            plist::to_writer_xml(&mut bytes, &d).unwrap();
            let (code, message) = inspect(&bytes);
            assert_eq!(code, EwErrorInvalidInput);
            for secret in ["-----", "test escrow secret", std::str::from_utf8(RSA_KEY).unwrap().lines().nth(1).unwrap()] {
                assert!(!message.contains(secret));
            }
        }
    }

    #[test]
    fn identifies_remote_pairing_before_lockdown_validation() {
        let mut d = Dictionary::new();
        d.insert("identifier".into(), "remote-host".into());
        for key in ["private_key", "public_key"] {
            d.insert(key.into(), plist::Value::Data(vec![7; 32]));
        }
        let mut bytes = Vec::new();
        plist::to_writer_binary(&mut bytes, &d).unwrap();
        let (code, text) = inspect(&bytes);
        assert_eq!(code, EwErrorOk);
        assert_eq!(serde_json::from_str::<Value>(&text).unwrap(), json!({ "format": "remote_pairing" }));
        d.remove("identifier");
        bytes.clear();
        plist::to_writer_binary(&mut bytes, &d).unwrap();
        assert_eq!(inspect(&bytes), (EwErrorInvalidInput, "Malformed RemotePairing record.".into()));
    }
}
