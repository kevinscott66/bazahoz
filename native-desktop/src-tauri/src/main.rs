#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Десктопная обёртка ВахтаХоз: окно поверх живого сайта.
//!
//! Единственная нативная логика — сохранение файлов (экспорт JSON/CSV/XLSX, шаблон накладной).
//! По умолчанию wry (движок Tauri) скачивание разрешает и кладёт файл в системную папку
//! «Загрузки», но делает это МОЛЧА:
//!   * Windows: `args.SetHandled(true)` в webview2 подавляет собственную панель загрузок WebView2;
//!   * Linux/macOS: путь назначения проставляется кодом wry, никакого уведомления нет.
//! Человек нажимает «Экспорт», видит тост «сохранён» — и не знает, где файл.
//!
//! Поэтому окно создаётся здесь, а не в tauri.conf.json: обработчик `on_download`
//! можно повесить только на строитель окна. Обработчик подстраховывает выбор папки
//! и по завершении показывает файл в проводнике/Finder/файловом менеджере.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use tauri::webview::DownloadEvent;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

const APP_URL: &str = "https://vahta.razvedchick.ru/vahtahoz.html";

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let url = tauri::Url::parse(APP_URL).expect("некорректный адрес приложения");
            // Куда пошёл файл — запоминаем на этапе Requested: на macOS событие Finished
            // путь не приносит вообще (ограничение WKDownload, см. документацию wry).
            let last_destination: Arc<Mutex<Option<PathBuf>>> = Arc::new(Mutex::new(None));

            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url))
                .title("ВахтаХоз")
                .inner_size(1100.0, 800.0)
                .resizable(true)
                .on_download(move |webview, event| {
                    match event {
                        DownloadEvent::Requested { url, destination } => {
                            // wry сам подставляет системную папку «Загрузки» и дописывает «(1)»
                            // при совпадении имён. Но если папку определить не удалось, он
                            // берёт текущий рабочий каталог — у установленного приложения это
                            // может быть каталог только для чтения. Тогда чиним путь сами.
                            let parent_ok = destination
                                .parent()
                                .map(|parent| parent.is_dir())
                                .unwrap_or(false);
                            if !parent_ok {
                                if let Ok(downloads) = webview.path().download_dir() {
                                    let name = destination
                                        .file_name()
                                        .map(PathBuf::from)
                                        .unwrap_or_else(|| PathBuf::from("vahtahoz-export"));
                                    *destination = downloads.join(name);
                                }
                            }
                            eprintln!("ВахтаХоз: скачиваю {url} → {}", destination.display());
                            if let Ok(mut slot) = last_destination.lock() {
                                *slot = Some(destination.clone());
                            }
                        }
                        DownloadEvent::Finished { path, success, .. } => {
                            let saved = path.or_else(|| {
                                last_destination.lock().ok().and_then(|slot| slot.clone())
                            });
                            match (success, saved) {
                                (true, Some(file)) => {
                                    eprintln!("ВахтаХоз: сохранено в {}", file.display());
                                    reveal_in_file_manager(&file);
                                }
                                (true, None) => eprintln!("ВахтаХоз: файл сохранён"),
                                (false, _) => eprintln!("ВахтаХоз: скачивание не удалось"),
                            }
                        }
                        _ => {}
                    }
                    // true — разрешаем скачивание (поведение обычного браузера)
                    true
                })
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running ВахтаХоз");
}

/// Открыть папку с сохранённым файлом — иначе человек не понимает, куда делся экспорт.
/// Любая ошибка здесь некритична: файл уже на диске.
fn reveal_in_file_manager(file: &Path) {
    #[cfg(target_os = "windows")]
    {
        let _ = std::process::Command::new("explorer")
            .arg(format!("/select,{}", file.display()))
            .spawn();
    }
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open")
            .arg("-R")
            .arg(file)
            .spawn();
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let folder = file.parent().unwrap_or(file);
        let _ = std::process::Command::new("xdg-open").arg(folder).spawn();
    }
}
