use std::{ffi::c_void, ptr, slice, str};

type Ref = *const c_void;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: Ref);
    fn CFDataCreate(allocator: Ref, bytes: *const u8, length: isize) -> Ref;
    fn CFDataGetBytePtr(data: Ref) -> *const u8;
    fn CFDataGetLength(data: Ref) -> isize;
    fn CFDictionaryCreate(allocator: Ref, keys: *const Ref, values: *const Ref, count: isize,
                          key_callbacks: Ref, value_callbacks: Ref) -> Ref;
}

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecAttrKeyType: Ref;
    static kSecAttrKeyTypeRSA: Ref;
    static kSecAttrKeyTypeECSECPrimeRandom: Ref;
    static kSecAttrKeyClass: Ref;
    static kSecAttrKeyClassPrivate: Ref;
    static kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1: Ref;
    static kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA224: Ref;
    static kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256: Ref;
    static kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384: Ref;
    static kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512: Ref;
    static kSecKeyAlgorithmECDSASignatureMessageX962SHA1: Ref;
    static kSecKeyAlgorithmECDSASignatureMessageX962SHA224: Ref;
    static kSecKeyAlgorithmECDSASignatureMessageX962SHA256: Ref;
    static kSecKeyAlgorithmECDSASignatureMessageX962SHA384: Ref;
    static kSecKeyAlgorithmECDSASignatureMessageX962SHA512: Ref;
    fn SecCertificateCreateWithData(allocator: Ref, data: Ref) -> Ref;
    fn SecCertificateCopyKey(certificate: Ref) -> Ref;
    fn SecKeyCreateWithData(data: Ref, attributes: Ref, error: *mut Ref) -> Ref;
    fn SecKeyCopyExternalRepresentation(key: Ref, error: *mut Ref) -> Ref;
    fn SecKeyCreateSignature(key: Ref, algorithm: Ref, data: Ref, error: *mut Ref) -> Ref;
    fn SecKeyVerifySignature(key: Ref, algorithm: Ref, data: Ref, signature: Ref, error: *mut Ref) -> u8;
}

struct Owned(Ref);

impl Owned {
    fn take(value: Ref) -> Option<Self> {
        (!value.is_null()).then_some(value).map(Self)
    }

    fn data(bytes: &[u8]) -> Option<Self> {
        Self::take(unsafe { CFDataCreate(ptr::null(), bytes.as_ptr(), isize::try_from(bytes.len()).ok()?) })
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

// Security imports PKCS#1 RSA and X9.63 EC. Lockdown files also carry those keys inside PKCS#8.
fn field<'a>(input: &mut &'a [u8], tag: u8) -> Option<&'a [u8]> {
    let (&actual, rest) = input.split_first()?;
    let (&size, mut rest) = rest.split_first()?;
    if actual != tag {
        return None;
    }
    let mut length = usize::from(size);
    if size >= 128 {
        let count = usize::from(size - 128);
        if count == 0 || count > size_of::<usize>() {
            return None;
        }
        let (bytes, tail) = rest.split_at_checked(count)?;
        length = bytes.iter().fold(0, |n, &b| (n << 8) | usize::from(b));
        rest = tail;
    }
    let (value, tail) = rest.split_at_checked(length)?;
    *input = tail;
    Some(value)
}

fn sequence(bytes: &[u8]) -> Option<&[u8]> {
    let mut rest = bytes;
    let seq = field(&mut rest, 0x30)?;
    rest.is_empty().then_some(seq)
}

fn certificate_key(der: &[u8], issuers: &[&Owned]) -> Option<Owned> {
    let data = Owned::data(der)?;
    let cert = Owned::take(unsafe { SecCertificateCreateWithData(ptr::null(), data.0) })?;
    let public = Owned::take(unsafe { SecCertificateCopyKey(cert.0) })?;
    let body = sequence(der)?;
    let mut rest = body;
    field(&mut rest, 0x30)?;
    let signed = Owned::data(&body[..body.len() - rest.len()])?;
    let mut algorithm = field(&mut rest, 0x30)?;
    let oid = field(&mut algorithm, 0x06)?;
    let signature = Owned::data(field(&mut rest, 0x03)?.strip_prefix(&[0])?)?;
    let algorithm = unsafe { match oid {
        b"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x05" => kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1,
        b"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0e" => kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA224,
        b"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0b" => kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
        b"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0c" => kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384,
        b"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0d" => kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512,
        b"\x2a\x86\x48\xce\x3d\x04\x01" => kSecKeyAlgorithmECDSASignatureMessageX962SHA1,
        b"\x2a\x86\x48\xce\x3d\x04\x03\x01" => kSecKeyAlgorithmECDSASignatureMessageX962SHA224,
        b"\x2a\x86\x48\xce\x3d\x04\x03\x02" => kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
        b"\x2a\x86\x48\xce\x3d\x04\x03\x03" => kSecKeyAlgorithmECDSASignatureMessageX962SHA384,
        b"\x2a\x86\x48\xce\x3d\x04\x03\x04" => kSecKeyAlgorithmECDSASignatureMessageX962SHA512,
        _ => return None,
    }};
    let valid = issuers.iter().copied().chain(std::iter::once(&public)).any(|key| unsafe {
        SecKeyVerifySignature(key.0, algorithm, signed.0, signature.0, ptr::null_mut()) != 0
    });
    (rest.is_empty() && valid).then_some(public)
}

