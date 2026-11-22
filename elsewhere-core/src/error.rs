use idevice::IdeviceError;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EwErrorCode {
    EwErrorOk = 0,
    EwErrorLocked,
    EwErrorNotPaired,
    EwErrorNotFound,
    EwErrorDdiMissing,
    EwErrorDdiMount,
    EwErrorNoService,
    EwErrorTunnelUnavailable,
    EwErrorCancelled,
    EwErrorInvalidInput,
    EwErrorFailed,
}

use EwErrorCode::*;

#[derive(Debug, Clone, Copy)]
pub(crate) struct Failure {
    pub code: EwErrorCode,
    pub message: &'static str,
}

/// cbindgen:ignore
impl Failure {
    pub const PANIC: Self = Self { code: EwErrorFailed, message: "Internal protocol error." };
    pub const CANCELLED: Self = Self { code: EwErrorCancelled, message: "Job cancelled." };
    pub const TIMEOUT: Self = Self { code: EwErrorTunnelUnavailable, message: "Device request timed out." };

    pub fn input(message: &'static str) -> Self {
        Self { code: EwErrorInvalidInput, message }
    }

    pub fn ddi(message: &'static str) -> Self {
        Self { code: EwErrorDdiMissing, message }
    }

    pub fn mount(error: IdeviceError, message: &'static str) -> Self {
        let failure = Self::from(error);
        match failure.code {
            EwErrorLocked | EwErrorNotPaired => failure,
            _ => Self { code: EwErrorDdiMount, message },
        }
    }
}

impl From<IdeviceError> for Failure {
    fn from(error: IdeviceError) -> Self {
        use IdeviceError::*;
        // Device-supplied strings and underlying TLS errors can contain pairing material.
        let code = match error {
            DeviceLocked => EwErrorLocked,
            InvalidHostID => EwErrorNotPaired,
            DeviceNotFound | NotFound => EwErrorNotFound,
            ServiceNotFound | DeveloperModeNotEnabled => EwErrorNoService,
            CanceledByUser => return Self::CANCELLED,
            Timeout => return Self::TIMEOUT,
            Socket(_) | NoEstablishedConnection |
                Xpc(idevice::xpc::errors::XpcError::HttpStreamReset | idevice::xpc::errors::XpcError::HttpGoAway(_)) => EwErrorTunnelUnavailable,
            UnexpectedResponse(s) if s == "HTTP/2 connection closed by peer" => EwErrorTunnelUnavailable,
            UnknownErrorType(s) => match s.split_whitespace().next() {
                Some("PasswordProtected" | "DeviceLocked") => EwErrorLocked,
                Some("InvalidPairRecord" | "InvalidHostID" | "PairingDialogResponsePending" | "UserDeniedPairing") => EwErrorNotPaired,
                Some("InvalidService") => EwErrorNoService,
                _ => EwErrorFailed,
            },
            _ => EwErrorFailed,
        };
        let message = match code {
            EwErrorLocked => "Unlock the target device.",
            EwErrorNotPaired => "The target rejected this pairing record.",
            EwErrorNotFound => "The target device or requested item was not found.",
            EwErrorNoService => "The requested developer service is unavailable.",
            EwErrorTunnelUnavailable => "The connection to the target device is unavailable.",
            _ => "The device protocol request failed.",
        };
        Self { code, message }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::ErrorKind;

    #[test]
    fn maps_device_and_transport_errors_without_returning_credentials() {
        use IdeviceError::*;
        let secret = "-----BEGIN PRIVATE KEY----- secret -----BEGIN CERTIFICATE-----";
        for (error, code) in [
            (DeviceLocked, EwErrorLocked), (InvalidHostID, EwErrorNotPaired),
            (DeviceNotFound, EwErrorNotFound), (Timeout, EwErrorTunnelUnavailable),
            (ServiceNotFound, EwErrorNoService), (UnexpectedResponse(secret.into()), EwErrorFailed),
            (UnknownErrorType(secret.into()), EwErrorFailed),
        ] {
            let failure = Failure::from(error);
            assert_eq!(failure.code, code);
            assert!(!failure.message.contains("-----"));
        }
        for kind in [ErrorKind::ConnectionRefused, ErrorKind::TimedOut, ErrorKind::NetworkUnreachable,
                     ErrorKind::HostUnreachable, ErrorKind::BrokenPipe] {
            let failure = Failure::from(Socket(std::io::Error::new(kind, secret)));
            assert_eq!(failure.code, EwErrorTunnelUnavailable);
            assert!(!failure.message.contains("-----"));
        }
    }
}
