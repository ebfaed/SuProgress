//  Copyright 2013 Max Howell. All rights reserved.
//  BSD licensed. See the README.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#define SuProgressBarTag 51381
#define SuProgressBarHeight 2

@protocol SuProgressDelegate
- (void)started:(id)ogre;
- (void)ogre:(id)ogre progressed:(float)progress;
- (void)finished:(id)ogre;
@end

@protocol KingOfDelegates
- (void)progressed:(float)progress;
@end

@interface NSURLConnection (SuProgress)
- (id)SuProgress_initWithRequest:(NSURLRequest *)request delegate:(id)delegate;
@end

@interface SuProgress : NSObject
@property (nonatomic, weak) id<SuProgressDelegate> delegate;
@property (nonatomic) float progress;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL finished;
- (void)reset;
@end

@interface TheKingOfOgres : NSObject <SuProgressDelegate>
+ (id)kingWithDelegate:(id<KingOfDelegates>)delegate;
- (void)addOgre:(SuProgress *)ogre singleUse:(BOOL)singleUse;
@property (nonatomic, readonly) NSMutableArray *ogres;
@property (nonatomic, weak, readonly) id<KingOfDelegates> delegate;
@property (nonatomic, readonly) float progress;
@end

@interface SuProgressBarView : UIView <KingOfDelegates>
@property (nonatomic, readonly) float progress;
@property (nonatomic, strong, readonly) TheKingOfOgres *king;
@end



//TODO make each bar a sublayer (or subview for easier animation control)
//     because if new progress occurs during fadeout it should let old bar
//     fadeout still, and new bar should start over the top, also reduces
//     state machine significantly
//TODO currently we are in the navigationbar and this means we will stay
//     there when the view transitions. Need to work around that.




// this class acts as an NSURLConnectionDelegate proxy
@interface SuProgressNSURLConnection : SuProgress <NSURLConnectionDelegate, NSURLConnectionDataDelegate>
// strong because NSURLConnection treats its delegates as strong
@property (strong, nonatomic) id<NSURLConnectionDelegate, NSURLConnectionDataDelegate> endDelegate;
@end

@interface SuProgressUIWebView : SuProgress <UIWebViewDelegate>
@end



// Used inside SuProgressURLConnectionsCreatedInBlock
// making us not-thread safe, but otherwise fine
// yes globals are horrible, but in this case there
// wasn't another solution I could think of that
// wasn't also ugly AND way more code.
static TheKingOfOgres *SuProgressKing;



@implementation UIViewController (SuProgress)

- (void)SuProgressURLConnectionsCreatedInBlock:(void(^)(void))block {
    Class class = [NSURLConnection class];
    Method original = class_getInstanceMethod(class, @selector(initWithRequest:delegate:));
    Method swizzle = class_getInstanceMethod(class, @selector(SuProgress_initWithRequest:delegate:));

    method_exchangeImplementations(original, swizzle);
    SuProgressKing = [self SuProgressBar].king;
    block();
    SuProgressKing = nil;
    method_exchangeImplementations(swizzle, original);  // put it back
}

static void SuProgressFixTintColor(UIView *bar) {
    CGFloat white, alpha;
    [bar.tintColor getWhite:&white alpha:&alpha];
    if (alpha == 0) {
        NSLog(@"Will not set a completely transparent tintColor, using window.tintColor");
        bar.tintColor = bar.window.tintColor;
        CGFloat white, alpha;
        [bar.tintColor getWhite:&white alpha:&alpha];
        if (alpha == 0) {
            NSLog(@"Will not set a completely transparent tintColor, using blueColor");
            bar.tintColor = [UIColor blueColor];
        }
    }
}

