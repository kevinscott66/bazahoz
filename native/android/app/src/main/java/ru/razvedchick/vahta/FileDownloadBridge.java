package ru.razvedchick.vahta;

import android.app.Activity;
import android.app.DownloadManager;
import android.content.ActivityNotFoundException;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.text.TextUtils;
import android.util.Base64;
import android.util.Log;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.JavascriptInterface;
import android.webkit.MimeTypeMap;
import android.webkit.URLUtil;
import android.webkit.WebView;
import android.widget.Toast;

import androidx.annotation.RequiresApi;
import androidx.appcompat.app.AlertDialog;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Сохранение файлов из WebView — то, чего в Capacitor нет вообще.
 *
 * В системном Android WebView НЕТ менеджера загрузок: клик по <a download href="blob:…">
 * (единственный доступный путь, потому что Web Share API в WebView не реализован —
 * navigator.canShare === undefined) не делает НИЧЕГО. Экспорт JSON/CSV/XLSX и шаблон
 * накладной молча пропадали, а приложение показывало тост «сохранён».
 *
 * Здесь два независимых слоя, второй страхует первый:
 *
 *  1) JS-шим (SHIM_JS) внедряется в каждую загруженную страницу НАШЕГО origin. Он ловит клик
 *     по <a download> с blob:/data:-ссылкой ДО перехода, отдаёт нативному коду ссылку и
 *     настоящее имя файла (blob:-URL имени не несёт — без шима файл назывался бы «downloadfile.bin»)
 *     и отменяет действие по умолчанию только если натив взял загрузку на себя.
 *  2) WebView.setDownloadListener — штатный механизм. Срабатывает, если шим почему-то не
 *     внедрился (ошибка JS, другая страница). Тогда имя берём из Content-Disposition/URLUtil.
 *
 * Содержимое blob читается в самой странице (fetch → FileReader.readAsDataURL) и передаётся
 * сюда кусками по 256 КБ, чтобы не упереться в лимит одной строки JS-моста и не держать
 * весь файл в памяти. Куски декодируются на лету во временный файл в кэше.
 *
 * Пишем в общую папку «Загрузки»: MediaStore.Downloads на Android 10+ (разрешения не нужны),
 * Environment.DIRECTORY_DOWNLOADS на Android 9 и старше (нужен WRITE_EXTERNAL_STORAGE).
 * После записи показываем диалог с именем файла и кнопками «Открыть»/«Поделиться» —
 * иначе человек не понимает, куда делся файл.
 */
public class FileDownloadBridge {

    public static final String JS_INTERFACE_NAME = "AndroidDownloader";
    /** Код запроса WRITE_EXTERNAL_STORAGE. Заведомо не пересекается с кодами плагинов Capacitor. */
    public static final int REQ_LEGACY_STORAGE = 0x7A11;

    private static final String TAG = "VahtaDownload";
    private static final int CHUNK_CHARS = 262144; // кратно 4 → каждый кусок base64 декодируется отдельно
    private static final long MAX_BYTES = 128L * 1024 * 1024;

    private final Activity activity;
    private final WebView webView;
    private final Set<String> allowedHosts;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Map<String, Job> jobs = new ConcurrentHashMap<>();
    private final AtomicInteger seq = new AtomicInteger();

    /**
     * Готовый файл, ждущий разрешения на запись в общие «Загрузки» (только Android 9 и старше).
     * Пишется из потока JS-моста, читается из UI-потока → volatile.
     */
    private volatile Job awaitingPermission;

    private static class Job {
        final String id;
        String name;
        String mime;
        File tmp;
        OutputStream out;
        long size;

        Job(String id, String name) {
            this.id = id;
            this.name = name;
        }
    }

    public FileDownloadBridge(Activity activity, WebView webView, Set<String> allowedHosts) {
        this.activity = activity;
        this.webView = webView;
        this.allowedHosts = allowedHosts == null ? new HashSet<String>() : allowedHosts;
    }

