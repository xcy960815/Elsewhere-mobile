use std::{
    cell::Cell,
    collections::{HashMap, hash_map::Entry},
    ffi::c_void,
    rc::Rc,
    sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}},
    thread,
};

use tokio::{runtime::Builder, sync::{mpsc, watch}, task::{JoinSet, LocalSet}, time::timeout_at};

use crate::{
    EwErrorCode, EwEventKind, EwJobCallback, EwJobEvent, EwStage,
    error::Failure, protocol::Request,
};

pub struct EwEngine {
    queue: mpsc::UnboundedSender<(Job, Request)>,
    active: Arc<Mutex<HashMap<u64, watch::Sender<bool>>>>,
    worker: thread::JoinHandle<()>,
}

pub(crate) struct Job {
    id: u64,
    callback: EwJobCallback,
    context: *mut c_void,
    stage: Cell<EwStage>,
    cancelled: watch::Receiver<bool>,
    pub awaiting_receipt: Arc<AtomicBool>,
}

// The caller keeps context alive through the terminal callback. Rust only passes it back on the worker.
unsafe impl Send for Job {}

impl Job {
    pub fn check_cancelled(&self) -> Result<(), Failure> {
        if *self.cancelled.borrow() { Err(Failure::CANCELLED) } else { Ok(()) }
    }

    pub fn stage(&self, stage: EwStage) -> Result<(), Failure> {
        self.check_cancelled()?;
        self.stage.set(stage);
        self.emit(EwEventKind::EwEventStage, EwErrorCode::EwErrorOk, false, &[]);
        // Swift may cancel synchronously from the progress callback before a device write.
        self.check_cancelled()
    }

    fn emit(&self, kind: EwEventKind, error_code: EwErrorCode, outcome_unknown: bool, payload: &[u8]) {
        let event = EwJobEvent {
            job_id: self.id, kind, stage: self.stage.get(), error_code, outcome_unknown,
            payload_ptr: payload.as_ptr(), payload_len: payload.len(),
        };
        (self.callback)(&event, self.context);
    }

    fn finish(&self, result: Result<serde_json::Value, Failure>) {
        match self.check_cancelled().and(result) {
            Ok(json) => self.emit(EwEventKind::EwEventSuccess, EwErrorCode::EwErrorOk, false, json.to_string().as_bytes()),
            Err(e) => self.emit(EwEventKind::EwEventFailure, e.code, self.awaiting_receipt.load(Ordering::Relaxed), e.message.as_bytes()),
        }
    }
}

impl EwEngine {
    pub(crate) fn new() -> Option<Self> {
        let runtime = Builder::new_current_thread().enable_all().build().ok()?;
        let (queue, mut inbox) = mpsc::unbounded_channel::<(Job, Request)>();
        let active = Arc::new(Mutex::new(HashMap::<u64, watch::Sender<bool>>::new()));
        let registry = Arc::clone(&active);
        let worker = thread::Builder::new().name("Elsewhere".into()).spawn(move || {
            LocalSet::new().block_on(&runtime, async move {
                let mut tasks = JoinSet::new();
                let mut callbacks = HashMap::new();
                let mut open = true;
                while open || !tasks.is_empty() {
                    tokio::select! {
                        input = inbox.recv(), if open => {
                            let Some((job, request)) = input else { open = false; continue };
                            let job = Rc::new(job);
                            let events = Rc::clone(&job);
                            let task = tasks.spawn_local(async move {
                                let mut cancel = events.cancelled.clone();
                                tokio::select! {
                                    biased;
                                    _ = cancel.changed() => Err(Failure::CANCELLED),
                                    result = timeout_at(request.deadline, request.run(&events)) =>
                                        result.unwrap_or(Err(Failure::TIMEOUT)),
                                }
                            });
                            callbacks.insert(task.id(), job);
                        }
                        Some(done) = tasks.join_next_with_id(), if !tasks.is_empty() => {
                            let (id, result) = done.unwrap_or_else(|e| (e.id(), Err(Failure::PANIC)));
                            let job = callbacks.remove(&id).unwrap();
                            registry.lock().unwrap().remove(&job.id);
                            job.finish(result);
                        }
                    }
                }
            });
        }).ok()?;
        Some(Self { queue, active, worker })
    }

