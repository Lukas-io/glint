mod keys;
mod session;

use serde_json::{Value, json};
use session::{Session, SessionError};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

/// Must equal `expectedDeviceHidProtocol` in lib/src/interaction/device_hid.dart.
const PROTOCOL: u32 = 6;

/// The display stream that unlocks input is dropped after this long without a command.
const IDLE_STREAM: Duration = Duration::from_secs(120);

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("version") {
        println!("glint-devicehid protocol {PROTOCOL}");
        return;
    }
    let Some(udid) = args.iter().position(|a| a == "--udid").and_then(|i| args.get(i + 1)) else {
        eprintln!("usage: glint-devicehid --udid <udid>");
        std::process::exit(2);
    };
    let mut out = tokio::io::stdout();
    let mut session = match Session::connect(udid).await {
        Ok(s) => s,
        Err(e) => {
            emit(&mut out, &failure(&e)).await;
            std::process::exit(1);
        }
    };
    if args.iter().any(|a| a == "status") {
        match session.stream_status().await {
            Ok(s) => println!("{s}"),
            Err(e) => emit(&mut out, &failure(&e)).await,
        }
        return;
    }
    emit(&mut out, &json!({"ready": PROTOCOL})).await;

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    loop {
        let line = tokio::select! {
            line = lines.next_line() => line,
            _ = tokio::time::sleep(IDLE_STREAM), if session.streaming() && !session.recording() => {
                session.stop_stream().await;
                continue;
            }
        };
        let Ok(Some(line)) = line else { break };
        let Ok(request) = serde_json::from_str::<Value>(&line) else {
            emit(&mut out, &json!({"ok": false, "kind": "badRequest", "error": "not JSON"})).await;
            continue;
        };
        if request["cmd"] == "quit" {
            break;
        }
        let reply = match session.handle(&request).await {
            Ok(extra) => {
                let mut ok = json!({"ok": true});
                if let (Some(o), Value::Object(e)) = (ok.as_object_mut(), extra) {
                    o.extend(e);
                }
                ok
            }
            Err(e) => failure(&e),
        };
        emit(&mut out, &reply).await;
    }
    session.network_off().await;
    session.stop_stream().await;
}

fn failure(e: &SessionError) -> Value {
    json!({"ok": false, "kind": e.kind, "error": e.detail})
}

async fn emit(out: &mut tokio::io::Stdout, value: &Value) {
    let _ = out.write_all(format!("{value}\n").as_bytes()).await;
    let _ = out.flush().await;
}