- (SuProgressBarView *)SuProgressBar {
    UIView *bar = nil;
    if (self.navigationController && self.navigationController.navigationBar) {
        UINavigationBar *navbar = self.navigationController.navigationBar;
        bar = [navbar viewWithTag:SuProgressBarTag];
        if (!bar) {
            bar = [SuProgressBarView new];
            bar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
            bar.backgroundColor = navbar.tintColor;
            bar.tag = SuProgressBarTag;
            bar.frame = (CGRect){0, navbar.bounds.size.height - SuProgressBarHeight, 0, SuProgressBarHeight};
            [navbar addSubview:bar];
        }
    } else {
        NSLog(@"Sorry dude, I haven't written code that supports showing progress in this configuration yet! Fork and help?");
    }

    SuProgressFixTintColor(bar);
    return (id)bar;
}

- (void)SuProgressForWebView:(UIWebView *)webView {
    SuProgressUIWebView *ogre = [SuProgressUIWebView new];
    ogre.delegate = [self SuProgressBar].king;
    [[self SuProgressBar].king addOgre:ogre singleUse:NO];
    webView.delegate = ogre;
}

@end




enum SuProgressBarViewState {
    SuProgressBarViewReady,
    SuProgressBarViewProgressing,
    SuProgressBarViewFinishing
};




@implementation SuProgressBarView {
    enum SuProgressBarViewState state;
    NSDate *startTime;
    NSDate *lastIncrementTime;
    NSDate *waitAtLeastUntil;
}

- (id)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _king = [TheKingOfOgres kingWithDelegate:self];
    }
    return self;
}

- (void)becomeFinished {
    state = SuProgressBarViewFinishing;

    [UIView animateWithDuration:0.1 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        // if we are already filled, then CoreAnimation is smart and this
        // block will finish instantly
        self.frame = (CGRect){0, self.frame.origin.y, self.superview.bounds.size.width, SuProgressBarHeight};
    } completion:^(BOOL finished) {
        if (!finished)
            return;

        NSTimeInterval dt = [[NSDate date] timeIntervalSinceDate:startTime];
        NSTimeInterval dt2 = [waitAtLeastUntil timeIntervalSinceNow];
        NSTimeInterval delay = dt2 < 0 ? -dt2 : MAX(0, 1. - dt);

        [UIView animateWithDuration:0.4 delay:delay options:0 animations:^{
            self.alpha = 0;
        } completion:^(BOOL finished) {
            if (finished)
                self.frame = (CGRect){self.frame.origin, 0, self.frame.size.height};
        }];
    }];
}

- (void)progressed:(float)progress {
    if (state == SuProgressBarViewFinishing)
        // finishing animation is happening. We are going to just override
        // that, then in finishing animation completion handler we will notice
        // and stop finishing
        state = SuProgressBarViewReady;
    
    if (state == SuProgressBarViewReady) {
        startTime = [NSDate date];
        lastIncrementTime = waitAtLeastUntil = nil;
        state = SuProgressBarViewProgressing;
        self.frame = (CGRect){self.frame.origin, 0, self.frame.size.height};
    }
    
    if (progress == 1.f) {
        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        [self becomeFinished];
    } else {
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    
        CGSize sz = self.superview.bounds.size;
        NSTimeInterval duration = 0.3;
        NSTimeInterval delay = MIN(0.01, [[NSDate date] timeIntervalSinceDate:lastIncrementTime]);
        int opts = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationCurveEaseIn;
        [UIView animateWithDuration:duration delay:delay options:opts animations:^{
            self.alpha = 1;
            self.frame = (CGRect){self.frame.origin, sz.width * progress, SuProgressBarHeight};
        } completion:nil];

        waitAtLeastUntil = [NSDate dateWithTimeIntervalSinceNow:delay + duration];
        lastIncrementTime = [NSDate date];
    }
}

- (float)progress {
    return _king.progress;
}

@dynamic progress;
@end




@implementation TheKingOfOgres {
    // We trickle a little when jobs start to indicate
    // progress and trickle ocassionally to indicate that
    // stuff is still happening, so the actual portion of
    // the width that is available for actual progress is
    // less than one.
    NSMutableArray *singleUses;
}

