// CacaoTuneLibrary Windows 版の Rust 側。外部プロセス（yt-dlp / ffmpeg / curl / tar）の起動と、ファイルの操作を受け持つ。
// 画面と、yt-dlp の出力の読み取りは src/main.ts（TypeScript）。
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

/// 動いている yt-dlp（ジョブ ID → 子プロセス）
#[derive(Default)]
struct Running(Arc<Mutex<HashMap<String, Child>>>);

#[cfg(target_os = "windows")]
fn hide_console(cmd: &mut Command) {
    // 黒いコンソール窓を出さない（CREATE_NO_WINDOW）。tokio の Command が同名のメソッドを持つ
    cmd.creation_flags(0x0800_0000);
}
#[cfg(not(target_os = "windows"))]
fn hide_console(_cmd: &mut Command) {}

/// yt-dlp（PyInstaller 版の Python）に標準出力を UTF-8 で書かせる。
/// 日本語 Windows では既定が cp932 で、題名が文字化けするうえ、Rust 側の行読みが止まる
fn utf8_env(cmd: &mut Command) {
    cmd.env("PYTHONIOENCODING", "utf-8").env("PYTHONUTF8", "1");
}

/// パイプを 1 行ずつ読む。UTF-8 でないバイトが混ざっても「�」に置き換えて読み続ける。
/// `lines()` は不正なバイトで Err を返して読み取りが終わり、パイプが閉じて
/// yt-dlp 側が "[Errno 22] Invalid argument" で落ちるので使わない
async fn read_lines_lossy<R: tokio::io::AsyncRead + Unpin>(r: R, tx: tokio::sync::mpsc::UnboundedSender<String>) {
    let mut reader = BufReader::new(r);
    let mut buf: Vec<u8> = Vec::new();
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                let s = String::from_utf8_lossy(&buf);
                let _ = tx.send(s.trim_end_matches(['\n', '\r']).to_string());
            }
        }
    }
}

fn exe_name(base: &str) -> String {
    if cfg!(target_os = "windows") { format!("{base}.exe") } else { base.to_string() }
}

/// アプリが落としてきた道具を置く場所（Windows: %LOCALAPPDATA%\CacaoTuneLibrary\tools）
fn tools_dir(app: &AppHandle) -> PathBuf {
    app.path().app_local_data_dir().map(|d| d.join("tools")).unwrap_or_else(|_| PathBuf::from("tools"))
}

/// PATH と、Mac の Homebrew の場所から探す
fn find_in_path(name: &str) -> Option<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    for extra in ["/opt/homebrew/bin", "/usr/local/bin"] {
        dirs.push(PathBuf::from(extra));
    }
    dirs.into_iter().map(|d| d.join(name)).find(|p| p.is_file())
}

fn locate(app: &AppHandle, base: &str, custom: &str) -> Option<PathBuf> {
    let custom = custom.trim();
    if !custom.is_empty() {
        let p = PathBuf::from(custom);
        return if p.is_file() { Some(p) } else { None };
    }
    let name = exe_name(base);
    let local = tools_dir(app).join(&name);
    if local.is_file() { return Some(local); }
    find_in_path(&name)
}

#[derive(Serialize, Default)]
struct ToolStatus {
    ytdlp: Option<String>,
    ffmpeg: Option<String>,
    deno: Option<String>,
    version: Option<String>,
    tools_dir: String,
    can_install: bool,
}

/// 道具の場所と yt-dlp のバージョン
#[tauri::command]
async fn tool_status(app: AppHandle, ytdlp_path: String, ffmpeg_path: String) -> ToolStatus {
    let ytdlp = locate(&app, "yt-dlp", &ytdlp_path);
    let ffmpeg = locate(&app, "ffmpeg", &ffmpeg_path);
    let deno = locate(&app, "deno", "");
    let version = match &ytdlp {
        Some(p) => run_capture_inner(p.to_string_lossy().to_string(), vec!["--version".into()], 20).await.ok()
            .filter(|r| r.code == Some(0)).map(|r| r.output.trim().to_string()),
        None => None,
    };
    ToolStatus {
        ytdlp: ytdlp.map(|p| p.to_string_lossy().to_string()),
        ffmpeg: ffmpeg.map(|p| p.to_string_lossy().to_string()),
        deno: deno.map(|p| p.to_string_lossy().to_string()),
        version,
        tools_dir: tools_dir(&app).to_string_lossy().to_string(),
        can_install: cfg!(target_os = "windows"),
    }
}