    /** Вызывается один раз из MainActivity.onCreate. */
    public void attach() {
        webView.addJavascriptInterface(this, JS_INTERFACE_NAME);
        webView.setDownloadListener(
            new DownloadListener() {
                @Override
                public void onDownloadStart(String url, String userAgent, String contentDisposition, String mimeType, long contentLength) {
                    // onDownloadStart всегда приходит в UI-потоке
                    if (url == null) return;
                    if (!isTrustedPage()) {
                        Log.w(TAG, "Загрузка с недоверенной страницы отклонена");
                        return;
                    }
                    if (url.startsWith("blob:") || url.startsWith("data:")) {
                        String name = URLUtil.guessFileName(url, contentDisposition, mimeType);
                        startBlobRead(url, name);
                    } else {
                        systemDownload(url, userAgent, contentDisposition, mimeType);
                    }
                }
            }
        );
    }

    /** Внедрить JS-шим. Зовётся из MainActivity на каждое завершение загрузки страницы. */
    public void injectShim() {
        if (!isTrustedPage()) return;
        try {
            webView.evaluateJavascript(SHIM_JS, null);
        } catch (Exception e) {
            Log.w(TAG, "Не удалось внедрить шим загрузок", e);
        }
    }

    // ------------------------------------------------------------------ JS → натив

    /**
     * Шим сообщает о клике по <a download>. true — натив забрал загрузку, страница
     * должна отменить действие по умолчанию.
     */
    @JavascriptInterface
    public boolean startDownload(final String href, final String name) {
        if (href == null) return false;
        if (href.startsWith("blob:")) {
            if (!isAllowedBlobOrigin(href)) return false;
        } else if (!href.startsWith("data:")) {
            return false;
        }
        final String fileName = name == null ? "" : name;
        ui.post(
            new Runnable() {
                @Override
                public void run() {
                    if (!isTrustedPage()) {
                        Log.w(TAG, "startDownload с недоверенной страницы отклонён");
                        return;
                    }
                    startBlobRead(href, fileName);
                }
            }
        );
        return true;
    }

    /** head — заголовок data-URL вида "data:application/json;base64". */
    @JavascriptInterface
    public boolean blobStart(String id, String head) {
        Job job = jobs.get(id);
        if (job == null) return false;
        try {
            String mime = null;
            if (head != null && head.startsWith("data:")) {
                mime = head.substring(5);
                int semi = mime.indexOf(';');
                if (semi >= 0) mime = mime.substring(0, semi);
                mime = mime.trim();
            }
            if (TextUtils.isEmpty(mime)) mime = "application/octet-stream";
            job.mime = mime;
            job.name = sanitizeName(job.name, mime);
            job.tmp = new File(activity.getCacheDir(), "vh-download-" + id + ".part");
            if (job.tmp.exists() && !job.tmp.delete()) {
                Log.w(TAG, "Не удалось удалить старый временный файл");
            }
            job.out = new FileOutputStream(job.tmp);
            return true;
        } catch (Exception e) {
            failJob(job, e.toString());
            return false;
        }
    }

    @JavascriptInterface
    public boolean blobChunk(String id, String base64) {
        Job job = jobs.get(id);
        if (job == null || job.out == null) return false;
        try {
            byte[] data = Base64.decode(base64, Base64.DEFAULT);
            job.size += data.length;
            if (job.size > MAX_BYTES) {
                failJob(job, "файл слишком большой");
                return false;
            }
            job.out.write(data);
            return true;
        } catch (Exception e) {
            failJob(job, e.toString());
            return false;
        }
    }

    @JavascriptInterface
    public void blobEnd(String id) {
        final Job job = jobs.remove(id);
        if (job == null) return;
        try {
            if (job.out != null) {
                job.out.flush();
                job.out.close();
                job.out = null;
            }
        } catch (Exception e) {
            Log.w(TAG, "Ошибка закрытия временного файла", e);
        }
        // мы уже в фоновом потоке JS-моста — копируем файл здесь, не занимая UI
        publish(job);
    }