    pub(crate) fn submit(&self, id: u64, request: Request, callback: EwJobCallback, context: *mut c_void) -> bool {
        let mut active = self.active.lock().unwrap();
        let Entry::Vacant(entry) = active.entry(id) else { return false };
        let (cancel, cancelled) = watch::channel(false);
        let job = Job {
            id, callback, context, cancelled, stage: Cell::new(EwStage::EwStageConnecting),
            awaiting_receipt: Arc::new(AtomicBool::new(false)),
        };
        if self.queue.send((job, request)).is_err() {
            return false;
        }
        entry.insert(cancel);
        true
    }

    pub(crate) fn cancel(&self, id: u64) {
        if let Some(cancel) = self.active.lock().unwrap().get(&id) {
            cancel.send_replace(true);
        }
    }

    pub(crate) fn shutdown(self) {
        for cancel in self.active.lock().unwrap().values() {
            cancel.send_replace(true);
        }
        drop(self.queue);
        let _ = self.worker.join();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{net::{SocketAddr, TcpListener}, ptr, sync::mpsc as sync, time::Duration};
    use tokio::{io::{AsyncWriteExt, duplex}, net::TcpSocket};
    use crate::{
        EwCommand::*, EwErrorCode::*, EwEventKind::*, EwRequest, EwStage::*,
        ew_cancel, ew_engine_create, ew_engine_destroy, ew_lockdown_port, ew_submit,
        location::action_frame, pairing::tests::xml_record, receipt::ReceiptStream,
    };

    type Event = (u64, EwEventKind, EwStage, EwErrorCode, bool);

    extern "C" fn capture(event: *const EwJobEvent, context: *mut c_void) {
        let event = unsafe { &*event };
        let sender = unsafe { &*context.cast::<sync::Sender<Event>>() };
        let _ = sender.send((event.job_id, event.kind, event.stage, event.error_code, event.outcome_unknown));
    }

    #[test]
    fn drains_refusal_timeout_cancellation_and_queued_jobs_through_the_abi() {
        // Binding without listen reserves a refused Lockdown port without reaching an existing service.
        let (addr, reserved) = ["127.0.0.1", "::1"].into_iter().find_map(|ip| {
            let addr = SocketAddr::new(ip.parse().unwrap(), ew_lockdown_port());
            let socket = if addr.is_ipv4() { TcpSocket::new_v4() } else { TcpSocket::new_v6() }.ok()?;
            socket.bind(addr).ok()?;
            Some((addr, socket))
        }).expect("a free loopback Lockdown port");
        let mut host = addr.ip().to_string().into_bytes();
        let mut pairing = xml_record();
        let (sender, events) = sync::channel::<Event>();
        let context = ptr::from_ref(&sender).cast_mut().cast();
        let next = || events.recv_timeout(Duration::from_secs(10)).unwrap();
        struct Handle(*mut EwEngine);
        impl Drop for Handle {
            fn drop(&mut self) { unsafe { ew_engine_destroy(self.0) } }
        }
        let engine = Handle(ew_engine_create());
        assert!(!engine.0.is_null());
        let mut request = EwRequest {
            command: EwCommandProbe, endpoint_host_ptr: host.as_ptr(), endpoint_host_len: host.len(),
            ipv6_scope_id: 0, pairing_ptr: pairing.as_ptr(), pairing_len: pairing.len(),
            expected_udid_ptr: ptr::null(), expected_udid_len: 0, ddi_dir_ptr: ptr::null(), ddi_dir_len: 0,
            latitude: 0.0, longitude: 0.0, timeout_ms: 5_000,
        };
        let submit = |id, req: &EwRequest| unsafe { ew_submit(engine.0, id, req, capture, context) };
        assert!(submit(1, &request));
        host.fill(0);
        pairing.fill(0);
        assert_eq!(next(), (1, EwEventStage, EwStageConnecting, EwErrorOk, false));
        assert_eq!(next(), (1, EwEventFailure, EwStageConnecting, EwErrorTunnelUnavailable, false));

        drop(reserved);
        let _listener = TcpListener::bind(addr).unwrap();
        host = addr.ip().to_string().into_bytes();
        pairing = xml_record();
        request.endpoint_host_ptr = host.as_ptr();
        request.pairing_ptr = pairing.as_ptr();
        request.timeout_ms = 1_500;
        assert!(submit(2, &request));
        assert_eq!(next(), (2, EwEventStage, EwStageConnecting, EwErrorOk, false));
        assert_eq!(next(), (2, EwEventFailure, EwStageConnecting, EwErrorTunnelUnavailable, false));

        request.timeout_ms = 5_000;
        assert!(submit(3, &request));
        assert_eq!(next(), (3, EwEventStage, EwStageConnecting, EwErrorOk, false));
        assert!(!submit(3, &request));
        unsafe { ew_cancel(engine.0, 3); ew_cancel(engine.0, 3) };
        assert_eq!(next(), (3, EwEventFailure, EwStageConnecting, EwErrorCancelled, false));

        request.command = EwCommandSetLocation;
        request.latitude = f64::NAN;
        assert!(submit(4, &request));
        assert_eq!(next(), (4, EwEventFailure, EwStageConnecting, EwErrorInvalidInput, false));
        request.command = EwCommandCheckDdi;
        assert!(submit(5, &request));
        assert_eq!(next(), (5, EwEventStage, EwStageConnecting, EwErrorOk, false));
        assert!(submit(6, &request));
        drop(engine);
        unsafe { ew_engine_destroy(ptr::null_mut()) };
        let remaining: Vec<_> = events.try_iter().collect();
        for id in [5, 6] {
            let terminal = (id, EwEventFailure, EwStageConnecting, EwErrorCancelled, false);
            let job: Vec<_> = remaining.iter().filter(|e| e.0 == id).collect();
            assert_eq!(job.last(), Some(&&terminal));
            assert_eq!(job.iter().filter(|e| e.1 != EwEventStage).count(), 1);
        }
        assert!(remaining.iter().all(|e| matches!(e.0, 5 | 6)));
    }

    #[test]
    fn a_lost_or_cancelled_location_write_is_unknown_only_after_the_action_was_sent() {
        let runtime = Builder::new_current_thread().build().unwrap();
        runtime.block_on(async {
            let (sender, events) = sync::channel::<Event>();
            let context = ptr::from_ref(&sender).cast_mut().cast();
            for (send_action, cancelled_by_caller) in [(false, true), (true, true), (true, false)] {
                let (cancel, cancelled) = watch::channel(false);
                let job = Job {
                    id: 7, callback: capture, context, stage: Cell::new(EwStageApplyingLocation), cancelled,
                    awaiting_receipt: Arc::new(AtomicBool::new(false)),
                };
                let (socket, peer) = duplex(512);
                let mut stream = ReceiptStream::new(socket, &job.awaiting_receipt, action_frame);
                stream.write_all(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").await.unwrap();
                stream.flush().await.unwrap();
                if send_action {
                    let action = b"com.apple.coredevice.action.setsimulatedlocation";
                    let mut frame = vec![0, 0, u8::try_from(action.len()).unwrap(), 0, 0, 0, 0, 0, 1];
                    frame.extend(action);
                    stream.write_all(&frame).await.unwrap();
                    stream.flush().await.unwrap();
                }
                drop(peer);
                if cancelled_by_caller { cancel.send_replace(true); }
                let error = stream.write_all(b"closed").await.unwrap_err();
                job.finish(Err(idevice::IdeviceError::Socket(error).into()));
                let code = if cancelled_by_caller { EwErrorCancelled } else { EwErrorTunnelUnavailable };
                assert_eq!(events.try_recv().unwrap(), (7, EwEventFailure, EwStageApplyingLocation, code, send_action));
            }
        });
    }
}
