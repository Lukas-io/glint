use crate::keys;
use idevice::{
    IdeviceService, ReadWrite, RsdService,
    core_device::{
        OrientationServiceClient, RotationDirection,
        CallInfoBlob, DisplayServiceClient, HevcDepacketizer, ImageFormat, RtpPacket, ScreenCaptureServiceClient, build_screen_audio_offer, build_screen_video_offer,
        build_start_audio_parameters, build_start_video_parameters,
        hid::{ButtonState, IndigoHidClient, TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE, TouchscreenContact, UniversalHidServiceClient},
        GENERAL_PASTEBOARD, PasteboardServiceClient,
    },
    core_device_proxy::CoreDeviceProxy,
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
    dvt::{condition_inducer::ConditionInducerClient, remote_server::RemoteServerClient},
    provider::UsbmuxdProvider,
    springboardservices::SpringBoardServicesClient,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};
use serde_json::{Value, json};
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

/// A request to the task that holds the network condition connection open.
enum NetCmd {
    List(oneshot::Sender<Result<Value, String>>),
    On(String, oneshot::Sender<Result<Value, String>>),
    Off(oneshot::Sender<Result<Value, String>>),
}

/// What Device Hub sends as the controller's own feature mask; the device's larger mask yields an invalid video config.
const CLIENT_SUPPORTED_FEATURES: u64 = 140;
const MAIN_DISPLAY: i64 = 1;

pub struct SessionError {
    pub kind: &'static str,
    pub detail: String,
}

fn err(kind: &'static str, detail: impl Into<String>) -> SessionError {
    SessionError { kind, detail: detail.into() }
}

struct Live {
    /// False when another host was already streaming; stopping would end its session too.
    sole_stream: bool,
    display: DisplayServiceClient<Box<dyn ReadWrite>>,
    drains: Vec<JoinHandle<()>>,
    touch: UniversalHidServiceClient<Box<dyn ReadWrite>>,
    indigo: IndigoHidClient<Box<dyn ReadWrite>>,
}

/// A recording in progress: the display's HEVC as Annex-B, timed from its first packet.
struct Recorder {
    out: std::io::BufWriter<std::fs::File>,
    depack: HevcDepacketizer,
    first: Option<Instant>,
    last_ts: u32,
    frames: u64,
    bytes: u64,
}

impl Recorder {
    fn push(&mut self, data: &[u8]) {
        let Some(pkt) = RtpPacket::parse(data) else { return };
        if self.first.is_none() {
            self.first = Some(Instant::now());
        }
        if pkt.timestamp != self.last_ts {
            self.frames += 1;
            self.last_ts = pkt.timestamp;
        }
        self.depack.push(pkt.sequence_number, pkt.timestamp, pkt.payload);
        let out = self.depack.take_output();
        if !out.is_empty() && self.out.write_all(&out).is_ok() {
            self.bytes += out.len() as u64;
        }
    }
}

pub struct Session {
    provider: UsbmuxdProvider,
    adapter: AdapterHandle,
    handshake: RsdHandshake,
    live: Option<Live>,
    capture: Option<ScreenCaptureServiceClient<Box<dyn ReadWrite>>>,
    recorder: Arc<Mutex<Option<Recorder>>>,
    network: Option<mpsc::Sender<NetCmd>>,
}

impl Session {
    pub async fn connect(udid: &str) -> Result<Self, SessionError> {
        let mut mux = UsbmuxdConnection::default()
            .await
            .map_err(|e| err("usbmuxd", format!("cannot reach usbmuxd: {e:?}")))?;
        let device = mux
            .get_device(udid)
            .await
            .map_err(|e| err("deviceNotFound", format!("{udid} is not connected: {e:?}")))?;
        let addr = UsbmuxdAddr::from_env_var().map_err(|e| err("usbmuxd", format!("{e:?}")))?;
        let provider = device.to_provider(addr, "glint-devicehid");
        let proxy = CoreDeviceProxy::connect(&provider)
            .await
            .map_err(|e| err("tunnel", format!("no CoreDevice tunnel (is the phone unlocked, trusted and in Developer Mode?): {e:?}")))?;
        let rsd_port = proxy.tunnel_info().server_rsd_port;
        let adapter = proxy
            .create_software_tunnel()
            .map_err(|e| err("tunnel", format!("{e:?}")))?;
        let mut adapter = adapter.to_async_handle();
        let stream = adapter
            .connect(rsd_port)
            .await
            .map_err(|e| err("tunnel", format!("no service directory: {e:?}")))?;
        let handshake = RsdHandshake::new(stream)
            .await
            .map_err(|e| err("tunnel", format!("service directory handshake failed: {e:?}")))?;
        Ok(Self { provider, adapter, handshake, live: None, capture: None, recorder: Arc::new(Mutex::new(None)), network: None })
    }