    @JavascriptInterface
    public void blobFailed(String id, String reason) {
        Job job = jobs.remove(id);
        Log.w(TAG, "Не удалось прочитать blob: " + reason);
        cleanup(job);
        toast("Не удалось сохранить файл: " + reason);
    }

    // ------------------------------------------------------------------ чтение blob

    private void startBlobRead(String url, String name) {
        String id = "vh" + seq.incrementAndGet();
        Job job = new Job(id, name);
        jobs.put(id, job);
        try {
            webView.evaluateJavascript(readerJs(url, id), null);
        } catch (Exception e) {
            jobs.remove(id);
            Log.w(TAG, "evaluateJavascript упал", e);
            toast("Не удалось сохранить файл");
        }
    }

    private static String readerJs(String url, String id) {
        return "(function(){var id=" +
        jsString(id) +
        ",u=" +
        jsString(url) +
        ";" +
        "function fail(m){try{" +
        JS_INTERFACE_NAME +
        ".blobFailed(id,String(m));}catch(e){}}" +
        "try{fetch(u).then(function(r){return r.blob();}).then(function(b){" +
        "var fr=new FileReader();" +
        "fr.onerror=function(){fail('не читается');};" +
        "fr.onload=function(){try{" +
        "var s=String(fr.result||'');var i=s.indexOf(',');" +
        "if(i<0){fail('пустой файл');return;}" +
        "if(!" +
        JS_INTERFACE_NAME +
        ".blobStart(id,s.slice(0,i)))return;" +
        "var d=s.slice(i+1),CH=" +
        CHUNK_CHARS +
        ";" +
        "for(var p=0;p<d.length;p+=CH){if(!" +
        JS_INTERFACE_NAME +
        ".blobChunk(id,d.substr(p,CH)))return;}" +
        JS_INTERFACE_NAME +
        ".blobEnd(id);" +
        "}catch(e){fail(e);}};" +
        "fr.readAsDataURL(b);}).catch(fail);}catch(e){fail(e);}})();";
    }

    private static final String SHIM_JS =
        "(function(){try{" +
        "if(!window." +
        JS_INTERFACE_NAME +
        "||window.__vhDownloadShim)return;" +
        "window.__vhDownloadShim=1;" +
        "document.addEventListener('click',function(e){try{" +
        "var n=e.target,a=null;" +
        "while(n&&n.nodeType===1){if(n.tagName==='A'&&n.hasAttribute('download')){a=n;break;}n=n.parentNode;}" +
        "if(!a)return;" +
        "var h=a.getAttribute('href')||'';" +
        "if(h.slice(0,5)!=='blob:'&&h.slice(0,5)!=='data:')return;" +
        "if(window." +
        JS_INTERFACE_NAME +
        ".startDownload(h,a.getAttribute('download')||''))e.preventDefault();" +
        "}catch(err){}},true);" +
        "}catch(err){}})();";

    // ------------------------------------------------------------------ запись файла

