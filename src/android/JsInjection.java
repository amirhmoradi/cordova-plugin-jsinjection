package com.amirhmoradi.jsinjection;

import android.content.Intent;
import android.net.Uri;
import android.content.res.AssetManager;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.ValueCallback;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.LinearLayout;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaActivity;
import org.apache.cordova.CordovaPlugin;

import org.apache.cordova.PluginResult;
import org.apache.cordova.Whitelist;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
* This class manipulates injects cordova js and plugins to webview.
*/
public class JsInjection extends CordovaPlugin {
    private static final String LOG_TAG = "JsInjection";

    private CordovaActivity activity;
    private CordovaPlugin whiteListPlugin;

    private LinearLayout rootLayout;
    private WebView offlineWebView;
    private boolean offlineOverlayEnabled = true;

    private boolean isConnectionError = false;

    @Override
    public void pluginInitialize() {
        final JsInjection me = JsInjection.this;
        this.activity = (CordovaActivity)this.cordova.getActivity();
    }

    @Override
    public boolean execute(String action, JSONArray args, final CallbackContext callbackContext) throws JSONException {
        final JsInjection me = JsInjection.this;

		if (action.equals("injectPluginScript")) {
			final List<String> scripts = new ArrayList<String>();
			scripts.add(args.getString(0));

            cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    injectScripts(scripts, new ValueCallback<String>() {
                        @Override
                        public void onReceiveValue(String s) {
                            callbackContext.success(1);
                        }
                    });
                }
            });

            return true;
		}

        return false;
    }

    @Override
    public Object onMessage(String id, Object data) {
        if (id.equals("networkconnection") && data != null) {
            this.handleNetworkConnectionChange(data.toString());
        } else if (id.equals("onPageStarted")) {
            this.isConnectionError = false;
        } else if (id.equals("onReceivedError")) {
            if (data instanceof JSONObject) {
                JSONObject errorData = (JSONObject) data;
                try {
                    int errorCode = errorData.getInt("errorCode");
                    if (404 == errorCode
                            || WebViewClient.ERROR_HOST_LOOKUP == errorCode
                            || WebViewClient.ERROR_CONNECT == errorCode
                            || WebViewClient.ERROR_TIMEOUT == errorCode) {
                        this.isConnectionError = true;
                        this.showOfflineOverlay();
                    }
                } catch (JSONException e) {
                    e.printStackTrace();
                }
            }
        }
        else if (id.equals("onPageFinished")) {
            if (!this.isConnectionError) {
                this.hideOfflineOverlay();
            }

            if (data != null) {
                String url = data.toString();
                Log.v(LOG_TAG, String.format("Finished loading URL '%s'", url));

                this.injectCordovaScripts(url);
            }
        }

        return null;
    }

    @Override
    public Boolean shouldAllowRequest(String url) {
        CordovaPlugin whiteListPlugin = this.getWhitelistPlugin();

        if (whiteListPlugin != null && Boolean.TRUE != whiteListPlugin.shouldAllowRequest(url)) {
            Log.w(LOG_TAG, String.format("Whitelist rejection: url='%s'", url));
        }

        // do not alter default behavior.
        return super.shouldAllowRequest(url);
    }

    @Override
    public boolean onOverrideUrlLoading(String url) {
        CordovaPlugin whiteListPlugin = this.getWhitelistPlugin();

        if (whiteListPlugin != null && Boolean.TRUE != whiteListPlugin.shouldAllowNavigation(url)) {
            // If the URL is not in the list URLs to allow navigation, open the URL in the external browser
            // (code extracted from CordovaLib/src/org/apache/cordova/CordovaWebViewImpl.java)
            Log.w(LOG_TAG, String.format("Whitelist rejection: url='%s'", url));

            try {
                Intent intent = new Intent(Intent.ACTION_VIEW);
                intent.addCategory(Intent.CATEGORY_BROWSABLE);
                Uri uri = Uri.parse(url);
                // Omitting the MIME type for file: URLs causes "No Activity found to handle Intent".
                // Adding the MIME type to http: URLs causes them to not be handled by the downloader.
                if ("file".equals(uri.getScheme())) {
                    intent.setDataAndType(uri, this.webView.getResourceApi().getMimeType(uri));
                } else {
                    intent.setData(uri);
                }
                this.activity.startActivity(intent);
            } catch (android.content.ActivityNotFoundException e) {
                e.printStackTrace();
            }

            return true;
        } else {
            return false;
        }
    }

    private void injectCordovaScripts(String pageUrl) {

        // Inject cordova scripts
        String pluginMode = webView.getPreferences().getString("JSINJ-PluginMode", "client").trim();
        String cordovaBaseUrl = webView.getPreferences().getString("JSINJ-BaseUrl", "/").trim();
        if (!cordovaBaseUrl.endsWith("/")) {
                                cordovaBaseUrl += "/";
        }

        this.webView.getEngine().loadUrl("javascript: window.jsInjection = { 'platform': 'android', 'pluginMode': '" + pluginMode + "', 'cordovaBaseUrl': '" + cordovaBaseUrl + "'};", false);

        List<String> scriptList = new ArrayList<String>();
        if (pluginMode.equals("client")) {
            scriptList.add("cordova.js");
        }

        scriptList.add("jsinjection-bridge.js");
        injectScripts(scriptList, null);

        // Inject custom scripts
        String customScripts = webView.getPreferences().getString("JSINJ-CustomScripts", "");
        for (String path : customScripts.split(",")) {
            injectScripts(Arrays.asList(new String[]{path.trim()}), null);
        }
    }

    private CordovaPlugin getWhitelistPlugin() {
        if (this.whiteListPlugin == null) {
            this.whiteListPlugin = this.webView.getPluginManager().getPlugin("Whitelist");
        }

        return whiteListPlugin;
    }

    private boolean assetExists(String asset) {
        final AssetManager assetManager = this.activity.getResources().getAssets();
        try {
            return Arrays.asList(assetManager.list("www")).contains(asset);
        } catch (IOException e) {
            e.printStackTrace();
        }

        return false;
    }

    private WebView createOfflineWebView() {
        WebView webView = new WebView(activity);
        webView.getSettings().setJavaScriptEnabled(true);

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.HONEYCOMB) {
            webView.setLayerType(View.LAYER_TYPE_SOFTWARE, null);
        }

        webView.setLayoutParams(new LinearLayout.LayoutParams(
                                                 ViewGroup.LayoutParams.MATCH_PARENT,
                                                 ViewGroup.LayoutParams.MATCH_PARENT,
                                                 1.0F));
        return webView;
    }

    private LinearLayout createOfflineRootLayout() {
        LinearLayout root = new LinearLayout(activity.getBaseContext());
        root.setOrientation(LinearLayout.VERTICAL);
        root.setVisibility(View.INVISIBLE);
        root.setLayoutParams(new LinearLayout.LayoutParams(
                                              ViewGroup.LayoutParams.MATCH_PARENT,
                                              ViewGroup.LayoutParams.MATCH_PARENT,
                                              0.0F));
        return root;
    }

    private void handleNetworkConnectionChange(String info) {
        final JsInjection me = JsInjection.this;
        if (info.equals("none")) {
            this.showOfflineOverlay();
        } else {
            if (this.isConnectionError) {

                this.activity.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        String currentUrl = me.webView.getUrl();
                        me.webView.loadUrlIntoView(currentUrl, false);
                    }
                });
            } else {
                this.hideOfflineOverlay();
            }
        }
    }

    private void showOfflineOverlay() {
        final JsInjection me = JsInjection.this;
        if (this.offlineOverlayEnabled) {
            this.activity.runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    if (me.rootLayout != null) {
                        me.rootLayout.setVisibility(View.VISIBLE);
                    }
                }
            });
        }
    }

    private void hideOfflineOverlay() {
        final JsInjection me = JsInjection.this;
        this.activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (me.rootLayout != null) {
                    me.rootLayout.setVisibility(View.INVISIBLE);
                }
            }
        });
    }

	private void injectScripts(final List<String> files, final ValueCallback<String> resultCallback) {
        final JsInjection me = this;

        this.cordova.getThreadPool().execute(new Runnable() {
            @Override
            public void run() {
                String script = "";
                for (int i = 0; i < files.size(); i++) {
                    String fileName = files.get(i);
                    String content = "";
                    Log.w(LOG_TAG, String.format("Injecting script: '%s'", fileName));

                    try {
                        Uri uri = Uri.parse(fileName);
                        if (uri.isRelative()) {
                            // Load script file from assets
                            try {
                                InputStream inputStream = me.activity.getResources().getAssets().open("www/" + fileName);
                                content = me.ReadStreamContent(inputStream);

                            } catch (IOException e) {
                                Log.v(LOG_TAG, String.format("ERROR: failed to load script file: '%s'", fileName));
                                e.printStackTrace();
                            }
                        } else {
                            // load script file from URL
                            URL url = new URL(fileName);
                            try {
                                HttpURLConnection urlConnection = (HttpURLConnection) url.openConnection();
                                try {
                                    InputStream inputStream = urlConnection.getInputStream();
                                    content = me.ReadStreamContent(inputStream);
                                } finally {
                                    urlConnection.disconnect();
                                }
                            } catch (IOException e) {
                                Log.v(LOG_TAG, String.format("ERROR: failed to load script file from URL: '%s'", fileName));
                                e.printStackTrace();
                            }
                        }
                    } catch (Exception e) {
                        Log.v(LOG_TAG, String.format("ERROR: Invalid path format of script file: '%s'", fileName));
                        e.printStackTrace();
                    }

                    if (!content.isEmpty()) {
                        script += "\r\n//# sourceURL=" + fileName + "\r\n" + content;
                    }
                }

                final String scriptToInject = script;
                me.activity.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        View webView = me.webView.getEngine().getView();

                        try {
                            Method evaluateJavaScriptMethod = webView.getClass().getMethod("evaluateJavascript", new Class[]{ String.class, (Class<ValueCallback<String>>)(Class<?>)ValueCallback.class });
                            evaluateJavaScriptMethod.invoke(webView, scriptToInject, resultCallback);
                        } catch (Exception e) {
                            Log.v(LOG_TAG, String.format("WARNING: Webview does not support 'evaluateJavascript' method. Webview type: '%s'", webView.getClass().getName()));
                            me.webView.getEngine().loadUrl("javascript:" + scriptToInject, false);

                            if (resultCallback != null) {
                                resultCallback.onReceiveValue(null);
                            }
                        }
                    }
                });
            }
        });
    }

    private String ReadStreamContent(InputStream inputStream) throws IOException {
        int size = inputStream.available();
        byte[] bytes = new byte[size];
        inputStream.read(bytes);
        inputStream.close();
        String content = new String(bytes, "UTF-8");

        return content;
    }
}