    pub async fn stream_status(&mut self) -> Result<String, SessionError> {
        let mut display = DisplayServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(|e| err("developerImage", format!("no display service: {e:?}")))?;
        display
            .get_media_stream_server_status()
            .await
            .map(|v| format!("{v:?}"))
            .map_err(|e| err("stream", format!("{e:?}")))
    }

    /// Writes the screen to `path` through the CoreDevice capture service, which needs no screen session.
    async fn screenshot(&mut self, request: &Value) -> Result<Value, SessionError> {
        let path = request["path"].as_str().ok_or_else(|| err("badRequest", "path is required"))?;
        let started = Instant::now();
        if self.capture.is_none() {
            let client = ScreenCaptureServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake)
                .await
                .map_err(|e| err("developerImage", format!("no screen capture service: {e:?}")))?;
            self.capture = Some(client);
        }
        let bytes = match self.capture.as_mut().expect("capture").take_screenshot(None, ImageFormat::Png).await {
            Ok(b) => b,
            Err(e) => {
                self.capture = None;
                return Err(err("stream", format!("screenshot failed: {e:?}")));
            }
        };
        std::fs::write(path, &bytes).map_err(|e| err("badRequest", format!("cannot write {path}: {e}")))?;
        Ok(json!({"bytes": bytes.len(), "ms": started.elapsed().as_millis() as u64}))
    }

    /// Puts [text] on the general pasteboard and presses cmd+V; returns what the pasteboard held, for the caller to put back once the app has read it (iOS may first ask to allow the paste).
    async fn paste(&mut self, request: &Value) -> Result<Value, SessionError> {
        let text = request["text"].as_str().ok_or_else(|| err("badRequest", "text is required"))?;
        self.ensure_live().await?;
        let mut board = PasteboardServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(|e| err("developerImage", format!("no pasteboard service: {e:?}")))?;
        let before = board.get(GENERAL_PASTEBOARD).await.ok().and_then(|s| s.text());
        board.set_text(text, GENERAL_PASTEBOARD).await.map_err(|e| err("stream", format!("pasteboard set failed: {e:?}")))?;
        let live = self.live.as_mut().expect("ensure_live");
        press(&mut live.indigo, 0x19, &[keys::LEFT_GUI]).await?;
        Ok(json!({"pasted": text.chars().count(), "previous": before}))
    }

    /// Puts [text] back on the general pasteboard.
    async fn pasteboard_set(&mut self, request: &Value) -> Result<Value, SessionError> {
        let text = request["text"].as_str().ok_or_else(|| err("badRequest", "text is required"))?;
        let mut board = PasteboardServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(|e| err("developerImage", format!("no pasteboard service: {e:?}")))?;
        board.set_text(text, GENERAL_PASTEBOARD).await.map_err(|e| err("stream", format!("pasteboard set failed: {e:?}")))?;
        Ok(json!({"set": true}))
    }

    /// Lists, turns on or turns off a network condition through Instruments, on a task that keeps its connection open while one is on.
    async fn network(&mut self, cmd: &str, request: &Value) -> Result<Value, SessionError> {
        if self.network.is_none() {
            let client = RemoteServerClient::connect_rsd(&mut self.adapter, &mut self.handshake)
                .await
                .map_err(|e| err("developerImage", format!("no Instruments service: {e:?}")))?;
            let (tx, rx) = mpsc::channel::<NetCmd>(4);
            tokio::spawn(network_task(client, rx));
            self.network = Some(tx);
        }
        let (reply, answer) = oneshot::channel();
        let message = match cmd {
            "networkList" => NetCmd::List(reply),
            "networkOn" => NetCmd::On(request["profile"].as_str().unwrap_or_default().to_string(), reply),
            _ => NetCmd::Off(reply),
        };
        let tx = self.network.as_ref().expect("network");
        if tx.send(message).await.is_err() {
            self.network = None;
            return Err(err("stream", "the network condition connection closed"));
        }
        answer.await.map_err(|_| err("stream", "no answer from the network task"))?.map_err(|e| err("badRequest", e))
    }

    /// Turns any network condition off, so it never outlives glint.
    pub async fn network_off(&mut self) {
        if let Some(tx) = self.network.take() {
            let (reply, answer) = oneshot::channel();
            if tx.send(NetCmd::Off(reply)).await.is_ok() {
                let _ = answer.await;
            }
        }
    }

    /// Whether a recording is running, so the idle timer leaves the stream alone.
    pub fn recording(&self) -> bool {
        self.recorder.lock().map(|r| r.is_some()).unwrap_or(false)
    }

    /// Starts writing the display's HEVC to `path`, on a fresh screen session so the file opens on a keyframe.
    async fn record_start(&mut self, request: &Value) -> Result<Value, SessionError> {
        let path = request["path"].as_str().ok_or_else(|| err("badRequest", "path is required"))?;
        if self.recording() {
            return Err(err("badRequest", "a recording is already running"));
        }
        let file = std::fs::File::create(path).map_err(|e| err("badRequest", format!("cannot write {path}: {e}")))?;
        self.stop_stream().await;
        *self.recorder.lock().expect("recorder") = Some(Recorder {
            out: std::io::BufWriter::new(file),
            depack: HevcDepacketizer::new(),
            first: None,
            last_ts: 0,
            frames: 0,
            bytes: 0,
        });
        if let Err(e) = self.ensure_live().await {
            *self.recorder.lock().expect("recorder") = None;
            return Err(e);
        }
        Ok(json!({"recording": path}))
    }

    /// Stops the recording and reports the frames, bytes and seconds of display time it holds.
    fn record_stop(&mut self) -> Result<Value, SessionError> {
        let Some(mut r) = self.recorder.lock().expect("recorder").take() else {
            return Err(err("badRequest", "no recording is running"));
        };
        let _ = r.out.flush();
        let span = r.first.map(|f| f.elapsed().as_secs_f64()).unwrap_or(0.0);
        Ok(json!({"frames": r.frames, "bytes": r.bytes, "seconds": span}))
    }

    pub fn streaming(&self) -> bool {
        self.live.is_some()
    }

    pub async fn handle(&mut self, request: &Value) -> Result<Value, SessionError> {
        let cmd = request["cmd"].as_str().unwrap_or_default();
        if cmd == "screenshot" {
            return self.screenshot(request).await;
        }
        if cmd == "recordStart" {
            return self.record_start(request).await;
        }
        if cmd == "recordStop" {
            return self.record_stop();
        }
        if cmd == "paste" {
            return self.paste(request).await;
        }
        if cmd == "pasteboardSet" {
            return self.pasteboard_set(request).await;
        }
        if cmd == "rotate" {
            let direction = if request["direction"] == "left" { RotationDirection::Left } else { RotationDirection::Right };
            let mut control = OrientationServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake)
                .await
                .map_err(|e| err("developerImage", format!("no device control service: {e:?}")))?;
            let state = control.rotate(direction).await.map_err(|e| err("stream", format!("rotate failed: {e:?}")))?;
            return Ok(json!({"orientation": format!("{:?}", state.orientation), "locked": state.locked}));
        }
        if cmd == "networkList" || cmd == "networkOn" || cmd == "networkOff" {
            return self.network(cmd, request).await;
        }
        if cmd == "orientation" {
            let mut sb = SpringBoardServicesClient::connect(&self.provider)
                .await
                .map_err(|e| err("tunnel", format!("no SpringBoard service: {e:?}")))?;
            let o = sb.get_interface_orientation().await.map_err(|e| err("stream", format!("{e:?}")))?;
            return Ok(json!({"interfaceOrientation": format!("{o:?}")}));
        }
        let opened = self.ensure_live().await?;
        let live = self.live.as_mut().expect("ensure_live");
        let started = Instant::now();
        let result = match cmd {
            "touch" => touch(live, request).await,
            "taps" => taps(live, request).await,
            "pinch" => pinch(live, request).await,
            "type" => type_text(live, request).await,
            "key" => key(live, request).await,
            "button" => button(live, request).await,
            other => Err(err("badRequest", format!("unknown cmd {other:?}"))),
        };
        if result.as_ref().is_err_and(|e| e.kind == "input") {
            self.stop_stream().await;
        }
        result.map(|()| json!({"streamOpened": opened, "ms": started.elapsed().as_millis() as u64}))
    }

    async fn ensure_live(&mut self) -> Result<bool, SessionError> {
        if self.live.is_some() {
            return Ok(false);
        }
        let mut display = DisplayServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(|e| err("developerImage", format!("no display service (the developer disk image may not be mounted): {e:?}")))?;
        let sole_stream = !display
            .get_media_stream_server_status()
            .await
            .ok()
            .and_then(|v| v.as_dictionary().and_then(|d| d.get("running")).and_then(|r| r.as_boolean()))
            .unwrap_or(false);
        let audio = self.adapter.bind_udp(0).await.map_err(|e| err("stream", format!("{e:?}")))?;
        let video = self.adapter.bind_udp(0).await.map_err(|e| err("stream", format!("{e:?}")))?;
        let receiver = self.adapter.host_ip().to_string();
        let sender = self.adapter.peer_ip().to_string();
        let call_info = CallInfoBlob {
            call_id: 0,
            client_version: 1,
            device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(),
            os_version: "25F71".into(),
            device_name: None,
            audio_device_uid: None,
        };
        let session_id = uuid::Uuid::new_v4();
        let audio_offer = build_screen_audio_offer(&uuid::Uuid::new_v4().to_string().to_uppercase(), &call_info)
            .map_err(|e| err("stream", format!("{e:?}")))?;
        display
            .start_media_stream(build_start_audio_parameters(&receiver, audio.local_port(), &sender, 50000, audio_offer, CLIENT_SUPPORTED_FEATURES, session_id))
            .await
            .map_err(|e| err("deviceBusy", format!("the phone refused a screen session (another Device Hub may be viewing it): {e:?}")))?;
        let video_offer = build_screen_video_offer(&uuid::Uuid::new_v4().to_string().to_uppercase(), &call_info, uuid::Uuid::new_v4().as_u128() as u32)
            .map_err(|e| err("stream", format!("{e:?}")))?;
        display
            .start_media_stream(build_start_video_parameters(&receiver, video.local_port(), &sender, 50001, video_offer, CLIENT_SUPPORTED_FEATURES, MAIN_DISPLAY, session_id))
            .await
            .map_err(|e| err("stream", format!("video start failed: {e:?}")))?;
        let recorder = self.recorder.clone();
        let drains = vec![
            tokio::spawn(async move { while audio.recv().await.is_ok() {} }),
            tokio::spawn(async move {
                while let Ok(dg) = video.recv().await {
                    if let Ok(mut slot) = recorder.lock() {
                        if let Some(r) = slot.as_mut() {
                            r.push(&dg.data);
                        }
                    }
                }
            }),
        ];
        // backboardd needs a moment to re-match the HID surfaces against the new stream before reports land.
        tokio::time::sleep(Duration::from_millis(300)).await;
        let touch = UniversalHidServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(|e| err("developerImage", format!("no touch service: {e:?}")))?;
        let indigo = IndigoHidClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(|e| err("developerImage", format!("no keyboard/button service: {e:?}")))?;
        self.live = Some(Live { sole_stream, display, drains, touch, indigo });
        Ok(true)
    }

    pub async fn stop_stream(&mut self) {
        let Some(mut live) = self.live.take() else { return };
        if live.sole_stream {
            let _ = live.display.stop_media_stream().await;
        }
        for d in live.drains {
            d.abort();
        }
    }
}