    /** Выполняется в фоновом потоке. */
    private void publish(Job job) {
        if (job.tmp == null || !job.tmp.exists()) {
            toast("Не удалось сохранить файл");
            return;
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Uri uri = writeToMediaStore(job);
                cleanup(job);
                showSaved(job.name, job.mime, uri, "Загрузки");
                return;
            }
            if (hasLegacyStoragePermission()) {
                publishLegacyPublic(job);
                return;
            }
            // разрешения нет — просим его и ждём ответа, файл уже лежит во временном
            awaitingPermission = job;
            ui.post(
                new Runnable() {
                    @Override
                    public void run() {
                        ActivityCompat.requestPermissions(
                            activity,
                            new String[] { android.Manifest.permission.WRITE_EXTERNAL_STORAGE },
                            REQ_LEGACY_STORAGE
                        );
                    }
                }
            );
        } catch (Exception e) {
            Log.e(TAG, "Ошибка сохранения файла", e);
            cleanup(job);
            toast("Не удалось сохранить файл: " + e.getMessage());
        }
    }

    /** Ответ на запрос WRITE_EXTERNAL_STORAGE (Android 9 и старше). */
    public void onLegacyStoragePermissionResult(boolean granted) {
        final Job job = awaitingPermission;
        awaitingPermission = null;
        if (job == null) return;
        new Thread(
            new Runnable() {
                @Override
                public void run() {
                    try {
                        if (granted && hasLegacyStoragePermission()) {
                            publishLegacyPublic(job);
                        } else {
                            publishLegacyPrivate(job);
                        }
                    } catch (Exception e) {
                        Log.e(TAG, "Ошибка отложенного сохранения", e);
                        cleanup(job);
                        toast("Не удалось сохранить файл");
                    }
                }
            },
            "vh-download-publish"
        )
            .start();
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private Uri writeToMediaStore(Job job) throws Exception {
        ContentResolver resolver = activity.getContentResolver();
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, job.name);
        values.put(MediaStore.MediaColumns.MIME_TYPE, job.mime);
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS);
        values.put(MediaStore.MediaColumns.IS_PENDING, 1);
        Uri item = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        if (item == null) throw new IllegalStateException("MediaStore отказал в записи");
        OutputStream os = null;
        try {
            os = resolver.openOutputStream(item);
            if (os == null) throw new IllegalStateException("MediaStore не отдал поток записи");
            copy(job.tmp, os);
        } finally {
            closeQuietly(os);
        }
        ContentValues done = new ContentValues();
        done.put(MediaStore.MediaColumns.IS_PENDING, 0);
        resolver.update(item, done, null, null);
        return item;
    }

    /** Android 9 и старше, разрешение есть: пишем в общий /sdcard/Download. */
    private void publishLegacyPublic(Job job) throws Exception {
        File dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
        if (!dir.exists() && !dir.mkdirs()) {
            publishLegacyPrivate(job);
            return;
        }
        File out = uniqueFile(dir, job.name);
        writeTo(job, out);
        try {
            MediaScannerConnection.scanFile(activity, new String[] { out.getAbsolutePath() }, new String[] { job.mime }, null);
        } catch (Exception e) {
            Log.w(TAG, "scanFile не сработал", e);
        }
        try {
            DownloadManager dm = (DownloadManager) activity.getSystemService(Context.DOWNLOAD_SERVICE);
            if (dm != null) {
                dm.addCompletedDownload(out.getName(), out.getName(), true, job.mime, out.getAbsolutePath(), out.length(), true);
            }
        } catch (Exception e) {
            Log.w(TAG, "addCompletedDownload не сработал", e);
        }
        showSaved(out.getName(), job.mime, fileProviderUri(out), "Загрузки");
    }

    /** Разрешения нет: кладём в собственную папку приложения — она доступна без разрешений. */
    private void publishLegacyPrivate(Job job) throws Exception {
        File dir = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS);
        if (dir == null) dir = new File(activity.getFilesDir(), "downloads");
        if (!dir.exists() && !dir.mkdirs()) throw new IllegalStateException("нет папки для файла");
        File out = uniqueFile(dir, job.name);
        writeTo(job, out);
        showSaved(out.getName(), job.mime, fileProviderUri(out), "папка приложения");
    }

    private void writeTo(Job job, File out) throws Exception {
        OutputStream os = null;
        try {
            os = new FileOutputStream(out);
            copy(job.tmp, os);
        } finally {
            closeQuietly(os);
            cleanup(job);
        }
    }

    private Uri fileProviderUri(File file) {
        try {
            return FileProvider.getUriForFile(activity, activity.getPackageName() + ".fileprovider", file);
        } catch (Exception e) {
            Log.w(TAG, "FileProvider не смог отдать ссылку на файл", e);
            return null;
        }
    }

    // ------------------------------------------------------------------ обычные http-ссылки

    private void systemDownload(String url, String userAgent, String contentDisposition, String mimeType) {
        try {
            DownloadManager dm = (DownloadManager) activity.getSystemService(Context.DOWNLOAD_SERVICE);
            if (dm == null) throw new IllegalStateException("нет менеджера загрузок");
            String name = sanitizeName(URLUtil.guessFileName(url, contentDisposition, mimeType), mimeType);
            DownloadManager.Request req = new DownloadManager.Request(Uri.parse(url));
            if (!TextUtils.isEmpty(mimeType)) req.setMimeType(mimeType);
            if (!TextUtils.isEmpty(userAgent)) req.addRequestHeader("User-Agent", userAgent);
            String cookie = CookieManager.getInstance().getCookie(url);
            if (!TextUtils.isEmpty(cookie)) req.addRequestHeader("cookie", cookie);
            req.setTitle(name);
            req.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
            try {
                req.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name);
            } catch (Exception e) {
                req.setDestinationInExternalFilesDir(activity, Environment.DIRECTORY_DOWNLOADS, name);
            }
            dm.enqueue(req);
            toast("Загрузка: " + name);
        } catch (Exception e) {
            Log.e(TAG, "Не удалось поставить загрузку в очередь", e);
            toast("Не удалось скачать файл");
        }
    }

    // ------------------------------------------------------------------ показ результата

    private void showSaved(final String name, final String mime, final Uri uri, final String where) {
        ui.post(
            new Runnable() {
                @Override
                public void run() {
                    if (activity.isFinishing() || activity.isDestroyed()) {
                        return;
                    }
                    AlertDialog.Builder b = new AlertDialog.Builder(activity);
                    b.setTitle("Файл сохранён");
                    b.setMessage(name + "\n\nГде искать: " + where);
                    b.setNegativeButton("Готово", null);
                    if (uri != null) {
                        b.setPositiveButton(
                            "Поделиться",
                            new android.content.DialogInterface.OnClickListener() {
                                @Override
                                public void onClick(android.content.DialogInterface d, int w) {
                                    shareFile(uri, mime, name);
                                }
                            }
                        );
                        b.setNeutralButton(
                            "Открыть",
                            new android.content.DialogInterface.OnClickListener() {
                                @Override
                                public void onClick(android.content.DialogInterface d, int w) {
                                    openFile(uri, mime);
                                }
                            }
                        );
                    }
                    try {
                        b.show();
                    } catch (Exception e) {
                        Log.w(TAG, "Диалог не показался", e);
                        Toast.makeText(activity, "Сохранено: " + name, Toast.LENGTH_LONG).show();
                    }
                }
            }
        );
    }

    private void openFile(Uri uri, String mime) {
        Intent view = new Intent(Intent.ACTION_VIEW);
        view.setDataAndType(uri, TextUtils.isEmpty(mime) ? "*/*" : mime);
        view.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        Intent chooser = Intent.createChooser(view, "Открыть файл");
        chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try {
            activity.startActivity(chooser);
        } catch (ActivityNotFoundException e) {
            toast("Нет приложения, которое откроет этот файл");
        }
    }

    private void shareFile(Uri uri, String mime, String name) {
        Intent send = new Intent(Intent.ACTION_SEND);
        send.setType(TextUtils.isEmpty(mime) ? "*/*" : mime);
        send.putExtra(Intent.EXTRA_STREAM, uri);
        send.putExtra(Intent.EXTRA_SUBJECT, name);
        send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        Intent chooser = Intent.createChooser(send, "Отправить файл");
        chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try {
            activity.startActivity(chooser);
        } catch (ActivityNotFoundException e) {
            toast("Нет приложения для отправки файла");
        }
    }

    private void toast(final String text) {
        ui.post(
            new Runnable() {
                @Override
                public void run() {
                    Toast.makeText(activity, text, Toast.LENGTH_LONG).show();
                }
            }
        );
    }

    // ------------------------------------------------------------------ мелочи

    private boolean hasLegacyStoragePermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true;
        return (
            ContextCompat.checkSelfPermission(activity, android.Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        );
    }

    /** Страница, на которой сейчас стоит WebView, — наша? Проверять только в UI-потоке. */
    private boolean isTrustedPage() {
        try {
            String current = webView.getUrl();
            if (current == null) return false;
            Uri uri = Uri.parse(current);
            String host = uri.getHost();
            return host != null && allowedHosts.contains(host.toLowerCase(Locale.ROOT));
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * blob:-ссылка несёт origin создавшей её страницы ("blob:https://host/uuid").
     * Не даём чужому фрейму подсунуть свой blob.
     */
    private boolean isAllowedBlobOrigin(String href) {
        try {
            Uri inner = Uri.parse(href.substring("blob:".length()));
            String host = inner.getHost();
            return host != null && allowedHosts.contains(host.toLowerCase(Locale.ROOT));
        } catch (Exception e) {
            return false;
        }
    }

    private static String sanitizeName(String raw, String mime) {
        String name = raw == null ? "" : raw.trim();
        int slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
        if (slash >= 0) name = name.substring(slash + 1);
        name = name.replaceAll("[\\x00-\\x1f\\x7f:*?\"<>|]", "_");
        if (name.startsWith(".")) name = "_" + name;
        if (name.length() > 120) name = name.substring(0, 120);
        if (TextUtils.isEmpty(name)) {
            String ext = null;
            if (!TextUtils.isEmpty(mime)) {
                ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime);
            }
            if (TextUtils.isEmpty(ext)) ext = "bin";
            name = "vahtahoz-" + new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date()) + "." + ext;
        }
        return name;
    }

    private static File uniqueFile(File dir, String name) {
        File file = new File(dir, name);
        if (!file.exists()) return file;
        String base = name;
        String ext = "";
        int dot = name.lastIndexOf('.');
        if (dot > 0) {
            base = name.substring(0, dot);
            ext = name.substring(dot);
        }
        for (int i = 1; i < 1000; i++) {
            File candidate = new File(dir, base + " (" + i + ")" + ext);
            if (!candidate.exists()) return candidate;
        }
        return new File(dir, base + "-" + System.currentTimeMillis() + ext);
    }

    private static void copy(File from, OutputStream to) throws Exception {
        InputStream in = null;
        try {
            in = new FileInputStream(from);
            byte[] buf = new byte[65536];
            int read;
            while ((read = in.read(buf)) > 0) {
                to.write(buf, 0, read);
            }
            to.flush();
        } finally {
            closeQuietly(in);
        }
    }

    private void failJob(Job job, String reason) {
        if (job != null) jobs.remove(job.id);
        Log.w(TAG, "Сохранение прервано: " + reason);
        cleanup(job);
        toast("Не удалось сохранить файл: " + reason);
    }

    private void cleanup(Job job) {
        if (job == null) return;
        closeQuietly(job.out);
        job.out = null;
        if (job.tmp != null && job.tmp.exists() && !job.tmp.delete()) {
            Log.w(TAG, "Временный файл не удалён: " + job.tmp);
        }
    }

    private static void closeQuietly(java.io.Closeable c) {
        if (c == null) return;
        try {
            c.close();
        } catch (Exception e) {
            Log.w(TAG, "Поток не закрылся", e);
        }
    }

    private static String jsString(String value) {
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"':
                    sb.append("\\\"");
                    break;
                case '\\':
                    sb.append("\\\\");
                    break;
                case '\n':
                    sb.append("\\n");
                    break;
                case '\r':
                    sb.append("\\r");
                    break;
                default:
                    if (c < 0x20 || c > 0x7e) {
                        sb.append(String.format(Locale.US, "\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.append('"').toString();
    }
}
