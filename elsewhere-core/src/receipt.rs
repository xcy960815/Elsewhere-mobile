use std::{
    io, pin::Pin,
    sync::{Arc, atomic::{AtomicBool, Ordering}},
    task::{Context, Poll, ready},
};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

// idevice combines sending and receiving in one future. A flushed request can outlive that future.
#[derive(Debug)]
pub(crate) struct ReceiptStream<S> {
    socket: S,
    pending: Arc<AtomicBool>,
    request_bytes: fn(&[u8]) -> bool,
    written: bool,
}

impl<S> ReceiptStream<S> {
    pub fn new(socket: S, pending: &Arc<AtomicBool>, request_bytes: fn(&[u8]) -> bool) -> Self {
        Self { socket, pending: Arc::clone(pending), request_bytes, written: false }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for ReceiptStream<S> {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for ReceiptStream<S> {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, bytes: &[u8]) -> Poll<io::Result<usize>> {
        let n = ready!(Pin::new(&mut self.socket).poll_write(cx, bytes))?;
        if (self.request_bytes)(&bytes[..n]) {
            self.written = true;
        }
        Poll::Ready(Ok(n))
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if std::mem::take(&mut self.written) {
            self.pending.store(true, Ordering::Relaxed);
        }
        Pin::new(&mut self.socket).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_shutdown(cx)
    }
}