+ (id)kingWithDelegate:(id<KingOfDelegates>)delegate {
    TheKingOfOgres *king = [TheKingOfOgres new];
    king->_delegate = delegate;
    king->_ogres = [NSMutableArray new];
    king->singleUses = [NSMutableArray new];
    return king;
}

- (void)addOgre:(SuProgress *)ogre singleUse:(BOOL)singleUse {
    ogre.delegate = self;
    if (_progress == 0.f) {
        self.progress = 0.05f; // do an initial trickle (yes, now)
    }
    [_ogres addObject:ogre];
    if (singleUse)
        [singleUses addObject:ogre];
}

- (void)setProgress:(float)newprogress {
    //TODO when you return make it so the progress portion of 0.8 is hardcoded
    // and then we can always know that > 0.9 should have exponential fall off
    // and then implement that!
    // AND THEN fix it so it isn't doing that anymore

    if (newprogress < _progress) {
        NSLog(@"Won't set progress to %f as it's less than current value (%f)", newprogress, _progress);
        return;
    }
    _progress = MIN(1.f, MAX(0.f, newprogress));
    [_delegate progressed:_progress];
}

- (void)started:(SuProgress *)ogre {
    if (_progress == 0.05f) {
        // a second initial trickle, for eg. NSURLConnection we
        // do this at header response, and thus gives more
        // progress feedback
        self.progress = 0.1f;
    }
}

- (void)ogre:(SuProgress *)ogre progressed:(float)progress {
    // TODO should reported-progress for any ogre go > 1
    // we should still drip, but in tiny amounts since we
    // will then exceed 90%

    self.progress += (progress / (float)_ogres.count) * 0.8;
}

- (void)finished:(SuProgress *)ogre {
    for (id ogre in _ogres)
        if (![ogre finished])
            return;

    self.progress = 1.f;

    [_ogres removeObjectsInArray:singleUses];
    [_ogres makeObjectsPerformSelector:@selector(reset)];
    [singleUses removeAllObjects];
    _progress = 0.f;  // don't use setter ∵ don't tell delegate
}

@end




@implementation SuProgress

// FIXME bit dumb to allow setting started to false considering
// this is an invalid state in fact. Same for finished. Needs enum.
- (void)setStarted:(BOOL)started {
    _started = started;
    if (started) {
        [_delegate started:self];
    }
}

- (void)setFinished:(BOOL)finished {
    _finished = finished;
    if (finished) {
        _progress = 1;
        [_delegate finished:self];
    }
}

- (void)reset {
    _started = NO;
    _finished = NO;
    _progress = 0.f;
}

@end




