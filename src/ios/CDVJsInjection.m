#import "CDVJsInjection.h"
#import <Cordova/CDV.h>
#import <Cordova/CDVAvailability.h>
#import "CDVConnection.h"

static NSString* const IOS_PLATFORM = @"ios";
static NSString* const DEFAULT_PLUGIN_MODE = @"client";
static NSString* const DEFAULT_CORDOVA_BASE_URL = @"";

@interface CDVJsInjection ()

@property UIWebView *offlineView;
@property NSString *offlinePage;
@property BOOL enableOfflineSupport;
@property NSURL *failedURL;

@end

@implementation CVDWebViewNotificationDelegate

- (void)webView:(WKWebView*)webView didStartProvisionalNavigation:(WKNavigation*)navigation
{
    [self.wrappedDelegate webView:webView didStartProvisionalNavigation:navigation];

    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kCDVJsInjectionWebViewDidStartLoad object:webView]];
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
    [self.wrappedDelegate webView:webView didFinishNavigation:navigation];

    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kCDVJsInjectionWebViewDidFinishLoad object:webView]];
}
- (void)webView:(WKWebView*)theWebView didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
    [self.wrappedDelegate webView:theWebView didFailProvisionalNavigation:navigation withError:error];
    
    [self webView:theWebView didFailNavigation:navigation withError:error];
}

- (void)webView:(WKWebView*)theWebView didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
    [self.wrappedDelegate webView:theWebView didFailNavigation:navigation withError:error];

    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kCDVJsInjectionWebViewDidFailLoadWithError object:error]];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    [self.wrappedDelegate webViewWebContentProcessDidTerminate:webView];
}

- (void) webView: (WKWebView *) webView decidePolicyForNavigationAction: (WKNavigationAction*) navigationAction decisionHandler: (void (^)(WKNavigationActionPolicy)) decisionHandler
{
    [self.wrappedDelegate webView:webView decidePolicyForNavigationAction:navigationAction decisionHandler:decisionHandler];
}

@end

@implementation CDVJsInjection

- (void)pluginInitialize
{
    [super pluginInitialize];

    // observe notifications from network-information plugin to detect when device is offline
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(networkReachabilityChanged:)
                                                 name:kReachabilityChangedNotification
                                               object:nil];

    // observe notifications from webview when page starts loading
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(webViewDidStartLoad:)
                                                 name:kCDVJsInjectionWebViewDidStartLoad
                                               object:nil];

    // observe notifications from webview when page starts loading
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(webViewDidFinishLoad:)
                                                 name:kCDVJsInjectionWebViewDidFinishLoad
                                               object:nil];

    // observe notifications from webview when page fails loading
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didWebViewFailLoadWithError:)
                                                 name:kCDVJsInjectionWebViewDidFailLoadWithError
                                               object:nil];

    // observe notifications from app when it pauses
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appStateChange)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    // observe notifications from app when it resumes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appStateChange)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    
    // enable offline support by default
    self.enableOfflineSupport = YES;

    // no connection errors on startup
    self.failedURL = nil;

    // set the webview delegate to notify navigation events
    notificationDelegate = [[CVDWebViewNotificationDelegate alloc] init];

    notificationDelegate.wrappedDelegate = ((WKWebView*)self.webView).navigationDelegate;
    [(WKWebView*)self.webView setNavigationDelegate:(id<WKNavigationDelegate>)notificationDelegate];

}