fn input(e: impl std::fmt::Debug) -> SessionError {
    err("input", format!("{e:?}"))
}

/// Contacts at each `[x, y, ms]` (x, y in 0..=65535 of the screen), then a release at the last point.
async fn touch(live: &mut Live, request: &Value) -> Result<(), SessionError> {
    let points: Vec<(u16, u16, u64)> = request["points"]
        .as_array()
        .ok_or_else(|| err("badRequest", "points must be [[x, y, ms], ...]"))?
        .iter()
        .map(|p| {
            let n = |i: usize| p.get(i).and_then(Value::as_f64).unwrap_or(-1.0);
            (n(0), n(1), n(2))
        })
        .map(|(x, y, t)| {
            if (0.0..=65535.0).contains(&x) && (0.0..=65535.0).contains(&y) && t >= 0.0 {
                Ok((x.round() as u16, y.round() as u16, t.round() as u64))
            } else {
                Err(err("badRequest", "x and y must be in 0..=65535, ms >= 0"))
            }
        })
        .collect::<Result<_, _>>()?;
    let Some(&(lx, ly, _)) = points.last() else {
        return Err(err("badRequest", "points is empty"));
    };
    let start = Instant::now();
    for (x, y, at) in points {
        let due = Duration::from_millis(at).saturating_sub(start.elapsed());
        if !due.is_zero() {
            tokio::time::sleep(due).await;
        }
        live.touch.send_touchscreen(TOUCHSCREEN_STATE_CONTACT, x, y, None).await.map_err(input)?;
    }
    live.touch.send_touchscreen(TOUCHSCREEN_STATE_RELEASE, lx, ly, None).await.map_err(input)
}