fn matching_key(public: &Owned, private: &mut Vec<u8>) -> Option<()> {
    let pem = private.starts_with(b"-----BEGIN ");
    let mut label = None;
    let decoded;
    let der = if pem {
        let text = str::from_utf8(private).ok()?.trim_end();
        let (header, body) = text.split_once('\n')?;
        let name = header.trim_end().strip_prefix("-----BEGIN ")?.strip_suffix("-----")?;
        let body = body.strip_suffix(&format!("-----END {name}-----"))?;
        decoded = Vec::from(plist::Data::from_xml_format(&body.split_ascii_whitespace().collect::<String>()).ok()?);
        label = Some(name);
        decoded.as_slice()
    } else {
        private.as_slice()
    };
    let mut parts = sequence(der)?;
    let mut version = field(&mut parts, 0x02)?;
    let mut algorithm = None;
    let mut parameters = &[][..];
    let mut key = der;
    if parts.first() == Some(&0x30) {
        if version != [0] && version != [1] {
            return None;
        }
        let mut identifier = field(&mut parts, 0x30)?;
        algorithm = Some(field(&mut identifier, 0x06)?);
        parameters = identifier;
        key = field(&mut parts, 0x04)?;
        parts = sequence(key)?;
        version = field(&mut parts, 0x02)?;
    }
    let ec = parts.first() == Some(&0x04);
    let name = match (algorithm, ec) {
        (Some(b"\x2a\x86\x48\xce\x3d\x02\x01"), true) |
        (Some(b"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01"), false) => "PRIVATE KEY",
        (None, true) => "EC PRIVATE KEY",
        (None, false) => "RSA PRIVATE KEY",
        _ => return None,
    };
    if label.is_some_and(|l| l != name) {
        return None;
    }
    let mut point;
    let (kind, algorithm) = unsafe {
        if ec {
            if version != [1] { return None }
            let scalar = field(&mut parts, 0x04)?;
            let external = Owned::take(SecKeyCopyExternalRepresentation(public.0, ptr::null_mut()))?;
            point = slice::from_raw_parts(CFDataGetBytePtr(external.0), usize::try_from(CFDataGetLength(external.0)).ok()?).to_vec();
            let curve: &[u8] = match point.len() {
                65 => b"\x2a\x86\x48\xce\x3d\x03\x01\x07",
                97 => b"\x2b\x81\x04\x00\x22",
                133 => b"\x2b\x81\x04\x00\x23",
                _ => return None,
            };
            if algorithm.is_some() && field(&mut parameters, 0x06)? != curve { return None }
            if parts.first() == Some(&0xa0) {
                let mut named = field(&mut parts, 0xa0)?;
                if field(&mut named, 0x06)? != curve { return None }
            }
            if parts.first() == Some(&0xa1) {
                let mut bits = field(&mut parts, 0xa1)?;
                if field(&mut bits, 0x03)?.strip_prefix(&[0])? != point.as_slice() { return None }
            }
            if !parts.is_empty() { return None }
            point.extend_from_slice(scalar);
            key = &point;
            (kSecAttrKeyTypeECSECPrimeRandom, kSecKeyAlgorithmECDSASignatureMessageX962SHA256)
        } else {
            (kSecAttrKeyTypeRSA, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256)
        }
    };
    let data = Owned::data(key)?;
    let challenge = Owned::data(b"Elsewhere Lockdown pairing")?;
    unsafe {
        let keys = [kSecAttrKeyType, kSecAttrKeyClass];
        let values = [kind, kSecAttrKeyClassPrivate];
        let attrs = Owned::take(CFDictionaryCreate(ptr::null(), keys.as_ptr(), values.as_ptr(), 2, ptr::null(), ptr::null()))?;
        let signing = Owned::take(SecKeyCreateWithData(data.0, attrs.0, ptr::null_mut()))?;
        let signature = Owned::take(SecKeyCreateSignature(signing.0, algorithm, challenge.0, ptr::null_mut()))?;
        if SecKeyVerifySignature(public.0, algorithm, challenge.0, signature.0, ptr::null_mut()) == 0 {
            return None;
        }
    }
    // The locked TLS client reads private keys as PEM even when the imported plist stores DER.
    if !pem {
        let body = plist::Data::new(std::mem::take(private)).to_xml_format();
        *private = format!("-----BEGIN {name}-----\n{body}\n-----END {name}-----\n").into_bytes();
    }
    Some(())
}

pub(crate) fn validate(pair: &mut idevice::pairing_file::PairingFile) -> Option<()> {
    let root = certificate_key(&pair.root_certificate, &[])?;
    let host = certificate_key(&pair.host_certificate, &[&root])?;
    certificate_key(&pair.device_certificate, &[&root, &host])?;
    matching_key(&host, &mut pair.host_private_key)?;
    matching_key(&root, &mut pair.root_private_key)
}
