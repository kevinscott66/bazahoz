package ru.razvedchick.vahta;

import android.app.Activity;
import android.app.DownloadManager;
import android.content.ActivityNotFoundException;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
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
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Queue;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicBoolean;
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
 * ЧЕСТНО о памяти. Нативная сторона действительно пишет потоком: куски по 256 КБ декодируются
 * во временный файл в кэше и оттуда копируются в «Загрузки». А вот СТРАНИЦА поток не умеет:
 * FileReader.readAsDataURL строит целиком строку base64 (≈1,4 от размера файла) поверх самого
 * blob'а. Поэтому предел MAX_BYTES выставлен по тому, что переживёт отрисовщик бюджетного
 * телефона, а не по тому, что переживёт файловая система: настоящие выгрузки — сотни килобайт,
 * запас тридцатикратный. Вторую полную копию строки (срез после запятой) мы убрали — куски
 * читаются из исходной строки по смещению, — и размер проверяется в странице ДО чтения,
 * пока это ещё дёшево.
 *
 * Пишем в общую папку «Загрузки»: MediaStore.Downloads на Android 10+ (разрешения не нужны),
 * Environment.DIRECTORY_DOWNLOADS на Android 9 и старше (нужен WRITE_EXTERNAL_STORAGE).
 * После записи показываем диалог с ФАКТИЧЕСКИМ именем файла и кнопками «Открыть»/«Поделиться» —
 * иначе человек не понимает, куда делся файл.
 */
public class FileDownloadBridge {

    public static final String JS_INTERFACE_NAME = "AndroidDownloader";
    /** Код запроса WRITE_EXTERNAL_STORAGE. Заведомо не пересекается с кодами плагинов Capacitor. */
    public static final int REQ_LEGACY_STORAGE = 0x7A11;

    private static final String TAG = "VahtaDownload";
    private static final int CHUNK_CHARS = 262144; // кратно 4 → каждый кусок base64 декодируется отдельно

    /**
     * Предел размера выгрузки. Раньше стояло 128 МБ, и это было обещание, которое некому
     * выполнить: страница сначала построила бы ~175 МБ строки base64, а до правки — ещё и
     * её копию, итого около 350 МБ в отрисовщике. Такой отрисовщик система убьёт задолго до
     * нашего предела, то есть предел был недостижим и только вводил в заблуждение.
     * 24 МБ — это ~34 МБ строки в странице: переживает даже слабый телефон, а самая большая
     * реальная выгрузка (XLSX всего склада) — сотни килобайт.
     */
    private static final long MAX_BYTES = 24L * 1024 * 1024;

    /** Сколько незавершённых чтений держим одновременно. Реально нужно одно; четыре — с запасом. */
    private static final int MAX_ACTIVE_JOBS = 4;

    /**
     * Сколько ждём от страницы следующего куска, прежде чем считать задание брошенным.
     * Отсчёт идёт от ПОСЛЕДНЕЙ активности, а не от начала: медленная, но живая передача
     * сторожа не разбудит.
     */
    private static final long JOB_IDLE_TIMEOUT_MS = 60_000L;

    /**
     * Задержка, после которой смена документа считается поводом добить старое задание.
     * Ноль ставить нельзя: onPageFinished может прийти повторно для того же документа
     * (редирект, восстановление истории), и живую передачу мы бы убили сами.
     */
    private static final long PAGE_CHANGE_GRACE_MS = 3_000L;

    private static final String TMP_PREFIX = "vh-download-";
    private static final String TMP_SUFFIX = ".part";
    /** Возраст, после которого .part-файл в кэше точно ничей (процесс убили посреди чтения). */
    private static final long TMP_MAX_AGE_MS = 60L * 60L * 1000L;

    /**
     * Пределы длины имени. Считаем в БАЙТАХ UTF-8, а не в символах: на ext4/FAT ограничение
     * в 255 байт, и 120 кириллических символов — это уже 240 байт плюс расширение.
     */
    private static final int MAX_NAME_BYTES = 200;
    /** Длиннее этого «расширением» точку в конце имени не считаем — это просто точка в тексте. */
    private static final int MAX_EXT_BYTES = 16;