/// Two fingers around `[cx, cy]` moving from `fromSpan` to `toSpan` apart (normalized units) over `ms`, then lifted.
async fn pinch(live: &mut Live, request: &Value) -> Result<(), SessionError> {
    let n = |k: &str| request[k].as_f64().ok_or_else(|| err("badRequest", format!("{k} is required")));
    let (cx, cy, from, to) = (n("cx")?, n("cy")?, n("fromSpan")?, n("toSpan")?);
    let ms = request["ms"].as_u64().unwrap_or(400).max(50);
    let angle = request["angle"].as_f64().unwrap_or(0.0).to_radians();
    let steps = (ms / 16).max(3);
    let clamp = |v: f64| v.clamp(0.0, 65535.0).round() as u16;
    let contacts = |span: f64, touching: bool| {
        let (dx, dy) = (angle.cos() * span / 2.0, angle.sin() * span / 2.0);
        [
            TouchscreenContact { identity: 0, touching, x: clamp(cx - dx), y: clamp(cy - dy) },
            TouchscreenContact { identity: 1, touching, x: clamp(cx + dx), y: clamp(cy + dy) },
        ]
    };
    for i in 0..=steps {
        let span = from + (to - from) * i as f64 / steps as f64;
        live.touch.send_multitouch(&contacts(span, true), None).await.map_err(input)?;
        tokio::time::sleep(Duration::from_millis(16)).await;
    }
    live.touch.send_multitouch(&contacts(to, false), None).await.map_err(input)
}

