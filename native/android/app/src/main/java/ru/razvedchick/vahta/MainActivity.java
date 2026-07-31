package ru.razvedchick.vahta;

import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.WebView;

import com.getcapacitor.BridgeActivity;
import com.getcapacitor.WebViewListener;

import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/**
 * Оболочка ВахтаХоз. Само приложение живёт на сайте (server.url в capacitor.config.json),
 * здесь только то, чего системному WebView не хватает по сравнению с браузером.
 *
 * Сейчас это ровно одна вещь — сохранение файлов (экспорт JSON/CSV/XLSX, шаблон накладной).
 * Подробности в {@link FileDownloadBridge}.
 */
public class MainActivity extends BridgeActivity {

    private FileDownloadBridge downloads;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // bridge == null бывает, если в системе нет пригодного WebView — тогда Capacitor
        // показывает экран-заглушку и делать нам здесь нечего.
        if (bridge == null) return;
        WebView webView = bridge.getWebView();
        if (webView == null) return;

        downloads = new FileDownloadBridge(this, webView, allowedHosts());
        downloads.attach();

        // Шим внедряется в КАЖДУЮ загруженную страницу: document, на котором висит
        // перехватчик клика, пересоздаётся при любой навигации.
        bridge.addWebViewListener(
            new WebViewListener() {
                @Override
                public void onPageLoaded(WebView view) {
                    if (downloads != null) downloads.injectShim();
                }
            }
        );
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode == FileDownloadBridge.REQ_LEGACY_STORAGE) {
            boolean granted = grantResults != null && grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
            if (downloads != null) downloads.onLegacyStoragePermissionResult(granted);
            return;
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
    }

    /**
     * Хосты, которым разрешено сохранять файлы: адрес самого приложения (server.url)
     * плюс список server.allowNavigation из capacitor.config.json. Всё остальное
     * (чужой iframe, случайная внешняя страница) до нативного сохранения не допускается.
     */
    private Set<String> allowedHosts() {
        Set<String> hosts = new HashSet<>();
        addHost(hosts, bridge.getServerUrl());
        addHost(hosts, bridge.getHost());
        String[] allowNavigation = bridge.getConfig().getAllowNavigation();
        if (allowNavigation != null) {
            for (String entry : allowNavigation) {
                addHost(hosts, entry);
            }
        }
        return hosts;
    }

    private static void addHost(Set<String> hosts, String value) {
        if (value == null) return;
        String raw = value.trim();
        if (raw.isEmpty()) return;
        String host = raw.contains("://") ? Uri.parse(raw).getHost() : raw;
        if (host == null) return;
        // маски вида *.example.com в этот список не попадают — сравнение только точное
        if (host.indexOf('*') >= 0) return;
        hosts.add(host.toLowerCase(Locale.ROOT));
    }
}
