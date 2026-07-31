#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Десктопная обёртка ВахтаХоз: окно поверх живого сайта.
//!
//! Единственная нативная логика — сохранение файлов (экспорт JSON/CSV/XLSX, шаблон накладной).
//! По умолчанию wry (движок Tauri) скачивание разрешает и кладёт файл в системную папку
//! «Загрузки», но делает это МОЛЧА:
//!   * Windows: `args.SetHandled(true)` в webview2 подавляет собственную панель загрузок WebView2;
//!   * Linux/macOS: путь назначения проставляется кодом wry, никакого уведомления нет.
//!
//! Человек нажимает «Экспорт», видит тост «сохранён» — и не знает, где файл.
//!
//! Поэтому окно создаётся здесь, а не в tauri.conf.json: обработчик `on_download`
//! можно повесить только на строитель окна. Обработчик подстраховывает выбор папки
//! и по завершении показывает файл в проводнике/Finder/файловом менеджере.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tauri::webview::DownloadEvent;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

const APP_URL: &str = "https://vahta.razvedchick.ru/vahtahoz.html";

/// Сколько незавершённых загрузок помним одновременно. Реально нужна одна; восемь — с запасом,
/// а предел нужен потому, что о прерванной загрузке событие Finished может не прийти вовсе,
/// и без него список рос бы до конца работы программы.
const MAX_TRACKED_DOWNLOADS: usize = 8;

/// Не чаще одного окна файлового менеджера за это время. Экспорт нескольких файлов подряд —
/// обычное дело (список + накладная), а три открытых окна проводника подряд человек
/// воспринимает как сбой, а не как помощь.
const REVEAL_COOLDOWN: Duration = Duration::from_secs(10);

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let url = tauri::Url::parse(APP_URL).expect("некорректный адрес приложения");

            // Куда пошёл файл — запоминаем на этапе Requested: на macOS событие Finished
            // путь не приносит вообще (ограничение WKDownload, см. документацию wry).
            //
            // Раньше здесь была ОДНА ячейка на все загрузки: при двух скачиваниях подряд
            // вторая перетирала первую, и по завершении первой проводник открывался
            // на чужом файле. Теперь путь привязан к адресу загрузки, который приходит
            // в обоих событиях, — перепутать нечего.
            let pending: Arc<Mutex<HashMap<String, PathBuf>>> = Arc::new(Mutex::new(HashMap::new()));
            // Порядок появления — чтобы при переполнении выкидывать самую старую запись.
            let order: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
            let last_reveal: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));

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
                            remember(&pending, &order, url.as_str(), destination.clone());
                        }
                        DownloadEvent::Finished { url, path, success } => {
                            // Свой путь, а не «последний вообще»: по адресу загрузки
                            // забираем ровно ту запись, которую сами и положили.
                            let saved = path.or_else(|| recall(&pending, &order, url.as_str()));
                            match (success, saved) {
                                (true, Some(file)) => {
                                    eprintln!("ВахтаХоз: сохранено в {}", file.display());
                                    if may_reveal(&last_reveal) {
                                        reveal_in_file_manager(&file);
                                    } else {
                                        eprintln!(
                                            "ВахтаХоз: окно с папкой не открываю — открывал только что"
                                        );
                                    }
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

/// Запомнить, куда пойдёт файл этой загрузки. Список ограничен: событие Finished для
/// оборванной загрузки может не прийти, и без предела записи копились бы навсегда.
fn remember(
    pending: &Mutex<HashMap<String, PathBuf>>,
    order: &Mutex<Vec<String>>,
    url: &str,
    destination: PathBuf,
) {
    let (Ok(mut map), Ok(mut queue)) = (pending.lock(), order.lock()) else {
        return;
    };
    if map.insert(url.to_string(), destination).is_none() {
        queue.push(url.to_string());
    }
    while queue.len() > MAX_TRACKED_DOWNLOADS {
        let oldest = queue.remove(0);
        map.remove(&oldest);
    }
}

/// Забрать запомненный путь ровно этой загрузки.
fn recall(
    pending: &Mutex<HashMap<String, PathBuf>>,
    order: &Mutex<Vec<String>>,
    url: &str,
) -> Option<PathBuf> {
    let (Ok(mut map), Ok(mut queue)) = (pending.lock(), order.lock()) else {
        return None;
    };
    queue.retain(|item| item != url);
    map.remove(url)
}

/// Можно ли сейчас открывать окно файлового менеджера. Заодно отмечает момент открытия.
fn may_reveal(last_reveal: &Mutex<Option<Instant>>) -> bool {
    let Ok(mut last) = last_reveal.lock() else {
        return false;
    };
    let now = Instant::now();
    let allowed = match *last {
        Some(previous) => now.duration_since(previous) >= REVEAL_COOLDOWN,
        None => true,
    };
    if allowed {
        *last = Some(now);
    }
    allowed
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