@implementation SuProgressNSURLConnection {
    long long total_bytes;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)rsp {
    if (rsp.statusCode == 200) {
        total_bytes = [rsp.allHeaderFields[@"Content-Length"] intValue];
        if ([rsp.allHeaderFields[@"Content-Encoding"] isEqual:@"gzip"]) {
            // Oh man, we get the data back UNgzip'd, and the total figure is
            // for bytes of content to expect! So we'll guestimate and x4 it
            // FIXME anyway to get a better solution? Probably not without private API
            // or AFNetworking.
            total_bytes *= 4;
        }
    } else {
        //TODO error!
    }
    self.started = YES;
    
    if ([_endDelegate respondsToSelector:@selector(connection:didReceiveResponse:)])
        [_endDelegate connection:connection didReceiveResponse:rsp];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    float f = total_bytes
            ? (float)data.length / (float)(total_bytes)
            // we can't know how big the content is TODO but we
            // could start adding a lot and get smaller as we
            // guess the rate and amounts a little
            : 0.01;

    [self.delegate ogre:self progressed:f];
    self.progress += f;

    if (self.progress > 1.f)
        NSLog(@"maxd: %f", self.progress);

    if ([_endDelegate respondsToSelector:@selector(connection:didReceiveData:)])
        [_endDelegate connection:connection didReceiveData:data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    self.finished = YES;
    if ([_endDelegate respondsToSelector:@selector(connection:didFailWithError:)])
        [_endDelegate connection:connection didFailWithError:error];
}

- (void)connectionDidFinishLoading:(id)connection {
    self.finished = YES;
    if ([_endDelegate respondsToSelector:@selector(connectionDidFinishLoading:)])
        [_endDelegate connectionDidFinishLoading:connection];
}

@end




@implementation NSURLConnection (Debug)

- (id)SuProgress_initWithRequest:(NSURLRequest *)request delegate:(id)delegate
{
    // Our ogre acts as an NSURLConnectionDelegate proxy, and filters
    // progress to our progress bar as its intermediary step.
    SuProgressNSURLConnection *ogre = [SuProgressNSURLConnection new];
    ogre.endDelegate = delegate;
    [SuProgressKing addOgre:ogre singleUse:YES];

    // looks weird? Google: objectivec swizzling
    return [self SuProgress_initWithRequest:request delegate:ogre];
}

@end




// Inspired by: https://github.com/ninjinkun/NJKWebViewProgress

#define SuProgressUIWebViewCompleteRPCURL "webviewprogressproxy:///complete"

@implementation SuProgressUIWebView {
    NSUInteger _loadingCount;
    NSUInteger _maxLoadCount;
    NSURL *_currentURL;
    BOOL _interactive;
}

- (void)incrementProgress {
    float progress = self.progress;
    float maxProgress = _interactive ? 1.f : 0.5f;
    float remainPercent = (float)_loadingCount / (float)_maxLoadCount;
    float increment = (maxProgress - progress) * remainPercent;

    [self.delegate ogre:self progressed:increment];
    self.progress += increment;
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType {
    if ([request.URL.absoluteString isEqualToString:@SuProgressUIWebViewCompleteRPCURL]) {
        self.finished = YES;
        return NO;
    }
    
    BOOL isFragmentJump = NO;
    if (request.URL.fragment) {
        NSString *nonFragmentURL = [request.URL.absoluteString stringByReplacingOccurrencesOfString:[@"#" stringByAppendingString:request.URL.fragment] withString:@""];
        isFragmentJump = [nonFragmentURL isEqualToString:webView.request.URL.absoluteString];
    }
    
    BOOL isTopLevelNavigation = [request.mainDocumentURL isEqual:request.URL];
    
    BOOL isHTTP = [request.URL.scheme isEqualToString:@"http"] || [request.URL.scheme isEqualToString:@"https"];
    if (!isFragmentJump && isHTTP && isTopLevelNavigation) {
        _currentURL = request.URL;
    }
    return YES;
}

- (void)webViewDidStartLoad:(UIWebView *)webView {
    _loadingCount++;
    _maxLoadCount = fmax(_maxLoadCount, _loadingCount);
    
    self.started = YES;
    [self.delegate started:self];
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    _loadingCount--;
    [self incrementProgress];
    
    NSString *readyState = [webView stringByEvaluatingJavaScriptFromString:@"document.readyState"];
    
    BOOL interactive = [readyState isEqualToString:@"interactive"];
    if (interactive) {
        _interactive = YES;
        // this callsback on webView:shouldStartLoadWithRequest:navigationType
        // when it has finished executing, indicating to us that loading has
        // completed (sorta, images usually still flicker in)
        [webView stringByEvaluatingJavaScriptFromString:@"window.addEventListener('load',function() { var iframe = document.createElement('iframe'); iframe.style.display = 'none'; iframe.src = '" SuProgressUIWebViewCompleteRPCURL "'; document.body.appendChild(iframe);  }, false);"];
    }
    
    BOOL isNotRedirect = [_currentURL isEqual:webView.request.mainDocumentURL];
    BOOL complete = [readyState isEqualToString:@"complete"];
    if (complete && isNotRedirect) {
        self.finished = YES;
    }
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    [self webViewDidFinishLoad:webView];
}

@end