- (void)injectPluginScript:(CDVInvokedUrlCommand*)command
{    
    NSArray* scriptList = @[[command.arguments objectAtIndex:0]];
    BOOL result = [self injectScripts:scriptList];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:result];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (BOOL)injectScripts:(NSArray*)scriptList
{    
    NSString* content = @"";
    for (NSString* scriptName in scriptList)
    {
        NSURL* scriptUrl = [NSURL URLWithString:scriptName relativeToURL:[NSURL URLWithString:@"www/"]];
        NSString* scriptPath = scriptUrl.absoluteString;
        NSError* error = nil;
        NSString* fileContents =  nil;
        if (scriptUrl.scheme == nil)
        {
            fileContents = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:scriptPath ofType:nil] encoding:NSUTF8StringEncoding error:&error];
        }
        else
        {
            fileContents = [NSString stringWithContentsOfURL:scriptUrl encoding:NSUTF8StringEncoding error:&error];
        }
        
        if (error == nil) {
            // prefix with @ sourceURL=<scriptName> comment to make the injected scripts visible in Safari's Web Inspector for debugging purposes
            content = [content stringByAppendingFormat:@"\r\n//@ sourceURL=%@\r\n%@", scriptName, fileContents];
        }
        else {
            NSLog(@"ERROR failed to load script file: '%@'", scriptName);
        }
    }
    
    //return[(UIWebView*)self.webView stringByEvaluatingJavaScriptFromString:content] != nil;
    [(WKWebView*)self.webView evaluateJavaScript:content completionHandler:NULL];
    return TRUE; //HACK: Return result is returned asynchronously, so this really needs to be changed to have a completion callback instead as well 
}

- (BOOL)isMatchingRuleForPage:(NSDictionary*)rule withPlatformCheck:(BOOL)checkPlatform
{
    // ensure rule applies to current platform
    if (checkPlatform)
    {
        BOOL isPlatformMatch = NO;
        NSObject* setting = [rule objectForKey:@"platform"];
        if (setting != nil && [setting isKindOfClass:[NSString class]])
        {
            for (id item in [(NSString*)setting componentsSeparatedByString:@","])
            {
                if ([[item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] caseInsensitiveCompare:IOS_PLATFORM] == NSOrderedSame)
                {
                    isPlatformMatch = YES;
                    break;
                }
            }
            
            if (!isPlatformMatch)
            {
                return NO;
            }
        }
    }
    
    // ensure rule applies to current page
    BOOL isURLMatch = YES;
    NSObject* setting = [rule objectForKey:@"match"];
    if (setting != nil)
    {
        NSArray* match = nil;
        if ([setting isKindOfClass:[NSArray class]])
        {
            match = (NSArray*)setting;
        }
        else if ([setting isKindOfClass:[NSString class]])
        {
            match = [NSArray arrayWithObjects:setting, nil];
        }
        
        if (match != nil)
        {
            CDVWhitelist* whitelist = [[CDVWhitelist alloc] initWithArray:match];
            NSURL* url = ((WKWebView*)self.webView).URL;
            isURLMatch = [whitelist URLIsAllowed:url];
        }
    }
    
    return isURLMatch;
}

// Creates an additional webview to load the offline page, places it above the content webview, and hides it. It will
// be made visible whenever network connectivity is lost.
- (void)createOfflineView
{
    CGRect webViewBounds = self.webView.bounds;

    webViewBounds.origin = self.webView.bounds.origin;

    self.offlineView = [[UIWebView alloc] initWithFrame:webViewBounds];
    self.offlineView.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    [self.offlineView setHidden:YES];

    [self.viewController.view addSubview:self.offlineView];

    NSURL* offlinePageURL = [NSURL URLWithString:self.offlinePage];
    if (offlinePageURL == nil) {
        offlinePageURL = [NSURL URLWithString:@"offline.html"];
    }

    NSString* offlineFilePath = [self.commandDelegate pathForResource:[offlinePageURL path]];
    if (offlineFilePath != nil) {
        offlinePageURL = [NSURL fileURLWithPath:offlineFilePath];
        [self.offlineView loadRequest:[NSURLRequest requestWithURL:offlinePageURL]];
    }
    else {
        NSString* offlinePageTemplate = @"<html><body><div style=\"height:100%;position:absolute;top:0;bottom:0;left:0;right:0;margin:auto 20;font-size:x-large;text-align:center;\">%@</div></body></html>";
        [self.offlineView
            loadHTMLString:[NSString stringWithFormat:offlinePageTemplate, @"It looks like you are offline. Please reconnect to use this application."]
            baseURL:nil];
    }

    [self.viewController.view sendSubviewToBack:self.webView];
}

- (void)networkReachabilityChanged:(NSNotification*)notification
{
    if ([[notification name] isEqualToString:kReachabilityChangedNotification]) {
        CDVReachability* reachability = [notification object];
        [self updateConnectivityStatus:reachability];
    }
}