/// Taps each `[x, y]` in turn, `intervalMs` apart, in one command.
async fn taps(live: &mut Live, request: &Value) -> Result<(), SessionError> {
    let interval = Duration::from_millis(request["intervalMs"].as_u64().unwrap_or(120));
    let points = request["points"].as_array().ok_or_else(|| err("badRequest", "points must be [[x, y], ...]"))?;
    for (i, p) in points.iter().enumerate() {
        let n = |k: usize| p.get(k).and_then(Value::as_f64).filter(|v| (0.0..=65535.0).contains(v));
        let (Some(x), Some(y)) = (n(0), n(1)) else {
            return Err(err("badRequest", "x and y must be in 0..=65535"));
        };
        let (x, y) = (x.round() as u16, y.round() as u16);
        live.touch.send_touchscreen(TOUCHSCREEN_STATE_CONTACT, x, y, None).await.map_err(input)?;
        tokio::time::sleep(Duration::from_millis(50)).await;
        live.touch.send_touchscreen(TOUCHSCREEN_STATE_RELEASE, x, y, None).await.map_err(input)?;
        if i + 1 < points.len() {
            tokio::time::sleep(interval).await;
        }
    }
    Ok(())
}

async fn press(indigo: &mut IndigoHidClient<Box<dyn ReadWrite>>, usage: u64, held: &[u64]) -> Result<(), SessionError> {
    for &m in held {
        indigo.send_keyboard(m, ButtonState::Down).await.map_err(input)?;
    }
    indigo.send_keyboard(usage, ButtonState::Down).await.map_err(input)?;
    indigo.send_keyboard(usage, ButtonState::Up).await.map_err(input)?;
    for &m in held.iter().rev() {
        indigo.send_keyboard(m, ButtonState::Up).await.map_err(input)?;
    }
    Ok(())
}

