use std::{
    io, pin::Pin,
    sync::{Arc, atomic::{AtomicBool, Ordering}},
    task::{Context, Poll, ready},
};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

const PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const ACTION: &[u8] = b"com.apple.coredevice.action.";

#[derive(Debug, Default)]
struct Http2ActionDetector {
    preface_pos: usize,
    header: [u8; 9],
    header_len: usize,
    remaining: usize,
    data_remaining: usize,
    expect_pad_length: bool,
    data_stream: u32,
    tail: [u8; ACTION.len() - 1],
}

impl Http2ActionDetector {
    fn observe(&mut self, mut bytes: &[u8]) -> bool {
        while self.preface_pos < PREFACE.len() {
            let Some((&first, rest)) = bytes.split_first() else { return false };
            if first != PREFACE[self.preface_pos] {
                // A stream without a preface can still start with the same bytes as the preface.
                self.frames(&PREFACE[..self.preface_pos]);
                self.preface_pos = PREFACE.len();
                break;
            }
            bytes = rest;
            self.preface_pos += 1;
        }
        self.frames(bytes)
    }

    fn frames(&mut self, mut bytes: &[u8]) -> bool {
        let mut found = false;
        while !bytes.is_empty() {
            if self.remaining == 0 {
                let n = bytes.len().min(self.header.len() - self.header_len);
                self.header[self.header_len..self.header_len + n].copy_from_slice(&bytes[..n]);
                self.header_len += n;
                bytes = &bytes[n..];
                if self.header_len == self.header.len() {
                    self.start_payload();
                    self.header_len = 0;
                }
                continue;
            }
            if self.expect_pad_length {
                self.remaining -= 1;
                self.data_remaining = self.remaining.saturating_sub(usize::from(bytes[0]));
                self.expect_pad_length = false;
                bytes = &bytes[1..];
                continue;
            }
            let n = self.remaining.min(bytes.len());
            let data_len = self.data_remaining.min(n);
            for &byte in &bytes[..data_len] {
                found |= byte == ACTION[self.tail.len()] && self.tail[..] == ACTION[..ACTION.len() - 1];
                self.tail.copy_within(1.., 0);
                self.tail[ACTION.len() - 2] = byte;
            }
            self.remaining -= n;
            self.data_remaining -= data_len;
            bytes = &bytes[n..];
        }
        found
    }

    fn start_payload(&mut self) {
        let [a, b, c, kind, flags, s0, s1, s2, s3] = self.header;
        self.remaining = u32::from_be_bytes([0, a, b, c]) as usize;
        let stream = u32::from_be_bytes([s0 & 0x7f, s1, s2, s3]);
        if kind == 0 && stream != 0 {
            if self.data_stream != stream {
                self.tail.fill(0);
                self.data_stream = stream;
            }
            self.data_remaining = self.remaining;
            self.expect_pad_length = self.remaining != 0 && flags & 0x08 != 0;
        }
    }
}

#[derive(Debug)]
enum RequestDetector {
    AnyWrite,
    Http2Action(Http2ActionDetector),
}

// idevice combines sending and receiving in one future. A flushed request can outlive that future.
#[derive(Debug)]
pub(crate) struct ReceiptStream<S> {
    socket: S,
    pending: Arc<AtomicBool>,
    detector: RequestDetector,
    written: bool,
}

impl<S> ReceiptStream<S> {
    pub fn any_write(socket: S, pending: &Arc<AtomicBool>) -> Self {
        Self { socket, pending: Arc::clone(pending), detector: RequestDetector::AnyWrite, written: false }
    }

    pub fn location(socket: S, pending: &Arc<AtomicBool>) -> Self {
        let detector = RequestDetector::Http2Action(Http2ActionDetector::default());
        Self { socket, pending: Arc::clone(pending), detector, written: false }
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
        let detected = match &mut self.detector {
            RequestDetector::AnyWrite => n != 0,
            RequestDetector::Http2Action(detector) => detector.observe(&bytes[..n]),
        };
        self.written |= detected;
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

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncWriteExt, Sink, sink};

    struct ShortWriter { inner: Sink, limit: usize }

    impl AsyncWrite for ShortWriter {
        fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, bytes: &[u8]) -> Poll<io::Result<usize>> {
            let n = self.limit.min(bytes.len());
            Pin::new(&mut self.inner).poll_write(cx, &bytes[..n])
        }

        fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.inner).poll_flush(cx)
        }

        fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.inner).poll_shutdown(cx)
        }
    }

    fn frame(kind: u8, flags: u8, stream: u32, payload: &[u8]) -> Vec<u8> {
        let mut bytes = (payload.len() as u32).to_be_bytes()[1..].to_vec();
        bytes.extend([kind, flags]);
        bytes.extend(stream.to_be_bytes());
        bytes.extend_from_slice(payload);
        bytes
    }

    #[test]
    fn short_writes_detect_only_flushed_action_data() {
        tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(async {
            let action = b"com.apple.coredevice.action.setsimulatedlocation";
            for limit in [1, 3, 5, 7, 512] {
                for preface in [PREFACE, &[]] {
                    let pending = Arc::new(AtomicBool::new(false));
                    let mut stream = ReceiptStream::location(ShortWriter { inner: sink(), limit }, &pending);
                    let mut headers = preface.to_vec();
                    headers.extend(frame(1, 4, 1, action));
                    stream.write_all(&headers).await.unwrap();
                    stream.flush().await.unwrap();
                    assert!(!pending.load(Ordering::Relaxed));

                    stream.write_all(&frame(0, 0, 1, action)).await.unwrap();
                    assert!(!pending.load(Ordering::Relaxed));
                    stream.flush().await.unwrap();
                    assert!(pending.load(Ordering::Relaxed));
                }
            }
        });
    }

    #[test]
    fn action_prefix_spans_data_frames_on_the_same_stream_and_excludes_padding() {
        let mut detector = Http2ActionDetector::default();
        let mut padded = vec![ACTION.len() as u8];
        padded.extend_from_slice(ACTION);
        assert!(!detector.observe(&frame(0, 8, 1, &padded)));
        let (prefix, suffix) = ACTION.split_at(10);
        assert!(!detector.observe(&frame(0, 0, 1, prefix)));
        assert!(!detector.observe(&frame(0, 0, 3, suffix)));

        let mut frames = frame(0, 0, 1, prefix);
        frames.extend(frame(8, 0, 1, &[0, 0, 0, 1]));
        frames.extend(frame(0, 0, 1, suffix));
        assert!(detector.observe(&frames));
    }
}