#[derive(Serialize)]
struct Captured { code: Option<i32>, output: String }

async fn run_capture_inner(exe: String, args: Vec<String>, timeout_sec: u64) -> Result<Captured, String> {
    let mut cmd = Command::new(&exe);
    cmd.args(&args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    utf8_env(&mut cmd);
    hide_console(&mut cmd);
    let fut = cmd.output();
    let out = tokio::time::timeout(std::time::Duration::from_secs(timeout_sec), fut)
        .await.map_err(|_| format!("{} が {} 秒たっても終わりません", exe, timeout_sec))?
        .map_err(|e| format!("{} を起動できません: {}", exe, e))?;
    let mut text = String::from_utf8_lossy(&out.stdout).to_string();
    let err = String::from_utf8_lossy(&out.stderr);
    if !err.trim().is_empty() {
        if !text.is_empty() && !text.ends_with('\n') { text.push('\n'); }
        text.push_str(&err);
    }
    Ok(Captured { code: out.status.code(), output: text })
}

/// 短く終わるコマンドを実行して出力を返す（先読み・ffprobe・更新など）
#[tauri::command]
async fn run_capture(exe: String, args: Vec<String>, timeout_sec: u64) -> Result<Captured, String> {
    run_capture_inner(exe, args, timeout_sec).await
}

#[derive(Serialize, Clone)]
struct DlLine { job_id: String, line: String }
#[derive(Serialize, Clone)]
struct DlDone { job_id: String, code: Option<i32>, error: Option<String> }

/// yt-dlp を起動し、出力を 1 行ずつ "dl-line" で送る。終わったら "dl-done"
#[tauri::command]
async fn start_download(app: AppHandle, running: State<'_, Running>, job_id: String, exe: String, args: Vec<String>, cwd: String) -> Result<(), String> {
    let mut cmd = Command::new(&exe);
    cmd.args(&args).current_dir(&cwd).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    utf8_env(&mut cmd);
    hide_console(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("yt-dlp を起動できません: {}", e))?;
    let stdout = child.stdout.take().ok_or("stdout")?;
    let stderr = child.stderr.take().ok_or("stderr")?;
    running.0.lock().unwrap().insert(job_id.clone(), child);

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    // 2 本のパイプを別々に読む
    let tx1 = tx.clone();
    tokio::spawn(async move { read_lines_lossy(stdout, tx1).await });
    tokio::spawn(async move { read_lines_lossy(stderr, tx).await });

    let map = running.0.clone();
    let app2 = app.clone();
    let jid = job_id.clone();
    tokio::spawn(async move {
        while let Some(l) = rx.recv().await {
            for piece in l.split('\r') {
                let t = piece.trim();
                if !t.is_empty() {
                    let _ = app2.emit("dl-line", DlLine { job_id: jid.clone(), line: t.to_string() });
                }
            }
        }
        // 両方のパイプが閉じた＝終わった
        let child = map.lock().unwrap().remove(&jid);
        let (code, error) = match child {
            Some(mut c) => match c.wait().await {
                Ok(st) => (st.code(), None),
                Err(e) => (None, Some(e.to_string())),
            },
            None => (None, Some("中止".into())),
        };
        let _ = app2.emit("dl-done", DlDone { job_id: jid, code, error });
    });
    Ok(())
}

/// 動いている yt-dlp を止める
#[tauri::command]
async fn cancel_download(running: State<'_, Running>, job_id: String) -> Result<(), String> {
    let child = running.0.lock().unwrap().remove(&job_id);
    if let Some(mut c) = child {
        let _ = c.kill().await;
        let _ = c.wait().await;
    }
    Ok(())
}

#[derive(Serialize, Clone)]
struct ToolsProgress { message: String }

fn emit_progress(app: &AppHandle, msg: impl Into<String>) {
    let _ = app.emit("tools-progress", ToolsProgress { message: msg.into() });
}

/// curl で落とす（Windows 10 以降には curl.exe が入っている）。大きさをときどき知らせる
async fn curl_download(app: &AppHandle, url: &str, dest: &Path, label: &str) -> Result<(), String> {
    let mut cmd = Command::new("curl");
    cmd.args(["-L", "--fail", "--silent", "--show-error", "-o"]).arg(dest).arg(url).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    hide_console(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("curl を起動できません: {}", e))?;
    let stderr = child.stderr.take();
    loop {
        tokio::select! {
            st = child.wait() => {
                let st = st.map_err(|e| e.to_string())?;
                if !st.success() {
                    let mut msg = String::new();
                    if let Some(mut e) = stderr { use tokio::io::AsyncReadExt; let _ = e.read_to_string(&mut msg).await; }
                    return Err(format!("{} のダウンロードに失敗しました: {}", label, msg.trim()));
                }
                return Ok(());
            }
            _ = tokio::time::sleep(std::time::Duration::from_millis(700)) => {
                if let Ok(m) = tokio::fs::metadata(dest).await {
                    emit_progress(app, format!("{} をダウンロード中… {:.1} MB", label, m.len() as f64 / 1_048_576.0));
                }
            }
        }
    }
}

/// zip から 1 つだけ取り出す（Windows 10 以降の tar.exe = bsdtar）
async fn tar_extract(zip: &Path, member: &str, dest_dir: &Path, strip: usize) -> Result<(), String> {
    let mut cmd = Command::new("tar");
    cmd.arg("-xf").arg(zip).arg("-C").arg(dest_dir).arg("--strip-components").arg(strip.to_string()).arg(member)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    hide_console(&mut cmd);
    let out = cmd.output().await.map_err(|e| format!("tar を起動できません: {}", e))?;
    if !out.status.success() {
        return Err(format!("{} を取り出せません: {}", member, String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(())
}

/// Windows: yt-dlp.exe・ffmpeg（ffprobe も）・deno を GitHub の公式リリースから落として tools に置く
#[tauri::command]
async fn install_tools(app: AppHandle) -> Result<ToolStatus, String> {
    if !cfg!(target_os = "windows") {
        return Err("この機能は Windows 用です。Mac では brew install yt-dlp ffmpeg を使ってください。".into());
    }
    let dir = tools_dir(&app);
    tokio::fs::create_dir_all(&dir).await.map_err(|e| format!("{}: {}", dir.display(), e))?;

    // 1. yt-dlp
    emit_progress(&app, "yt-dlp をダウンロード中…");
    curl_download(&app, "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe", &dir.join("yt-dlp.exe"), "yt-dlp").await?;

    // 2. ffmpeg（yt-dlp チームのビルド。zip の中の bin/ffmpeg.exe と bin/ffprobe.exe だけ使う）
    let zip = dir.join("ffmpeg.zip");
    curl_download(&app, "https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip", &zip, "ffmpeg").await?;
    emit_progress(&app, "ffmpeg を取り出し中…");
    tar_extract(&zip, "ffmpeg-master-latest-win64-gpl/bin/ffmpeg.exe", &dir, 2).await?;
    tar_extract(&zip, "ffmpeg-master-latest-win64-gpl/bin/ffprobe.exe", &dir, 2).await?;
    let _ = tokio::fs::remove_file(&zip).await;

    // 3. deno（yt-dlp が YouTube の解析に使う JavaScript の実行環境）
    let dzip = dir.join("deno.zip");
    curl_download(&app, "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip", &dzip, "deno").await?;
    emit_progress(&app, "deno を取り出し中…");
    tar_extract(&dzip, "deno.exe", &dir, 0).await?;
    let _ = tokio::fs::remove_file(&dzip).await;

    emit_progress(&app, "準備ができました");
    Ok(tool_status(app, String::new(), String::new()).await)
}

#[derive(Serialize)]
struct LibFile { path: String, channel: String, name: String, ext: String }

/// 保存先の中の m4a / mp3（直下と、1 段下のチャンネルフォルダ）
#[tauri::command]
fn scan_library(folder: String) -> Vec<LibFile> {
    fn is_audio(p: &Path) -> bool {
        matches!(p.extension().and_then(|e| e.to_str()).map(|e| e.to_lowercase()).as_deref(), Some("m4a") | Some("mp3"))
    }
    fn push(out: &mut Vec<LibFile>, p: &Path, channel: &str) {
        out.push(LibFile {
            path: p.to_string_lossy().to_string(),
            channel: channel.to_string(),
            name: p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
            ext: p.extension().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
        });
    }
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(&folder) else { return out };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with('.') { continue; }
        if p.is_dir() {
            if let Ok(rd2) = std::fs::read_dir(&p) {
                for f in rd2.flatten() {
                    let fp = f.path();
                    if fp.is_file() && is_audio(&fp) { push(&mut out, &fp, &name); }
                }
            }
        } else if is_audio(&p) {
            push(&mut out, &p, "");
        }
    }
    out
}

#[derive(Deserialize)]
struct MovePair { from: String, to: String }
#[derive(Serialize)]
struct MoveResult { from: String, ok: bool, error: Option<String> }

/// ファイルを移す・名前を変える。隣の同名 jpg も一緒に。移し先が既にあれば失敗
#[tauri::command]
fn move_files(pairs: Vec<MovePair>) -> Vec<MoveResult> {
    pairs.into_iter().map(|p| {
        let from = PathBuf::from(&p.from);
        let to = PathBuf::from(&p.to);
        if to.exists() && from != to {
            return MoveResult { from: p.from, ok: false, error: Some("移し先に同じ名前のファイルがあります".into()) };
        }
        if let Some(dir) = to.parent() { let _ = std::fs::create_dir_all(dir); }
        match std::fs::rename(&from, &to) {
            Ok(()) => {
                for ext in ["jpg", "jpeg", "png"] {
                    let side = from.with_extension(ext);
                    if side.is_file() { let _ = std::fs::rename(&side, to.with_extension(ext)); }
                }
                MoveResult { from: p.from, ok: true, error: None }
            }
            Err(e) => MoveResult { from: p.from, ok: false, error: Some(e.to_string()) },
        }
    }).collect()
}

#[tauri::command]
fn path_exists(path: String) -> bool { Path::new(&path).exists() }

#[tauri::command]
fn ensure_dir(path: String) -> Result<(), String> {
    std::fs::create_dir_all(&path).map_err(|e| format!("{}: {}", path, e))
}

#[tauri::command]
fn remove_file(path: String) -> Result<(), String> {
    std::fs::remove_file(&path).map_err(|e| e.to_string())
}

/// 既定の保存先（Windows: ミュージック\CacaoTuneLibrary、Mac: ~/Music/YouTube）
#[tauri::command]
fn default_folder() -> String {
    let music = dirs::audio_dir().or_else(dirs::home_dir).unwrap_or_else(|| PathBuf::from("."));
    let sub = if cfg!(target_os = "windows") { "CacaoTuneLibrary" } else { "YouTube" };
    music.join(sub).to_string_lossy().to_string()
}

/// 動作確認用: 環境変数 CACAOTUNELIBRARY_FOLDER があれば、その保存先を使う（設定には保存しない）
#[tauri::command]
fn folder_override() -> Option<String> {
    std::env::var("CACAOTUNELIBRARY_FOLDER").ok().filter(|s| !s.is_empty())
}

/// 動作確認用: 環境変数 CACAOTUNELIBRARY_SEARCH があれば、起動と同時にその語で検索窓を開く
#[tauri::command]
fn search_override() -> Option<String> {
    std::env::var("CACAOTUNELIBRARY_SEARCH").ok().filter(|s| !s.is_empty())
}

/// エクスプローラ（Finder）でそのファイルを選んで見せる
#[tauri::command]
async fn reveal(path: String) -> Result<(), String> {
    let mut cmd = if cfg!(target_os = "windows") {
        let mut c = Command::new("explorer");
        c.arg(format!("/select,{}", path));
        c
    } else if cfg!(target_os = "macos") {
        let mut c = Command::new("open");
        c.arg("-R").arg(&path);
        c
    } else {
        let mut c = Command::new("xdg-open");
        c.arg(Path::new(&path).parent().map(|p| p.to_string_lossy().to_string()).unwrap_or(path.clone()));
        c
    };
    hide_console(&mut cmd);
    cmd.spawn().map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(Running::default())
        .invoke_handler(tauri::generate_handler![
            tool_status, run_capture, start_download, cancel_download, install_tools,
            scan_library, move_files, path_exists, ensure_dir, remove_file, default_folder, folder_override, search_override, reveal
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