async fn type_text(live: &mut Live, request: &Value) -> Result<(), SessionError> {
    let text = request["text"].as_str().ok_or_else(|| err("badRequest", "text is required"))?;
    let gap = Duration::from_millis(request["keyDelayMs"].as_u64().unwrap_or(12));
    let strokes: Vec<(u64, bool)> = text
        .chars()
        .map(|c| keys::usage_for(c).ok_or(c))
        .collect::<Result<_, _>>()
        .map_err(|c| err("unsupportedText", format!("{c:?} has no key on the US keyboard; only printable ASCII can be typed")))?;
    for (usage, shift) in strokes {
        press(&mut live.indigo, usage, if shift { &[keys::LEFT_SHIFT] } else { &[] }).await?;
        tokio::time::sleep(gap).await;
    }
    Ok(())
}

async fn key(live: &mut Live, request: &Value) -> Result<(), SessionError> {
    let name = request["key"].as_str().unwrap_or_default();
    let usage = keys::named(name).ok_or_else(|| err("badRequest", format!("unknown key {name:?}")))?;
    let held: Vec<u64> = request["modifiers"]
        .as_array()
        .map(|m| m.iter().filter_map(Value::as_str).filter_map(keys::modifier).collect())
        .unwrap_or_default();
    for _ in 0..request["count"].as_u64().unwrap_or(1).max(1) {
        press(&mut live.indigo, usage, &held).await?;
        tokio::time::sleep(Duration::from_millis(12)).await;
    }
    Ok(())
}

async fn button(live: &mut Live, request: &Value) -> Result<(), SessionError> {
    let name = request["name"].as_str().unwrap_or_default();
    let (page, usage, hold) = keys::button(name).ok_or_else(|| err("badRequest", format!("unknown button {name:?}")))?;
    live.indigo.send_button(page, usage, ButtonState::Down).await.map_err(input)?;
    tokio::time::sleep(Duration::from_millis(hold)).await;
    live.indigo.send_button(page, usage, ButtonState::Up).await.map_err(input)
}

/// Owns the Instruments connection; a condition stays on only while it is open.
async fn network_task(mut client: RemoteServerClient<Box<dyn ReadWrite>>, mut rx: mpsc::Receiver<NetCmd>) {
    let mut inducer = match ConditionInducerClient::new(&mut client).await {
        Ok(c) => c,
        Err(e) => {
            while let Some(cmd) = rx.recv().await {
                let reply = match cmd {
                    NetCmd::List(r) | NetCmd::On(_, r) | NetCmd::Off(r) => r,
                };
                let _ = reply.send(Err(format!("no condition inducer: {e:?}")));
            }
            return;
        }
    };
    while let Some(cmd) = rx.recv().await {
        match cmd {
            NetCmd::List(reply) => {
                let r = inducer.available_conditions().await.map(|groups| {
                    json!(groups
                        .iter()
                        .flat_map(|g| g.profiles.iter().map(move |p| json!({"group": g.identifier, "profile": p.identifier, "description": p.description})))
                        .collect::<Vec<_>>())
                });
                let _ = reply.send(r.map(|v| json!({"conditions": v})).map_err(|e| format!("{e:?}")));
            }
            NetCmd::On(profile, reply) => {
                let r = match inducer.available_conditions().await {
                    Ok(groups) => match groups.iter().find_map(|g| g.profiles.iter().find(|p| p.identifier == profile).map(|p| (g.identifier.clone(), p.description.clone()))) {
                        Some((group, description)) => inducer
                            .enable_condition(&group, &profile)
                            .await
                            .map(|_| json!({"profile": profile, "description": description}))
                            .map_err(|e| format!("{e:?}")),
                        None => Err(format!("no condition profile {profile:?}; networkList shows them")),
                    },
                    Err(e) => Err(format!("{e:?}")),
                };
                let _ = reply.send(r);
            }
            NetCmd::Off(reply) => {
                let _ = reply.send(inducer.disable_condition().await.map(|_| json!({"off": true})).map_err(|e| format!("{e:?}")));
            }
        }
    }
    let _ = inducer.disable_condition().await;
}