    private final Activity activity;
    private final WebView webView;
    private final Set<String> allowedHosts;
    private final Handler ui = new Handler(Looper.getMainLooper());

    /**
     * Активные чтения. Ключ — разовый непредсказуемый пропуск (см. newJobId): страница получает
     * его только вместе с заданием, поэтому назвать чужой пропуск нельзя.
     */
    private final Map<String, Job> jobs = new ConcurrentHashMap<>();

    private final SecureRandom random = new SecureRandom();

    /**
     * Поколение документа: растёт на каждой загрузке страницы. Задание помнит, в каком поколении
     * родилось, — по этому признаку sweepJobs находит чтения, за которыми уже некому прийти
     * (переход, перезагрузка, уход в другой раздел).
     */
    private final AtomicInteger pageEpoch = new AtomicInteger();

    /**
     * Наш ли сейчас главный фрейм. Считается ТОЛЬКО в UI-потоке (webView.getUrl() из другого
     * потока вызывать нельзя), а обратные вызовы моста — они приходят в потоке JS-моста —
     * читают уже готовое значение.
     */
    private volatile boolean pageTrusted;

    /**
     * Готовые файлы, ждущие разрешения на запись в общие «Загрузки» (только Android 9 и старше).
     *
     * ОЧЕРЕДЬ, а не одна ячейка: два экспорта подряд до выдачи разрешения затирали друг друга,
     * и первый файл пропадал молча — ни сообщения, ни диалога, ни файла.
     *
     * И СТАТИЧЕСКАЯ, а не поле экземпляра: пока висит системный диалог разрешения, наша Activity
     * может быть пересоздана, и ответ придёт уже в НОВЫЙ экземпляр FileDownloadBridge —
     * у него поле экземпляра было бы пустым, обработчик вышел бы впустую, и файл потерялся бы
     * молча. Поворот экрана сюда, кстати, не относится: он перечислен в android:configChanges
     * манифеста и пересоздания не вызывает. А вот смена размера шрифта или плотности экрана,
     * «Не сохранять действия» в меню разработчика и вытеснение фоновой Activity из памяти —
     * вызывают. Процесс при этом остаётся тем же, поэтому статика доживает.
     * Job не держит ссылок на Activity — утечки контекста здесь нет.
     */
    private static final Queue<Job> pendingPermission = new ConcurrentLinkedQueue<>();

    /** Системный диалог разрешения уже показан. Второй requestPermissions поверх него бесполезен. */
    private static final AtomicBoolean permissionAsked = new AtomicBoolean(false);

    private static class Job {
        final String id;
        final int epoch;
        String name;
        String mime;
        File tmp;
        OutputStream out;
        long size;
        /** Момент последней активности, монотонный (nanoTime не прыгает при переводе часов). */
        volatile long touchedNanos = System.nanoTime();
        /** Сторож незавершённого чтения; снимается, как только задание закрыто. */
        volatile Runnable watchdog;

