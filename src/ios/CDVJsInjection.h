#import <Cordova/CDVPlugin.h>
#import <WebKit/WebKit.h>

#define kManifestLoadedNotification @"kManifestLoadedNotification"

#define kCDVJsInjectionWebViewDidStartLoad @"CDVJsInjectionWebViewDidStartLoad"
#define kCDVJsInjectionWebViewShouldStartLoadWithRequest @"CDVJsInjectionWebViewShouldStartLoadWithRequest"
#define kCDVJsInjectionWebViewDidFinishLoad @"CDVJsInjectionWebViewDidFinishLoad"
#define kCDVJsInjectionWebViewDidFailLoadWithError @"CDVJsInjectionWebViewDidFailLoadWithError"

@interface CVDWebViewNotificationDelegate : NSObject <WKNavigationDelegate>
    @property (nonatomic,retain) id<WKNavigationDelegate> wrappedDelegate;
@end

@interface CDVJsInjection : CDVPlugin
{
    CVDWebViewNotificationDelegate* notificationDelegate;
}


- (void)injectPluginScript:(CDVInvokedUrlCommand*)command;

@end