// Handles notifications from the network-information plugin and shows the offline page whenever
// network connectivity is lost. It restores the original view once the network is up again.
- (void)updateConnectivityStatus:(CDVReachability*)reachability
{
    if ((reachability != nil) && [reachability isKindOfClass:[CDVReachability class]]) {
        BOOL isOffline = (reachability.currentReachabilityStatus == NotReachable);
        NSLog (@"Received a network connectivity change notification. The device is currently %@.", isOffline ? @"offLine" : @"online");
        if (self.enableOfflineSupport) {
            if (isOffline) {
                [self.offlineView setHidden:NO];
            }
            else {
                if (self.failedURL) {
                    [(WKWebView*)self.webView loadRequest:[NSURLRequest requestWithURL:self.failedURL]];
                }
                else {
                    [self.offlineView setHidden:YES];
                }
            }
        }
    }
}

// Handles notifications from the webview delegate whenever a page starts loading.
- (void)webViewDidStartLoad:(NSNotification*)notification
{
    if ([[notification name] isEqualToString:kCDVJsInjectionWebViewDidStartLoad]) {
        NSLog (@"Received a navigation start notification.");
        self.failedURL = nil;
    }
}

// Handles notifications from the webview delegate whenever a page finishes loading.
- (void)webViewDidFinishLoad:(NSNotification*)notification
{
    if ([[notification name] isEqualToString:kCDVJsInjectionWebViewDidFinishLoad]) {
        NSLog (@"Received a navigation completed notification.");
        if (!self.failedURL) {
            [self.offlineView setHidden:YES];
        }
        
        // inject Cordova
        NSString* setting = [self settingForKey:@"JSINJ-PluginMode"];
        NSString* pluginMode = (setting != nil && [setting isKindOfClass:[NSString class]])
            ? [(NSString*)setting stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            : DEFAULT_PLUGIN_MODE;

        setting = [self settingForKey:@"JSINJ-BaseUrl"];
        NSString* cordovaBaseUrl = (setting != nil && [setting isKindOfClass:[NSString class]])
            ? [(NSString*)setting stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            : DEFAULT_CORDOVA_BASE_URL;

        if (![cordovaBaseUrl hasSuffix:@"/"])
        {
            cordovaBaseUrl = [cordovaBaseUrl stringByAppendingString:@"/"];
        }

        NSString* javascript = [NSString stringWithFormat:@"window.jsInjection = { 'platform': '%@', 'pluginMode': '%@', 'cordovaBaseUrl': '%@'};", IOS_PLATFORM, pluginMode, cordovaBaseUrl];
        [(WKWebView*)self.webView evaluateJavaScript:javascript completionHandler:NULL];

        NSMutableArray* scripts = [[NSMutableArray alloc] init];
        if ([pluginMode isEqualToString:@"client"])
        {
            [scripts addObject:@"cordova.js"];
        }

        [scripts addObject:@"plugins/cordova-plugin-wkwebview-engine/src/www/ios/ios-wkwebview-exec.js"];
        [scripts addObject:@"jsinjection-bridge.js"];
        [self injectScripts:scripts];
        
        // inject custom scripts
        setting = [self settingForKey:@"JSINJ-BaseUrl"];
        if (setting != nil && [setting isKindOfClass:[NSArray class]])
        {
            NSArray* customScripts = (NSArray*)setting;
            if (customScripts != nil && customScripts.count > 0)
            {
                for (NSDictionary* item in customScripts)
                {
                    NSString* source = [item valueForKey:@"src"];
                    [self injectScripts:@[source]];
                }
            }
        }
    }
}
// Handles notifications from the webview delegate whenever a page load fails.
- (void)didWebViewFailLoadWithError:(NSNotification*)notification
{
 /*   NSError* error = [notification object];

    if ([[notification name] isEqualToString:kCDVHostedWebAppWebViewDidFailLoadWithError]) {
        NSLog (@"Received a navigation failure notification. error: %@", [error description]);
        if ([error code] == NSURLErrorTimedOut ||
            [error code] == NSURLErrorUnsupportedURL ||
            [error code] == NSURLErrorCannotFindHost ||
            [error code] == NSURLErrorCannotConnectToHost ||
            [error code] == NSURLErrorDNSLookupFailed ||
            [error code] == NSURLErrorNotConnectedToInternet ||
            [error code] == NSURLErrorNetworkConnectionLost) {

            self.failedURL = [NSURL URLWithString:[error.userInfo objectForKey:@"NSErrorFailingURLStringKey"]];

            if (self.enableOfflineSupport) {
                [self.offlineView setHidden:NO];
            }
        }
    }
  */
    UIAlertView * alert =[[UIAlertView alloc ] initWithTitle:@"Load Error"
                                                      message:@"There was an issue contacting the server."
                                                     delegate:self
                                            cancelButtonTitle:@"Close"
                                            otherButtonTitles: nil];
     [alert addButtonWithTitle:@"Try again?"];
     [alert show];

}
#ifndef __CORDOVA_4_0_0
- (BOOL)shouldOverrideLoadWithRequest:(NSURLRequest*)request navigationType:(UIWebViewNavigationType)navigationType
{
    NSURL* url = [request URL];

    if (![self shouldAllowNavigation:url])
    {
        if ([[UIApplication sharedApplication] canOpenURL:url])
        {
            [[UIApplication sharedApplication] openURL:url]; // opens the URL outside the webview
            return YES;
        }
    }
    
    return NO;
}

- (BOOL)shouldAllowNavigation:(NSURL*)url
{
    NSMutableArray* scopeList = [[NSMutableArray alloc] initWithCapacity:0];
    
    // determine base rule based on the start_url and the scope
    NSURL* baseURL = nil;
    NSString* startURL = [self.manifest objectForKey:@"start_url"];
    if (startURL != nil) {
        baseURL = [NSURL URLWithString:startURL];
        NSString* scope = [self.manifest objectForKey:@"scope"];
        if (scope != nil) {
            baseURL = [NSURL URLWithString:scope relativeToURL:baseURL];
        }
    }
    
    if (baseURL != nil) {
        // If there are no wildcards in the pattern, add '*' at the end
        if (![[baseURL absoluteString] containsString:@"*"]) {
            baseURL = [NSURL URLWithString:@"*" relativeToURL:baseURL];
        }
        
        
        // add base rule to the scope list
        [scopeList addObject:[baseURL absoluteString]];
    }
    
    // add additional navigation rules from mjs_access_whitelist
    // TODO: mjs_access_whitelist is deprecated. Should be removed in future versions
    NSObject* setting = [self.manifest objectForKey:@"mjs_access_whitelist"];
    if (setting != nil && [setting isKindOfClass:[NSArray class]])
    {
        NSArray* accessRules = (NSArray*)setting;
        if (accessRules != nil)
        {
            for (NSDictionary* rule in accessRules)
            {
                NSString* accessUrl = [rule objectForKey:@"url"];
                if (accessUrl != nil)
                {
                    [scopeList addObject:accessUrl];
                }
            }
        }
    }
    
    // add additional navigation rules from mjs_extended_scope
    setting = [self.manifest objectForKey:@"mjs_extended_scope"];
    if (setting != nil && [setting isKindOfClass:[NSArray class]])
    {
        NSArray* scopeRules = (NSArray*)setting;
        if (scopeRules != nil)
        {
            for (NSString* rule in scopeRules)
            {
                [scopeList addObject:rule];
            }
        }
    }
    
    return [[[CDVWhitelist alloc] initWithArray:scopeList] URLIsAllowed:url];
}
#endif

// Updates the network connectivity status when the app is paused or resumes
// NOTE: for onPause and onResume, calls into JavaScript must not call or trigger any blocking UI, like alerts
- (void)appStateChange
{
    CDVConnection* connection = [self.commandDelegate getCommandInstance:@"NetworkStatus"];
    [self updateConnectivityStatus:connection.internetReach];
}

//Reads preferences from the configuration.
- (id)settingForKey:(NSString *)key
{
    return [self.commandDelegate.settings objectForKey:[key lowercaseString]];
}

@end