        Job(String id, int epoch, String name) {
            this.id = id;
            this.epoch = epoch;
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
        // Интерфейс достаётся ВСЕМ фреймам документа — ограничить его главным фреймом
        // штатный WebView не умеет (для этого нужен WebViewCompat.addWebMessageListener
        // с allowedOriginRules из androidx.webkit, это другая архитектура моста).
        // Поэтому настоящая защита здесь — непредсказуемый пропуск задания, а не адрес страницы:
        // webView.getUrl() возвращает адрес только ГЛАВНОГО фрейма и чужой фрейм им прикрылся бы.
        webView.addJavascriptInterface(this, JS_INTERFACE_NAME);
        webView.setDownloadListener(
            new DownloadListener() {
                @Override
                public void onDownloadStart(String url, String userAgent, String contentDisposition, String mimeType, long contentLength) {
                    // onDownloadStart всегда приходит в UI-потоке
                    if (url == null) return;
                    if (!refreshPageTrust()) {
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
        // Новый экземпляр Activity — значит, прошлый системный диалог разрешения (если он был)
        // нас уже не касается: ответ на него либо придёт сюда сам, либо не придёт никогда.
        // Флаг сбрасываем, иначе он мог бы остаться поднятым навсегда, и следующий экспорт
        // на Android 9 встал бы в очередь, за которой никто не придёт.
        permissionAsked.set(false);
        sweepOrphanTempFiles();
    }

    /** Внедрить JS-шим. Зовётся из MainActivity на каждое завершение загрузки страницы. */
    public void injectShim() {
        // Документ сменился: перехватчик клика в старом больше не существует, а вместе с ним
        // исчезли и его незавершённые чтения — обработчик успеха уже не позовут никогда.
        // Раньше такое задание оставалось в карте навсегда вместе с открытым потоком записи
        // и временным файлом; повторные «Экспорт» с уходом со страницы копили и то, и другое.
        int epoch = pageEpoch.incrementAndGet();
        boolean trusted = refreshPageTrust();
        sweepJobs(epoch, PAGE_CHANGE_GRACE_MS);
        if (!trusted) return;
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
                    if (!refreshPageTrust()) {
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
        Job job = liveJob(id);
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
            job.tmp = new File(activity.getCacheDir(), TMP_PREFIX + id + TMP_SUFFIX);
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
        Job job = liveJob(id);
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
        // Доверие проверяем и здесь, а не только на входе: между blobStart и blobEnd страница
        // могла уйти на чужой адрес, и записывать в «Загрузки» её результат мы не обязаны.
        if (!pageTrusted) {
            Job stray = takeJob(id);
            if (stray != null) {
                Log.w(TAG, "blobEnd с недоверенной страницы — результат выброшен");
                cleanup(stray);
            }
            return;
        }
        final Job job = takeJob(id);
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
        // Сообщение о неудаче принимаем в любом случае: хуже прибраться, чем оставить мусор.
        Job job = takeJob(id);
        if (job == null) return;
        Log.w(TAG, "Не удалось прочитать blob: " + reason);
        cleanup(job);
        toast("Не удалось сохранить файл: " + reason);
    }

    // ------------------------------------------------------------------ учёт заданий

    /**
     * Проверка, общая для КАЖДОГО обратного вызова из страницы, а не только для входа.
     * Два условия, и оба обязательны:
     *   1) пропуск известен — то есть зовёт тот, кому мы его сами выдали;
     *   2) главный фрейм по-прежнему наш.
     */
    private Job liveJob(String id) {
        if (id == null) return null;
        if (!pageTrusted) {
            Log.w(TAG, "Обратный вызов с недоверенной страницы отклонён");
            return null;
        }
        Job job = jobs.get(id);
        if (job == null) return null;
        job.touchedNanos = System.nanoTime();
        return job;
    }

    /**
     * Снять задание с учёта. Возвращает его ровно одному вызывающему: remove у
     * ConcurrentHashMap атомарен, поэтому двойное завершение (blobEnd и сторож разом)
     * невозможно.
     */
    private Job takeJob(String id) {
        if (id == null) return null;
        Job job = jobs.remove(id);
        if (job != null) cancelWatchdog(job);
        return job;
    }

    private void cancelWatchdog(Job job) {
        Runnable watchdog = job.watchdog;
        job.watchdog = null;
        if (watchdog != null) ui.removeCallbacks(watchdog);
    }

    /**
     * Сторож незавершённого чтения. Нужен потому, что о смерти страницы натив не узнаёт
     * ниоткуда: гибель отрисовщика, закрытие окна, зависший JS — обработчик успеха просто
     * не приходит. Без сторожа задание, поток записи и временный файл жили бы до конца процесса.
     */
    private void armWatchdog(final Job job) {
        Runnable watchdog = new Runnable() {
            @Override
            public void run() {
                long idleMs = (System.nanoTime() - job.touchedNanos) / 1_000_000L;
                if (idleMs < JOB_IDLE_TIMEOUT_MS && jobs.containsKey(job.id)) {
                    // куски всё ещё идут, просто медленно — досыпаем остаток
                    Runnable self = job.watchdog;
                    if (self != null) ui.postDelayed(self, JOB_IDLE_TIMEOUT_MS - idleMs);
                    return;
                }
                abandonJob(job, "страница не ответила");
            }
        };
        job.watchdog = watchdog;
        ui.postDelayed(watchdog, JOB_IDLE_TIMEOUT_MS);
    }

    /**
     * Добить одно задание. Вызывается из UI-потока (сторож): закрытие потока и удаление
     * файла в кэше — это один close и один unlink, на UI-потоке это доли миллисекунды.
     */
    private void abandonJob(Job job, String reason) {
        if (jobs.remove(job.id) == null) return; // успело закрыться само
        cancelWatchdog(job);
        Log.w(TAG, "Задание " + job.id + " брошено: " + reason);
        cleanup(job);
        toast("Не удалось сохранить файл: " + reason);
    }

    /**
     * Подмести чтения, за которыми некому прийти.
     *
     * @param beforeEpoch убирать только задания старше этого поколения документа (0 — любые)
     * @param idleMs      и только те, от которых давно не было ни куска: повторный
     *                    onPageFinished для того же документа не должен рвать живую передачу
     */
    private void sweepJobs(int beforeEpoch, long idleMs) {
        long now = System.nanoTime();
        for (Job job : jobs.values()) {
            if (beforeEpoch > 0 && job.epoch >= beforeEpoch) continue;
            if ((now - job.touchedNanos) / 1_000_000L < idleMs) continue;
            if (jobs.remove(job.id) == null) continue;
            cancelWatchdog(job);
            Log.w(TAG, "Брошенное задание убрано: " + job.id);
            cleanup(job);
        }
    }

    /**
     * Мусор от прошлого запуска. Если процесс убили между blobStart и blobEnd, .part-файл
     * остаётся в кэше и сам не исчезает. Чистим в фоне при старте — но только по-настоящему
     * старые: во время пересоздания Activity этот же метод зовётся заново, а в очереди
     * pendingPermission может лежать свежий файл, который трогать нельзя.
     */
    private void sweepOrphanTempFiles() {
        new Thread(
            new Runnable() {
                @Override
                public void run() {
                    try {
                        File[] files = activity.getCacheDir().listFiles();
                        if (files == null) return;
                        long now = System.currentTimeMillis();
                        for (File file : files) {
                            String name = file.getName();
                            if (!name.startsWith(TMP_PREFIX) || !name.endsWith(TMP_SUFFIX)) continue;
                            if (now - file.lastModified() < TMP_MAX_AGE_MS) continue;
                            if (!file.delete()) Log.w(TAG, "Старый временный файл не удалён: " + name);
                        }
                    } catch (Exception e) {
                        Log.w(TAG, "Уборка кэша не удалась", e);
                    }
                }
            },
            "vh-download-sweep"
        )
            .start();
    }

    // ------------------------------------------------------------------ чтение blob

    /** Только UI-поток. */
    private void startBlobRead(String url, String name) {
        if (jobs.size() >= MAX_ACTIVE_JOBS) {
            // Карта заданий обязана быть ограниченной: без предела повторные нажатия «Экспорт»
            // с уходом со страницы копили бы дескрипторы до конца процесса.
            sweepJobs(0, PAGE_CHANGE_GRACE_MS);
            if (jobs.size() >= MAX_ACTIVE_JOBS) {
                Log.w(TAG, "Слишком много незавершённых сохранений");
                toast("Дождитесь окончания предыдущего сохранения");
                return;
            }
        }
        String id = newJobId();
        Job job = new Job(id, pageEpoch.get(), name);
        jobs.put(id, job);
        armWatchdog(job);
        try {
            webView.evaluateJavascript(readerJs(url, id), null);
        } catch (Exception e) {
            takeJob(id);
            Log.w(TAG, "evaluateJavascript упал", e);
            toast("Не удалось сохранить файл");
        }
    }

    /**
     * Разовый пропуск для страницы. Раньше это были "vh1", "vh2", … — номера предсказуемые,
     * и любой код, у которого есть доступ к интерфейсу моста (а он достаётся всем фреймам
     * документа), мог назвать чужой номер и подмешать свои куски в чужую выгрузку.
     * Теперь 128 случайных бит от SecureRandom: угадать нельзя, знает его только тот,
     * кому мы сами его передали в readerJs.
     */
    private String newJobId() {
        byte[] raw = new byte[16];
        random.nextBytes(raw);
        StringBuilder sb = new StringBuilder("vh");
        for (byte b : raw) {
            sb.append(Character.forDigit((b >> 4) & 0xf, 16));
            sb.append(Character.forDigit(b & 0xf, 16));
        }
        return sb.toString();
    }

    private static String readerJs(String url, String id) {
        return "(function(){var id=" +
        jsString(id) +
        ",u=" +
        jsString(url) +
        ",MAX=" +
        MAX_BYTES +
        ",CH=" +
        CHUNK_CHARS +
        ";" +
        "function fail(m){try{" +
        JS_INTERFACE_NAME +
        ".blobFailed(id,String(m));}catch(e){}}" +
        "try{fetch(u).then(function(r){return r.blob();}).then(function(b){" +
        // размер известен ДО чтения: отказать сейчас дёшево, а построить строку base64
        // на 1,4 размера и убить этим отрисовщик — дорого и молча
        "if(b.size>MAX){fail('файл слишком большой');return;}" +
        "var fr=new FileReader();" +
        "fr.onerror=function(){fail('не читается');};" +
        "fr.onload=function(){try{" +
        "var s=String(fr.result||'');var i=s.indexOf(',');" +
        "if(i<0){fail('пустой файл');return;}" +
        "if(!" +
        JS_INTERFACE_NAME +
        ".blobStart(id,s.slice(0,i)))return;" +
        // читаем ИЗ исходной строки по смещению: s.slice(i+1) создавал вторую полную копию.
        // Смещение куска от начала base64 кратно CH, а CH кратно 4 — значит каждый кусок
        // декодируется независимо, как и раньше.
        "for(var p=i+1;p<s.length;p+=CH){if(!" +
        JS_INTERFACE_NAME +
        ".blobChunk(id,s.substr(p,CH)))return;}" +
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
                // Имя берём ФАКТИЧЕСКОЕ: при совпадении система сама переименовывает файл
                // в «имя (1).xlsx», а повторный экспорт в тот же день — обычное дело.
                // Показывать запрошенное — значит отправить человека искать в «Загрузках» то,
                // чего там нет. На пути для Android 9 так и сделано (out.getName()), здесь —
                // не было.
                showSaved(mediaStoreName(uri, job.name), job.mime, uri, "Загрузки");
                return;
            }
            if (hasLegacyStoragePermission()) {
                publishLegacyPublic(job);
                return;
            }
            // разрешения нет — просим его и ждём ответа, файл уже лежит во временном
            pendingPermission.add(job);
            if (permissionAsked.compareAndSet(false, true)) {
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
            }
        } catch (Exception e) {
            Log.e(TAG, "Ошибка сохранения файла", e);
            cleanup(job);
            toast("Не удалось сохранить файл: " + e.getMessage());
        }
    }

    /** Ответ на запрос WRITE_EXTERNAL_STORAGE (Android 9 и старше). */
    public void onLegacyStoragePermissionResult(final boolean granted) {
        permissionAsked.set(false);
        if (pendingPermission.isEmpty()) return;
        new Thread(
            new Runnable() {
                @Override
                public void run() {
                    // Разбираем ВСЮ очередь: пока показывался системный диалог, человек мог
                    // нажать «Экспорт» ещё раз, и второе задание тоже ждёт этого же ответа.
                    Job job;
                    while ((job = pendingPermission.poll()) != null) {
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
        boolean done = false;
        try {
            OutputStream os = null;
            try {
                os = resolver.openOutputStream(item);
                if (os == null) throw new IllegalStateException("MediaStore не отдал поток записи");
                copy(job.tmp, os);
            } finally {
                closeQuietly(os);
            }
            ContentValues finish = new ContentValues();
            finish.put(MediaStore.MediaColumns.IS_PENDING, 0);
            resolver.update(item, finish, null, null);
            done = true;
            return item;
        } finally {
            if (!done) {
                // Иначе запись навсегда осталась бы с IS_PENDING=1: пользователю она не видна,
                // место занимает, сама не исчезает, и с каждой неудачей таких становится больше.
                try {
                    resolver.delete(item, null, null);
                } catch (Exception e) {
                    Log.w(TAG, "Недописанная запись MediaStore не удалена", e);
                }
            }
        }
    }

    /** Фактическое имя записи в MediaStore — система могла переименовать при совпадении. */
    private String mediaStoreName(Uri item, String fallback) {
        if (item == null) return fallback;
        Cursor cursor = null;
        try {
            cursor = activity.getContentResolver().query(item, new String[] { MediaStore.MediaColumns.DISPLAY_NAME }, null, null, null);
            if (cursor != null && cursor.moveToFirst()) {
                String name = cursor.getString(0);
                if (!TextUtils.isEmpty(name)) return name;
            }
        } catch (Exception e) {
            Log.w(TAG, "Не удалось узнать фактическое имя файла", e);
        } finally {
            closeQuietly(cursor);
        }
        return fallback;
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
        boolean done = false;
        try {
            os = new FileOutputStream(out);
            copy(job.tmp, os);
            done = true;
        } finally {
            closeQuietly(os);
            // Оборвалось копирование (кончилось место, вынули карту) — и в «Загрузках» оставался
            // обрезанный vahtahoz-2026-07-31.xlsx: по имени и наличию неотличимый от целого.
            // Человек открыл бы его через месяц на сверке и получил мусор. Лучше никакого файла,
            // чем тихо испорченный: исключение из copy при этом уходит выше и превращается в
            // честное «Не удалось сохранить файл».
            if (!done && out.exists() && !out.delete()) {
                Log.w(TAG, "Обрезанный файл не удалён: " + out);
            }
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

    /** Пересчитать доверие к главному фрейму и запомнить ответ. Только UI-поток. */
    private boolean refreshPageTrust() {
        boolean trusted = isTrustedPage();
        pageTrusted = trusted;
        return trusted;
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
        name = limitLength(name);
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

    /**
     * Укоротить слишком длинное имя, СОХРАНИВ расширение.
     *
     * Раньше здесь было substring(0, 120), и длинное кириллическое имя теряло «.xlsx» —
     * файл переставал открываться по тапу, потому что система выбирает приложение по расширению.
     * Режем середину-хвост основы, а расширение приклеиваем обратно.
     *
     * Считаем в байтах UTF-8: ограничение файловой системы (255 байт на ext4 и FAT) —
     * байтовое, а кириллица в UTF-8 занимает по два байта на букву.
     */
    private static String limitLength(String name) {
        int dot = name.lastIndexOf('.');
        String base = name;
        String ext = "";
        if (dot > 0) {
            base = name.substring(0, dot);
            ext = name.substring(dot);
            if (utf8Length(ext) > MAX_EXT_BYTES) {
                // не расширение, а просто точка внутри длинного имени — режем как обычный текст
                base = name;
                ext = "";
            }
        }
        int budget = MAX_NAME_BYTES - utf8Length(ext);
        if (budget < 1) return name; // расширение само по себе длиннее лимита — не трогаем
        if (utf8Length(base) <= budget) return name;

        StringBuilder cut = new StringBuilder();
        int used = 0;
        for (int i = 0; i < base.length(); ) {
            int cp = base.codePointAt(i);
            int width = utf8Width(cp);
            if (used + width > budget) break;
            cut.appendCodePoint(cp);
            used += width;
            i += Character.charCount(cp); // по кодовым точкам — иначе можно разрубить суррогатную пару
        }
        String trimmed = cut.toString().trim();
        if (trimmed.isEmpty()) return ext.isEmpty() ? name : ext.substring(1);
        return trimmed + ext;
    }

    private static int utf8Length(String value) {
        return value.getBytes(StandardCharsets.UTF_8).length;
    }

    private static int utf8Width(int codePoint) {
        if (codePoint < 0x80) return 1;
        if (codePoint < 0x800) return 2;
        if (codePoint < 0x10000) return 3;
        return 4;
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
        if (job == null) return;
        if (jobs.remove(job.id) == null) return;
        cancelWatchdog(job);
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
