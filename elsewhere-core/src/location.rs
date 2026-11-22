use std::sync::atomic::Ordering;

use idevice::{
    IdeviceError, IdeviceService,
    core_device::{CoreDeviceError, CoreDeviceServiceClient},
    core_device_proxy::CoreDeviceProxy, provider::TcpProvider, rsd::RsdHandshake,
};

use crate::{engine::Job, error::Failure, protocol::identity, receipt::ReceiptStream};

pub(crate) async fn invoke(
    provider: &TcpProvider, action: &str, input: plist::Dictionary, expected: Option<&str>, job: &Job,
) -> Result<(), Failure> {
    let proxy = CoreDeviceProxy::connect(provider).await?;
    let port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let stream = adapter.connect(port).await.map_err(IdeviceError::from)?;
    let handshake = RsdHandshake::new(stream).await?;
    if expected.is_some() && let Some(udid) = handshake.properties.get("UniqueDeviceID") {
        identity(udid.as_string(), expected)?;
    }
    let service = handshake.services.get("com.apple.coredevice.locationservice").ok_or(IdeviceError::ServiceNotFound)?;
    let stream = adapter.connect(service.port).await.map_err(IdeviceError::from)?;
    let mut client = CoreDeviceServiceClient::new(ReceiptStream::location(stream, &job.awaiting_receipt)).await?;
    job.check_cancelled()?;
    let result = client.invoke_with_plist_action("com.apple.coredevice.feature.simulatelocation", input, action).await;
    if result.is_ok() || matches!(&result, Err(IdeviceError::CoreDevice(CoreDeviceError::DeviceError(_)))) {
        job.awaiting_receipt.store(false, Ordering::Relaxed);
    }
    result.map(|_| ()).map_err(Failure::from)
}
